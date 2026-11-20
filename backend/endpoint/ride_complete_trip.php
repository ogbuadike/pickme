<?php
declare(strict_types=1);

/**
 * POST ride_complete_trip.php — driver completes a trip (session required, activated driver).
 * Referenced by the app (ApiConstants.rideCompleteEndpoint). Thin alias of
 * driver_hub.php action=ride_action, ride_action=complete — same GPS gating, OTP rule,
 * idempotency and wallet/fee settlement. Params: ride_id (or trip_id/id), lat, lng, accuracy.
 */

$_POST['action'] = 'ride_action';
$_POST['ride_action'] = 'complete';
if (empty($_POST['ride_id'])) {
    $_POST['ride_id'] = $_POST['trip_id'] ?? ($_POST['id'] ?? '');
}

require __DIR__ . '/driver_hub.php';
