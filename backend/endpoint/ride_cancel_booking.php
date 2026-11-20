<?php
declare(strict_types=1);

/**
 * POST ride_cancel_booking.php — cancel a ride (session required).
 * Rider: allowed while searching / accepted / en route / arrived at pickup (not once the trip started).
 * Assigned driver: allowed from any open state (same as driver_hub ride_action=cancel, without fees).
 * Idempotent: cancelling an already-canceled ride returns the ride.
 */

require_once __DIR__ . '/ride_api_bootstrap.php';

pm_require_method('POST');
$uid = ride_authorize();
$in = ride_input();

$rideId = ride_i($in['ride_id'] ?? $in['trip_id'] ?? $in['id'] ?? 0, 0);
$reason = pm_in_str($in, 'reason', 255);
if ($rideId <= 0) {
    pm_error('VALIDATION', 'ride_id is required', 422);
}

$driverRow = null;
$ride = ride_fetch_owned($rideId, $uid, $driverRow);
$asRider = hash_equals((string)$ride['rider_id'], $uid);
$status = ride_norm_status((string)$ride['status']);

if ($status === 'completed') {
    pm_error('CONFLICT', 'Completed ride cannot be cancelled', 409);
}

$result = pm_tx(function () use ($rideId, $uid, $asRider, $driverRow, $reason) {
    $locked = ride_fetch_ride(null, $rideId, true);
    if ($asRider) {
        $t = pm_ride_transition($rideId, 'rider_cancel', 'rider_id', $uid, ', canceled_at = IFNULL(canceled_at, NOW()), cancel_reason = ?', 's', [$reason !== '' ? $reason : 'rider_canceled']);
    } else {
        $t = pm_ride_transition($rideId, 'driver_cancel', 'driver_id', (int)$driverRow['id'], ', canceled_at = IFNULL(canceled_at, NOW()), cancel_reason = ?', 's', [$reason !== '' ? $reason : 'driver_canceled']);
    }
    if ($t['changed']) {
        $driverId = (int)($locked['driver_id'] ?? 0);
        $weight = (float)($locked['package_weight'] ?? 0);
        if ($driverId > 0 && $weight > 0 && !empty($locked['batch_group_id']) && empty($locked['delivery_otp_verified_at'])) {
            pm_exec('UPDATE ride_drivers SET current_payload_weight = GREATEST(0, current_payload_weight - ?) WHERE id = ?', 'di', [$weight, $driverId]);
        }
        if ($driverId > 0 && in_array(ride_norm_status((string)$locked['status']), PM_RIDE_ACTIVE_STATUSES, true)) {
            pm_exec("UPDATE ride_driver_locations SET phase = 'idle', updated_at = CURRENT_TIMESTAMP WHERE driver_id = ?", 'i', [$driverId]);
        }
    }
    return $t;
});

$ride = $result['ride'];
$driverId = ride_i($ride['driver_id'] ?? 0, 0);
$driver = $driverId > 0 ? ride_fetch_driver(null, $driverId) : null;

if ($result['changed'] && $asRider && $driverId > 0) {
    $driverUser = pm_q_one('SELECT user_uid FROM ride_driver_onboarding WHERE driver_id = ? ORDER BY id DESC LIMIT 1', 'i', [$driverId]);
    if ($driverUser) {
        $duid = (string)$driverUser['user_uid'];
        pm_defer(static function () use ($duid, $rideId): void {
            pm_push_ride_update($duid, 'Ride canceled', 'The rider canceled the trip.', ['ride_id' => (string)$rideId, 'status' => 'canceled']);
        });
    }
}

ride_json(ride_payload($ride, $driver), 200);
