<?php
declare(strict_types=1);

/**
 * POST drivers_update_location.php — driver publishes live GPS (session required, activated driver).
 * driver_id is resolved from the session (a client-sent driver_id must match or 403).
 * Single-row upsert on the PK of ride_driver_locations; offline drivers are not published.
 */

require_once __DIR__ . '/ride_api_bootstrap.php';

pm_require_method('POST');
$uid = ride_authorize();
$in = ride_input();
$driver = pm_require_driver($uid);
$driverId = (int)$driver['id'];

$lat = pm_in_float($in, 'lat', 0.0);
$lng = pm_in_float($in, 'lng', 0.0);
$heading = fmod(max(0.0, pm_in_float($in, 'heading', 0.0)), 360.0);

if (!pm_valid_lat($lat) || !pm_valid_lng($lng)) {
    pm_error('VALIDATION', 'lat and lng are required', 422);
}
if ((int)$driver['is_online'] !== 1) {
    ride_json(['error' => false, 'message' => 'ignored: driver offline'], 200);
}

pm_rate_limit('driver_location', (string)$driverId, 60, 60, 'Location updates are too frequent.');
$speed = isset($in['speed']) ? min(max(pm_in_float($in, 'speed', 0.0), 0.0), 100.0) : null;
$accuracy = isset($in['accuracy']) ? min(max(pm_in_float($in, 'accuracy', 0.0), 0.0), 10000.0) : null;

pm_exec(
    'INSERT INTO ride_driver_locations (driver_id, lat, lng, heading, speed, accuracy)
     VALUES (?, ?, ?, ?, ?, ?)
     ON DUPLICATE KEY UPDATE lat = VALUES(lat), lng = VALUES(lng), heading = VALUES(heading),
                             speed = VALUES(speed), accuracy = VALUES(accuracy), updated_at = CURRENT_TIMESTAMP()',
    'iddddd',
    [$driverId, $lat, $lng, $heading, $speed, $accuracy]
);

ride_json(['error' => false, 'message' => 'ok'], 200);
