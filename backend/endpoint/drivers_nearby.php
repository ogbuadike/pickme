<?php
declare(strict_types=1);

/**
 * POST drivers_nearby.php — online, idle drivers around a point (session required).
 *
 * Query plan: bounding box on ride_driver_locations (idx_rdl_lat_lng / idx_rdl_updated) with a
 * freshness cut-off, joined to ride_drivers by PK, busy drivers excluded via
 * idx_rr_driver_status (driver_id, status); haversine is only evaluated on the boxed rows.
 * Driver PII (phone, NIN) is never returned here — keys are kept (empty) for client compatibility.
 */

require_once __DIR__ . '/security.php';

const SEARCH_RADIUS_KM = 50.0;
const EARTH_RADIUS_KM  = 6371.0;
const DRIVER_LOCATION_FRESH_SEC = 90; // no ghost cars

$uid = pm_require_session(['drivers' => []]);
$in = pm_input();

$lat      = pm_in_float($in, 'lat', 0.0);
$lng      = pm_in_float($in, 'lng', 0.0);
$tripKm   = max(0.0, pm_in_float($in, 'trip_km', 0.0));
$currency = strtoupper(pm_in_str($in, 'currency', 3, 'NGN'));
$rideType = pm_in_enum($in, 'ride_type', ['street_ride', 'campus_ride', 'dispatch', 'send_me'], 'street_ride');

if (!pm_valid_lat($lat) || !pm_valid_lng($lng)) {
    pm_json(['error' => true, 'code' => 'VALIDATION', 'message' => 'lat/lng required', 'drivers' => []], 200);
}

$reqRadius = pm_in_float($in, 'radius_km', SEARCH_RADIUS_KM);
$radius = ($reqRadius > 0 && $reqRadius <= SEARCH_RADIUS_KM) ? $reqRadius : SEARCH_RADIUS_KM;
[$minLat, $maxLat, $minLng, $maxLng] = pm_bbox($lat, $lng, $radius);

$active = PM_RIDE_ACTIVE_STATUSES;
$sql = "
SELECT * FROM (
    SELECT d.id, d.name, d.category, d.rating, d.car_plate, d.`rank`, d.completed_trips, d.cancelled_trips,
           d.incomplete_trips, d.reviews_count, d.total_trips, d.vehicle_type, d.seats, d.vehicle_description,
           d.vehicle_images, d.car_image_url, d.avatar_url, d.price_per_km, d.base_fare, d.currency,
           l.lat, l.lng, l.heading, l.updated_at,
           (? * 2 * ASIN(LEAST(1, SQRT(
                POWER(SIN(RADIANS(? - l.lat) / 2), 2) +
                COS(RADIANS(?)) * COS(RADIANS(l.lat)) * POWER(SIN(RADIANS(? - l.lng) / 2), 2)
           )))) AS distance_km
    FROM ride_driver_locations l
    INNER JOIN ride_drivers d ON d.id = l.driver_id
    WHERE l.lat BETWEEN ? AND ?
      AND l.lng BETWEEN ? AND ?
      AND l.updated_at > NOW() - INTERVAL " . DRIVER_LOCATION_FRESH_SEC . " SECOND
      AND l.lat <> 0 AND l.lng <> 0
      AND d.is_online = 1
      AND FIND_IN_SET(?, IFNULL(d.allowed_ride_types, 'street_ride')) > 0
      AND NOT EXISTS (
          SELECT 1 FROM ride_rides rr
          WHERE rr.driver_id = d.id AND rr.status IN (" . pm_in_placeholders($active) . ")
      )
) AS nearby
WHERE nearby.distance_km <= ?
ORDER BY nearby.distance_km ASC, nearby.updated_at DESC
LIMIT 200";

$rows = pm_q_all(
    $sql,
    'dddddddds' . str_repeat('s', count($active)) . 'd',
    array_merge(
        [EARTH_RADIUS_KM, $lat, $lat, $lng, $minLat, $maxLat, $minLng, $maxLng, $rideType],
        $active,
        [$radius]
    )
);

$drivers = [];
foreach ($rows as $r) {
    $dist = (float)$r['distance_km'];
    $vehicleImages = json_decode((string)($r['vehicle_images'] ?? '[]'), true);
    if (!is_array($vehicleImages)) {
        $vehicleImages = [];
    }
    $carImage = (string)($r['car_image_url'] ?? '');
    if ($vehicleImages === [] && $carImage !== '') {
        $vehicleImages = [$carImage];
    }
    $ppk  = (float)($r['price_per_km'] ?? 0);
    $base = (float)($r['base_fare'] ?? 0);
    $drivers[] = [
        'id'                  => (string)$r['id'],
        'name'                => (string)($r['name'] ?? ''),
        'category'            => (string)($r['category'] ?? ''),
        'rating'              => (float)($r['rating'] ?? 0),
        'car_plate'           => (string)($r['car_plate'] ?? ''),
        'lat'                 => (float)$r['lat'],
        'lng'                 => (float)$r['lng'],
        'heading'             => (float)($r['heading'] ?? 0),
        'distance_km'         => round($dist, 3),
        'eta_min'             => max(1, (int)round($dist / 0.4)),
        'vehicle_type'        => (string)($r['vehicle_type'] ?? 'car'),
        'seats'               => (int)($r['seats'] ?? 4),
        'vehicle_images'      => $vehicleImages,
        'vehicle_description' => (string)($r['vehicle_description'] ?? ''),
        'car_image_url'       => $carImage,
        'avatar_url'          => (string)($r['avatar_url'] ?? ''),
        'phone'               => '', // shared only after acceptance (ride_status / ride_history)
        'nin'                 => '', // never exposed
        'rank'                => (string)($r['rank'] ?? ''),
        'completed_trips'     => (int)($r['completed_trips'] ?? 0),
        'cancelled_trips'     => (int)($r['cancelled_trips'] ?? 0),
        'incomplete_trips'    => (int)($r['incomplete_trips'] ?? 0),
        'reviews_count'       => (int)($r['reviews_count'] ?? 0),
        'total_trips'         => (int)($r['total_trips'] ?? 0),
        'currency'            => (string)($r['currency'] ?: ($currency !== '' ? $currency : 'NGN')),
        'price_per_km'        => $ppk,
        'base_fare'           => $base,
        'trip_km'             => $tripKm,
        'estimated_total'     => ($tripKm > 0 && $ppk > 0) ? ($base + $ppk * $tripKm) : 0.0,
    ];
}

pm_json([
    'error'            => false,
    'cursor'           => time(),
    'radius_km'        => $radius,
    'returned_drivers' => count($drivers),
    'drivers'          => $drivers,
]);
