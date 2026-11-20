<?php
declare(strict_types=1);

require_once 'ride_api_bootstrap.php';

// 1. Authorize should validate the token and Ideally return the Driver ID directly.
// e.g., $driverId = ride_authorize()['user_id'];
ride_authorize();
$in = ride_input();

$driverId = ride_i($in['driver_id'] ?? 0, 0);
$lat = ride_f($in['lat'] ?? 0, 0.0);
$lng = ride_f($in['lng'] ?? 0, 0.0);
$heading = ride_f($in['heading'] ?? 0, 0.0);

// Note: 0.0, 0.0 is technically Null Island (coast of Africa), but works as an empty check here.
if ($driverId <= 0 || $lat == 0.0 || $lng == 0.0) {
    ride_json(['error' => true, 'message' => 'driver_id, lat and lng are required'], 422);
}

try {
    // 2. ONE Single Query. Ultra-fast Upsert.
    // This updates the live map instantly without locking up the database.
    ride_exec(
        $dbconn,
        "INSERT INTO ride_driver_locations (driver_id, lat, lng, heading)
         VALUES (?, ?, ?, ?)
         ON DUPLICATE KEY UPDATE
            lat = VALUES(lat),
            lng = VALUES(lng),
            heading = VALUES(heading),
            updated_at = CURRENT_TIMESTAMP()",
        'iddd',
        [$driverId, $lat, $lng, $heading]
    );

    // 3. Return lightweight OK. 
    // We do not echo the coordinates back. The client just sent them, so it already knows them! 
    // Saving JSON payload size saves bandwidth and speeds up the response time.
    ride_json([
        'error' => false,
        'message' => 'ok'
    ], 200);

} catch (Exception $e) {
    // Fails silently for the client to prevent UI freezing, but you should log $e internally.
    ride_json(['error' => true, 'message' => 'Failed to update location'], 500);
}