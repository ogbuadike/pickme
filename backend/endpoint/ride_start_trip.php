<?php
declare(strict_types=1);

header('Content-Type: application/json');
require_once 'ride_api_bootstrap.php';

const START_TRIP_MAX_METERS = 150.0;
const DRIVER_FIX_MAX_AGE_SEC = 180; 

ride_authorize();
$in = ride_input();

$rideId = ride_i($in['ride_id'] ?? $in['trip_id'] ?? $in['id'] ?? 0, 0);
if ($rideId <= 0) {
    ride_json(['error' => true, 'message' => 'ride_id is required'], 422);
}

$ride = ride_fetch_ride($dbconn, $rideId);
if (!$ride) {
    ride_json(['error' => true, 'message' => 'Ride not found'], 404);
}

$status = strtolower(trim((string)($ride['status'] ?? 'searching')));
if ($status === 'driver_assigned') $status = 'accepted';
if ($status === 'in_ride') $status = 'in_progress';

if (!in_array($status, ['accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress'], true)) {
    ride_json(['error' => true, 'message' => 'Ride is not in a startable state'], 409);
}

$driverId = ride_i($ride['driver_id'] ?? 0, 0);
if ($driverId <= 0) {
    ride_json(['error' => true, 'message' => 'Driver is not assigned to this ride'], 409);
}

$clientLat = isset($in['lat']) ? ride_f($in['lat'], 0.0) : null;
$clientLng = isset($in['lng']) ? ride_f($in['lng'], 0.0) : null;
// --- HYBRID FIX: FETCH ACCURACY ---
$clientAccuracy = isset($in['accuracy']) ? ride_f($in['accuracy'], 15.0) : 15.0;
// ----------------------------------

$driverLat = null;
$driverLng = null;

// HYBRID FIX: Prioritize client GPS provided in the request payload
if ($clientLat !== null && $clientLng !== null && $clientLat != 0.0 && $clientLng != 0.0) {
    $driverLat = $clientLat;
    $driverLng = $clientLng;
    
    // Update the database to reflect this fresh fallback
    ride_exec($dbconn, "UPDATE ride_driver_locations SET lat=?, lng=?, updated_at=CURRENT_TIMESTAMP WHERE driver_id=?", 'ddi', [$driverLat, $driverLng, $driverId]);
} else {
    // HYBRID FIX: Bulletproof Timezone-safe SQL check
    $live = ride_query_one(
        $dbconn,
        "SELECT lat, lng, TIMESTAMPDIFF(SECOND, updated_at, CURRENT_TIMESTAMP) AS db_age_sec
         FROM ride_driver_locations WHERE driver_id = ? LIMIT 1",
        'i', [$driverId]
    );

    if (!$live) ride_json(['error' => true, 'message' => 'Driver location unavailable.'], 409);

    $ageSec = isset($live['db_age_sec']) ? (int)$live['db_age_sec'] : PHP_INT_MAX;
    if ($ageSec < 0) $ageSec = 0;

    if ($ageSec > DRIVER_FIX_MAX_AGE_SEC) {
        ride_json(['error' => true, 'message' => 'Driver GPS location is stale (' . $ageSec . 's old). Keep app open.'], 409);
    }

    $driverLat = (float)$live['lat'];
    $driverLng = (float)$live['lng'];
}

// --- HYBRID FIX: DYNAMIC ACCURACY COMPENSATION ---
$compensation = min($clientAccuracy, 150.0);
$effectiveStartRadius = START_TRIP_MAX_METERS + $compensation;

$metersToPickup = ride_haversine_m($driverLat, $driverLng, ride_f($ride['pickup_lat'] ?? 0, 0), ride_f($ride['pickup_lng'] ?? 0, 0));

if ($metersToPickup > $effectiveStartRadius) {
    ride_json(['error' => true, 'message' => 'Driver and rider must be together. Current gap: ' . round($metersToPickup) . ' m. (GPS Error Margin: ±' . round($clientAccuracy) . 'm)'], 409);
}
// -------------------------------------------------

try {
    ride_exec($dbconn, "UPDATE ride_rides SET status = 'in_progress', started_at = IFNULL(started_at, NOW()), updated_at = CURRENT_TIMESTAMP WHERE id = ?", 'i', [$rideId]);
    ride_exec($dbconn, "UPDATE ride_driver_locations SET phase = 'enroute_destination', updated_at = CURRENT_TIMESTAMP WHERE driver_id = ?", 'i', [$driverId]);

    ride_json(['error' => false, 'message' => 'Trip started.', 'data' => ['distance_m' => $metersToPickup]], 200);
} catch (Exception $e) {
    ride_json(['error' => true, 'message' => 'Failed to start trip.'], 500);
}