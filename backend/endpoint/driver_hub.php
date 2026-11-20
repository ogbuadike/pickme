<?php
header('Content-Type: application/json');
//driver_hub.php
require_once '../unique/unique_con.php';
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

// ==================================================================
// 📡 GPS TRACKING CONSTANTS 
// ==================================================================
const DRIVER_FIX_MAX_AGE_SEC = 180;
const ARRIVED_PICKUP_MAX_METERS = 200.0;
const START_TRIP_MAX_METERS = 200.0;
const ARRIVED_DESTINATION_MAX_METERS = 150.0;
const COMPLETE_RIDE_MAX_METERS = 200.0;
// ==================================================================

function jsonResponse(array $payload, int $statusCode = 200): void {
    http_response_code($statusCode);
    echo json_encode($payload);
    exit();
}

function sanitizeInput($input): string {
    return trim(htmlspecialchars((string)$input, ENT_QUOTES, 'UTF-8'));
}

function headersSafe(): array {
    if (function_exists('apache_request_headers')) {
        $headers = apache_request_headers();
        if (is_array($headers)) return $headers;
    }

    $headers = [];
    foreach ($_SERVER as $key => $value) {
        if (strpos($key, 'HTTP_') === 0) {
            $name = str_replace(' ', '-', ucwords(strtolower(str_replace('_', ' ', substr($key, 5)))));
            $headers[$name] = $value;
        }
    }
    return $headers;
}

function authorizeRequest(): void {
    $headers = headersSafe();
    $token = '';
    foreach ($headers as $key => $value) {
        if (strtolower((string)$key) === 'authorization') {
            $token = trim((string)$value);
            break;
        }
    }
    if ($token === '' || !checkAuthorization($token)) {
        jsonResponse(['error' => true, 'message' => 'Unauthorized access', 'data' => null], 401);
    }
}

authorizeRequest();

function requirePosted(string $key, string $label): string {
    $value = isset($_POST[$key]) ? sanitizeInput($_POST[$key]) : '';
    if ($value === '') {
        throw new Exception($label . ' is required.');
    }
    return $value;
}

function normalizeDriverStatus(string $value): string {
    $status = strtolower(trim($value));
    if ($status === 'approved' || $status === 'activated') return 'activated';
    if ($status === 'pending') return 'pending';
    if ($status === 'rejected') return 'rejected';
    return 'not_started';
}

function normalizeRideStatus(string $value): string {
    $status = strtolower(trim($value));
    if ($status === 'driver_assigned') return 'accepted';
    if ($status === 'in_ride') return 'in_progress';
    return $status === '' ? 'searching' : $status;
}

function activeRideStatusesSql(): string {
    return "'accepted','enroute_pickup','arrived_pickup','in_progress','arrived_destination','driver_assigned','in_ride'";
}

function haversineMeters(float $lat1, float $lng1, float $lat2, float $lng2): float {
    $earth = 6371000.0;
    $dLat = deg2rad($lat2 - $lat1);
    $dLng = deg2rad($lng2 - $lng1);
    $a = sin($dLat / 2) * sin($dLat / 2) +
         cos(deg2rad($lat1)) * cos(deg2rad($lat2)) *
         sin($dLng / 2) * sin($dLng / 2);
    return 2.0 * $earth * asin(min(1.0, sqrt($a)));
}

function fetchDriverSession(string $userUid): array {
    global $dbconn;

    $escapedUid = mysqli_real_escape_string($dbconn, $userUid);
    
    $sql = "SELECT
                o.id AS onboarding_id,
                o.status AS onboarding_status,
                o.driver_id,
                o.admin_note,
                d.id,
                d.name,
                d.phone,
                d.nin,
                d.rank,
                d.category,
                d.rating,
                d.car_plate,
                d.vehicle_type,
                d.seats,
                d.avatar_url,
                d.completed_trips,
                d.total_trips,
                d.cancelled_trips,
                d.incomplete_trips,
                d.is_online,
                d.currency,
                d.allowed_ride_types,
                d.max_payload_weight,
                d.current_payload_weight,
                u.u_uid,
                u.fname,
                u.lname,
                u.email,
                u.phone AS user_phone
            FROM ride_driver_onboarding o
            LEFT JOIN ride_drivers d ON d.id = o.driver_id
            LEFT JOIN unique_user_table u ON u.u_uid = o.user_uid
            WHERE o.user_uid='$escapedUid'
            ORDER BY o.id DESC
            LIMIT 1";

    $result = mysqli_query($dbconn, $sql);
    if (!$result || mysqli_num_rows($result) === 0) {
        throw new Exception('No driver onboarding record was found for this account.');
    }

    $row = mysqli_fetch_assoc($result);
    $status = normalizeDriverStatus((string)($row['onboarding_status'] ?? ''));
    if ($status !== 'activated' || !isset($row['id']) || $row['id'] === null) {
        throw new Exception('Driver account is not yet activated.');
    }
    return $row;
}

function fetchDriverLive(int $driverId): ?array {
    global $dbconn;
    $driverId = (int)$driverId;
    $sql = "SELECT driver_id, lat, lng, heading, phase, updated_at,
                   TIMESTAMPDIFF(SECOND, updated_at, CURRENT_TIMESTAMP) AS db_age_sec
            FROM ride_driver_locations
            WHERE driver_id=$driverId
            LIMIT 1";
            
    $result = mysqli_query($dbconn, $sql);
    if (!$result || mysqli_num_rows($result) === 0) return null;
    $row = mysqli_fetch_assoc($result);
    
    $ageSec = isset($row['db_age_sec']) ? (int)$row['db_age_sec'] : PHP_INT_MAX;
    if ($ageSec < 0) $ageSec = 0;

    return [
        'driver_id' => (int)$row['driver_id'],
        'lat' => isset($row['lat']) ? (float)$row['lat'] : 0.0,
        'lng' => isset($row['lng']) ? (float)$row['lng'] : 0.0,
        'heading' => isset($row['heading']) ? (float)$row['heading'] : 0.0,
        'phase' => (string)($row['phase'] ?? 'idle'),
        'updated_at' => $row['updated_at'] ?? null,
        'age_sec' => $ageSec,
    ];
}

function requireFreshDriverLive(int $driverId, int $maxAgeSec = DRIVER_FIX_MAX_AGE_SEC): array {
    $live = fetchDriverLive($driverId);
    if (!$live) {
        throw new Exception('Driver live location is unavailable. Wait for GPS sync and try again.');
    }
    if (($live['lat'] == 0.0 && $live['lng'] == 0.0) || (int)$live['age_sec'] > $maxAgeSec) {
        throw new Exception('Driver GPS fix is stale (' . $live['age_sec'] . 's). Keep the app open until live location refreshes.');
    }
    return $live;
}

function phaseForRideAction(string $rideAction, string $fallback = 'idle'): string {
    switch ($rideAction) {
        case 'enroute_pickup':
        case 'head_to_pickup':
        case 'start_to_pickup':
            return 'enroute_pickup';
        case 'arrived_pickup':
            return 'waiting_pickup';
        case 'start_trip':
            return 'enroute_destination';
        case 'arrived_destination':
            return 'arrived_destination';
        case 'complete':
        case 'complete_trip':
        case 'cancel':
        case 'cancel_trip':
        case 'cancel_ride':
            return 'idle';
        default:
            return $fallback;
    }
}

function upsertDriverLiveFromClient(int $driverId, ?string $latRaw, ?string $lngRaw, ?string $headingRaw, string $phase = 'idle'): void {
    global $dbconn;
    if ($latRaw === null || $lngRaw === null) return;

    $lat = (float)$latRaw;
    $lng = (float)$lngRaw;
    if (($lat == 0.0 && $lng == 0.0) || !is_finite($lat) || !is_finite($lng)) return;

    $heading = $headingRaw !== null ? (float)$headingRaw : 0.0;
    $driverId = (int)$driverId;
    $phaseEscaped = mysqli_real_escape_string($dbconn, $phase);

    $sql = "INSERT INTO ride_driver_locations (driver_id, lat, lng, heading, phase, updated_at)
            VALUES ($driverId, $lat, $lng, $heading, '$phaseEscaped', CURRENT_TIMESTAMP)
            ON DUPLICATE KEY UPDATE lat=VALUES(lat), lng=VALUES(lng), heading=VALUES(heading), phase=VALUES(phase), updated_at=CURRENT_TIMESTAMP";
    mysqli_query($dbconn, $sql);
}

function buildDriverPayload(array $session): array {
    return [
        'id' => (int)$session['id'],
        'name' => (string)$session['name'],
        'phone' => $session['phone'],
        'nin' => $session['nin'],
        'rank' => $session['rank'],
        'category' => $session['category'],
        'rating' => (float)$session['rating'],
        'car_plate' => $session['car_plate'],
        'vehicle_type' => $session['vehicle_type'],
        'seats' => (int)$session['seats'],
        'avatar_url' => $session['avatar_url'],
        'completed_trips' => (int)$session['completed_trips'],
        'total_trips' => (int)$session['total_trips'],
        'cancelled_trips' => (int)$session['cancelled_trips'],
        'incomplete_trips' => (int)$session['incomplete_trips'],
        'is_online' => (int)$session['is_online'],
        'currency' => $session['currency'] ?? 'NGN',
        'status' => 'activated',
        
        'allowed_ride_types' => $session['allowed_ride_types'] ?? 'street_ride,campus_ride',
        'max_payload_weight' => isset($session['max_payload_weight']) ? (float)$session['max_payload_weight'] : 0.0,
        'current_payload_weight' => isset($session['current_payload_weight']) ? (float)$session['current_payload_weight'] : 0.0,
    ];
}

function mapRidePayload(?array $ride): ?array {
    if (!$ride) return null;
    
    // FETCH DYNAMIC APP FEE ONLY ONCE PER REQUEST LIFECYCLE
    static $cachedFee = null;
    if ($cachedFee === null) {
        global $dbconn;
        $feeQuery = mysqli_query($dbconn, "SELECT setting_value FROM app_settings WHERE setting_key = 'app_ride_fee_percentage' LIMIT 1");
        $cachedFee = ($feeQuery && mysqli_num_rows($feeQuery) > 0) ? (float)mysqli_fetch_assoc($feeQuery)['setting_value'] : 25.0;
    }

    $status = normalizeRideStatus((string)($ride['status'] ?? 'searching'));
    $rideType = $ride['ride_type'] ?? 'street_ride';
    
    // Fallback logo logic for Deliveries (Send Me & Dispatch)
    $packageImage = trim((string)($ride['package_image'] ?? ''));
    if ($packageImage === '' && in_array($rideType, ['dispatch', 'send_me'])) {
        $packageImage = 'https://phantomphones.store/pick_me/img/logo.png';
    }

    return [
        'id' => (int)$ride['id'],
        'status' => $status,
        
        'ride_type' => $rideType,
        'package_size' => $ride['package_size'] ?? null,
        'package_weight' => isset($ride['package_weight']) ? (float)$ride['package_weight'] : 0.0,
        'delivery_otp' => $ride['delivery_otp'] ?? null,
        'batch_group_id' => $ride['batch_group_id'] ?? null,
        'recipient_phone' => $ride['recipient_phone'] ?? null,
        
        'instructions' => $ride['instructions'] ?? null,
        'package_image' => $packageImage,
        
        // --- 💰 DYNAMIC MONETIZATION SENT TO APP ---
        'app_fee_percentage' => $cachedFee,
        // ------------------------------------------
        
        'rider_id' => (string)($ride['rider_id'] ?? ''),
        'rider_name' => trim((string)($ride['rider_name'] ?? '')) !== '' ? trim((string)$ride['rider_name']) : 'Rider',
        'rider_phone' => $ride['rider_phone'] ?? '',
        'pickup_lat' => isset($ride['pickup_lat']) ? (float)$ride['pickup_lat'] : 0.0,
        'pickup_lng' => isset($ride['pickup_lng']) ? (float)$ride['pickup_lng'] : 0.0,
        'pickup_text' => $ride['pickup_text'] ?? '',
        'dest_lat' => isset($ride['dest_lat']) ? (float)$ride['dest_lat'] : 0.0,
        'dest_lng' => isset($ride['dest_lng']) ? (float)$ride['dest_lng'] : 0.0,
        'dest_text' => $ride['dest_text'] ?? '',
        'price' => isset($ride['price']) ? (float)$ride['price'] : 0.0,
        'currency' => $ride['currency'] ?? 'NGN',
        'eta_min' => isset($ride['eta_min']) ? (int)$ride['eta_min'] : 0,
        'pay_method' => $ride['pay_method'] ?? 'cash',
        'vehicle_type' => $ride['vehicle_type'] ?? 'car',
        'seats' => isset($ride['seats']) ? (int)$ride['seats'] : 4,
        'created_at' => $ride['created_at'] ?? null,
        'updated_at' => $ride['updated_at'] ?? null,
        'started_at' => $ride['started_at'] ?? null,
        'arrived_pickup_at' => $ride['arrived_pickup_at'] ?? null,
        'completed_at' => $ride['completed_at'] ?? null,
    ];
}

function fetchQueueRides(int $driverId, int $limit = 10): array {
    global $dbconn;
    $driverId = (int)$driverId;
    $limit = (int)$limit;
    
    $sql = "SELECT
                r.*,
                CONCAT(TRIM(COALESCE(u.fname, '')), ' ', TRIM(COALESCE(u.lname, ''))) AS rider_name,
                u.phone AS rider_phone
            FROM ride_rides r
            LEFT JOIN unique_user_table u ON u.u_uid = r.rider_id
            WHERE r.status='searching'
              AND (r.driver_id = $driverId OR r.driver_id IS NULL OR r.driver_id = 0)
            ORDER BY CASE WHEN r.driver_id = $driverId THEN 0 ELSE 1 END, r.created_at DESC
            LIMIT $limit";
    $result = mysqli_query($dbconn, $sql);
    $rows = [];
    if ($result) {
        while ($row = mysqli_fetch_assoc($result)) {
            $rows[] = $row;
        }
    }
    return $rows;
}

function fetchActiveRide(int $driverId): ?array {
    global $dbconn;
    $driverId = (int)$driverId;
    $sql = "SELECT
                r.*,
                CONCAT(TRIM(COALESCE(u.fname, '')), ' ', TRIM(COALESCE(u.lname, ''))) AS rider_name,
                u.phone AS rider_phone
            FROM ride_rides r
            LEFT JOIN unique_user_table u ON u.u_uid = r.rider_id
            WHERE r.driver_id = $driverId
              AND r.status IN (" . activeRideStatusesSql() . ")
            ORDER BY r.updated_at DESC
            LIMIT 1";
    $result = mysqli_query($dbconn, $sql);
    if ($result && mysqli_num_rows($result) > 0) {
        return mysqli_fetch_assoc($result);
    }
    return null;
}

function dashboard(string $userUid): array {
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    return [
        'error' => false,
        'message' => 'Driver dashboard loaded.',
        'data' => [
            'driver' => buildDriverPayload($session),
            'driver_live' => fetchDriverLive($driverId),
            'active_ride' => mapRidePayload(fetchActiveRide($driverId)),
            'queue' => array_map('mapRidePayload', fetchQueueRides($driverId, 12)),
        ],
    ];
}

// ==================================================================
// 🟢 ONLINE STATUS & INITIAL GPS SYNC
// ==================================================================
function setOnline(string $userUid, string $isOnline, float $lat = 0.0, float $lng = 0.0, float $heading = 0.0): array {
    global $dbconn;
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    $online = $isOnline === '1' ? 1 : 0;

    // 1. Update the main driver profile status
    if (!mysqli_query($dbconn, "UPDATE ride_drivers SET is_online=$online, updated_at=NOW() WHERE id=$driverId LIMIT 1")) {
        throw new Exception('Unable to update driver online status.');
    }

    // 2. Handle Location Updates
    if ($online === 1) {
        // DRIVER ONLINE: Insert or update their actual exact location immediately
        $sql = "INSERT INTO ride_driver_locations (driver_id, lat, lng, heading, phase)
                VALUES ($driverId, $lat, $lng, $heading, 'idle')
                ON DUPLICATE KEY UPDATE 
                lat = $lat, 
                lng = $lng, 
                heading = $heading, 
                phase = 'idle', 
                updated_at = CURRENT_TIMESTAMP";
                
        mysqli_query($dbconn, $sql);
    } else {
        // DRIVER OFFLINE: Nullify the location to prevent ghost cars on the map
        $sql = "INSERT INTO ride_driver_locations (driver_id, lat, lng, heading, phase)
                VALUES ($driverId, 0, 0, 0, 'idle')
                ON DUPLICATE KEY UPDATE 
                lat = 0,
                lng = 0,
                phase = 'idle', 
                updated_at = CURRENT_TIMESTAMP";
                
        mysqli_query($dbconn, $sql);
    }

     Activities("Driver is now online and visible to riders.",$driverId);
    return [
        'error' => false,
        'message' => $online === 1 ? 'Driver is now online and visible to riders.' : 'Driver is now offline and hidden from riders.',
        'data' => [
            'driver_id' => $driverId,
            'is_online' => $online,
            'lat' => $lat,
            'lng' => $lng
        ],
    ];
}

function heartbeat(string $userUid, string $lat, string $lng, string $heading, string $phase): array {
    global $dbconn;
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    if ((int)$session['is_online'] !== 1) {
        throw new Exception('Driver must be online before publishing live location.');
    }

    $latF = (float)$lat;
    $lngF = (float)$lng;
    $headingF = (float)$heading;
    $phaseSafe = sanitizeInput($phase);
    if ($phaseSafe === '') $phaseSafe = 'idle';
    $phaseEsc = mysqli_real_escape_string($dbconn, $phaseSafe);

    $sql = "INSERT INTO ride_driver_locations (driver_id, lat, lng, heading, phase)
            VALUES ($driverId, $latF, $lngF, $headingF, '$phaseEsc')
            ON DUPLICATE KEY UPDATE lat=VALUES(lat), lng=VALUES(lng), heading=VALUES(heading), phase=VALUES(phase), updated_at=CURRENT_TIMESTAMP";
    if (!mysqli_query($dbconn, $sql)) {
        throw new Exception('Unable to update driver live location.');
    }

    return [
        'error' => false,
        'message' => 'Live driver location updated.',
        'data' => [
            'driver_id' => $driverId,
            'lat' => $latF,
            'lng' => $lngF,
            'heading' => $headingF,
            'phase' => $phaseSafe,
        ],
    ];
}

function phaseForRideStatus(string $status): string {
    switch (normalizeRideStatus($status)) {
        case 'accepted':
        case 'enroute_pickup':
            return 'enroute_pickup';
        case 'arrived_pickup':
            return 'waiting_pickup';
        case 'in_progress':
            return 'enroute_destination';
        case 'arrived_destination':
            return 'arrived_destination';
        default:
            return 'idle';
    }
}

function acceptRide(string $userUid, string $rideIdRaw): array {
    global $dbconn;
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    $rideId = (int)$rideIdRaw;

    if ((int)$session['is_online'] !== 1) {
        throw new Exception('Go online before accepting ride requests.');
    }
    if ($rideId <= 0) {
        throw new Exception('Ride ID is invalid.');
    }

    $busy = mysqli_query($dbconn, "SELECT id FROM ride_rides WHERE driver_id=$driverId AND status IN (" . activeRideStatusesSql() . ") LIMIT 1");
    if ($busy && mysqli_num_rows($busy) > 0) {
        throw new Exception('Finish the current trip before accepting another ride.');
    }

    mysqli_begin_transaction($dbconn);
    try {
        // [NOV-DEV NOTE]: "FOR UPDATE" is critical here! It locks this specific row in the database.
        // If two drivers click "Accept" at the exact same millisecond, the database puts them in a queue. 
        // The first driver gets it, the second driver is thrown the exception below because the status changed.
        $lockResult = mysqli_query($dbconn, "SELECT * FROM ride_rides WHERE id=$rideId LIMIT 1 FOR UPDATE");
        if (!$lockResult || mysqli_num_rows($lockResult) === 0) {
            throw new Exception('Ride request no longer exists.');
        }
        $ride = mysqli_fetch_assoc($lockResult);
        $currentStatus = normalizeRideStatus((string)($ride['status'] ?? 'searching'));
        $requestedDriverId = isset($ride['driver_id']) ? (int)$ride['driver_id'] : 0;

        if ($currentStatus !== 'searching') {
            throw new Exception('This ride has already moved beyond queue state.');
        }
        if ($requestedDriverId > 0 && $requestedDriverId !== $driverId) {
            throw new Exception('This request is assigned to another driver queue.');
        }

        $driverName = mysqli_real_escape_string($dbconn, (string)$session['name']);
        $carPlate = mysqli_real_escape_string($dbconn, (string)$session['car_plate']);
        if (!mysqli_query($dbconn, "UPDATE ride_rides SET driver_id=$driverId, driver_name='$driverName', car_plate='$carPlate', status='accepted', updated_at=CURRENT_TIMESTAMP WHERE id=$rideId LIMIT 1")) {
            throw new Exception('Unable to assign ride to this driver.');
        }

        mysqli_query($dbconn, "INSERT INTO ride_driver_locations (driver_id, lat, lng, heading, phase)
            VALUES ($driverId, 0, 0, 0, 'enroute_pickup')
            ON DUPLICATE KEY UPDATE phase='enroute_pickup', updated_at=CURRENT_TIMESTAMP");

        mysqli_commit($dbconn);
        return [
            'error' => false,
            'message' => 'Ride accepted. Proceed to pickup.',
            'data' => [
                'ride_id' => $rideId,
                'driver_id' => $driverId,
                'status' => 'accepted',
            ],
        ];
    } catch (Exception $e) {
        mysqli_rollback($dbconn);
        throw $e;
    }
}

function scanAndBatchDispatchRides(string $userUid, string $latRaw, string $lngRaw): array {
    global $dbconn;
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    
    if ((int)$session['is_online'] !== 1) {
        throw new Exception('Go online to scan for dispatch batches.');
    }
    
    $allowedTypes = $session['allowed_ride_types'] ?? '';
    if (strpos($allowedTypes, 'dispatch') === false) {
        throw new Exception('Your vehicle is not authorized for Fleet Dispatch.');
    }

    $driverLat = (float)$latRaw;
    $driverLng = (float)$lngRaw;
    
    $maxPayload = (float)($session['max_payload_weight'] ?? 0);
    $currentPayload = (float)($session['current_payload_weight'] ?? 0);
    $capacityRemaining = $maxPayload - $currentPayload;
    
    if ($capacityRemaining <= 0) {
        throw new Exception('Your active payload is full. Deliver current packages first.');
    }

    $sql = "SELECT id, dest_lat, dest_lng, package_weight, price,
            (6371000 * acos(cos(radians($driverLat)) * cos(radians(pickup_lat)) * cos(radians(pickup_lng) - radians($driverLng)) + sin(radians($driverLat)) * sin(radians(pickup_lat)))) AS distance
            FROM ride_rides
            WHERE status = 'searching' 
              AND ride_type = 'dispatch' 
              AND package_weight <= $capacityRemaining
              AND (driver_id IS NULL OR driver_id = 0)
            HAVING distance < 5000
            ORDER BY distance ASC
            LIMIT 3"; 
            
    $result = mysqli_query($dbconn, $sql);
    $batch = [];
    $batchGroupId = uniqid('BATCH_');
    
    if ($result && mysqli_num_rows($result) > 0) {
        mysqli_begin_transaction($dbconn);
        try {
            $driverName = mysqli_real_escape_string($dbconn, (string)$session['name']);
            $carPlate = mysqli_real_escape_string($dbconn, (string)$session['car_plate']);
            
            while ($row = mysqli_fetch_assoc($result)) {
                $rideId = (int)$row['id'];
                $batch[] = $row;
                mysqli_query($dbconn, "UPDATE ride_rides SET driver_id=$driverId, driver_name='$driverName', car_plate='$carPlate', batch_group_id='$batchGroupId' WHERE id=$rideId");
            }
            $totalWeight = array_sum(array_column($batch, 'package_weight'));
            mysqli_query($dbconn, "UPDATE ride_drivers SET current_payload_weight = current_payload_weight + $totalWeight WHERE id=$driverId");
            
            mysqli_commit($dbconn);
        } catch (Exception $e) {
            mysqli_rollback($dbconn);
            throw $e;
        }
    }
    
    return [
        'error' => false,
        'message' => count($batch) > 0 ? "Successfully batched " . count($batch) . " nearby deliveries to your route." : "No dispatch requests nearby matching your capacity.",
        'data' => [
            'batched_count' => count($batch),
            'batch_group_id' => count($batch) > 0 ? $batchGroupId : null
        ]
    ];
}

function verifyDeliveryOtp(string $userUid, string $rideIdRaw, string $providedOtp): array {
    global $dbconn;
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    $rideId = (int)$rideIdRaw;
    $safeOtp = sanitizeInput($providedOtp);

    $sql = "SELECT id, status, delivery_otp, package_weight FROM ride_rides WHERE id=$rideId AND driver_id=$driverId LIMIT 1 FOR UPDATE";
    
    mysqli_begin_transaction($dbconn);
    try {
        $lockResult = mysqli_query($dbconn, $sql);
        if (!$lockResult || mysqli_num_rows($lockResult) === 0) {
            throw new Exception('Delivery not found or not assigned to you.');
        }
        
        $ride = mysqli_fetch_assoc($lockResult);
        
        if ($ride['status'] !== 'arrived_destination' && $ride['status'] !== 'in_progress') {
            throw new Exception('You must be at the destination to verify the OTP.');
        }
        
        if ((string)$ride['delivery_otp'] !== $safeOtp) {
            throw new Exception('Invalid Secure OTP. Handoff denied. Contact recipient.');
        }

        $weight = (float)$ride['package_weight'];
        if ($weight > 0) {
            mysqli_query($dbconn, "UPDATE ride_drivers SET current_payload_weight = GREATEST(0, current_payload_weight - $weight) WHERE id=$driverId");
        }

        mysqli_commit($dbconn);
        return [
            'error' => false,
            'message' => 'OTP Verified successfully. Chain of custody confirmed.',
            'data' => ['ride_id' => $rideId, 'verified' => true]
        ];
    } catch (Exception $e) {
        mysqli_rollback($dbconn);
        throw $e;
    }
}

// ==============================================================================
// 💰 FINANCIAL TRANSACTION & MONETIZATION ENGINE (ALL RIDE TYPES)
// ==============================================================================
// This engine processes actions (start, complete, cancel) for humans (street_ride) 
// AND packages (send_me, dispatch) identically. 
//
// HOW THE MATH WORKS:
// 1. The default system fee is 25% (overridden by DB settings if found).
// 2. We ONLY charge money when the driver taps 'complete' (or 'cancel' if trip started).
// 3. We check the driver's wallet to ensure they can afford our 25% cut.
// 4. If the passenger/sender chose "wallet" payment, we subtract 100% of the fare 
//    from the rider's wallet, and give 100% of it to the driver. 
// 5. Finally, we deduct our 25% commission from the driver's wallet. 
// ==============================================================================

function rideAction(string $userUid, string $rideIdRaw, string $rideActionRaw): array {
    global $dbconn;
    $session = fetchDriverSession($userUid);
    $driverId = (int)$session['id'];
    $rideId = (int)$rideIdRaw;
    $rideAction = strtolower(trim($rideActionRaw));

    if ($rideId <= 0) {
        throw new Exception('Ride ID is invalid.');
    }

    // Normalizing aliases to core statuses
    if ($rideAction === 'start_to_pickup' || $rideAction === 'head_to_pickup') $rideAction = 'enroute_pickup';
    if ($rideAction === 'complete_trip') $rideAction = 'complete';
    if ($rideAction === 'cancel_trip' || $rideAction === 'cancel_ride') $rideAction = 'cancel';

    $clientLat = isset($_POST['lat']) ? sanitizeInput($_POST['lat']) : null;
    $clientLng = isset($_POST['lng']) ? sanitizeInput($_POST['lng']) : null;
    $clientHeading = isset($_POST['heading']) ? sanitizeInput($_POST['heading']) : null;
    upsertDriverLiveFromClient($driverId, $clientLat, $clientLng, $clientHeading, phaseForRideAction($rideAction));

    // [NOV-DEV NOTE]: Begin the transaction and lock the ride table row!
    mysqli_begin_transaction($dbconn);
    try {
        $lockResult = mysqli_query($dbconn, "SELECT * FROM ride_rides WHERE id=$rideId AND driver_id=$driverId LIMIT 1 FOR UPDATE");
        if (!$lockResult || mysqli_num_rows($lockResult) === 0) {
            throw new Exception('No active ride was found for this driver action.');
        }
        $ride = mysqli_fetch_assoc($lockResult);
        $currentStatus = normalizeRideStatus((string)($ride['status'] ?? 'searching'));
        
        // Is this action finishing the ride and triggering money transfers?
        $isChargeableAction = ($rideAction === 'complete') || ($rideAction === 'cancel' && in_array($currentStatus, ['in_progress', 'arrived_destination'], true));
        
        $payMethod = $ride['pay_method'] ?? 'cash';
        $price = (float)($ride['price'] ?? 0.0);
        $appFee = 0.0;
        $feePercentage = 25.0; // The App's Commission 
        
        // $riderId refers to the account that booked the request. 
        // For 'send_me' & 'dispatch', this is the SENDER of the package.
        $riderId = mysqli_real_escape_string($dbconn, (string)($ride['rider_id'] ?? ''));
        $escapedUserUid = mysqli_real_escape_string($dbconn, $userUid);

        // --- STEP 1: PRE-CHECK DRIVER WALLET ---
        if ($isChargeableAction) {
            // Retrieve dynamic fee from settings table if available
            $feeQuery = mysqli_query($dbconn, "SELECT setting_value FROM app_settings WHERE setting_key = 'app_ride_fee_percentage'");
            if ($feeQuery && mysqli_num_rows($feeQuery) > 0) {
                $feeRow = mysqli_fetch_assoc($feeQuery);
                $feePercentage = (float)$feeRow['setting_value'];
            }
            
            // Calculate our cut
            $appFee = ($feePercentage / 100) * $price;
            
            // Look up driver's current balance
            $driverQuery = mysqli_query($dbconn, "SELECT bal FROM unique_user_table WHERE u_uid = '$escapedUserUid'");
            if ($driverQuery && mysqli_num_rows($driverQuery) > 0) {
                $driverData = mysqli_fetch_assoc($driverQuery);
                $driverBal = (float)($driverData['bal'] ?? 0);
                
                // If the driver can't afford the app fee, block the completion.
                if ($driverBal < $appFee) {
                    $driveFundAmount = $appFee-$driverBal;
                    throw new Exception("Insufficient balance to cover the app fee (" . ($ride['currency'] ?? 'NGN') . " " . number_format($appFee, 2) . "). Please fund your wallet with (" . ($ride['currency'] ?? 'NGN') . " " . number_format($driveFundAmount, 2) . ") to be able to complete this transaction.");
                }
            }
        }

        $live = requireFreshDriverLive($driverId, DRIVER_FIX_MAX_AGE_SEC);
        $driverLat = (float)$live['lat'];
        $driverLng = (float)$live['lng'];
        $distanceToPickup = haversineMeters($driverLat, $driverLng, (float)$ride['pickup_lat'], (float)$ride['pickup_lng']);
        $distanceToDest = haversineMeters($driverLat, $driverLng, (float)$ride['dest_lat'], (float)$ride['dest_lng']);

        $gpsErrorMargin = isset($_POST['accuracy']) ? (float)$_POST['accuracy'] : 15.0;
        $compensation = min($gpsErrorMargin, 150.0);
        
        $effectivePickupRadius = ARRIVED_PICKUP_MAX_METERS + $compensation;
        $effectiveStartRadius = START_TRIP_MAX_METERS + $compensation;
        $effectiveDestRadius = ARRIVED_DESTINATION_MAX_METERS + $compensation;
        $effectiveCompleteRadius = COMPLETE_RIDE_MAX_METERS + $compensation;

        $nextStatus = '';
        $message = '';
        $timestampSql = '';
        $counterSql = '';
        $phase = 'idle';

        switch ($rideAction) {
            case 'enroute_pickup':
                if (!in_array($currentStatus, ['accepted', 'enroute_pickup'], true)) {
                    throw new Exception('Ride cannot move to pickup transit from ' . $currentStatus . '.');
                }
                $nextStatus = 'enroute_pickup';
                $message = 'Driver is heading to pickup.';
                $phase = 'enroute_pickup';
                break;

            case 'arrived_pickup':
                if (!in_array($currentStatus, ['accepted', 'enroute_pickup'], true)) {
                    throw new Exception('Pickup arrival can only be marked while heading to rider.');
                }
                if ($distanceToPickup > $effectivePickupRadius) {
                    throw new Exception('Driver must be inside the pickup zone before marking arrived. Current distance: ' . round($distanceToPickup) . ' m.');
                }
                $nextStatus = 'arrived_pickup';
                $message = 'Driver has arrived at pickup.';
                $timestampSql = ", arrived_pickup_at=NOW()";
                $phase = 'waiting_pickup';
                break;

            case 'start_trip':
                if (!in_array($currentStatus, ['arrived_pickup'], true)) {
                    throw new Exception('Trip can only start after pickup arrival is confirmed.');
                }
                if ($distanceToPickup > $effectiveStartRadius) {
                    throw new Exception('Driver and rider must still be together inside pickup zone before starting trip. Current distance: ' . round($distanceToPickup) . ' m.');
                }
                $nextStatus = 'in_progress';
                $message = 'Trip started. Driver is en route to destination.';
                $timestampSql = ", started_at=IFNULL(started_at,NOW())";
                $phase = 'enroute_destination';
                break;

            case 'arrived_destination':
                if (!in_array($currentStatus, ['in_progress'], true)) {
                    throw new Exception('Destination arrival can only be marked for an active trip.');
                }
                if ($distanceToDest > $effectiveDestRadius) {
                    throw new Exception('Driver must be inside the destination zone before marking arrived. Current distance: ' . round($distanceToDest) . ' m.');
                }
                $nextStatus = 'arrived_destination';
                $message = 'Driver reached the destination.';
                $phase = 'arrived_destination';
                break;

            case 'complete':
                if (!in_array($currentStatus, ['in_progress', 'arrived_destination'], true)) {
                    throw new Exception('Only active or destination-arrived rides can be completed.');
                }
                if ($distanceToDest > $effectiveCompleteRadius) {
                    throw new Exception('Ride can only be completed at the destination zone. Current distance: ' . round($distanceToDest) . ' m.');
                }
                
                $nextStatus = 'completed';
                $message = 'Ride completed successfully.';
                $timestampSql = ", completed_at=CURRENT_TIMESTAMP";
                $counterSql = "UPDATE ride_drivers SET completed_trips=completed_trips+1, total_trips=total_trips+1 WHERE id=$driverId LIMIT 1";
                $phase = 'idle';
                break;

            case 'cancel':
                if (!in_array($currentStatus, ['searching', 'accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination'], true)) {
                    throw new Exception('Ride cannot be canceled from ' . $currentStatus . '.');
                }
                $nextStatus = 'canceled';
                $message = 'Ride canceled.';
                $timestampSql = ", canceled_at=NOW()";
                $counterSql = "UPDATE ride_drivers SET cancelled_trips=cancelled_trips+1, total_trips=total_trips+1 WHERE id=$driverId LIMIT 1";
                $phase = 'idle';
                
                // If it was a package delivery, restore the driver's vehicle capacity limit
                $weight = (float)($ride['package_weight'] ?? 0);
                if ($weight > 0) {
                    mysqli_query($dbconn, "UPDATE ride_drivers SET current_payload_weight = GREATEST(0, current_payload_weight - $weight) WHERE id=$driverId");
                }
                break;

            default:
                throw new Exception('Unsupported ride action.');
        }

        // --- STEP 2: EXECUTE MONETIZATION TRANSFERS ---
        if ($isChargeableAction) {
            $transactionId = uniqid('TRX_');
            
            // A. WALLET PAYMENT PROCESSING
            // If the sender/rider chose 'wallet' as the payment method, we deduct the fare from their balance.
            if ($payMethod === 'wallet' && $rideAction === 'complete') {
                // 1. Deduct from Sender/Rider
                mysqli_query($dbconn, "UPDATE unique_user_table SET bal = bal - $price WHERE u_uid = '$riderId'");
                mysqli_query($dbconn, "INSERT INTO unique_account_table (user_uid, amount, type, descTxt, reference, datetime) VALUES ('$riderId', '$price', 'minus', 'Paid for ride via wallet', '$transactionId', NOW())");
                
                // 2. Give to Driver
                mysqli_query($dbconn, "UPDATE unique_user_table SET bal = bal + $price WHERE u_uid = '$escapedUserUid'");
                mysqli_query($dbconn, "INSERT INTO unique_account_table (user_uid, amount, type, descTxt, reference, datetime) VALUES ('$escapedUserUid', '$price', 'plus', 'Ride earnings from rider', '$transactionId', NOW())");
            }
            
            // B. THE APP COMMISSION (e.g., 25%)
            // Regardless of Cash or Wallet, the App takes its commission directly out of the Driver's balance.
            mysqli_query($dbconn, "UPDATE unique_user_table SET bal = bal - $appFee WHERE u_uid = '$escapedUserUid'");
            mysqli_query($dbconn, "INSERT INTO unique_account_table (user_uid, amount, type, descTxt, reference, datetime) VALUES ('$escapedUserUid', '$appFee', 'minus', 'App service fee ({$feePercentage}%)', '$transactionId', NOW())");
        }

        if (!mysqli_query($dbconn, "UPDATE ride_rides SET status='$nextStatus', updated_at=CURRENT_TIMESTAMP$timestampSql WHERE id=$rideId AND driver_id=$driverId LIMIT 1")) {
            throw new Exception('Unable to update ride status.');
        }
        if ($counterSql !== '' && !mysqli_query($dbconn, $counterSql)) {
            throw new Exception('Ride counters could not be updated.');
        }
        mysqli_query($dbconn, "UPDATE ride_driver_locations SET phase='$phase', updated_at=CURRENT_TIMESTAMP WHERE driver_id=$driverId LIMIT 1");

        mysqli_commit($dbconn);
        return [
            'error' => false,
            'message' => $message,
            'data' => [
                'ride_id' => $rideId,
                'driver_id' => $driverId,
                'status' => $nextStatus,
                'phase' => $phase,
                'distance_to_pickup_m' => round($distanceToPickup, 2),
                'distance_to_destination_m' => round($distanceToDest, 2),
                'driver_fix_age_sec' => (int)$live['age_sec'],
            ],
        ];
    } catch (Exception $e) {
        mysqli_rollback($dbconn);
        throw $e;
    }
}

try {
    $action = isset($_POST['action']) ? sanitizeInput($_POST['action']) : 'dashboard';
    $userUid = requirePosted('user', 'User');

    switch ($action) {
        case 'dashboard':
            jsonResponse(dashboard($userUid));
            break;
            
        case 'set_online':
            $isOnline = requirePosted('is_online', 'Online status');
            $lat = isset($_POST['lat']) ? (float)$_POST['lat'] : 0.0;
            $lng = isset($_POST['lng']) ? (float)$_POST['lng'] : 0.0;
            $heading = isset($_POST['heading']) ? (float)$_POST['heading'] : 0.0;
            jsonResponse(setOnline($userUid, $isOnline, $lat, $lng, $heading));
            break;
            
        case 'heartbeat':
            jsonResponse(heartbeat(
                $userUid,
                requirePosted('lat', 'Latitude'),
                requirePosted('lng', 'Longitude'),
                isset($_POST['heading']) ? sanitizeInput($_POST['heading']) : '0',
                isset($_POST['phase']) ? sanitizeInput($_POST['phase']) : 'idle'
            ));
            break;
            
        case 'accept_ride':
            jsonResponse(acceptRide($userUid, requirePosted('ride_id', 'Ride ID')));
            break;
            
        case 'ride_action':
            jsonResponse(rideAction($userUid, requirePosted('ride_id', 'Ride ID'), requirePosted('ride_action', 'Ride action')));
            break;
            
        case 'verify_otp':
            jsonResponse(verifyDeliveryOtp(
                $userUid, 
                requirePosted('ride_id', 'Ride ID'), 
                requirePosted('otp', 'OTP')
            ));
            break;
            
        case 'scan_dispatch_batch':
            jsonResponse(scanAndBatchDispatchRides(
                $userUid, 
                requirePosted('lat', 'Latitude'), 
                requirePosted('lng', 'Longitude')
            ));
            break;
            
        default:
            throw new Exception('Unsupported driver action.');
    }
} catch (Exception $e) {
    jsonResponse(['error' => true, 'message' => $e->getMessage(), 'data' => null], 200);
}

?>