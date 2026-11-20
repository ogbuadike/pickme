<?php
declare(strict_types=1);

/**
 * POST user_logistics.php — Send Me (errand) and Dispatch (parcel) bookings (session required).
 * action=estimate_delivery | book_service
 * Pricing is computed server-side; distance_km from the client is floored at the straight-line distance.
 * A 4-digit delivery OTP (random_int) is returned ONLY to the sender; drivers must obtain it from the
 * recipient and it is verified server-side (driver_hub.php action=verify_otp, attempt-limited).
 */

require_once __DIR__ . '/ride_api_bootstrap.php';

pm_require_method('POST');
$uid = pm_require_session();
$in = pm_input();

function calculatePrice(float $distanceKm, string $rideType, string $packageSize = 'envelope', float $weightKg = 0.0): float
{
    $distanceKm = max(0.0, min($distanceKm, 500.0));
    if ($rideType === 'send_me') {
        return round(1200.0 + $distanceKm * 150.0, 2);
    }
    $sizeMultiplier = $packageSize === 'box' ? 1.3 : ($packageSize === 'heavy' ? 2.0 : 1.0);
    $weightPenalty = $weightKg > 10 ? ($weightKg - 10) * 40.0 : 0.0;
    return round((800.0 + $distanceKm * 120.0) * $sizeMultiplier + $weightPenalty, 2);
}

function lg_fail(string $message, string $code = 'VALIDATION'): void
{
    pm_error($code, $message, 400);
}

$action = pm_in_str($in, 'action', 40);
$rideType = pm_in_enum($in, 'ride_type', ['send_me', 'dispatch'], 'dispatch');
$packageSize = pm_in_enum($in, 'package_size', ['envelope', 'box', 'heavy'], 'envelope');
$weightKg = min(max(pm_in_float($in, 'weight_kg', 1.0), 0.0), 1000.0);

$pickupLat = pm_in_float($in, 'pickup_lat', 0.0);
$pickupLng = pm_in_float($in, 'pickup_lng', 0.0);
$destLat = pm_in_float($in, 'dest_lat', 0.0);
$destLng = pm_in_float($in, 'dest_lng', 0.0);
$distanceKm = max(0.0, pm_in_float($in, 'distance_km', 0.0));
if (pm_valid_lat($pickupLat) && pm_valid_lng($pickupLng) && pm_valid_lat($destLat) && pm_valid_lng($destLng)) {
    $distanceKm = max($distanceKm, pm_haversine_m($pickupLat, $pickupLng, $destLat, $destLng) / 1000.0);
}

switch ($action) {
    case 'estimate_delivery':
        pm_json(['error' => false, 'data' => ['estimated_price' => calculatePrice($distanceKm, $rideType, $packageSize, $weightKg)]]);
        break;

    case 'book_service':
        if (!pm_valid_lat($pickupLat) || !pm_valid_lng($pickupLng) || !pm_valid_lat($destLat) || !pm_valid_lng($destLng)) {
            lg_fail('Pickup and destination coordinates are required.');
        }
        pm_rate_limit('logistics_book', $uid, 20, 600, 'Too many booking attempts. Please wait a moment.');
        $payMethod = pm_in_enum($in, 'pay_method', ['cash', 'wallet', 'card', 'transfer'], 'cash');
        $pickupText = pm_in_str($in, 'pickup_text', 255);
        $destText = pm_in_str($in, 'dest_text', 255);
        $deliveryOtp = pm_random_digits(4);
        $idemKey = pm_clean_text(pm_header('X-Idempotency-Key') ?: ($in['idempotency_key'] ?? ''), 64);

        if ($idemKey !== '') {
            $dup = pm_q_one('SELECT id, delivery_otp, ride_type FROM ride_rides WHERE rider_id = ? AND idempotency_key = ? LIMIT 1', 'ss', [$uid, $idemKey]);
            if ($dup) {
                pm_json(['error' => false, 'message' => ($dup['ride_type'] === 'send_me' ? 'Errand booked.' : 'Dispatch booked.'), 'data' => ['ride_id' => (int)$dup['id'], 'delivery_otp' => (string)$dup['delivery_otp']], 'idempotent_replay' => true]);
            }
        }

        if ($rideType === 'send_me') {
            $instructions = pm_in_str($in, 'instructions', 1000);
            if ($instructions === '') {
                lg_fail('Errand instructions are required.');
            }
            $price = calculatePrice($distanceKm, 'send_me');
            $user = pm_q_one('SELECT bal FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$uid]);
            if ($payMethod === 'wallet' && (float)($user['bal'] ?? 0) < $price) {
                lg_fail('Insufficient wallet balance. Fund your wallet or pay with cash.', 'CONFLICT');
            }
            $rideId = pm_insert(
                "INSERT INTO ride_rides (rider_id, status, ride_type, category, vehicle_type, pickup_lat, pickup_lng, pickup_text,
                                         dest_lat, dest_lng, dest_text, price, currency, pay_method, instructions, delivery_otp, idempotency_key)
                 VALUES (?, 'searching', 'send_me', 'errand', 'bike', ?, ?, ?, ?, ?, ?, ?, 'NGN', ?, ?, ?, ?)",
                'sddsddsdssss',
                [$uid, $pickupLat, $pickupLng, $pickupText, $destLat, $destLng, $destText, $price, $payMethod, $instructions, $deliveryOtp, $idemKey !== '' ? $idemKey : null]
            );
            pm_json(['error' => false, 'message' => 'Errand booked.', 'data' => ['ride_id' => $rideId, 'delivery_otp' => $deliveryOtp]]);
        }

        $recipientPhone = pm_normalize_phone(pm_in_str($in, 'recipient_phone', 32));
        if ($recipientPhone === '') {
            lg_fail('Recipient phone is required for OTP handoff.');
        }
        $price = calculatePrice($distanceKm, 'dispatch', $packageSize, $weightKg);
        $user = pm_q_one('SELECT bal FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$uid]);
        if ($payMethod === 'wallet' && (float)($user['bal'] ?? 0) < $price) {
            lg_fail('Insufficient wallet balance. Fund your wallet or pay with cash.', 'CONFLICT');
        }
        try {
            $imageUrl = pm_store_image('package_image', 'uploads/packages/' . pm_uid_dir($uid), true, 8 * 1024 * 1024, 1600);
        } catch (PmHttpError $e) {
            lg_fail($e->getMessage() === 'Missing required upload: package image.' ? 'A clear photo of the package is required.' : $e->getMessage());
        }
        $rideId = pm_insert(
            "INSERT INTO ride_rides (rider_id, status, ride_type, category, vehicle_type, pickup_lat, pickup_lng, pickup_text,
                                     dest_lat, dest_lng, dest_text, price, currency, pay_method, package_size, package_weight,
                                     delivery_otp, recipient_phone, package_image, idempotency_key)
             VALUES (?, 'searching', 'dispatch', 'logistics', 'delivery', ?, ?, ?, ?, ?, ?, ?, 'NGN', ?, ?, ?, ?, ?, ?, ?)",
            'sddsddsdssdssss',
            [$uid, $pickupLat, $pickupLng, $pickupText, $destLat, $destLng, $destText, $price, $payMethod, $packageSize, $weightKg,
             $deliveryOtp, $recipientPhone, $imageUrl, $idemKey !== '' ? $idemKey : null]
        );
        pm_json(['error' => false, 'message' => 'Dispatch booked.', 'data' => ['ride_id' => $rideId, 'delivery_otp' => $deliveryOtp]]);
        break;

    default:
        lg_fail('Unsupported action.');
}
