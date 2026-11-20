<?php
declare(strict_types=1);

/**
 * POST drivers_poll.php — incremental driver map updates since `cursor` (unix seconds). Session required.
 * Optional lat/lng/radius_km limit the result to a bounding box (strongly recommended).
 * upserts: drivers whose location changed since cursor (idx_rdl_updated + bbox)
 * deletes: drivers that went offline or became busy since cursor (bounded by updated_at)
 */

require_once __DIR__ . '/security.php';

const POLL_MAX_RADIUS_KM = 50.0;

pm_require_session(['upserts' => [], 'deletes' => []]);
$in = pm_input();

$now = time();
$cursor = pm_in_int($in, 'cursor', 0);
if ($cursor <= 0 || $cursor > $now || $cursor < $now - 3600) {
    $cursor = $now - 5;
}
$since = date('Y-m-d H:i:s', $cursor - 2); // small overlap for clock skew

$lat = pm_in_float($in, 'lat', 0.0);
$lng = pm_in_float($in, 'lng', 0.0);
$radius = pm_in_float($in, 'radius_km', POLL_MAX_RADIUS_KM);
$radius = ($radius > 0 && $radius <= POLL_MAX_RADIUS_KM) ? $radius : POLL_MAX_RADIUS_KM;
$useBox = pm_valid_lat($lat) && pm_valid_lng($lng);

$active = PM_RIDE_ACTIVE_STATUSES;
$activeIn = pm_in_placeholders($active);
$activeTypes = str_repeat('s', count($active));

$sql = "SELECT d.id, d.name, d.category, d.rating, d.car_plate, l.lat, l.lng, l.heading
        FROM ride_driver_locations l
        JOIN ride_drivers d ON d.id = l.driver_id
        WHERE l.updated_at > ?
          AND d.is_online = 1
          AND l.lat <> 0 AND l.lng <> 0";
$types = 's';
$params = [$since];
if ($useBox) {
    [$minLat, $maxLat, $minLng, $maxLng] = pm_bbox($lat, $lng, $radius);
    $sql .= ' AND l.lat BETWEEN ? AND ? AND l.lng BETWEEN ? AND ?';
    $types .= 'dddd';
    array_push($params, $minLat, $maxLat, $minLng, $maxLng);
}
$sql .= " AND NOT EXISTS (SELECT 1 FROM ride_rides rr WHERE rr.driver_id = d.id AND rr.status IN ($activeIn)) LIMIT 500";
$rows = pm_q_all($sql, $types . $activeTypes, array_merge($params, $active));

$upserts = [];
foreach ($rows as $r) {
    $upserts[] = [
        'id'        => (string)$r['id'],
        'name'      => (string)$r['name'],
        'category'  => (string)$r['category'],
        'rating'    => (float)$r['rating'],
        'car_plate' => (string)$r['car_plate'],
        'lat'       => (float)$r['lat'],
        'lng'       => (float)$r['lng'],
        'heading'   => (float)$r['heading'],
    ];
}

$deleteRows = pm_q_all(
    "SELECT d.id FROM ride_drivers d WHERE d.is_online = 0 AND d.updated_at > ?
     UNION
     SELECT rr.driver_id AS id FROM ride_rides rr
     WHERE rr.status IN ($activeIn) AND rr.updated_at > ? AND rr.driver_id IS NOT NULL
     LIMIT 1000",
    's' . $activeTypes . 's',
    array_merge([$since], $active, [$since])
);
$deletes = array_values(array_unique(array_map(static fn($r) => (string)$r['id'], $deleteRows)));

pm_json(['error' => false, 'cursor' => $now, 'upserts' => $upserts, 'deletes' => $deletes]);
