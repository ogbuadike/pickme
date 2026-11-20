<?php
declare(strict_types=1);

/**
 * Shared ride helpers + the ride state machine (contract §8).
 * Library file — not an endpoint.
 *
 * Canonical statuses: searching → accepted → enroute_pickup → arrived_pickup → in_progress
 *                     → arrived_destination → completed ; any pre-terminal → canceled
 * Legacy aliases accepted on read: driver_assigned (=accepted), in_ride (=in_progress), cancelled (=canceled).
 */

if (isset($_SERVER['SCRIPT_FILENAME']) && realpath((string)$_SERVER['SCRIPT_FILENAME']) === __FILE__) {
    http_response_code(404);
    exit;
}

require_once __DIR__ . '/security.php';
require_once __DIR__ . '/activities.php';

const PM_RIDE_SEARCH_TTL_MIN = 30;

/**
 * action => [allowed source statuses, target status]
 * Only the listed edges are legal; every transition is a single conditional UPDATE.
 */
const PM_RIDE_TRANSITIONS = [
    'accept'              => [['searching'], 'accepted'],
    'enroute_pickup'      => [['accepted', 'driver_assigned', 'enroute_pickup'], 'enroute_pickup'],
    'arrived_pickup'      => [['accepted', 'driver_assigned', 'enroute_pickup'], 'arrived_pickup'],
    'start_trip'          => [['arrived_pickup'], 'in_progress'],
    'rider_start_trip'    => [['accepted', 'driver_assigned', 'enroute_pickup', 'arrived_pickup'], 'in_progress'],
    'arrived_destination' => [['in_progress', 'in_ride'], 'arrived_destination'],
    'complete'            => [['in_progress', 'in_ride', 'arrived_destination'], 'completed'],
    'driver_cancel'       => [['searching', 'accepted', 'driver_assigned', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'in_ride', 'arrived_destination'], 'canceled'],
    'rider_cancel'        => [['searching', 'accepted', 'driver_assigned', 'enroute_pickup', 'arrived_pickup'], 'canceled'],
];

// ---------------------------------------------------------------------------
// Legacy helper names (kept so endpoint code stays readable)
// ---------------------------------------------------------------------------
function ride_json(array $payload, int $status = 200): void
{
    pm_json($payload, $status);
}

/** Returns the session user's uid (contract §2/§3). */
function ride_authorize(): string
{
    return pm_require_session();
}

function ride_input(): array
{
    return pm_input();
}

function ride_s($v, string $fallback = ''): string
{
    $x = pm_clean_text($v, 1000);
    return $x === '' ? $fallback : $x;
}

function ride_i($v, int $fallback = 0): int
{
    if (is_int($v)) {
        return $v;
    }
    if (is_scalar($v) && is_numeric(trim((string)$v))) {
        return (int)trim((string)$v);
    }
    return $fallback;
}

function ride_f($v, float $fallback = 0.0): float
{
    if (is_float($v) || is_int($v)) {
        return is_finite((float)$v) ? (float)$v : $fallback;
    }
    if (is_scalar($v) && is_numeric(trim((string)$v))) {
        $f = (float)trim((string)$v);
        return is_finite($f) ? $f : $fallback;
    }
    return $fallback;
}

function ride_parse_latlng($compound, $latField, $lngField): array
{
    $lat = 0.0;
    $lng = 0.0;
    if (is_array($compound)) {
        $lat = ride_f($compound['lat'] ?? $compound['latitude'] ?? null, 0.0);
        $lng = ride_f($compound['lng'] ?? $compound['longitude'] ?? null, 0.0);
    } elseif (is_string($compound) && strpos($compound, ',') !== false) {
        $parts = explode(',', $compound, 2);
        $lat = ride_f($parts[0] ?? null, 0.0);
        $lng = ride_f($parts[1] ?? null, 0.0);
    }
    if ($lat == 0.0 && $lng == 0.0) {
        $lat = ride_f($latField, 0.0);
        $lng = ride_f($lngField, 0.0);
    }
    return [$lat, $lng];
}

function ride_query_one(?mysqli $db, string $sql, string $types = '', array $params = []): ?array
{
    return pm_q_one($sql, $types, $params);
}

function ride_exec(?mysqli $db, string $sql, string $types = '', array $params = []): int
{
    return pm_exec($sql, $types, $params);
}

function ride_haversine_m(float $lat1, float $lng1, float $lat2, float $lng2): float
{
    return pm_haversine_m($lat1, $lng1, $lat2, $lng2);
}

function ride_norm_status(string $status): string
{
    $s = strtolower(trim($status));
    if ($s === 'driver_assigned') {
        return 'accepted';
    }
    if ($s === 'in_ride') {
        return 'in_progress';
    }
    if ($s === 'cancelled') {
        return 'canceled';
    }
    return $s === '' ? 'searching' : $s;
}

function ride_fetch_driver(?mysqli $db, int $driverId): ?array
{
    return pm_q_one(
        'SELECT d.id, d.name, d.category, d.vehicle_type, d.car_plate, d.rating, l.lat, l.lng, l.heading
         FROM ride_drivers d
         LEFT JOIN ride_driver_locations l ON l.driver_id = d.id
         WHERE d.id = ?
         LIMIT 1',
        'i',
        [$driverId]
    );
}

function ride_fetch_ride(?mysqli $db, int $rideId, bool $forUpdate = false): ?array
{
    return pm_q_one('SELECT * FROM ride_rides WHERE id = ? LIMIT 1' . ($forUpdate ? ' FOR UPDATE' : ''), 'i', [$rideId]);
}

/**
 * Loads a ride the session user may see: as rider (rider_id) or as the assigned driver.
 * Unknown or foreign rides both yield 404 (no enumeration).
 */
function ride_fetch_owned(int $rideId, string $uid, ?array &$driverRow = null): array
{
    $ride = ride_fetch_ride(null, $rideId);
    if ($ride !== null && hash_equals((string)$ride['rider_id'], $uid)) {
        return $ride;
    }
    if ($ride !== null && (int)($ride['driver_id'] ?? 0) > 0) {
        $drv = pm_driver_for_user($uid);
        if ($drv !== null && (int)($drv['id'] ?? 0) === (int)$ride['driver_id']) {
            $driverRow = $drv;
            return $ride;
        }
    }
    pm_error('NOT_FOUND', 'Ride not found', 404);
    return [];
}

/**
 * Atomic conditional transition.
 *
 * @param string $ownerCol 'driver_id' or 'rider_id' (server-defined, never user input)
 * @param string $extraSet server-defined SQL fragment, e.g. ", started_at = IFNULL(started_at, NOW())"
 * @return array{changed: bool, ride: array, from: string}
 */
function pm_ride_transition(int $rideId, string $action, string $ownerCol, $ownerVal, string $extraSet = '', string $extraTypes = '', array $extraParams = []): array
{
    if (!isset(PM_RIDE_TRANSITIONS[$action]) || !in_array($ownerCol, ['driver_id', 'rider_id'], true)) {
        throw new InvalidArgumentException('invalid transition definition');
    }
    [$from, $to] = PM_RIDE_TRANSITIONS[$action];
    $ownerType = $ownerCol === 'driver_id' ? 'i' : 's';

    $sql = 'UPDATE ride_rides SET status = ?, updated_at = CURRENT_TIMESTAMP' . $extraSet
         . ' WHERE id = ? AND ' . $ownerCol . ' = ? AND status IN (' . pm_in_placeholders($from) . ')';
    if ($action === 'accept') {
        $sql .= ' AND created_at > NOW() - INTERVAL ' . PM_RIDE_SEARCH_TTL_MIN . ' MINUTE';
    }
    $sql .= ' LIMIT 1';

    $types = 's' . $extraTypes . 'i' . $ownerType . str_repeat('s', count($from));
    $params = array_merge([$to], $extraParams, [$rideId, $ownerVal], $from);
    $changed = pm_exec($sql, $types, $params) === 1;

    $ride = pm_q_one('SELECT * FROM ride_rides WHERE id = ? AND ' . $ownerCol . ' = ? LIMIT 1', 'i' . $ownerType, [$rideId, $ownerVal]);
    if ($ride === null) {
        pm_fail('NOT_FOUND', 'Ride not found', 404);
    }
    $current = ride_norm_status((string)$ride['status']);
    if (!$changed && $current !== $to) {
        pm_fail('CONFLICT', 'Ride cannot change from ' . $current . ' to ' . $to . '.', 409, ['status' => $current]);
    }
    return ['changed' => $changed, 'ride' => $ride, 'from' => $current];
}

/** Lazily expires stale searching rides (throttled; index idx_ride_rides_status_created). */
function pm_ride_expire_stale(): void
{
    $due = true;
    if (function_exists('apcu_add') && filter_var(ini_get('apc.enabled'), FILTER_VALIDATE_BOOLEAN)) {
        $due = apcu_add('pickme_ride_expire_lock', 1, 60);
    } else {
        $due = random_int(1, 20) === 1;
    }
    if (!$due) {
        return;
    }
    try {
        pm_exec(
            "UPDATE ride_rides SET status = 'canceled', canceled_at = IFNULL(canceled_at, NOW()), cancel_reason = IFNULL(cancel_reason, 'expired')
             WHERE status = 'searching' AND created_at <= NOW() - INTERVAL " . PM_RIDE_SEARCH_TTL_MIN . ' MINUTE
             LIMIT 500'
        );
    } catch (mysqli_sql_exception $e) {
        pm_log('warning', 'ride expiry sweep failed', ['msg' => $e->getMessage()]);
    }
}

function ride_payload(array $ride, ?array $driver = null): array
{
    $status = ride_norm_status((string)($ride['status'] ?? 'searching'));

    $driverPayload = null;
    if ($driver) {
        $driverPayload = [
            'id'           => (string)($driver['id'] ?? ''),
            'name'         => ride_s($driver['name'] ?? ''),
            'category'     => ride_s($driver['category'] ?? ''),
            'vehicle_type' => ride_s($driver['vehicle_type'] ?? ''),
            'car_plate'    => ride_s($driver['car_plate'] ?? ''),
            'rating'       => ride_f($driver['rating'] ?? 0, 0),
            'lat'          => ride_f($driver['lat'] ?? 0, 0),
            'lng'          => ride_f($driver['lng'] ?? 0, 0),
            'heading'      => ride_f($driver['heading'] ?? 0, 0),
        ];
    }

    return [
        'error'          => false,
        'ride_id'        => (string)$ride['id'],
        'trip_id'        => (string)$ride['id'],
        'status'         => $status,
        'phase'          => $status,
        'ride_status'    => $status,
        'driver_lat'     => $driverPayload ? (float)$driverPayload['lat'] : 0.0,
        'driver_lng'     => $driverPayload ? (float)$driverPayload['lng'] : 0.0,
        'driver_heading' => $driverPayload ? (float)$driverPayload['heading'] : 0.0,
        'ride' => [
            'id'                => (string)$ride['id'],
            'rider_id'          => ride_s($ride['rider_id'] ?? ''),
            'driver_id'         => (string)($ride['driver_id'] ?? ''),
            'offer_id'          => ride_s($ride['offer_id'] ?? ''),
            'status'            => $status,
            'provider'          => ride_s($ride['provider'] ?? 'Pick Me'),
            'category'          => ride_s($ride['category'] ?? 'Standard'),
            'vehicle_type'      => ride_s($ride['vehicle_type'] ?? 'car'),
            'currency'          => ride_s($ride['currency'] ?? 'NGN'),
            'pay_method'        => ride_s($ride['pay_method'] ?? 'cash'),
            'price'             => ride_f($ride['price'] ?? 0, 0),
            'pickup' => [
                'lat'  => ride_f($ride['pickup_lat'] ?? 0, 0),
                'lng'  => ride_f($ride['pickup_lng'] ?? 0, 0),
                'text' => ride_s($ride['pickup_text'] ?? ''),
            ],
            'destination' => [
                'lat'  => ride_f($ride['dest_lat'] ?? 0, 0),
                'lng'  => ride_f($ride['dest_lng'] ?? 0, 0),
                'text' => ride_s($ride['dest_text'] ?? ''),
            ],
            'pickup_lat'        => ride_f($ride['pickup_lat'] ?? 0, 0),
            'pickup_lng'        => ride_f($ride['pickup_lng'] ?? 0, 0),
            'dest_lat'          => ride_f($ride['dest_lat'] ?? 0, 0),
            'dest_lng'          => ride_f($ride['dest_lng'] ?? 0, 0),
            'ride_type'         => ride_s($ride['ride_type'] ?? 'street_ride'),
            'stops_json'        => $ride['stops_json'] ?? null,
            'eta_min'           => ride_i($ride['eta_min'] ?? 0, 0),
            'surge'             => ride_i($ride['surge'] ?? 0, 0),
            'started_at'        => $ride['started_at'] ?? null,
            'arrived_pickup_at' => $ride['arrived_pickup_at'] ?? null,
            'completed_at'      => $ride['completed_at'] ?? null,
            'canceled_at'       => $ride['canceled_at'] ?? null,
            'cancel_reason'     => $ride['cancel_reason'] ?? null,
            'created_at'        => $ride['created_at'] ?? null,
            'updated_at'        => $ride['updated_at'] ?? null,
        ],
        'driver' => $driverPayload,
    ];
}
