<?php
declare(strict_types=1);

/**
 * POST ride_status.php — poll a ride (session required).
 * With ride_id: the ride must belong to the session user (as rider or assigned driver), else 404.
 * Without ride_id: the session user's latest open ride as rider.
 * Hot path: PK lookup or index idx_ride_rides_rider_status (rider_id, status, updated_at).
 */

require_once __DIR__ . '/ride_api_bootstrap.php';

$uid = ride_authorize();
$in = ride_input();

$rideId = ride_i($in['ride_id'] ?? $in['trip_id'] ?? $in['id'] ?? 0, 0);

if ($rideId > 0) {
    $ride = ride_fetch_owned($rideId, $uid);
} else {
    $ride = pm_q_one(
        'SELECT * FROM ride_rides
         WHERE rider_id = ? AND status IN (' . pm_in_placeholders(PM_RIDE_OPEN_STATUSES) . ')
         ORDER BY updated_at DESC, id DESC
         LIMIT 1',
        's' . str_repeat('s', count(PM_RIDE_OPEN_STATUSES)),
        array_merge([$uid], PM_RIDE_OPEN_STATUSES)
    );
}

if (!$ride) {
    ride_json(['error' => false, 'message' => 'No active ride found', 'ride' => null, 'driver' => null, 'status' => 'idle'], 200);
}

// A searching request older than the TTL is reported (and persisted) as expired.
if (ride_norm_status((string)$ride['status']) === 'searching') {
    $age = pm_q_one('SELECT TIMESTAMPDIFF(MINUTE, created_at, NOW()) AS m FROM ride_rides WHERE id = ?', 'i', [(int)$ride['id']]);
    if ((int)($age['m'] ?? 0) >= PM_RIDE_SEARCH_TTL_MIN) {
        pm_exec(
            "UPDATE ride_rides SET status = 'canceled', canceled_at = IFNULL(canceled_at, NOW()), cancel_reason = IFNULL(cancel_reason, 'expired')
             WHERE id = ? AND status = 'searching'",
            'i',
            [(int)$ride['id']]
        );
        $ride = ride_fetch_ride(null, (int)$ride['id']);
    }
}

$ride['status'] = ride_norm_status((string)$ride['status']);
$driverId = ride_i($ride['driver_id'] ?? 0, 0);
$driver = $driverId > 0 ? ride_fetch_driver(null, $driverId) : null;
$payload = ride_payload($ride, $driver);
$payload['message'] = 'Ride status loaded.';
ride_json($payload, 200);
