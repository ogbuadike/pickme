<?php
declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');

require_once '../unique/unique_con.php';
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

if (!isset($dbconn) || !($dbconn instanceof mysqli)) {
    http_response_code(500);
    echo json_encode(['error' => true, 'message' => 'Database connection unavailable']);
    exit;
}

mysqli_set_charset($dbconn, 'utf8mb4');

function ride_json(array $payload, int $status = 200): void {
    http_response_code($status);
    echo json_encode($payload);
    exit;
}

function ride_headers_safe(): array {
    if (function_exists('apache_request_headers')) {
        $h = apache_request_headers();
        if (is_array($h)) return $h;
    }

    $out = [];
    foreach ($_SERVER as $k => $v) {
        if (strpos($k, 'HTTP_') === 0) {
            $name = str_replace(' ', '-', ucwords(strtolower(str_replace('_', ' ', substr($k, 5)))));
            $out[$name] = $v;
        }
    }

    if (isset($_SERVER['CONTENT_TYPE'])) {
        $out['Content-Type'] = $_SERVER['CONTENT_TYPE'];
    }

    if (isset($_SERVER['Authorization'])) {
        $out['Authorization'] = $_SERVER['Authorization'];
    }

    return $out;
}

function ride_authorize(): void {
    $headers = ride_headers_safe();
    $token = '';

    foreach ($headers as $k => $v) {
        if (strtolower((string)$k) === 'authorization') {
            $token = trim((string)$v);
            break;
        }
    }

    if ($token === '' || !checkAuthorization($token)) {
        ride_json(['error' => true, 'message' => 'Unauthorized'], 401);
    }
}

function ride_input(): array {
    $raw = file_get_contents('php://input');
    if (is_string($raw) && trim($raw) !== '') {
        $json = json_decode($raw, true);
        if (is_array($json)) {
            return $json;
        }
    }
    return is_array($_POST) ? $_POST : [];
}

function ride_s($v, string $fallback = ''): string {
    if ($v === null) return $fallback;
    $x = trim((string)$v);
    return $x === '' ? $fallback : $x;
}

function ride_i($v, int $fallback = 0): int {
    if ($v === null || $v === '') return $fallback;
    if (is_int($v)) return $v;
    if (is_numeric($v)) return (int)$v;
    return $fallback;
}

function ride_f($v, float $fallback = 0.0): float {
    if ($v === null || $v === '') return $fallback;
    if (is_float($v) || is_int($v)) return (float)$v;
    if (is_numeric($v)) return (float)$v;
    return $fallback;
}

function ride_parse_latlng($compound, $latField, $lngField): array {
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

function ride_bind(mysqli_stmt $stmt, string $types, array $params): void {
    if ($types === '') return;

    $bind = [$types];
    foreach ($params as $k => $v) {
        $bind[] = &$params[$k];
    }

    if (!call_user_func_array([$stmt, 'bind_param'], $bind)) {
        ride_json(['error' => true, 'message' => 'bind_param failed'], 500);
    }
}

function ride_stmt_assoc_one(mysqli_stmt $stmt): ?array {
    $meta = $stmt->result_metadata();
    if (!$meta) return null;

    $row = [];
    $bind = [];

    while ($field = $meta->fetch_field()) {
        $row[$field->name] = null;
        $bind[] = &$row[$field->name];
    }

    call_user_func_array([$stmt, 'bind_result'], $bind);

    if (!$stmt->fetch()) {
        $stmt->free_result();
        return null;
    }

    $out = [];
    foreach ($row as $k => $v) {
        $out[$k] = $v;
    }

    $stmt->free_result();
    return $out;
}

function ride_query_one(mysqli $db, string $sql, string $types = '', array $params = []): ?array {
    $stmt = mysqli_prepare($db, $sql);
    if (!$stmt) {
        ride_json(['error' => true, 'message' => 'Prepare failed: ' . mysqli_error($db)], 500);
    }

    if ($types !== '') {
        ride_bind($stmt, $types, $params);
    }

    if (!mysqli_stmt_execute($stmt)) {
        $err = mysqli_stmt_error($stmt);
        mysqli_stmt_close($stmt);
        ride_json(['error' => true, 'message' => 'Execute failed: ' . $err], 500);
    }

    $row = ride_stmt_assoc_one($stmt);
    mysqli_stmt_close($stmt);
    return $row;
}

function ride_exec(mysqli $db, string $sql, string $types = '', array $params = []): mysqli_stmt {
    $stmt = mysqli_prepare($db, $sql);
    if (!$stmt) {
        ride_json(['error' => true, 'message' => 'Prepare failed: ' . mysqli_error($db)], 500);
    }

    if ($types !== '') {
        ride_bind($stmt, $types, $params);
    }

    if (!mysqli_stmt_execute($stmt)) {
        $err = mysqli_stmt_error($stmt);
        mysqli_stmt_close($stmt);
        ride_json(['error' => true, 'message' => 'Execute failed: ' . $err], 500);
    }

    return $stmt;
}

function ride_haversine_m(float $lat1, float $lng1, float $lat2, float $lng2): float {
    $earth = 6371000.0;
    $dLat = deg2rad($lat2 - $lat1);
    $dLng = deg2rad($lng2 - $lng1);
    $a = sin($dLat / 2) * sin($dLat / 2)
       + cos(deg2rad($lat1)) * cos(deg2rad($lat2))
       * sin($dLng / 2) * sin($dLng / 2);
    return 2 * $earth * asin(min(1, sqrt($a)));
}

function ride_fetch_driver(mysqli $db, int $driverId): ?array {
    return ride_query_one(
        $db,
        "SELECT d.id, d.name, d.category, d.vehicle_type, d.car_plate, d.rating,
                l.lat, l.lng, l.heading
         FROM ride_drivers d
         LEFT JOIN ride_driver_locations l ON l.driver_id = d.id
         WHERE d.id = ?
         LIMIT 1",
        'i',
        [$driverId]
    );
}

function ride_fetch_ride(mysqli $db, int $rideId): ?array {
    return ride_query_one(
        $db,
        "SELECT * FROM ride_rides WHERE id = ? LIMIT 1",
        'i',
        [$rideId]
    );
}

function ride_payload(array $ride, ?array $driver = null): array {
    $status = ride_s($ride['status'] ?? 'searching', 'searching');

    $driverPayload = null;
    if ($driver) {
        $driverPayload = [
            'id' => (string)($driver['id'] ?? ''),
            'name' => ride_s($driver['name'] ?? ''),
            'category' => ride_s($driver['category'] ?? ''),
            'vehicle_type' => ride_s($driver['vehicle_type'] ?? ''),
            'car_plate' => ride_s($driver['car_plate'] ?? ''),
            'rating' => ride_f($driver['rating'] ?? 0, 0),
            'lat' => ride_f($driver['lat'] ?? 0, 0),
            'lng' => ride_f($driver['lng'] ?? 0, 0),
            'heading' => ride_f($driver['heading'] ?? 0, 0),
        ];
    }

    return [
        'error' => false,
        'ride_id' => (string)$ride['id'],
        'trip_id' => (string)$ride['id'],
        'status' => $status,
        'phase' => $status,
        'ride_status' => $status,

        'driver_lat' => $driverPayload ? (float)$driverPayload['lat'] : 0.0,
        'driver_lng' => $driverPayload ? (float)$driverPayload['lng'] : 0.0,
        'driver_heading' => $driverPayload ? (float)$driverPayload['heading'] : 0.0,

        'ride' => [
            'id' => (string)$ride['id'],
            'rider_id' => ride_s($ride['rider_id'] ?? ''),
            'driver_id' => (string)($ride['driver_id'] ?? ''),
            'offer_id' => ride_s($ride['offer_id'] ?? ''),
            'status' => $status,
            'provider' => ride_s($ride['provider'] ?? 'Pick Me'),
            'category' => ride_s($ride['category'] ?? 'Standard'),
            'vehicle_type' => ride_s($ride['vehicle_type'] ?? 'car'),
            'currency' => ride_s($ride['currency'] ?? 'NGN'),
            'pay_method' => ride_s($ride['pay_method'] ?? 'cash'),
            'price' => ride_f($ride['price'] ?? 0, 0),
            'pickup' => [
                'lat' => ride_f($ride['pickup_lat'] ?? 0, 0),
                'lng' => ride_f($ride['pickup_lng'] ?? 0, 0),
                'text' => ride_s($ride['pickup_text'] ?? ''),
            ],
            'destination' => [
                'lat' => ride_f($ride['dest_lat'] ?? 0, 0),
                'lng' => ride_f($ride['dest_lng'] ?? 0, 0),
                'text' => ride_s($ride['dest_text'] ?? ''),
            ],
            'stops_json' => $ride['stops_json'] ?? null,
            'eta_min' => ride_i($ride['eta_min'] ?? 0, 0),
            'surge' => ride_i($ride['surge'] ?? 0, 0),
            'started_at' => $ride['started_at'] ?? null,
            'arrived_pickup_at' => $ride['arrived_pickup_at'] ?? null,
            'completed_at' => $ride['completed_at'] ?? null,
            'canceled_at' => $ride['canceled_at'] ?? null,
            'cancel_reason' => $ride['cancel_reason'] ?? null,
            'created_at' => $ride['created_at'] ?? null,
            'updated_at' => $ride['updated_at'] ?? null,
        ],
        'driver' => $driverPayload,
    ];
}