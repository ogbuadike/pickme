<?php
declare(strict_types=1);

header('Content-Type: application/json');
require_once 'ride_api_bootstrap.php';

ride_authorize();
$in = ride_input();

// --- GLOBAL LAZY CRON JOB (DATABASE CLEANUP) ---
// Let MySQL handle the time natively to completely eliminate PHP vs MySQL timezone mismatches!
$cleanupSql = "UPDATE ride_rides 
               SET status = 'cancelled', canceled_at = NOW() 
               WHERE status = 'searching' 
               AND created_at <= NOW() - INTERVAL 30 MINUTE";
mysqli_query($dbconn, $cleanupSql);
// -----------------------------------------------

$userId = ride_s($in['user_id'] ?? $in['uid'] ?? '');
$role = ride_s($in['role'] ?? 'rider'); // 'rider' or 'driver'
$limit = ride_i($in['limit'] ?? 50, 50);

if ($userId === '') {
    ride_json(['error' => true, 'message' => 'User ID is required'], 422);
}

$rides = [];

if ($role === 'driver') {
    // 1. Get driver internal ID securely
    $driverData = ride_query_one(
        $dbconn,
        "SELECT d.id FROM ride_driver_onboarding o 
         JOIN ride_drivers d ON d.id = o.driver_id 
         WHERE o.user_uid = ? LIMIT 1",
        's',
        [$userId]
    );

    if (!$driverData) {
        ride_json(['error' => false, 'message' => 'No driver profile found', 'data' => []], 200);
    }
    
    $driverId = (int)$driverData['id'];

    // 2. Fetch rides for driver (Join Rider info: unique_user_table)
    // Using COALESCE to guarantee we pull the phone number securely without NULL breaks
    $sql = "SELECT r.*, 
                   u.fname AS r_fname, u.lname AS r_lname, 
                   COALESCE(u.phone, '') AS r_phone, 
                   COALESCE(u.b_logo, '') AS r_logo,
                   (1800 - TIMESTAMPDIFF(SECOND, r.created_at, NOW())) AS db_remaining_seconds
            FROM ride_rides r
            LEFT JOIN unique_user_table u ON r.rider_id = u.u_uid 
            WHERE r.driver_id = ?
            ORDER BY r.created_at DESC LIMIT ?";
             
    $stmt = mysqli_prepare($dbconn, $sql);
    mysqli_stmt_bind_param($stmt, 'ii', $driverId, $limit);
    mysqli_stmt_execute($stmt);
    $result = mysqli_stmt_get_result($stmt);

    if ($result) {
        while ($row = mysqli_fetch_assoc($result)) {
            $row['peer_name'] = trim(($row['r_fname'] ?? '') . ' ' . ($row['r_lname'] ?? ''));
            // Explicitly cast to string so Dart parses it cleanly
            $row['peer_phone'] = (string)($row['r_phone'] ?? ''); 
            $row['peer_avatar'] = (string)($row['r_logo'] ?? '');
            
            if ($row['peer_name'] === '') {
                $row['peer_name'] = 'Rider';
            }
            
            $rides[] = formatRideData($row, 'driver');
        }
    }
    if (isset($stmt)) mysqli_stmt_close($stmt);

} else {
    // Rider Mode: Fetch rides for rider (Join Driver info: ride_drivers)
    $sql = "SELECT r.*, 
                   d.name AS d_name, 
                   COALESCE(d.phone, '') AS d_phone, 
                   COALESCE(d.car_plate, '') AS d_plate, 
                   COALESCE(d.rating, 0.0) AS d_rating, 
                   COALESCE(d.avatar_url, '') AS d_avatar, 
                   COALESCE(d.vehicle_type, '') AS d_vehicle_type,
                   (1800 - TIMESTAMPDIFF(SECOND, r.created_at, NOW())) AS db_remaining_seconds
            FROM ride_rides r
            LEFT JOIN ride_drivers d ON r.driver_id = d.id
            WHERE r.rider_id = ?
            ORDER BY r.created_at DESC LIMIT ?";
            
    $stmt = mysqli_prepare($dbconn, $sql);
    mysqli_stmt_bind_param($stmt, 'si', $userId, $limit);
    mysqli_stmt_execute($stmt);
    $result = mysqli_stmt_get_result($stmt);

    if ($result) {
        while ($row = mysqli_fetch_assoc($result)) {
            $row['peer_name'] = $row['d_name'] ?? 'Searching...';
            $row['peer_phone'] = (string)($row['d_phone'] ?? '');
            $row['peer_plate'] = (string)($row['d_plate'] ?? '');
            $row['vehicle_type'] = $row['vehicle_type'] ?? $row['d_vehicle_type'] ?? 'car';
            $row['peer_rating'] = (float)($row['d_rating'] ?? 0.0);
            $row['peer_avatar'] = (string)($row['d_avatar'] ?? '');
            
            $rides[] = formatRideData($row, 'rider');
        }
    }
    if (isset($stmt)) mysqli_stmt_close($stmt);
}

function formatRideData(array $row, string $viewRole): array {
    $status = strtolower(trim((string)($row['status'] ?? 'searching')));
    $rideType = $row['ride_type'] ?? 'street_ride';

    // Fetch the 100% accurate time calculated by MySQL
    $remainingSeconds = isset($row['db_remaining_seconds']) ? (int)$row['db_remaining_seconds'] : 0;

    // Failsafe: if somehow the global cron missed it, force cancelled state locally for ALL ride types
    if ($status === 'searching' && $remainingSeconds <= 0) {
        $status = 'cancelled';
        $remainingSeconds = 0;
    }

    if ($status === 'driver_assigned') $status = 'accepted';
    if ($status === 'in_ride') $status = 'in_progress';

    $stops = [];
    if (!empty($row['stops_json'])) {
        $decoded = json_decode($row['stops_json'], true);
        if (is_array($decoded)) $stops = $decoded;
    }

    $defaultLogo = 'https://phantomphones.store/pick_me/img/logo.png';

    $peerAvatar = trim((string)($row['peer_avatar'] ?? ''));
    if ($peerAvatar === '') {
        $peerAvatar = $defaultLogo;
    }

    $packageImage = trim((string)($row['package_image'] ?? ''));
    if ($packageImage === '' && in_array($rideType, ['dispatch', 'send_me'])) {
        $packageImage = $defaultLogo;
    }

    return [
        'id' => (int)$row['id'],
        'rider_id' => $row['rider_id'] ?? '',
        'driver_id' => (int)($row['driver_id'] ?? 0),
        'status' => $status,
        'ride_type' => $rideType,
        'category' => $row['category'] ?? 'Standard',
        'vehicle_type' => $row['vehicle_type'] ?? 'car',
        'price' => (float)($row['price'] ?? 0.0),
        'currency' => $row['currency'] ?? 'NGN',
        'eta_min' => (int)($row['eta_min'] ?? 0),
        'pickup_text' => $row['pickup_text'] ?? 'Unknown Pickup',
        'dest_text' => $row['dest_text'] ?? 'Unknown Destination',
        'pickup_lat' => (float)($row['pickup_lat'] ?? 0.0),
        'pickup_lng' => (float)($row['pickup_lng'] ?? 0.0),
        'dest_lat' => (float)($row['dest_lat'] ?? 0.0),
        'dest_lng' => (float)($row['dest_lng'] ?? 0.0),
        'stops' => $stops,
        'created_at' => $row['created_at'] ?? null,
        'started_at' => $row['started_at'] ?? null,
        'completed_at' => $row['completed_at'] ?? null,
        'canceled_at' => $row['canceled_at'] ?? null,
        
        // Exact remaining seconds sent directly to Flutter
        'remaining_seconds' => $remainingSeconds > 0 ? $remainingSeconds : 0,
        
        // Final string casting to ensure Dart receives the format it expects
        'peer_name' => trim((string)($row['peer_name'] ?? '')),
        'peer_phone' => trim((string)($row['peer_phone'] ?? '')),
        'peer_plate' => trim((string)($row['peer_plate'] ?? '')),
        'peer_rating' => isset($row['peer_rating']) ? (float)$row['peer_rating'] : 0.0,
        'peer_avatar' => $peerAvatar,

        'delivery_otp' => (string)($row['delivery_otp'] ?? ''),
        'instructions' => (string)($row['instructions'] ?? ''),
        'package_size' => (string)($row['package_size'] ?? ''),
        'package_weight' => (float)($row['package_weight'] ?? 0.0),
        'recipient_phone' => (string)($row['recipient_phone'] ?? ''),
        'package_image' => $packageImage,
    ];
}

ride_json([
    'error' => false,
    'message' => 'History retrieved',
    'data' => $rides
], 200);