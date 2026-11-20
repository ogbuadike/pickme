<?php
declare(strict_types=1);

/**
 * POST driver_hub.php — driver command centre (session required, activated driver).
 *
 * action = dashboard | set_online | heartbeat | accept_ride | ride_action | verify_otp | scan_dispatch_batch
 * The driver is always resolved from the session user (param `user` must equal the session uid,
 * a client-sent driver_id must match the session driver, else 403).
 *
 * Business errors keep the legacy shape: HTTP 200 + { error:true, code, message, data:null }.
 *
 * State machine: see PM_RIDE_TRANSITIONS in ride_api_bootstrap.php. Every transition is a single
 * conditional UPDATE inside a transaction holding the ride row lock (SELECT ... FOR UPDATE), so
 * exactly one driver can win a ride and repeated taps are idempotent.
 */

require_once __DIR__ . '/ride_api_bootstrap.php';

const DRIVER_FIX_MAX_AGE_SEC = 180;
const ARRIVED_PICKUP_MAX_METERS = 200.0;
const START_TRIP_MAX_METERS = 200.0;
const ARRIVED_DESTINATION_MAX_METERS = 150.0;
const COMPLETE_RIDE_MAX_METERS = 200.0;
const DELIVERY_OTP_MAX_ATTEMPTS = 15;
const DISPATCH_SCAN_RADIUS_M = 5000.0;
const DEFAULT_APP_FEE_PERCENT = 25.0;

pm_require_method('POST');
$sessionUid = pm_require_session();
$IN = pm_input();

function hub_fail(string $message, string $code = 'VALIDATION'): void
{
    pm_fail($code, $message, 200, ['data' => null]);
}

function hub_param(string $key, string $label, int $max = 64): string
{
    global $IN;
    $v = pm_in_str($IN, $key, $max);
    if ($v === '') {
        hub_fail($label . ' is required.');
    }
    return $v;
}

function fetchDriverSession(string $userUid): array
{
    $row = pm_require_driver($userUid, 200);
    $user = pm_q_one('SELECT u_uid, fname, lname, email, phone AS user_phone FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$userUid]);
    return array_merge($row, $user ?? []);
}

function appFeePercent(): float
{
    static $fee = null;
    if ($fee === null) {
        $row = pm_q_one("SELECT setting_value FROM app_settings WHERE setting_key = 'app_ride_fee_percentage' LIMIT 1");
        $fee = ($row && is_numeric($row['setting_value'])) ? (float)$row['setting_value'] : DEFAULT_APP_FEE_PERCENT;
        $fee = min(max($fee, 0.0), 100.0);
    }
    return $fee;
}

function fetchDriverLive(int $driverId): ?array
{
    $row = pm_q_one(
        'SELECT driver_id, lat, lng, heading, phase, updated_at, TIMESTAMPDIFF(SECOND, updated_at, CURRENT_TIMESTAMP) AS db_age_sec
         FROM ride_driver_locations WHERE driver_id = ? LIMIT 1',
        'i',
        [$driverId]
    );
    if (!$row) {
        return null;
    }
    return [
        'driver_id'  => (int)$row['driver_id'],
        'lat'        => (float)$row['lat'],
        'lng'        => (float)$row['lng'],
        'heading'    => (float)$row['heading'],
        'phase'      => (string)($row['phase'] ?? 'idle'),
        'updated_at' => $row['updated_at'] ?? null,
        'age_sec'    => max(0, (int)$row['db_age_sec']),
    ];
}

function requireFreshDriverLive(int $driverId, int $maxAgeSec = DRIVER_FIX_MAX_AGE_SEC): array
{
    $live = fetchDriverLive($driverId);
    if (!$live) {
        hub_fail('Driver live location is unavailable. Wait for GPS sync and try again.', 'CONFLICT');
    }
    if (($live['lat'] == 0.0 && $live['lng'] == 0.0) || $live['age_sec'] > $maxAgeSec) {
        hub_fail('Driver GPS fix is stale (' . $live['age_sec'] . 's). Keep the app open until live location refreshes.', 'CONFLICT');
    }
    return $live;
}

function phaseForRideAction(string $rideAction, string $fallback = 'idle'): string
{
    switch ($rideAction) {
        case 'enroute_pickup':
            return 'enroute_pickup';
        case 'arrived_pickup':
            return 'waiting_pickup';
        case 'start_trip':
            return 'enroute_destination';
        case 'arrived_destination':
            return 'arrived_destination';
        case 'complete':
        case 'cancel':
            return 'idle';
        default:
            return $fallback;
    }
}

function upsertDriverLive(int $driverId, float $lat, float $lng, float $heading, string $phase): void
{
    if (!pm_valid_lat($lat) || !pm_valid_lng($lng)) {
        return;
    }
    pm_exec(
        'INSERT INTO ride_driver_locations (driver_id, lat, lng, heading, phase, updated_at)
         VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
         ON DUPLICATE KEY UPDATE lat = VALUES(lat), lng = VALUES(lng), heading = VALUES(heading), phase = VALUES(phase), updated_at = CURRENT_TIMESTAMP',
        'iddds',
        [$driverId, $lat, $lng, fmod(max(0.0, $heading), 360.0), $phase]
    );
}

function buildDriverPayload(array $s): array
{
    return [
        'id'                     => (int)$s['id'],
        'name'                   => (string)$s['name'],
        'phone'                  => $s['phone'],
        'nin'                    => $s['nin'], // the driver's own record
        'rank'                   => $s['rank'],
        'category'               => $s['category'],
        'rating'                 => (float)$s['rating'],
        'car_plate'              => $s['car_plate'],
        'vehicle_type'           => $s['vehicle_type'],
        'seats'                  => (int)$s['seats'],
        'avatar_url'             => $s['avatar_url'],
        'completed_trips'        => (int)$s['completed_trips'],
        'total_trips'            => (int)$s['total_trips'],
        'cancelled_trips'        => (int)$s['cancelled_trips'],
        'incomplete_trips'       => (int)$s['incomplete_trips'],
        'is_online'              => (int)$s['is_online'],
        'currency'               => $s['currency'] ?? 'NGN',
        'status'                 => 'activated',
        'allowed_ride_types'     => $s['allowed_ride_types'] ?? 'street_ride,campus_ride',
        'max_payload_weight'     => (float)($s['max_payload_weight'] ?? 0),
        'current_payload_weight' => (float)($s['current_payload_weight'] ?? 0),
    ];
}

/** Ride as seen by the DRIVER. The delivery OTP itself is never sent to drivers (masked). */
function mapRidePayload(?array $ride): ?array
{
    if (!$ride) {
        return null;
    }
    $rideType = (string)($ride['ride_type'] ?? 'street_ride');
    $packageImage = trim((string)($ride['package_image'] ?? ''));
    if ($packageImage === '' && in_array($rideType, ['dispatch', 'send_me'], true)) {
        $packageImage = 'https://phantomphones.store/pick_me/img/logo.png';
    }
    $otpRequired = trim((string)($ride['delivery_otp'] ?? '')) !== '';

    return [
        'id'                      => (int)$ride['id'],
        'status'                  => ride_norm_status((string)($ride['status'] ?? 'searching')),
        'ride_type'               => $rideType,
        'package_size'            => $ride['package_size'] ?? null,
        'package_weight'          => (float)($ride['package_weight'] ?? 0),
        'delivery_otp'            => $otpRequired ? '****' : null,
        'delivery_otp_required'   => $otpRequired,
        'delivery_otp_verified'   => !empty($ride['delivery_otp_verified_at']),
        'batch_group_id'          => $ride['batch_group_id'] ?? null,
        'recipient_phone'         => $ride['recipient_phone'] ?? null,
        'instructions'            => $ride['instructions'] ?? null,
        'package_image'           => $packageImage,
        'app_fee_percentage'      => appFeePercent(),
        'rider_id'                => (string)($ride['rider_id'] ?? ''),
        'rider_name'              => trim((string)($ride['rider_name'] ?? '')) !== '' ? trim((string)$ride['rider_name']) : 'Rider',
        'rider_phone'             => $ride['rider_phone'] ?? '',
        'pickup_lat'              => (float)($ride['pickup_lat'] ?? 0),
        'pickup_lng'              => (float)($ride['pickup_lng'] ?? 0),
        'pickup_text'             => $ride['pickup_text'] ?? '',
        'dest_lat'                => (float)($ride['dest_lat'] ?? 0),
        'dest_lng'                => (float)($ride['dest_lng'] ?? 0),
        'dest_text'               => $ride['dest_text'] ?? '',
        'price'                   => (float)($ride['price'] ?? 0),
        'currency'                => $ride['currency'] ?? 'NGN',
        'eta_min'                 => (int)($ride['eta_min'] ?? 0),
        'pay_method'              => $ride['pay_method'] ?? 'cash',
        'vehicle_type'            => $ride['vehicle_type'] ?? 'car',
        'seats'                   => (int)($ride['seats'] ?? 4),
        'created_at'              => $ride['created_at'] ?? null,
        'updated_at'              => $ride['updated_at'] ?? null,
        'started_at'              => $ride['started_at'] ?? null,
        'arrived_pickup_at'       => $ride['arrived_pickup_at'] ?? null,
        'completed_at'            => $ride['completed_at'] ?? null,
    ];
}

function fetchQueueRides(int $driverId, int $limit = 12): array
{
    // Index: idx_ride_rides_search_queue (status, driver_id, created_at)
    return pm_q_all(
        "SELECT r.*, CONCAT(TRIM(COALESCE(u.fname, '')), ' ', TRIM(COALESCE(u.lname, ''))) AS rider_name, u.phone AS rider_phone
         FROM ride_rides r
         LEFT JOIN unique_user_table u ON u.u_uid = r.rider_id
         WHERE r.status = 'searching'
           AND (r.driver_id = ? OR r.driver_id IS NULL OR r.driver_id = 0)
           AND r.created_at > NOW() - INTERVAL " . PM_RIDE_SEARCH_TTL_MIN . " MINUTE
         ORDER BY CASE WHEN r.driver_id = ? THEN 0 ELSE 1 END, r.created_at DESC
         LIMIT ?",
        'iii',
        [$driverId, $driverId, $limit]
    );
}

function fetchActiveRide(int $driverId): ?array
{
    return pm_q_one(
        "SELECT r.*, CONCAT(TRIM(COALESCE(u.fname, '')), ' ', TRIM(COALESCE(u.lname, ''))) AS rider_name, u.phone AS rider_phone
         FROM ride_rides r
         LEFT JOIN unique_user_table u ON u.u_uid = r.rider_id
         WHERE r.driver_id = ? AND r.status IN (" . pm_in_placeholders(PM_RIDE_ACTIVE_STATUSES) . ')
         ORDER BY r.updated_at DESC
         LIMIT 1',
        'i' . str_repeat('s', count(PM_RIDE_ACTIVE_STATUSES)),
        array_merge([$driverId], PM_RIDE_ACTIVE_STATUSES)
    );
}

function dashboard(string $userUid): array
{
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    pm_ride_expire_stale();
    return [
        'error'   => false,
        'message' => 'Driver dashboard loaded.',
        'data'    => [
            'driver'      => buildDriverPayload($session),
            'driver_live' => fetchDriverLive($driverId),
            'active_ride' => mapRidePayload(fetchActiveRide($driverId)),
            'queue'       => array_map('mapRidePayload', fetchQueueRides($driverId, 12)),
        ],
    ];
}

function setOnline(string $userUid, string $isOnline, float $lat, float $lng, float $heading): array
{
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    $online = $isOnline === '1' ? 1 : 0;

    pm_tx(function () use ($driverId, $online, $lat, $lng, $heading) {
        pm_exec('UPDATE ride_drivers SET is_online = ?, updated_at = NOW() WHERE id = ? LIMIT 1', 'ii', [$online, $driverId]);
        if ($online === 1 && pm_valid_lat($lat) && pm_valid_lng($lng)) {
            upsertDriverLive($driverId, $lat, $lng, $heading, 'idle');
        } elseif ($online === 0) {
            // Hide from the map immediately (bbox queries exclude 0,0).
            pm_exec(
                "INSERT INTO ride_driver_locations (driver_id, lat, lng, heading, phase) VALUES (?, 0, 0, 0, 'idle')
                 ON DUPLICATE KEY UPDATE lat = 0, lng = 0, phase = 'idle', updated_at = CURRENT_TIMESTAMP",
                'i',
                [$driverId]
            );
        }
    });

    pm_activity($userUid, $online === 1 ? 'Driver went online' : 'Driver went offline');
    return [
        'error'   => false,
        'message' => $online === 1 ? 'Driver is now online and visible to riders.' : 'Driver is now offline and hidden from riders.',
        'data'    => ['driver_id' => $driverId, 'is_online' => $online, 'lat' => $lat, 'lng' => $lng],
    ];
}

function heartbeat(string $userUid, float $lat, float $lng, float $heading, string $phase): array
{
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    if ((int)$session['is_online'] !== 1) {
        hub_fail('Driver must be online before publishing live location.', 'CONFLICT');
    }
    if (!pm_valid_lat($lat) || !pm_valid_lng($lng)) {
        hub_fail('Latitude and longitude are invalid.');
    }
    $allowedPhases = ['idle', 'enroute_pickup', 'waiting_pickup', 'enroute_destination', 'arrived_destination'];
    if (!in_array($phase, $allowedPhases, true)) {
        $phase = 'idle';
    }
    upsertDriverLive($driverId, $lat, $lng, $heading, $phase);
    return [
        'error'   => false,
        'message' => 'Live driver location updated.',
        'data'    => ['driver_id' => $driverId, 'lat' => $lat, 'lng' => $lng, 'heading' => $heading, 'phase' => $phase],
    ];
}

function acceptRide(string $userUid, int $rideId): array
{
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    if ((int)$session['is_online'] !== 1) {
        hub_fail('Go online before accepting ride requests.', 'CONFLICT');
    }
    if ($rideId <= 0) {
        hub_fail('Ride ID is invalid.');
    }

    $result = pm_tx(function () use ($driverId, $rideId, $session) {
        // Per-driver lock: serialises this driver's accepts so they can never hold two active rides.
        pm_q_one('SELECT id FROM ride_drivers WHERE id = ? FOR UPDATE', 'i', [$driverId]);

        $ride = ride_fetch_ride(null, $rideId, true);
        if (!$ride) {
            hub_fail('Ride request no longer exists.', 'NOT_FOUND');
        }
        $current = ride_norm_status((string)$ride['status']);
        $assigned = (int)($ride['driver_id'] ?? 0);
        if ($assigned === $driverId && $current === 'accepted') {
            return ['idempotent' => true, 'ride' => $ride]; // double tap
        }
        if ($assigned > 0 && $assigned !== $driverId) {
            hub_fail($current === 'searching' ? 'This request is assigned to another driver queue.' : 'This ride has already been taken.', 'CONFLICT');
        }
        $busy = pm_q_one(
            'SELECT id FROM ride_rides WHERE driver_id = ? AND id <> ? AND status IN (' . pm_in_placeholders(PM_RIDE_ACTIVE_STATUSES) . ') LIMIT 1',
            'ii' . str_repeat('s', count(PM_RIDE_ACTIVE_STATUSES)),
            array_merge([$driverId, $rideId], PM_RIDE_ACTIVE_STATUSES)
        );
        if ($busy) {
            hub_fail('Finish the current trip before accepting another ride.', 'CONFLICT');
        }

        // Single conditional UPDATE: wins only if still searching and unassigned/assigned to me.
        $won = pm_exec(
            "UPDATE ride_rides
             SET driver_id = ?, driver_name = ?, car_plate = ?, status = 'accepted', updated_at = CURRENT_TIMESTAMP
             WHERE id = ? AND status = 'searching' AND (driver_id IS NULL OR driver_id = 0 OR driver_id = ?)
               AND created_at > NOW() - INTERVAL " . PM_RIDE_SEARCH_TTL_MIN . ' MINUTE
             LIMIT 1',
            'issii',
            [$driverId, (string)$session['name'], (string)($session['car_plate'] ?? ''), $rideId, $driverId]
        );
        if ($won !== 1) {
            hub_fail('This ride has already moved beyond queue state.', 'CONFLICT');
        }
        pm_exec(
            "INSERT INTO ride_driver_locations (driver_id, lat, lng, heading, phase) VALUES (?, 0, 0, 0, 'enroute_pickup')
             ON DUPLICATE KEY UPDATE phase = 'enroute_pickup', updated_at = CURRENT_TIMESTAMP",
            'i',
            [$driverId]
        );
        return ['idempotent' => false, 'ride' => $ride];
    });

    if (!$result['idempotent']) {
        $riderUid = (string)$result['ride']['rider_id'];
        pm_defer(static function () use ($riderUid, $rideId): void {
            pm_push_ride_update($riderUid, 'Driver on the way', 'Your ride has been accepted.', ['ride_id' => (string)$rideId, 'status' => 'accepted']);
        });
    }

    return [
        'error'   => false,
        'message' => 'Ride accepted. Proceed to pickup.',
        'data'    => ['ride_id' => $rideId, 'driver_id' => $driverId, 'status' => 'accepted'],
    ];
}

function scanAndBatchDispatchRides(string $userUid, float $driverLat, float $driverLng): array
{
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    if ((int)$session['is_online'] !== 1) {
        hub_fail('Go online to scan for dispatch batches.', 'CONFLICT');
    }
    $allowed = array_map('trim', explode(',', (string)($session['allowed_ride_types'] ?? '')));
    if (!in_array('dispatch', $allowed, true)) {
        hub_fail('Your vehicle is not authorized for Fleet Dispatch.', 'FORBIDDEN');
    }
    if (!pm_valid_lat($driverLat) || !pm_valid_lng($driverLng)) {
        hub_fail('Latitude and longitude are invalid.');
    }

    $batchGroupId = 'BATCH_' . bin2hex(random_bytes(8));
    $won = pm_tx(function () use ($driverId, $driverLat, $driverLng, $session, $batchGroupId) {
        $drv = pm_q_one('SELECT max_payload_weight, current_payload_weight FROM ride_drivers WHERE id = ? FOR UPDATE', 'i', [$driverId]);
        $capacity = (float)($drv['max_payload_weight'] ?? 0) - (float)($drv['current_payload_weight'] ?? 0);
        if ($capacity <= 0) {
            hub_fail('Your active payload is full. Deliver current packages first.', 'CONFLICT');
        }
        [$minLat, $maxLat, $minLng, $maxLng] = pm_bbox($driverLat, $driverLng, DISPATCH_SCAN_RADIUS_M / 1000.0);
        $candidates = pm_q_all(
            "SELECT id, package_weight, pickup_lat, pickup_lng
             FROM ride_rides
             WHERE status = 'searching' AND ride_type = 'dispatch'
               AND (driver_id IS NULL OR driver_id = 0)
               AND created_at > NOW() - INTERVAL " . PM_RIDE_SEARCH_TTL_MIN . ' MINUTE
               AND pickup_lat BETWEEN ? AND ? AND pickup_lng BETWEEN ? AND ?
               AND package_weight <= ?
             LIMIT 50',
            'ddddd',
            [$minLat, $maxLat, $minLng, $maxLng, $capacity]
        );
        foreach ($candidates as &$c) {
            $c['distance'] = pm_haversine_m($driverLat, $driverLng, (float)$c['pickup_lat'], (float)$c['pickup_lng']);
        }
        unset($c);
        $candidates = array_values(array_filter($candidates, static fn($c) => $c['distance'] < DISPATCH_SCAN_RADIUS_M));
        usort($candidates, static fn($a, $b) => $a['distance'] <=> $b['distance']);

        $won = [];
        $weight = 0.0;
        foreach ($candidates as $c) {
            if (count($won) >= 3) {
                break;
            }
            $w = (float)$c['package_weight'];
            if ($weight + $w > $capacity) {
                continue;
            }
            // Conditional claim: another driver scanning concurrently cannot claim the same parcel.
            $ok = pm_exec(
                "UPDATE ride_rides SET driver_id = ?, driver_name = ?, car_plate = ?, batch_group_id = ?
                 WHERE id = ? AND status = 'searching' AND (driver_id IS NULL OR driver_id = 0) LIMIT 1",
                'isssi',
                [$driverId, (string)$session['name'], (string)($session['car_plate'] ?? ''), $batchGroupId, (int)$c['id']]
            );
            if ($ok === 1) {
                $won[] = (int)$c['id'];
                $weight += $w;
            }
        }
        if ($weight > 0) {
            pm_exec('UPDATE ride_drivers SET current_payload_weight = current_payload_weight + ? WHERE id = ?', 'di', [$weight, $driverId]);
        }
        return $won;
    });

    $n = count($won);
    return [
        'error'   => false,
        'message' => $n > 0 ? 'Successfully batched ' . $n . ' nearby deliveries to your route.' : 'No dispatch requests nearby matching your capacity.',
        'data'    => ['batched_count' => $n, 'batch_group_id' => $n > 0 ? $batchGroupId : null],
    ];
}

/** Server-side delivery OTP check with attempt limits (rate limit + hard cap per ride). */
function verifyDeliveryOtp(string $userUid, int $rideId, string $providedOtp): array
{
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    if ($rideId <= 0) {
        hub_fail('Ride ID is invalid.');
    }
    pm_rate_limit('delivery_otp', (string)$rideId, 5, 900, 'Too many wrong codes. Please wait 15 minutes or contact support.');

    $ride = pm_q_one(
        'SELECT id, status, delivery_otp, delivery_otp_attempts, delivery_otp_verified_at FROM ride_rides WHERE id = ? AND driver_id = ? LIMIT 1',
        'ii',
        [$rideId, $driverId]
    );
    if (!$ride) {
        hub_fail('Delivery not found or not assigned to you.', 'NOT_FOUND');
    }
    if (!empty($ride['delivery_otp_verified_at'])) {
        return ['error' => false, 'message' => 'OTP already verified.', 'data' => ['ride_id' => $rideId, 'verified' => true]];
    }
    if (!in_array(ride_norm_status((string)$ride['status']), ['in_progress', 'arrived_destination'], true)) {
        hub_fail('You must be at the destination to verify the OTP.', 'CONFLICT');
    }
    $expected = trim((string)$ride['delivery_otp']);
    if ($expected === '') {
        return ['error' => false, 'message' => 'No OTP required for this delivery.', 'data' => ['ride_id' => $rideId, 'verified' => true]];
    }
    if ((int)$ride['delivery_otp_attempts'] >= DELIVERY_OTP_MAX_ATTEMPTS) {
        hub_fail('This delivery is locked after too many wrong codes. Contact support.', 'RATE_LIMITED');
    }

    $provided = preg_replace('/\D/', '', $providedOtp) ?? '';
    if (!hash_equals($expected, $provided)) {
        // Committed immediately (autocommit) so failed attempts are always counted.
        pm_exec('UPDATE ride_rides SET delivery_otp_attempts = delivery_otp_attempts + 1 WHERE id = ?', 'i', [$rideId]);
        hub_fail('Invalid Secure OTP. Handoff denied. Contact recipient.');
    }

    pm_tx(function () use ($rideId, $driverId) {
        $first = pm_exec('UPDATE ride_rides SET delivery_otp_verified_at = NOW() WHERE id = ? AND driver_id = ? AND delivery_otp_verified_at IS NULL', 'ii', [$rideId, $driverId]);
        if ($first === 1) {
            $r = pm_q_one('SELECT package_weight, batch_group_id FROM ride_rides WHERE id = ?', 'i', [$rideId]);
            $weight = (float)($r['package_weight'] ?? 0);
            if ($weight > 0 && !empty($r['batch_group_id'])) {
                pm_exec('UPDATE ride_drivers SET current_payload_weight = GREATEST(0, current_payload_weight - ?) WHERE id = ?', 'di', [$weight, $driverId]);
            }
        }
    });
    pm_rate_limit_clear('delivery_otp', (string)$rideId);

    return ['error' => false, 'message' => 'OTP Verified successfully. Chain of custody confirmed.', 'data' => ['ride_id' => $rideId, 'verified' => true]];
}

/**
 * Ride actions with GPS gating and money movement.
 * Charging rules (unchanged): app fee (% of fare, app_settings.app_ride_fee_percentage) is taken from the
 * driver's wallet on completion, or on a driver cancel after the trip started. Wallet-paid rides move the
 * fare rider → driver on completion. All balance changes are atomic conditional UPDATEs in one transaction
 * with the ride transition, so a double tap can never charge twice.
 */
function rideAction(string $userUid, int $rideId, string $rideActionRaw): array
{
    global $IN;
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    if ($rideId <= 0) {
        hub_fail('Ride ID is invalid.');
    }

    $rideAction = strtolower(trim($rideActionRaw));
    $aliases = ['start_to_pickup' => 'enroute_pickup', 'head_to_pickup' => 'enroute_pickup', 'complete_trip' => 'complete', 'cancel_trip' => 'cancel', 'cancel_ride' => 'cancel'];
    $rideAction = $aliases[$rideAction] ?? $rideAction;
    if (!in_array($rideAction, ['enroute_pickup', 'arrived_pickup', 'start_trip', 'arrived_destination', 'complete', 'cancel'], true)) {
        hub_fail('Unsupported ride action.');
    }

    $clientLat = pm_in_float($IN, 'lat', 0.0);
    $clientLng = pm_in_float($IN, 'lng', 0.0);
    if (pm_valid_lat($clientLat) && pm_valid_lng($clientLng)) {
        upsertDriverLive($driverId, $clientLat, $clientLng, pm_in_float($IN, 'heading', 0.0), phaseForRideAction($rideAction));
    }
    $compensation = min(max(pm_in_float($IN, 'accuracy', 15.0), 0.0), 150.0);

    $out = pm_tx(function () use ($driverId, $rideId, $rideAction, $userUid, $compensation) {
        $ride = pm_q_one('SELECT * FROM ride_rides WHERE id = ? AND driver_id = ? LIMIT 1 FOR UPDATE', 'ii', [$rideId, $driverId]);
        if (!$ride) {
            hub_fail('No active ride was found for this driver action.', 'NOT_FOUND');
        }
        $current = ride_norm_status((string)$ride['status']);
        $live = requireFreshDriverLive($driverId);
        $toPickup = pm_haversine_m($live['lat'], $live['lng'], (float)$ride['pickup_lat'], (float)$ride['pickup_lng']);
        $toDest = pm_haversine_m($live['lat'], $live['lng'], (float)$ride['dest_lat'], (float)$ride['dest_lng']);

        $transition = $rideAction === 'cancel' ? 'driver_cancel' : $rideAction;
        [$from, $target] = PM_RIDE_TRANSITIONS[$transition];
        $base = ['ride_id' => $rideId, 'driver_id' => $driverId, 'distance_to_pickup_m' => round($toPickup, 2), 'distance_to_destination_m' => round($toDest, 2), 'driver_fix_age_sec' => $live['age_sec']];

        // Idempotent replay (double tap / retry after timeout): no side effects.
        if ($current === $target) {
            return ['message' => 'Ride already ' . $target . '.', 'status' => $target, 'phase' => phaseForRideAction($rideAction), 'base' => $base, 'notify' => null];
        }
        if (!in_array((string)$ride['status'], $from, true) && !in_array($current, $from, true)) {
            hub_fail('Ride cannot move to ' . $target . ' from ' . $current . '.', 'CONFLICT');
        }

        $extra = '';
        $message = '';
        $phase = phaseForRideAction($rideAction);
        switch ($rideAction) {
            case 'enroute_pickup':
                $message = 'Driver is heading to pickup.';
                break;
            case 'arrived_pickup':
                if ($toPickup > ARRIVED_PICKUP_MAX_METERS + $compensation) {
                    hub_fail('Driver must be inside the pickup zone before marking arrived. Current distance: ' . round($toPickup) . ' m.', 'CONFLICT');
                }
                $message = 'Driver has arrived at pickup.';
                $extra = ', arrived_pickup_at = NOW()';
                break;
            case 'start_trip':
                if ($toPickup > START_TRIP_MAX_METERS + $compensation) {
                    hub_fail('Driver and rider must still be together inside pickup zone before starting trip. Current distance: ' . round($toPickup) . ' m.', 'CONFLICT');
                }
                $message = 'Trip started. Driver is en route to destination.';
                $extra = ', started_at = IFNULL(started_at, NOW())';
                break;
            case 'arrived_destination':
                if ($toDest > ARRIVED_DESTINATION_MAX_METERS + $compensation) {
                    hub_fail('Driver must be inside the destination zone before marking arrived. Current distance: ' . round($toDest) . ' m.', 'CONFLICT');
                }
                $message = 'Driver reached the destination.';
                break;
            case 'complete':
                if ($toDest > COMPLETE_RIDE_MAX_METERS + $compensation) {
                    hub_fail('Ride can only be completed at the destination zone. Current distance: ' . round($toDest) . ' m.', 'CONFLICT');
                }
                if (in_array((string)$ride['ride_type'], ['dispatch', 'send_me'], true) && trim((string)$ride['delivery_otp']) !== '' && empty($ride['delivery_otp_verified_at'])) {
                    hub_fail('Verify the recipient OTP before completing this delivery.', 'CONFLICT');
                }
                $message = 'Ride completed successfully.';
                $extra = ', completed_at = CURRENT_TIMESTAMP';
                break;
            case 'cancel':
                $message = 'Ride canceled.';
                $extra = ", canceled_at = NOW(), cancel_reason = IFNULL(cancel_reason, 'driver_canceled')";
                break;
        }

        $t = pm_ride_transition($rideId, $transition, 'driver_id', $driverId, $extra);
        if (!$t['changed']) {
            return ['message' => 'Ride already ' . $target . '.', 'status' => $target, 'phase' => $phase, 'base' => $base, 'notify' => null];
        }

        // --- money movement (only on the request that performed the transition) ---
        $chargeable = $rideAction === 'complete' || ($rideAction === 'cancel' && in_array($current, ['in_progress', 'arrived_destination'], true));
        if ($chargeable) {
            $price = round((float)$ride['price'], 2);
            $feePct = appFeePercent();
            $appFee = round($price * $feePct / 100.0, 2);
            $currency = (string)($ride['currency'] ?? 'NGN');
            $ref = 'RIDE_' . $rideId;
            $riderUid = (string)$ride['rider_id'];

            if ($rideAction === 'complete' && ($ride['pay_method'] ?? 'cash') === 'wallet' && $price > 0) {
                if (pm_wallet_debit($riderUid, $price)) {
                    pm_ledger_add($riderUid, $price, 'minus', 'Paid for ride via wallet', $ref, 'wallet');
                    pm_wallet_credit($userUid, $price);
                    pm_ledger_add($userUid, $price, 'plus', 'Ride earnings from rider', $ref, 'wallet');
                } else {
                    // Rider wallet no longer covers the fare: settle in cash instead of going negative.
                    pm_exec("UPDATE ride_rides SET pay_method = 'cash' WHERE id = ?", 'i', [$rideId]);
                    $message .= ' Rider wallet balance was insufficient — collect ' . $currency . ' ' . number_format($price, 2) . ' in cash.';
                }
            }
            if ($appFee > 0) {
                if (!pm_wallet_debit($userUid, $appFee)) {
                    $bal = (float)(pm_wallet_balance($userUid) ?? 0);
                    hub_fail('Insufficient balance to cover the app fee (' . $currency . ' ' . number_format($appFee, 2) . '). Please fund your wallet with (' . $currency . ' ' . number_format(max(0, $appFee - $bal), 2) . ') to be able to complete this transaction.', 'CONFLICT');
                }
                pm_ledger_add($userUid, $appFee, 'minus', 'App service fee (' . rtrim(rtrim(number_format($feePct, 2, '.', ''), '0'), '.') . '%)', $ref, 'wallet');
            }
        }

        if ($rideAction === 'complete') {
            pm_exec('UPDATE ride_drivers SET completed_trips = completed_trips + 1, total_trips = total_trips + 1 WHERE id = ? LIMIT 1', 'i', [$driverId]);
        } elseif ($rideAction === 'cancel') {
            pm_exec('UPDATE ride_drivers SET cancelled_trips = cancelled_trips + 1, total_trips = total_trips + 1 WHERE id = ? LIMIT 1', 'i', [$driverId]);
            $weight = (float)($ride['package_weight'] ?? 0);
            if ($weight > 0 && !empty($ride['batch_group_id']) && empty($ride['delivery_otp_verified_at'])) {
                pm_exec('UPDATE ride_drivers SET current_payload_weight = GREATEST(0, current_payload_weight - ?) WHERE id = ?', 'di', [$weight, $driverId]);
            }
        }
        pm_exec('UPDATE ride_driver_locations SET phase = ?, updated_at = CURRENT_TIMESTAMP WHERE driver_id = ? LIMIT 1', 'si', [$phase, $driverId]);

        return ['message' => $message, 'status' => $target, 'phase' => $phase, 'base' => $base, 'notify' => (string)$ride['rider_id']];
    });

    if ($out['notify']) {
        $riderUid = $out['notify'];
        $status = $out['status'];
        $msg = $out['message'];
        pm_defer(static function () use ($riderUid, $rideId, $status, $msg): void {
            pm_push_ride_update($riderUid, 'Trip update', $msg, ['ride_id' => (string)$rideId, 'status' => $status]);
        });
    }

    return [
        'error'   => false,
        'message' => $out['message'],
        'data'    => $out['base'] + ['status' => $out['status'], 'phase' => $out['phase']],
    ];
}

// ---------------------------------------------------------------------------
try {
    $action = pm_in_str($IN, 'action', 40, 'dashboard');
    switch ($action) {
        case 'dashboard':
            pm_json(dashboard($sessionUid));
            break;
        case 'set_online':
            pm_json(setOnline($sessionUid, hub_param('is_online', 'Online status', 1), pm_in_float($IN, 'lat', 0.0), pm_in_float($IN, 'lng', 0.0), pm_in_float($IN, 'heading', 0.0)));
            break;
        case 'heartbeat':
            hub_param('lat', 'Latitude');
            hub_param('lng', 'Longitude');
            pm_json(heartbeat($sessionUid, pm_in_float($IN, 'lat', 0.0), pm_in_float($IN, 'lng', 0.0), pm_in_float($IN, 'heading', 0.0), pm_in_str($IN, 'phase', 40, 'idle')));
            break;
        case 'accept_ride':
            pm_json(acceptRide($sessionUid, (int)hub_param('ride_id', 'Ride ID', 20)));
            break;
        case 'ride_action':
            pm_json(rideAction($sessionUid, (int)hub_param('ride_id', 'Ride ID', 20), hub_param('ride_action', 'Ride action', 40)));
            break;
        case 'verify_otp':
            pm_json(verifyDeliveryOtp($sessionUid, (int)hub_param('ride_id', 'Ride ID', 20), hub_param('otp', 'OTP', 10)));
            break;
        case 'scan_dispatch_batch':
            hub_param('lat', 'Latitude');
            hub_param('lng', 'Longitude');
            pm_json(scanAndBatchDispatchRides($sessionUid, pm_in_float($IN, 'lat', 0.0), pm_in_float($IN, 'lng', 0.0)));
            break;
        default:
            hub_fail('Unsupported driver action.');
    }
} catch (PmHttpError $e) {
    $status = $e->httpStatus;
    // Legacy contract for this endpoint: business errors are HTTP 200 with error:true.
    if (!in_array($e->apiCode, ['UNAUTHORIZED', 'SESSION_EXPIRED', 'RATE_LIMITED'], true) && $status !== 403) {
        $status = 200;
    }
    pm_error($e->apiCode, $e->getMessage(), $status, $e->extra + ['data' => null]);
}
