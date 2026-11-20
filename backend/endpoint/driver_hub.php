<?php
declare(strict_types=1);

/**
 * POST driver_hub.php — driver command centre (session required, activated driver).
 *
 * action = dashboard | set_online | heartbeat | accept_ride | decline_ride | ride_action | verify_otp
 *          (scan_dispatch_batch is retired → 410)
 *
 * Identity: the driver is resolved from the session user. The client still sends `user`; it must equal
 * the session uid, and a client-sent driver_id must match the session driver (else 403 FORBIDDEN).
 *
 * Errors use the contract envelope with real HTTP codes:
 *   422 VALIDATION · 403 FORBIDDEN (not an activated driver / not allowed) · 404 NOT_FOUND
 *   409 CONFLICT (lost accept race, illegal transition, stale GPS, insufficient balance) · 429 RATE_LIMITED
 *
 * Idempotency: accept_ride / decline_ride / ride_action honour the Idempotency-Key header (or request_id);
 * a repeated key replays the original success response. On top of that every transition is a single
 * conditional UPDATE inside a transaction holding the ride row lock, so exactly one driver can win a
 * ride and a repeated action never moves money twice.
 */

require_once __DIR__ . '/ride_api_bootstrap.php';

const DRIVER_FIX_MAX_AGE_SEC = 180;
const ARRIVAL_RADIUS_METERS = 200.0;          // unified pickup / start / destination / complete radius
const MAX_ACCURACY_COMPENSATION_M = 50.0;     // client-reported GPS accuracy is capped at this
const DELIVERY_OTP_MAX_ATTEMPTS = 5;          // hard cap per ride
const QUEUE_RADIUS_KM = 15.0;                 // open (unassigned) requests shown within this radius
const DEFAULT_PAYLOAD_CAPACITY_KG = 50.0;     // used when a driver has no max_payload_weight configured
const DEFAULT_APP_FEE_PERCENT = 25.0;

pm_require_method('POST');
$sessionUid = pm_require_session();
$IN = pm_input();

function hub_fail(string $message, string $code = 'VALIDATION', int $status = 0): void
{
    pm_fail($code, $message, $status, ['data' => null]);
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

/**
 * Optional client GPS: returns [lat, lng] when supplied and valid, null when absent,
 * and rejects (422) a supplied-but-invalid fix (0,0 / out of range / non-numeric).
 */
function hub_client_fix(bool $required = false): ?array
{
    global $IN;
    $hasLat = isset($IN['lat']) && trim((string)$IN['lat']) !== '';
    $hasLng = isset($IN['lng']) && trim((string)$IN['lng']) !== '';
    if (!$hasLat && !$hasLng) {
        if ($required) {
            hub_fail('Latitude and longitude are required.');
        }
        return null;
    }
    $lat = pm_in_float($IN, 'lat', 0.0);
    $lng = pm_in_float($IN, 'lng', 0.0);
    if (!$hasLat || !$hasLng || !pm_valid_lat($lat) || !pm_valid_lng($lng)) {
        hub_fail('Latitude and longitude are invalid.');
    }
    return [$lat, $lng];
}

function hub_accuracy_compensation(): float
{
    global $IN;
    return min(max(pm_in_float($IN, 'accuracy', 15.0), 0.0), MAX_ACCURACY_COMPENSATION_M);
}

function fetchDriverSession(string $userUid): array
{
    $row = pm_require_driver($userUid, 403);
    $user = pm_q_one('SELECT u_uid, fname, lname, email, phone AS user_phone FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$userUid]);
    return array_merge($row, $user ?? []);
}

function driverAllowedTypes(array $session): array
{
    $types = array_filter(array_map('trim', explode(',', (string)($session['allowed_ride_types'] ?? ''))));
    return $types ?: ['street_ride'];
}

function driverCapacityKg(array $session): float
{
    $max = (float)($session['max_payload_weight'] ?? 0);
    return $max > 0 ? $max : DEFAULT_PAYLOAD_CAPACITY_KG;
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
        'SELECT driver_id, lat, lng, heading, speed, accuracy, phase, updated_at,
                TIMESTAMPDIFF(SECOND, updated_at, CURRENT_TIMESTAMP) AS db_age_sec
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
        'speed'      => $row['speed'] !== null ? (float)$row['speed'] : null,
        'accuracy'   => $row['accuracy'] !== null ? (float)$row['accuracy'] : null,
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
    if (!pm_valid_lat($live['lat']) || !pm_valid_lng($live['lng']) || $live['age_sec'] > $maxAgeSec) {
        hub_fail('Driver GPS fix is stale (' . $live['age_sec'] . 's). Keep the app open until live location refreshes.', 'CONFLICT');
    }
    return $live;
}

function phaseForRideAction(string $rideAction, string $fallback = 'idle'): string
{
    $map = ['enroute_pickup' => 'enroute_pickup', 'arrived_pickup' => 'waiting_pickup', 'start_trip' => 'enroute_destination',
            'arrived_destination' => 'arrived_destination', 'complete' => 'idle', 'cancel' => 'idle'];
    return $map[$rideAction] ?? $fallback;
}

/** Writes a validated fix; callers validate first (pm_valid_lat/lng). */
function upsertDriverLive(int $driverId, float $lat, float $lng, float $heading, string $phase, ?float $speed = null, ?float $accuracy = null): void
{
    if (!pm_valid_lat($lat) || !pm_valid_lng($lng)) {
        return;
    }
    $heading = fmod(max(0.0, $heading), 360.0);
    $speed = $speed !== null ? min(max($speed, 0.0), 100.0) : null;
    $accuracy = $accuracy !== null ? min(max($accuracy, 0.0), 10000.0) : null;
    pm_exec(
        'INSERT INTO ride_driver_locations (driver_id, lat, lng, heading, speed, accuracy, phase, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
         ON DUPLICATE KEY UPDATE lat = VALUES(lat), lng = VALUES(lng), heading = VALUES(heading),
                                 speed = VALUES(speed), accuracy = VALUES(accuracy), phase = VALUES(phase), updated_at = CURRENT_TIMESTAMP',
        'iddddds',
        [$driverId, $lat, $lng, $heading, $speed, $accuracy, $phase]
    );
}

/** Reserves / releases a parcel's weight on the driver exactly once (ride_rides.payload_reserved flag). */
function reservePayload(int $rideId, int $driverId, float $weight): void
{
    if ($weight <= 0) {
        return;
    }
    if (pm_exec('UPDATE ride_rides SET payload_reserved = 1 WHERE id = ? AND payload_reserved = 0', 'i', [$rideId]) === 1) {
        pm_exec('UPDATE ride_drivers SET current_payload_weight = current_payload_weight + ? WHERE id = ?', 'di', [$weight, $driverId]);
    }
}

function releasePayload(int $rideId, int $driverId): void
{
    $r = pm_q_one('SELECT package_weight FROM ride_rides WHERE id = ?', 'i', [$rideId]);
    $weight = (float)($r['package_weight'] ?? 0);
    if (pm_exec('UPDATE ride_rides SET payload_reserved = 0 WHERE id = ? AND payload_reserved = 1', 'i', [$rideId]) === 1 && $weight > 0) {
        pm_exec('UPDATE ride_drivers SET current_payload_weight = GREATEST(0, current_payload_weight - ?) WHERE id = ?', 'di', [$weight, $driverId]);
    }
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
        'allowed_ride_types'     => $s['allowed_ride_types'] ?? 'street_ride',
        'max_payload_weight'     => (float)($s['max_payload_weight'] ?? 0),
        'current_payload_weight' => (float)($s['current_payload_weight'] ?? 0),
    ];
}

/**
 * Ride as seen by the DRIVER. The delivery OTP is never sent (requires_otp flag instead);
 * rider / recipient phone numbers are only included once this driver has accepted the ride.
 */
function mapRidePayload(?array $ride, float $distanceKm = -1.0): ?array
{
    if (!$ride) {
        return null;
    }
    $rideType = (string)($ride['ride_type'] ?? 'street_ride');
    $status = ride_norm_status((string)($ride['status'] ?? 'searching'));
    $accepted = in_array($status, ['accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination'], true);
    $packageImage = trim((string)($ride['package_image'] ?? ''));
    if ($packageImage === '' && in_array($rideType, ['dispatch', 'send_me'], true)) {
        $packageImage = 'https://phantomphones.store/pick_me/img/logo.png';
    }
    $requiresOtp = trim((string)($ride['delivery_otp'] ?? '')) !== '';

    $out = [
        'id'                => (int)$ride['id'],
        'status'            => $status,
        'ride_type'         => $rideType,
        'package_size'      => $ride['package_size'] ?? null,
        'package_weight'    => (float)($ride['package_weight'] ?? 0),
        'requires_otp'      => $requiresOtp,
        'otp_verified'      => !empty($ride['delivery_otp_verified_at']),
        'batch_group_id'    => $ride['batch_group_id'] ?? null,
        'recipient_phone'   => $accepted ? ($ride['recipient_phone'] ?? null) : null,
        'instructions'      => $ride['instructions'] ?? null,
        'package_image'     => $packageImage,
        'app_fee_percentage'=> appFeePercent(),
        'rider_id'          => (string)($ride['rider_id'] ?? ''),
        'rider_name'        => trim((string)($ride['rider_name'] ?? '')) !== '' ? trim((string)$ride['rider_name']) : 'Rider',
        'rider_phone'       => $accepted ? (string)($ride['rider_phone'] ?? '') : '',
        'pickup_lat'        => (float)($ride['pickup_lat'] ?? 0),
        'pickup_lng'        => (float)($ride['pickup_lng'] ?? 0),
        'pickup_text'       => $ride['pickup_text'] ?? '',
        'dest_lat'          => (float)($ride['dest_lat'] ?? 0),
        'dest_lng'          => (float)($ride['dest_lng'] ?? 0),
        'dest_text'         => $ride['dest_text'] ?? '',
        'price'             => (float)($ride['price'] ?? 0),
        'currency'          => $ride['currency'] ?? 'NGN',
        'eta_min'           => (int)($ride['eta_min'] ?? 0),
        'pay_method'        => $ride['pay_method'] ?? 'cash',
        'vehicle_type'      => $ride['vehicle_type'] ?? 'car',
        'seats'             => (int)($ride['seats'] ?? 4),
        'created_at'        => $ride['created_at'] ?? null,
        'updated_at'        => $ride['updated_at'] ?? null,
        'started_at'        => $ride['started_at'] ?? null,
        'arrived_pickup_at' => $ride['arrived_pickup_at'] ?? null,
        'completed_at'      => $ride['completed_at'] ?? null,
    ];
    if ($distanceKm >= 0) {
        $out['pickup_distance_km'] = round($distanceKm, 3);
    }
    return $out;
}

/**
 * Offer queue: requests booked for this driver, plus open requests within QUEUE_RADIUS_KM of the
 * driver's fresh fix (bounding box on idx_rr_dispatch_scan / idx_ride_rides_search_queue, then haversine),
 * restricted to the driver's allowed ride types and remaining payload capacity, minus declined rides.
 */
function fetchQueueRides(array $session, int $limit = 12): array
{
    $driverId = (int)$session['id'];
    $types = driverAllowedTypes($session);
    $capacity = max(0.0, driverCapacityKg($session) - (float)($session['current_payload_weight'] ?? 0));
    $live = fetchDriverLive($driverId);
    $hasFix = $live && pm_valid_lat($live['lat']) && pm_valid_lng($live['lng']) && $live['age_sec'] <= DRIVER_FIX_MAX_AGE_SEC;

    $sql = "SELECT r.*, CONCAT(TRIM(COALESCE(u.fname, '')), ' ', TRIM(COALESCE(u.lname, ''))) AS rider_name
            FROM ride_rides r
            LEFT JOIN unique_user_table u ON u.u_uid = r.rider_id
            WHERE r.status = 'searching'
              AND r.created_at > NOW() - INTERVAL " . PM_RIDE_SEARCH_TTL_MIN . ' MINUTE
              AND r.ride_type IN (' . pm_in_placeholders($types) . ')
              AND COALESCE(r.package_weight, 0) <= ?
              AND NOT EXISTS (SELECT 1 FROM ride_declines rd WHERE rd.ride_id = r.id AND rd.driver_id = ?)';
    $t = str_repeat('s', count($types)) . 'di';
    $p = array_merge($types, [$capacity, $driverId]);
    if ($hasFix) {
        [$minLat, $maxLat, $minLng, $maxLng] = pm_bbox($live['lat'], $live['lng'], QUEUE_RADIUS_KM);
        $sql .= ' AND (r.driver_id = ? OR ((r.driver_id IS NULL OR r.driver_id = 0)
                       AND r.pickup_lat BETWEEN ? AND ? AND r.pickup_lng BETWEEN ? AND ?))';
        $t .= 'idddd';
        array_push($p, $driverId, $minLat, $maxLat, $minLng, $maxLng);
    } else {
        $sql .= ' AND r.driver_id = ?';
        $t .= 'i';
        $p[] = $driverId;
    }
    $sql .= ' ORDER BY CASE WHEN r.driver_id = ? THEN 0 ELSE 1 END, r.created_at DESC LIMIT 60';
    $t .= 'i';
    $p[] = $driverId;

    $out = [];
    foreach (pm_q_all($sql, $t, $p) as $row) {
        $dist = $hasFix ? pm_haversine_m($live['lat'], $live['lng'], (float)$row['pickup_lat'], (float)$row['pickup_lng']) / 1000.0 : -1.0;
        if ((int)($row['driver_id'] ?? 0) !== $driverId && $dist > QUEUE_RADIUS_KM) {
            continue;
        }
        $out[] = mapRidePayload($row, $dist);
        if (count($out) >= $limit) {
            break;
        }
    }
    return $out;
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
            'queue'       => fetchQueueRides($session, 12),
        ],
    ];
}

function setOnline(string $userUid, string $isOnline): array
{
    global $IN;
    if (!in_array($isOnline, ['0', '1'], true)) {
        hub_fail('Online status must be 0 or 1.');
    }
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    $online = $isOnline === '1' ? 1 : 0;
    $fix = $online === 1 ? hub_client_fix() : null;

    pm_tx(function () use ($driverId, $online, $fix, $IN) {
        pm_exec('UPDATE ride_drivers SET is_online = ?, updated_at = NOW() WHERE id = ? LIMIT 1', 'ii', [$online, $driverId]);
        if ($online === 1 && $fix !== null) {
            upsertDriverLive($driverId, $fix[0], $fix[1], pm_in_float($IN, 'heading', 0.0), 'idle',
                isset($IN['speed']) ? pm_in_float($IN, 'speed', 0.0) : null, isset($IN['accuracy']) ? pm_in_float($IN, 'accuracy', 0.0) : null);
        } elseif ($online === 0) {
            // Hide from every map immediately (map queries exclude 0,0).
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
        'data'    => ['driver_id' => $driverId, 'is_online' => $online, 'lat' => $fix[0] ?? 0.0, 'lng' => $fix[1] ?? 0.0],
    ];
}

function heartbeat(string $userUid, string $phase): array
{
    global $IN;
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    pm_rate_limit('driver_heartbeat', (string)$driverId, 60, 60, 'Location updates are too frequent.');
    if ((int)$session['is_online'] !== 1) {
        hub_fail('Driver must be online before publishing live location.', 'CONFLICT');
    }
    [$lat, $lng] = hub_client_fix(true);
    $allowedPhases = ['idle', 'enroute_pickup', 'waiting_pickup', 'enroute_destination', 'arrived_destination'];
    if (!in_array($phase, $allowedPhases, true)) {
        $phase = 'idle';
    }
    $heading = pm_in_float($IN, 'heading', 0.0);
    $speed = isset($IN['speed']) ? pm_in_float($IN, 'speed', 0.0) : null;
    $accuracy = isset($IN['accuracy']) ? pm_in_float($IN, 'accuracy', 0.0) : null;
    upsertDriverLive($driverId, $lat, $lng, $heading, $phase, $speed, $accuracy);
    return [
        'error'   => false,
        'message' => 'Live driver location updated.',
        'data'    => ['driver_id' => $driverId, 'lat' => $lat, 'lng' => $lng, 'heading' => $heading, 'speed' => $speed, 'accuracy' => $accuracy, 'phase' => $phase],
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
    $types = driverAllowedTypes($session);

    $result = pm_tx(function () use ($driverId, $rideId, $session, $types) {
        // Per-driver lock serialises this driver's accepts: never two active rides, capacity read is current.
        $drv = pm_q_one('SELECT max_payload_weight, current_payload_weight FROM ride_drivers WHERE id = ? FOR UPDATE', 'i', [$driverId]);
        $ride = ride_fetch_ride(null, $rideId, true);
        if (!$ride) {
            hub_fail('Ride request no longer exists.', 'NOT_FOUND');
        }
        $current = ride_norm_status((string)$ride['status']);
        $assigned = (int)($ride['driver_id'] ?? 0);
        if ($assigned === $driverId && $current === 'accepted') {
            return ['idempotent' => true, 'ride' => $ride];
        }
        if ($current !== 'searching' || ($assigned > 0 && $assigned !== $driverId)) {
            hub_fail('This ride has already been taken by another driver.', 'CONFLICT');
        }
        if (!in_array((string)$ride['ride_type'], $types, true)) {
            hub_fail('Your vehicle is not authorized for this ride type.', 'FORBIDDEN');
        }
        $weight = (float)($ride['package_weight'] ?? 0);
        $capacity = driverCapacityKg(['max_payload_weight' => $drv['max_payload_weight'] ?? 0]) - (float)($drv['current_payload_weight'] ?? 0);
        if ($weight > 0 && $weight > $capacity) {
            hub_fail('This package exceeds your remaining payload capacity.', 'CONFLICT');
        }
        $busy = pm_q_one(
            'SELECT id FROM ride_rides WHERE driver_id = ? AND id <> ? AND status IN (' . pm_in_placeholders(PM_RIDE_ACTIVE_STATUSES) . ') LIMIT 1',
            'ii' . str_repeat('s', count(PM_RIDE_ACTIVE_STATUSES)),
            array_merge([$driverId, $rideId], PM_RIDE_ACTIVE_STATUSES)
        );
        if ($busy) {
            hub_fail('Finish the current trip before accepting another ride.', 'CONFLICT');
        }

        // Single conditional UPDATE — exactly one driver wins.
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
            hub_fail('This ride has already been taken by another driver.', 'CONFLICT');
        }
        reservePayload($rideId, $driverId, $weight);
        pm_exec(
            "INSERT INTO ride_driver_locations (driver_id, lat, lng, heading, phase) VALUES (?, 0, 0, 0, 'enroute_pickup')
             ON DUPLICATE KEY UPDATE phase = 'enroute_pickup', updated_at = updated_at",
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

/**
 * Records the decline (the ride is never offered to this driver again). A request booked
 * specifically for this driver is closed (canceled, reason driver_declined) so the rider can rebook.
 */
function declineRide(string $userUid, int $rideId): array
{
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    if ($rideId <= 0) {
        hub_fail('Ride ID is invalid.');
    }
    $ride = pm_q_one('SELECT id, rider_id, driver_id, status FROM ride_rides WHERE id = ? LIMIT 1', 'i', [$rideId]);
    if (!$ride) {
        hub_fail('Ride request no longer exists.', 'NOT_FOUND');
    }
    pm_exec('INSERT IGNORE INTO ride_declines (ride_id, driver_id, created_at) VALUES (?, ?, NOW())', 'ii', [$rideId, $driverId]);
    $closed = pm_exec(
        "UPDATE ride_rides SET status = 'canceled', canceled_at = NOW(), cancel_reason = 'driver_declined'
         WHERE id = ? AND driver_id = ? AND status = 'searching' LIMIT 1",
        'ii',
        [$rideId, $driverId]
    ) === 1;
    if ($closed) {
        $riderUid = (string)$ride['rider_id'];
        pm_defer(static function () use ($riderUid, $rideId): void {
            pm_push_ride_update($riderUid, 'Driver unavailable', 'Your driver could not take this trip. Please choose another driver.', ['ride_id' => (string)$rideId, 'status' => 'canceled']);
        });
    }
    return ['error' => false, 'message' => 'Ride declined.', 'data' => ['ride_id' => $rideId, 'driver_id' => $driverId, 'request_closed' => $closed]];
}

/** Server-side delivery OTP check: constant-time, max DELIVERY_OTP_MAX_ATTEMPTS per ride, idempotent. */
function verifyDeliveryOtp(string $userUid, int $rideId, string $providedOtp): array
{
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    if ($rideId <= 0) {
        hub_fail('Ride ID is invalid.');
    }
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
        hub_fail('This delivery is locked after too many wrong codes. Contact support.', 'RATE_LIMITED', 429);
    }

    $provided = preg_replace('/\D/', '', $providedOtp) ?? '';
    if (!hash_equals($expected, $provided)) {
        // Counted atomically and committed immediately (autocommit), even under parallel requests.
        pm_exec('UPDATE ride_rides SET delivery_otp_attempts = delivery_otp_attempts + 1 WHERE id = ? AND delivery_otp_attempts < ?', 'ii', [$rideId, DELIVERY_OTP_MAX_ATTEMPTS]);
        $left = max(0, DELIVERY_OTP_MAX_ATTEMPTS - (int)$ride['delivery_otp_attempts'] - 1);
        hub_fail('Invalid Secure OTP. Handoff denied. ' . $left . ' attempt(s) left.', 'VALIDATION', 422);
    }

    pm_tx(function () use ($rideId, $driverId) {
        $first = pm_exec('UPDATE ride_rides SET delivery_otp_verified_at = NOW() WHERE id = ? AND driver_id = ? AND delivery_otp_verified_at IS NULL', 'ii', [$rideId, $driverId]);
        if ($first === 1) {
            releasePayload($rideId, $driverId); // once, on the first successful verification
        }
    });
    return ['error' => false, 'message' => 'OTP Verified successfully. Chain of custody confirmed.', 'data' => ['ride_id' => $rideId, 'verified' => true]];
}

/**
 * Ride actions with GPS gating and money movement.
 * GPS: arrived_pickup / start_trip / arrived_destination / complete need a fresh fix inside
 * ARRIVAL_RADIUS_METERS (+ accuracy, capped at 50 m). enroute_pickup and cancel do not need GPS.
 * Money: on complete (or a driver cancel after the trip started) the app fee is taken from the driver;
 * wallet-paid fares move rider → driver on complete. All in one transaction with the transition.
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

    $fix = hub_client_fix();
    if ($fix !== null) {
        upsertDriverLive($driverId, $fix[0], $fix[1], pm_in_float($IN, 'heading', 0.0), phaseForRideAction($rideAction),
            isset($IN['speed']) ? pm_in_float($IN, 'speed', 0.0) : null, isset($IN['accuracy']) ? pm_in_float($IN, 'accuracy', 0.0) : null);
    }
    $radius = ARRIVAL_RADIUS_METERS + hub_accuracy_compensation();
    $needsGps = in_array($rideAction, ['arrived_pickup', 'start_trip', 'arrived_destination', 'complete'], true);

    $out = pm_tx(function () use ($driverId, $rideId, $rideAction, $userUid, $radius, $needsGps) {
        $ride = pm_q_one('SELECT * FROM ride_rides WHERE id = ? AND driver_id = ? LIMIT 1 FOR UPDATE', 'ii', [$rideId, $driverId]);
        if (!$ride) {
            hub_fail('No active ride was found for this driver action.', 'NOT_FOUND');
        }
        $current = ride_norm_status((string)$ride['status']);
        $transition = $rideAction === 'cancel' ? 'driver_cancel' : $rideAction;
        [$from, $target] = PM_RIDE_TRANSITIONS[$transition];
        $phase = phaseForRideAction($rideAction);

        if ($current === $target) { // replay (double tap / retry): no GPS needed, no side effects
            return ['message' => 'Ride already ' . $target . '.', 'status' => $target, 'phase' => $phase, 'base' => ['ride_id' => $rideId, 'driver_id' => $driverId], 'notify' => null];
        }
        $live = $needsGps ? requireFreshDriverLive($driverId) : fetchDriverLive($driverId);
        $hasFix = $live !== null && pm_valid_lat($live['lat']) && pm_valid_lng($live['lng']);
        $toPickup = $hasFix ? pm_haversine_m($live['lat'], $live['lng'], (float)$ride['pickup_lat'], (float)$ride['pickup_lng']) : null;
        $toDest = $hasFix ? pm_haversine_m($live['lat'], $live['lng'], (float)$ride['dest_lat'], (float)$ride['dest_lng']) : null;
        $base = [
            'ride_id' => $rideId, 'driver_id' => $driverId,
            'distance_to_pickup_m' => $toPickup !== null ? round($toPickup, 2) : null,
            'distance_to_destination_m' => $toDest !== null ? round($toDest, 2) : null,
            'driver_fix_age_sec' => $live['age_sec'] ?? null,
        ];

        if (!in_array($current, array_map('ride_norm_status', $from), true)) {
            hub_fail('Ride cannot move to ' . $target . ' from ' . $current . '.', 'CONFLICT');
        }

        $extra = '';
        switch ($rideAction) {
            case 'enroute_pickup':
                $message = 'Driver is heading to pickup.';
                break;
            case 'arrived_pickup':
                if ($toPickup > $radius) {
                    hub_fail('Driver must be inside the pickup zone before marking arrived. Current distance: ' . round($toPickup) . ' m.', 'CONFLICT');
                }
                $message = 'Driver has arrived at pickup.';
                $extra = ', arrived_pickup_at = NOW()';
                break;
            case 'start_trip':
                if ($toPickup > $radius) {
                    hub_fail('Driver and rider must still be together inside pickup zone before starting trip. Current distance: ' . round($toPickup) . ' m.', 'CONFLICT');
                }
                $message = 'Trip started. Driver is en route to destination.';
                $extra = ', started_at = IFNULL(started_at, NOW())';
                break;
            case 'arrived_destination':
                if ($toDest > $radius) {
                    hub_fail('Driver must be inside the destination zone before marking arrived. Current distance: ' . round($toDest) . ' m.', 'CONFLICT');
                }
                $message = 'Driver reached the destination.';
                break;
            case 'complete':
                if ($toDest > $radius) {
                    hub_fail('Ride can only be completed at the destination zone. Current distance: ' . round($toDest) . ' m.', 'CONFLICT');
                }
                if (in_array((string)$ride['ride_type'], ['dispatch', 'send_me'], true) && trim((string)$ride['delivery_otp']) !== '' && empty($ride['delivery_otp_verified_at'])) {
                    hub_fail('Verify the recipient OTP before completing this delivery.', 'CONFLICT');
                }
                $message = 'Ride completed successfully.';
                $extra = ', completed_at = CURRENT_TIMESTAMP';
                break;
            default: // cancel
                $message = 'Ride canceled.';
                $extra = ", canceled_at = NOW(), cancel_reason = IFNULL(cancel_reason, 'driver_canceled')";
                break;
        }

        $t = pm_ride_transition($rideId, $transition, 'driver_id', $driverId, $extra);
        if (!$t['changed']) {
            return ['message' => 'Ride already ' . $target . '.', 'status' => $target, 'phase' => $phase, 'base' => $base, 'notify' => null];
        }

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
            releasePayload($rideId, $driverId); // no-op when already released by OTP verification
        } elseif ($rideAction === 'cancel') {
            pm_exec('UPDATE ride_drivers SET cancelled_trips = cancelled_trips + 1, total_trips = total_trips + 1 WHERE id = ? LIMIT 1', 'i', [$driverId]);
            releasePayload($rideId, $driverId);
        }
        pm_exec('UPDATE ride_driver_locations SET phase = ?, updated_at = updated_at WHERE driver_id = ? LIMIT 1', 'si', [$phase, $driverId]);

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
    return ['error' => false, 'message' => $out['message'], 'data' => $out['base'] + ['status' => $out['status'], 'phase' => $out['phase']]];
}

// ---------------------------------------------------------------------------
try {
    $action = pm_in_str($IN, 'action', 40, 'dashboard');
    if (in_array($action, ['accept_ride', 'decline_ride', 'ride_action'], true)) {
        pm_idempotency_begin($sessionUid, 'driver_hub:' . $action);
    }
    switch ($action) {
        case 'dashboard':
            pm_json(dashboard($sessionUid));
            break;
        case 'set_online':
            pm_json(setOnline($sessionUid, hub_param('is_online', 'Online status', 1)));
            break;
        case 'heartbeat':
            pm_json(heartbeat($sessionUid, pm_in_str($IN, 'phase', 40, 'idle')));
            break;
        case 'accept_ride':
            pm_json(acceptRide($sessionUid, (int)hub_param('ride_id', 'Ride ID', 20)));
            break;
        case 'decline_ride':
            pm_json(declineRide($sessionUid, (int)hub_param('ride_id', 'Ride ID', 20)));
            break;
        case 'ride_action':
            pm_json(rideAction($sessionUid, (int)hub_param('ride_id', 'Ride ID', 20), hub_param('ride_action', 'Ride action', 40)));
            break;
        case 'verify_otp':
            pm_rate_limit('delivery_otp_driver', $sessionUid, 20, 900, 'Too many OTP attempts. Please wait.');
            pm_json(verifyDeliveryOtp($sessionUid, (int)hub_param('ride_id', 'Ride ID', 20), hub_param('otp', 'OTP', 10)));
            break;
        case 'scan_dispatch_batch':
            hub_fail('Dispatch batching has been retired. Accept dispatch requests from the queue.', 'VALIDATION', 410);
            break;
        default:
            hub_fail('Unsupported driver action.');
    }
} catch (PmHttpError $e) {
    pm_error($e->apiCode, $e->getMessage(), $e->httpStatus, $e->extra + ['data' => null]);
}
