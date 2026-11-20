<?php
declare(strict_types=1);

/**
 * POST ride_history.php — the session user's rides (session required).
 * role=rider (default): rides booked by the session user.
 * role=driver: rides assigned to the session user's driver profile.
 * The delivery OTP is only returned to the person who booked the delivery (rider view).
 */

require_once __DIR__ . '/ride_api_bootstrap.php';

$uid = ride_authorize();
$in = ride_input();

pm_ride_expire_stale();

$role = pm_in_enum($in, 'role', ['rider', 'driver'], 'rider');
$limit = pm_in_int($in, 'limit', 50, 1, 100);
$rides = [];

function formatRideData(array $row, string $viewRole): array
{
    $status = ride_norm_status((string)($row['status'] ?? 'searching'));
    $rideType = (string)($row['ride_type'] ?? 'street_ride');
    $remaining = (int)($row['db_remaining_seconds'] ?? 0);
    if ($status === 'searching' && $remaining <= 0) {
        $status = 'canceled';
        $remaining = 0;
    }
    $stops = [];
    if (!empty($row['stops_json'])) {
        $decoded = json_decode((string)$row['stops_json'], true);
        if (is_array($decoded)) {
            $stops = $decoded;
        }
    }
    $defaultLogo = 'https://phantomphones.store/pick_me/img/logo.png';
    $peerAvatar = trim((string)($row['peer_avatar'] ?? ''));
    $packageImage = trim((string)($row['package_image'] ?? ''));
    if ($packageImage === '' && in_array($rideType, ['dispatch', 'send_me'], true)) {
        $packageImage = $defaultLogo;
    }
    $otp = trim((string)($row['delivery_otp'] ?? ''));
    // Drivers must obtain the code from the recipient; they only learn that one is required.
    $otpOut = $viewRole === 'rider' ? $otp : '';
    $isOpen = in_array($status, ['accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination'], true);

    return [
        'id'                => (int)$row['id'],
        'rider_id'          => (string)($row['rider_id'] ?? ''),
        'driver_id'         => (int)($row['driver_id'] ?? 0),
        'status'            => $status,
        'ride_type'         => $rideType,
        'category'          => $row['category'] ?? 'Standard',
        'vehicle_type'      => $row['vehicle_type'] ?? 'car',
        'price'             => (float)($row['price'] ?? 0),
        'currency'          => $row['currency'] ?? 'NGN',
        'eta_min'           => (int)($row['eta_min'] ?? 0),
        'pickup_text'       => $row['pickup_text'] ?? 'Unknown Pickup',
        'dest_text'         => $row['dest_text'] ?? 'Unknown Destination',
        'pickup_lat'        => (float)($row['pickup_lat'] ?? 0),
        'pickup_lng'        => (float)($row['pickup_lng'] ?? 0),
        'dest_lat'          => (float)($row['dest_lat'] ?? 0),
        'dest_lng'          => (float)($row['dest_lng'] ?? 0),
        'stops'             => $stops,
        'created_at'        => $row['created_at'] ?? null,
        'started_at'        => $row['started_at'] ?? null,
        'completed_at'      => $row['completed_at'] ?? null,
        'canceled_at'       => $row['canceled_at'] ?? null,
        'remaining_seconds' => max(0, $remaining),
        'peer_name'         => trim((string)($row['peer_name'] ?? '')),
        // Phone numbers are only shared while a trip is live.
        'peer_phone'        => $isOpen ? trim((string)($row['peer_phone'] ?? '')) : '',
        'peer_plate'        => trim((string)($row['peer_plate'] ?? '')),
        'peer_rating'       => (float)($row['peer_rating'] ?? 0),
        'peer_avatar'       => $peerAvatar !== '' ? $peerAvatar : $defaultLogo,
        'delivery_otp'      => $otpOut,
        'requires_otp'      => $otp !== '',
        'otp_verified'      => !empty($row['delivery_otp_verified_at']),
        'instructions'      => (string)($row['instructions'] ?? ''),
        'package_size'      => (string)($row['package_size'] ?? ''),
        'package_weight'    => (float)($row['package_weight'] ?? 0),
        'recipient_phone'   => ($viewRole === 'rider' || $isOpen) ? (string)($row['recipient_phone'] ?? '') : '',
        'package_image'     => $packageImage,
    ];
}

$ttlSec = PM_RIDE_SEARCH_TTL_MIN * 60;

if ($role === 'driver') {
    $driver = pm_driver_for_user($uid);
    if (!$driver || $driver['id'] === null) {
        ride_json(['error' => false, 'message' => 'No driver profile found', 'data' => []], 200);
    }
    $rows = pm_q_all(
        "SELECT r.*, u.fname AS r_fname, u.lname AS r_lname, COALESCE(u.phone, '') AS r_phone, COALESCE(u.b_logo, '') AS r_logo,
                (? - TIMESTAMPDIFF(SECOND, r.created_at, NOW())) AS db_remaining_seconds
         FROM ride_rides r
         LEFT JOIN unique_user_table u ON r.rider_id = u.u_uid
         WHERE r.driver_id = ?
         ORDER BY r.created_at DESC
         LIMIT ?",
        'iii',
        [$ttlSec, (int)$driver['id'], $limit]
    );
    foreach ($rows as $row) {
        $row['peer_name'] = trim(($row['r_fname'] ?? '') . ' ' . ($row['r_lname'] ?? '')) ?: 'Rider';
        $row['peer_phone'] = (string)($row['r_phone'] ?? '');
        $row['peer_avatar'] = (string)($row['r_logo'] ?? '');
        $rides[] = formatRideData($row, 'driver');
    }
} else {
    $rows = pm_q_all(
        "SELECT r.*, d.name AS d_name, COALESCE(d.phone, '') AS d_phone, COALESCE(d.car_plate, '') AS d_plate,
                COALESCE(d.rating, 0.0) AS d_rating, COALESCE(d.avatar_url, '') AS d_avatar, COALESCE(d.vehicle_type, '') AS d_vehicle_type,
                (? - TIMESTAMPDIFF(SECOND, r.created_at, NOW())) AS db_remaining_seconds
         FROM ride_rides r
         LEFT JOIN ride_drivers d ON r.driver_id = d.id
         WHERE r.rider_id = ?
         ORDER BY r.created_at DESC
         LIMIT ?",
        'isi',
        [$ttlSec, $uid, $limit]
    );
    foreach ($rows as $row) {
        $row['peer_name'] = $row['d_name'] ?? 'Searching...';
        $row['peer_phone'] = (string)($row['d_phone'] ?? '');
        $row['peer_plate'] = (string)($row['d_plate'] ?? '');
        $row['vehicle_type'] = $row['vehicle_type'] ?? $row['d_vehicle_type'] ?? 'car';
        $row['peer_rating'] = (float)($row['d_rating'] ?? 0);
        $row['peer_avatar'] = (string)($row['d_avatar'] ?? '');
        $rides[] = formatRideData($row, 'rider');
    }
}

ride_json(['error' => false, 'message' => 'History retrieved', 'data' => $rides], 200);
