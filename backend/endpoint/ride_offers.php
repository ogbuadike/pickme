<?php
declare(strict_types=1);

/**
 * POST ride_offers.php — price offers from nearby online drivers (session required).
 * Body: origin{lat,lng}, destination{lat,lng}, optional radius_km (<= 50). JSON or form
 * (form callers may send origin_lat/origin_lng/destination_lat/destination_lng).
 * Bounding-box pre-filter, then haversine; busy drivers excluded.
 */

require_once __DIR__ . '/security.php';

const OFFERS_MAX_RADIUS_KM = 50.0;
const OFFERS_FRESH_MIN = 15;

pm_require_session(['offers' => []]);
$in = pm_input();

$o = is_array($in['origin'] ?? null) ? $in['origin'] : [];
$d = is_array($in['destination'] ?? null) ? $in['destination'] : [];
$olat = pm_in_float($o, 'lat', pm_in_float($in, ['origin_lat', 'lat'], 0.0));
$olng = pm_in_float($o, 'lng', pm_in_float($in, ['origin_lng', 'lng'], 0.0));
$dlat = pm_in_float($d, 'lat', pm_in_float($in, ['destination_lat', 'dest_lat'], 0.0));
$dlng = pm_in_float($d, 'lng', pm_in_float($in, ['destination_lng', 'dest_lng'], 0.0));
$radius = pm_in_float($in, 'radius_km', OFFERS_MAX_RADIUS_KM);
$radius = ($radius > 0 && $radius <= OFFERS_MAX_RADIUS_KM) ? $radius : OFFERS_MAX_RADIUS_KM;

if (!pm_valid_lat($olat) || !pm_valid_lng($olng) || !pm_valid_lat($dlat) || !pm_valid_lng($dlng)) {
    pm_json(['error' => true, 'code' => 'VALIDATION', 'message' => 'origin/destination required', 'offers' => []], 200);
}

$distPickDest = pm_haversine_m($olat, $olng, $dlat, $dlng) / 1000.0;
[$minLat, $maxLat, $minLng, $maxLng] = pm_bbox($olat, $olng, $radius);
$active = PM_RIDE_ACTIVE_STATUSES;

$rows = pm_q_all(
    'SELECT * FROM (
        SELECT d.id, d.name, d.category, d.rating, d.car_plate, l.lat, l.lng,
               (6371 * 2 * ASIN(LEAST(1, SQRT(POWER(SIN(RADIANS(? - l.lat) / 2), 2) +
                COS(RADIANS(?)) * COS(RADIANS(l.lat)) * POWER(SIN(RADIANS(? - l.lng) / 2), 2))))) AS distance_km
        FROM ride_driver_locations l
        JOIN ride_drivers d ON d.id = l.driver_id
        WHERE l.lat BETWEEN ? AND ? AND l.lng BETWEEN ? AND ?
          AND l.updated_at >= NOW() - INTERVAL ' . OFFERS_FRESH_MIN . ' MINUTE
          AND d.is_online = 1
          AND NOT EXISTS (SELECT 1 FROM ride_rides rr WHERE rr.driver_id = d.id AND rr.status IN (' . pm_in_placeholders($active) . '))
     ) x
     WHERE x.distance_km <= ?
     ORDER BY x.distance_km ASC
     LIMIT 30',
    'ddddddd' . str_repeat('s', count($active)) . 'd',
    array_merge([$olat, $olat, $olng, $minLat, $maxLat, $minLng, $maxLng], $active, [$radius])
);

$offers = [];
foreach ($rows as $r) {
    $cat = (string)$r['category'];
    $mult = ($cat === 'XL') ? 1.8 : (($cat === 'Comfort') ? 1.35 : 1.0);
    $price = 500.0 + ($distPickDest * 120.0 * $mult);
    $offers[] = [
        'id'          => $r['id'] . '-' . $cat,
        'provider'    => 'Pick Me',
        'category'    => $cat,
        'price'       => round($price, 0),
        'eta_min'     => max(1, (int)round(((float)$r['distance_km']) / 0.4)),
        'seats'       => ($cat === 'XL' ? 6 : 4),
        'surge'       => false,
        'driver_id'   => (string)$r['id'],
        'driver_name' => (string)$r['name'],
        'rating'      => (float)$r['rating'],
        'car_plate'   => (string)$r['car_plate'],
    ];
}

pm_json(['error' => false, 'offers' => $offers]);
