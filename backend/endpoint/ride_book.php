<?php
declare(strict_types=1);

/**
 * POST ride_book.php — rider books a specific driver (session required).
 * Identity: rider = session user (rider_id/uid/user_id params must match or 403).
 * Idempotency: optional X-Idempotency-Key header / idempotency_key param; a double-tap
 * for the same driver within 15 s returns the existing request instead of creating a new one.
 */

require_once __DIR__ . '/ride_api_bootstrap.php';

pm_require_method('POST');
$riderId = ride_authorize();
$in = ride_input();

$driverId    = ride_i($in['driver_id'] ?? 0, 0);
$offerId     = pm_in_str($in, 'offer_id', 64);
$provider    = pm_in_str($in, 'provider', 40, 'PickMe');
$category    = pm_in_str($in, 'category', 32);
$vehicleType = pm_in_str($in, ['vehicle_type', 'vehicle'], 32);
$currency    = strtoupper(pm_in_str($in, 'currency', 3, 'NGN'));
$payMethod   = pm_in_enum($in, 'pay_method', ['cash', 'wallet', 'card', 'transfer'], 'cash');
$price       = max(0.0, pm_in_float($in, ['price', 'price_total', 'price_ngn'], 0.0));
$estimated   = max(0.0, pm_in_float($in, ['estimated_total', 'price_total'], $price));
$pickupText  = pm_in_str($in, 'pickup_text', 255);
$destText    = pm_in_str($in, ['destination_text', 'dest_text'], 255);
$etaMin      = pm_in_int($in, 'eta_min', 0, 0, 1440);
$surge       = pm_in_int($in, 'surge', 0, 0, 1);
$seats       = pm_in_int($in, 'seats', 0, 0, 20);
$tripKm      = max(0.0, pm_in_float($in, 'trip_km', 0.0));
$rideType    = pm_in_enum($in, 'ride_type', ['street_ride', 'campus_ride', 'dispatch', 'send_me'], 'street_ride');
$instructions = pm_in_str($in, 'instructions', 1000);
$idemKey     = pm_clean_text(pm_header('X-Idempotency-Key') ?: ($in['idempotency_key'] ?? ''), 64);

[$pickupLat, $pickupLng] = ride_parse_latlng($in['pickup'] ?? null, $in['pickup_lat'] ?? null, $in['pickup_lng'] ?? null);
[$destLat, $destLng] = ride_parse_latlng($in['destination'] ?? null, $in['destination_lat'] ?? null, $in['destination_lng'] ?? null);

$stopsRaw = $in['stops'] ?? '';
$stops = [];
if (is_array($stopsRaw)) {
    foreach ($stopsRaw as $s) {
        if (is_array($s)) {
            $stops[] = [ride_f($s['lat'] ?? $s['latitude'] ?? null, 0.0), ride_f($s['lng'] ?? $s['longitude'] ?? null, 0.0)];
        }
    }
} elseif (is_string($stopsRaw) && trim($stopsRaw) !== '') {
    foreach (explode('|', $stopsRaw) as $p) {
        if (strpos($p, ',') !== false) {
            [$la, $lo] = explode(',', $p, 2);
            $stops[] = [ride_f($la, 0.0), ride_f($lo, 0.0)];
        }
    }
}
$norm = [];
foreach (array_slice($stops, 0, 5) as [$la, $lo]) {
    if (pm_valid_lat($la) && pm_valid_lng($lo)) {
        $norm[] = ['lat' => $la, 'lng' => $lo];
    }
}
$stopsJson = $norm ? json_encode($norm) : null;

if ($driverId <= 0) {
    pm_error('VALIDATION', 'driver_id is required', 422);
}
if (!pm_valid_lat($pickupLat) || !pm_valid_lng($pickupLng)) {
    pm_error('VALIDATION', 'pickup coordinates are required', 422);
}
if (!pm_valid_lat($destLat) || !pm_valid_lng($destLng)) {
    pm_error('VALIDATION', 'destination coordinates are required', 422);
}
if (!preg_match('/^[A-Z]{3}$/', $currency)) {
    $currency = 'NGN';
}

pm_rate_limit('ride_book', $riderId, 20, 600, 'Too many booking attempts. Please wait a moment.');
pm_ride_expire_stale();

$result = pm_tx(function () use (
    $riderId, $driverId, $offerId, $provider, $category, $vehicleType, $currency, $payMethod, $price, $estimated,
    $pickupText, $destText, $etaMin, $surge, $seats, $tripKm, $rideType, $instructions, $idemKey,
    $pickupLat, $pickupLng, $destLat, $destLng, $stopsJson
) {
    // Serialise bookings per rider (prevents duplicate rides from parallel taps).
    $user = pm_q_one('SELECT u_uid, sta, bal FROM unique_user_table WHERE u_uid = ? LIMIT 1 FOR UPDATE', 's', [$riderId]);
    if ($user === null || (int)$user['sta'] !== 0) {
        pm_fail('FORBIDDEN', 'Rider account is not active', 403);
    }

    if ($idemKey !== '') {
        $dup = pm_q_one('SELECT * FROM ride_rides WHERE rider_id = ? AND idempotency_key = ? LIMIT 1', 'ss', [$riderId, $idemKey]);
        if ($dup) {
            return ['ride' => $dup, 'replay' => true];
        }
    }

    $open = pm_q_all(
        'SELECT id, driver_id, status, TIMESTAMPDIFF(SECOND, created_at, NOW()) AS age_sec
         FROM ride_rides
         WHERE rider_id = ? AND status IN (' . pm_in_placeholders(PM_RIDE_OPEN_STATUSES) . ')
           AND ride_type IN (\'street_ride\', \'campus_ride\')
         ORDER BY id DESC LIMIT 10',
        's' . str_repeat('s', count(PM_RIDE_OPEN_STATUSES)),
        array_merge([$riderId], PM_RIDE_OPEN_STATUSES)
    );
    foreach ($open as $o) {
        $st = ride_norm_status((string)$o['status']);
        if ($st !== 'searching') {
            pm_fail('CONFLICT', 'You already have an active ride. Finish or cancel it first.', 409, ['ride_id' => (string)$o['id']]);
        }
        if ((int)$o['driver_id'] === $driverId && (int)$o['age_sec'] <= 15) {
            return ['ride' => ride_fetch_ride(null, (int)$o['id']), 'replay' => true]; // double-tap
        }
    }
    // A new request supersedes the rider's older unanswered requests.
    if ($open) {
        pm_exec(
            "UPDATE ride_rides SET status = 'canceled', canceled_at = NOW(), cancel_reason = 'superseded'
             WHERE rider_id = ? AND status = 'searching' AND ride_type IN ('street_ride', 'campus_ride')",
            's',
            [$riderId]
        );
    }

    $driver = pm_q_one(
        'SELECT id, name, category, vehicle_type, car_plate, rating, is_online, seats, base_fare, price_per_km, currency, allowed_ride_types
         FROM ride_drivers WHERE id = ? LIMIT 1',
        'i',
        [$driverId]
    );
    if (!$driver) {
        pm_fail('NOT_FOUND', 'Driver not found', 404);
    }
    if ((int)$driver['is_online'] !== 1) {
        pm_fail('CONFLICT', 'Driver is offline', 409);
    }
    $allowedTypes = array_map('trim', explode(',', (string)($driver['allowed_ride_types'] ?: 'street_ride')));
    if (!in_array($rideType, $allowedTypes, true)) {
        pm_fail('CONFLICT', 'This driver does not accept this ride type', 409);
    }
    $busy = pm_q_one(
        'SELECT id FROM ride_rides WHERE driver_id = ? AND status IN (' . pm_in_placeholders(PM_RIDE_ACTIVE_STATUSES) . ') LIMIT 1',
        'i' . str_repeat('s', count(PM_RIDE_ACTIVE_STATUSES)),
        array_merge([$driverId], PM_RIDE_ACTIVE_STATUSES)
    );
    if ($busy) {
        pm_fail('CONFLICT', 'Driver is busy', 409);
    }

    $category    = $category !== '' ? $category : (string)($driver['category'] ?: 'Standard');
    $vehicleType = $vehicleType !== '' ? $vehicleType : (string)($driver['vehicle_type'] ?: 'car');
    $seats       = $seats > 0 ? $seats : (int)($driver['seats'] ?: 4);
    $baseFare    = (float)$driver['base_fare'];
    $pricePerKm  = (float)$driver['price_per_km'];

    // Server-side price floor: never below base fare + per-km x straight-line distance.
    $straightKm = pm_haversine_m($pickupLat, $pickupLng, $destLat, $destLng) / 1000.0;
    $effectiveKm = max($tripKm, $straightKm);
    if ($pricePerKm > 0) {
        $floor = round($baseFare + $pricePerKm * $effectiveKm, 2);
        if ($price < $floor) {
            $price = $floor;
        }
        if ($estimated < $floor) {
            $estimated = $floor;
        }
    }
    if ($estimated <= 0) {
        $estimated = $price;
    }

    if ($payMethod === 'wallet' && (float)$user['bal'] < $price) {
        pm_fail('CONFLICT', 'Insufficient wallet balance for this ride. Fund your wallet or pay with cash.', 409);
    }

    try {
        $rideId = pm_insert(
            "INSERT INTO ride_rides
                (rider_id, driver_id, offer_id, status, provider, category, vehicle_type, seats, price, estimated_total, base_fare, price_per_km,
                 currency, pay_method, pickup_lat, pickup_lng, pickup_text, dest_lat, dest_lng, dest_text, stops_json, eta_min, surge,
                 ride_type, instructions, idempotency_key)
             VALUES (?, ?, ?, 'searching', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            'sissssiddddssddsddssiisss',
            [
                $riderId, $driverId, $offerId, $provider, $category, $vehicleType, $seats, $price, $estimated, $baseFare, $pricePerKm,
                $currency, $payMethod, $pickupLat, $pickupLng, $pickupText, $destLat, $destLng, $destText, $stopsJson, $etaMin, $surge,
                $rideType, $instructions, $idemKey !== '' ? $idemKey : null,
            ]
        );
    } catch (mysqli_sql_exception $e) {
        if ((int)$e->getCode() === 1062 && $idemKey !== '') {
            $dup = pm_q_one('SELECT * FROM ride_rides WHERE rider_id = ? AND idempotency_key = ? LIMIT 1', 'ss', [$riderId, $idemKey]);
            if ($dup) {
                return ['ride' => $dup, 'replay' => true];
            }
        }
        throw $e;
    }
    return ['ride' => ride_fetch_ride(null, $rideId), 'replay' => false];
});

$ride = $result['ride'];
$driverLive = ride_fetch_driver(null, (int)$ride['driver_id']);
$payload = ride_payload($ride, $driverLive);
$payload['message'] = 'Ride request created and sent to the driver queue.';
$payload['displayMessage'] = 'Ride request sent. Waiting for driver acceptance.';
$payload['queue_state'] = 'pending_driver_acceptance';
$payload['idempotent_replay'] = (bool)$result['replay'];

if (!$result['replay']) {
    $driverUser = pm_q_one('SELECT user_uid FROM ride_driver_onboarding WHERE driver_id = ? ORDER BY id DESC LIMIT 1', 'i', [(int)$ride['driver_id']]);
    if ($driverUser) {
        $rid = (string)$ride['id'];
        $duid = (string)$driverUser['user_uid'];
        pm_defer(static function () use ($duid, $rid): void {
            pm_push_ride_update($duid, 'New ride request', 'A rider is waiting for you to accept.', ['ride_id' => $rid, 'click_action' => 'driver_home']);
        });
    }
}

ride_json($payload, 200);
