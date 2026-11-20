<?php
declare(strict_types=1);

require_once 'ride_api_bootstrap.php';

ride_authorize();
$in = ride_input();

$rideId  = ride_i($in['ride_id'] ?? $in['trip_id'] ?? $in['id'] ?? 0, 0);
$riderId = ride_s($in['rider_id'] ?? $in['uid'] ?? $in['user_id'] ?? '');

if ($rideId <= 0 && $riderId === '') {
    ride_json(['error' => true, 'message' => 'ride_id or rider_id is required'], 422);
}

if ($rideId > 0) {
    $ride = ride_fetch_ride($dbconn, $rideId);
} else {
    $ride = ride_query_one(
        $dbconn,
        "SELECT *
         FROM ride_rides
         WHERE rider_id = ?
           AND status IN ('searching','accepted','enroute_pickup','arrived_pickup','in_progress','arrived_destination','driver_assigned','in_ride')
         ORDER BY updated_at DESC, id DESC
         LIMIT 1",
        's',
        [$riderId]
    );
}

if (!$ride) {
    ride_json(['error' => false, 'message' => 'No active ride found', 'ride' => null, 'driver' => null, 'status' => 'idle'], 200);
}

$status = ride_s($ride['status'] ?? 'searching', 'searching');
if ($status === 'driver_assigned') $ride['status'] = 'accepted';
if ($status === 'in_ride') $ride['status'] = 'in_progress';

$driverId = ride_i($ride['driver_id'] ?? 0, 0);
$driver = $driverId > 0 ? ride_fetch_driver($dbconn, $driverId) : null;
$payload = ride_payload($ride, $driver);
$payload['message'] = 'Ride status loaded.';
ride_json($payload, 200);
