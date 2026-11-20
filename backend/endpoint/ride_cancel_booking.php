<?php
declare(strict_types=1);

require_once 'ride_api_bootstrap.php';

ride_authorize();
$in = ride_input();

$rideId = ride_i($in['ride_id'] ?? $in['trip_id'] ?? $in['id'] ?? 0, 0);
$reason = ride_s($in['reason'] ?? '');

if ($rideId <= 0) {
    ride_json(['error' => true, 'message' => 'ride_id is required'], 422);
}

$ride = ride_fetch_ride($dbconn, $rideId);
if (!$ride) {
    ride_json(['error' => true, 'message' => 'Ride not found'], 404);
}

$status = ride_s($ride['status'] ?? 'searching', 'searching');

if ($status === 'completed') {
    ride_json(['error' => true, 'message' => 'Completed ride cannot be cancelled'], 409);
}

if ($status === 'canceled') {
    $driver = ride_i($ride['driver_id'] ?? 0, 0) > 0
        ? ride_fetch_driver($dbconn, ride_i($ride['driver_id'] ?? 0, 0))
        : null;
    ride_json(ride_payload($ride, $driver), 200);
}

ride_exec(
    $dbconn,
    "UPDATE ride_rides
     SET status = 'canceled',
         canceled_at = IFNULL(canceled_at, NOW()),
         cancel_reason = ?
     WHERE id = ?
     LIMIT 1",
    'si',
    [$reason, $rideId]
);

$ride = ride_fetch_ride($dbconn, $rideId);
$driver = ride_i($ride['driver_id'] ?? 0, 0) > 0
    ? ride_fetch_driver($dbconn, ride_i($ride['driver_id'] ?? 0, 0))
    : null;

ride_json(ride_payload($ride, $driver), 200);