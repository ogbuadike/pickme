<?php
declare(strict_types=1);

/**
 * POST ride_start_trip.php — start a trip (session required; rider of the ride or its assigned driver).
 * Transition: accepted | enroute_pickup | arrived_pickup → in_progress (idempotent when already in_progress).
 * Proximity: driver (fresh live fix, or the driver's own client GPS) must be within the pickup radius.
 * Only the driver's own request may update the driver's live location.
 */

require_once __DIR__ . '/ride_api_bootstrap.php';

const START_TRIP_MAX_METERS = 150.0;
const DRIVER_FIX_MAX_AGE_SEC = 180;

pm_require_method('POST');
$uid = ride_authorize();
$in = ride_input();

$rideId = ride_i($in['ride_id'] ?? $in['trip_id'] ?? $in['id'] ?? 0, 0);
if ($rideId <= 0) {
    pm_error('VALIDATION', 'ride_id is required', 422);
}

$driverRow = null;
$ride = ride_fetch_owned($rideId, $uid, $driverRow);
$asDriver = $driverRow !== null && !hash_equals((string)$ride['rider_id'], $uid);
$status = ride_norm_status((string)$ride['status']);

if ($status === 'in_progress') {
    ride_json(['error' => false, 'message' => 'Trip already started.', 'data' => ['distance_m' => 0.0], 'status' => 'in_progress'], 200);
}
if (!in_array($status, ['accepted', 'enroute_pickup', 'arrived_pickup'], true)) {
    pm_error('CONFLICT', 'Ride is not in a startable state', 409, ['status' => $status]);
}
$driverId = ride_i($ride['driver_id'] ?? 0, 0);
if ($driverId <= 0) {
    pm_error('CONFLICT', 'Driver is not assigned to this ride', 409);
}

$clientLat = pm_in_float($in, 'lat', 0.0);
$clientLng = pm_in_float($in, 'lng', 0.0);
$clientAccuracy = min(max(pm_in_float($in, 'accuracy', 15.0), 0.0), 150.0);

if ($asDriver && pm_valid_lat($clientLat) && pm_valid_lng($clientLng)) {
    $driverLat = $clientLat;
    $driverLng = $clientLng;
    pm_exec('UPDATE ride_driver_locations SET lat = ?, lng = ?, updated_at = CURRENT_TIMESTAMP WHERE driver_id = ?', 'ddi', [$driverLat, $driverLng, $driverId]);
} else {
    $live = pm_q_one(
        'SELECT lat, lng, TIMESTAMPDIFF(SECOND, updated_at, CURRENT_TIMESTAMP) AS db_age_sec FROM ride_driver_locations WHERE driver_id = ? LIMIT 1',
        'i',
        [$driverId]
    );
    if (!$live) {
        pm_error('CONFLICT', 'Driver location unavailable.', 409);
    }
    $ageSec = max(0, (int)$live['db_age_sec']);
    if ($ageSec > DRIVER_FIX_MAX_AGE_SEC) {
        pm_error('CONFLICT', 'Driver GPS location is stale (' . $ageSec . 's old). Keep app open.', 409);
    }
    $driverLat = (float)$live['lat'];
    $driverLng = (float)$live['lng'];
}

$effectiveRadius = START_TRIP_MAX_METERS + $clientAccuracy;
$metersToPickup = pm_haversine_m($driverLat, $driverLng, (float)$ride['pickup_lat'], (float)$ride['pickup_lng']);
if ($metersToPickup > $effectiveRadius) {
    pm_error('CONFLICT', 'Driver and rider must be together. Current gap: ' . round($metersToPickup) . ' m. (GPS Error Margin: ±' . round($clientAccuracy) . 'm)', 409);
}

pm_tx(function () use ($rideId, $driverId) {
    pm_ride_transition($rideId, 'rider_start_trip', 'driver_id', $driverId, ', started_at = IFNULL(started_at, NOW())');
    pm_exec("UPDATE ride_driver_locations SET phase = 'enroute_destination', updated_at = CURRENT_TIMESTAMP WHERE driver_id = ?", 'i', [$driverId]);
});

ride_json(['error' => false, 'message' => 'Trip started.', 'data' => ['distance_m' => $metersToPickup], 'status' => 'in_progress'], 200);
