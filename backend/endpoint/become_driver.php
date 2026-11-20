<?php
declare(strict_types=1);

/**
 * POST become_driver.php — driver onboarding for the session user (session required).
 * action=status : application status
 * action=submit : multipart application (9 images re-encoded to WebP with random names)
 *
 * Security: the onboarding row and driver record are always those of the session user. An existing
 * ride_drivers row is only re-used if it is already linked to this user's onboarding, or if it is an
 * unlinked legacy row with the same phone/NIN; a phone/NIN that belongs to ANOTHER user's driver
 * profile is rejected (prevents hijacking someone else's driver account / wallet).
 */

require_once __DIR__ . '/security.php';
require_once __DIR__ . '/activities.php';

const DRIVER_IMAGE_FIELDS = ['driver_face', 'license_front', 'license_back', 'nin_front', 'nin_back', 'vehicle_angled', 'vehicle_front', 'vehicle_back', 'vehicle_side'];
const DRIVER_RIDE_TYPES = ['street_ride', 'campus_ride', 'send_me', 'dispatch'];
const DRIVER_VEHICLE_TYPES = ['car', 'bike', 'keke', 'tricycle', 'bus', 'van', 'truck', 'bicycle', 'delivery'];

pm_require_method('POST');
$uid = pm_require_session();
$in = pm_input();

function bd_fail(string $message, string $code = 'VALIDATION'): void
{
    pm_error($code, $message, 200, ['data' => null]);
}

function buildStatusPayload(?array $row): array
{
    if (!$row) {
        return ['status' => 'not_started', 'raw_status' => null, 'can_submit' => true, 'driver_id' => null, 'admin_note' => null,
                'submitted_at' => null, 'updated_at' => null, 'message' => 'No driver application found.'];
    }
    $status = pm_normalize_driver_status((string)$row['status']);
    $messages = [
        'pending'   => 'Your driver application is pending review.',
        'activated' => 'Your driver profile is already activated.',
        'rejected'  => 'Your previous application was rejected. You may update and resubmit.',
    ];
    return [
        'status'       => $status,
        'raw_status'   => $row['status'],
        'can_submit'   => !in_array($status, ['pending', 'activated'], true),
        'driver_id'    => $row['driver_id'] !== null ? (int)$row['driver_id'] : null,
        'admin_note'   => $row['admin_note'],
        'submitted_at' => $row['submitted_at'],
        'updated_at'   => $row['updated_at'],
        'message'      => $messages[$status] ?? 'No driver application found.',
    ];
}

$action = strtolower(pm_in_str($in, 'action', 20, 'submit'));
$existing = pm_q_one(
    'SELECT id, status, driver_id, admin_note, submitted_at, updated_at FROM ride_driver_onboarding WHERE user_uid = ? LIMIT 1',
    's',
    [$uid]
);

if ($action === 'status') {
    pm_json(['error' => false, 'message' => 'Driver application status loaded.', 'data' => buildStatusPayload($existing)]);
}
if ($action !== 'submit') {
    bd_fail('Unsupported action.');
}

pm_rate_limit('driver_apply', $uid, 5, 3600, 'Too many submissions. Please try again later.');

$legalName = pm_in_str($in, 'legal_full_name', 120);
$email = strtolower(pm_in_str($in, 'email', 120));
$phone = pm_normalize_phone(pm_in_str($in, 'phone', 32));
$nin = strtoupper(preg_replace('/\s+/', '', pm_in_str($in, 'nin', 64)) ?? '');
$bankName = pm_in_str($in, 'bank_name', 150);
$accountNumber = preg_replace('/\D/', '', pm_in_str($in, 'account_number', 20)) ?? '';
$vehicleType = pm_in_enum($in, 'vehicle_type', DRIVER_VEHICLE_TYPES, 'car');
$vehicleModel = pm_in_str($in, 'vehicle_model', 40);
$rideTypesRaw = json_decode((string)($in['allowed_ride_types'] ?? '["street_ride"]'), true);
$rideTypes = array_values(array_intersect(DRIVER_RIDE_TYPES, is_array($rideTypesRaw) ? array_map('strval', $rideTypesRaw) : []));
if (!$rideTypes) {
    $rideTypes = ['street_ride'];
}

foreach (['Legal full name' => $legalName, 'Phone number' => $phone, 'NIN' => $nin, 'Bank Name' => $bankName, 'Account Number' => $accountNumber] as $label => $v) {
    if ($v === '') {
        bd_fail($label . ' is required.');
    }
}
if ($email !== '' && !filter_var($email, FILTER_VALIDATE_EMAIL)) {
    bd_fail('Please enter a valid email address.');
}
if (!preg_match('/^[A-Z0-9]{8,20}$/', $nin)) {
    bd_fail('NIN is invalid.');
}
if (strlen($accountNumber) < 10) {
    bd_fail('Account Number is invalid.');
}

$existingStatus = pm_normalize_driver_status((string)($existing['status'] ?? ''));
if ($existingStatus === 'pending') {
    bd_fail('Your driver application is already pending review.', 'CONFLICT');
}
if ($existingStatus === 'activated') {
    bd_fail('Your driver profile is already activated.', 'CONFLICT');
}

// Phone / NIN already used by another user's onboarding?
$clash = pm_q_one('SELECT id FROM ride_driver_onboarding WHERE (phone = ? OR nin = ?) AND user_uid <> ? LIMIT 1', 'sss', [$phone, $nin, $uid]);
if ($clash) {
    bd_fail('This phone number or NIN is already registered to another driver.', 'CONFLICT');
}

$user = pm_q_one('SELECT fname, lname, email FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$uid]);
$resolvedEmail = $email !== '' ? $email : (string)($user['email'] ?? '');

$urls = [];
try {
    foreach (DRIVER_IMAGE_FIELDS as $field) {
        $urls[$field] = pm_store_image($field, 'uploads/driver_applications/' . pm_uid_dir($uid), true, 10 * 1024 * 1024, 1200);
    }
} catch (PmHttpError $e) {
    foreach ($urls as $u) {
        pm_delete_stored_file($u);
    }
    bd_fail($e->getMessage());
}

$vehicleImagesJson = json_encode([$urls['vehicle_angled'], $urls['vehicle_front'], $urls['vehicle_back'], $urls['vehicle_side']], JSON_UNESCAPED_SLASHES);
$submittedImagesJson = json_encode([
    'driver_face_url' => $urls['driver_face'], 'license_front_url' => $urls['license_front'], 'license_back_url' => $urls['license_back'],
    'nin_front_url' => $urls['nin_front'], 'nin_back_url' => $urls['nin_back'], 'vehicle_angled_url' => $urls['vehicle_angled'],
    'vehicle_front_url' => $urls['vehicle_front'], 'vehicle_back_url' => $urls['vehicle_back'], 'vehicle_side_url' => $urls['vehicle_side'],
], JSON_UNESCAPED_SLASHES);
$rideTypesStr = implode(',', $rideTypes);

$result = pm_tx(function () use ($uid, $existing, $legalName, $resolvedEmail, $phone, $nin, $bankName, $accountNumber, $vehicleType, $vehicleModel, $rideTypesStr, $urls, $vehicleImagesJson, $submittedImagesJson) {
    pm_exec('UPDATE unique_user_table SET phone = ? WHERE u_uid = ? LIMIT 1', 'ss', [$phone, $uid]);

    if ($existing) {
        $onboardingId = (int)$existing['id'];
        pm_exec(
            "UPDATE ride_driver_onboarding SET legal_full_name = ?, email = ?, phone = ?, nin = ?, license_front_url = ?, license_back_url = ?,
                    nin_front_url = ?, nin_back_url = ?, vehicle_angled_url = ?, vehicle_front_url = ?, vehicle_back_url = ?, vehicle_side_url = ?,
                    submitted_images = ?, status = 'pending', admin_note = NULL, updated_at = NOW()
             WHERE id = ? AND user_uid = ?",
            'sssssssssssssis',
            [$legalName, $resolvedEmail, $phone, $nin, $urls['license_front'], $urls['license_back'], $urls['nin_front'], $urls['nin_back'],
             $urls['vehicle_angled'], $urls['vehicle_front'], $urls['vehicle_back'], $urls['vehicle_side'], $submittedImagesJson, $onboardingId, $uid]
        );
        $driverId = $existing['driver_id'] !== null ? (int)$existing['driver_id'] : 0;
    } else {
        $onboardingId = pm_insert(
            "INSERT INTO ride_driver_onboarding (user_uid, legal_full_name, email, phone, nin, license_front_url, license_back_url, nin_front_url,
                    nin_back_url, vehicle_angled_url, vehicle_front_url, vehicle_back_url, vehicle_side_url, submitted_images, status)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending')",
            'ssssssssssssss',
            [$uid, $legalName, $resolvedEmail, $phone, $nin, $urls['license_front'], $urls['license_back'], $urls['nin_front'], $urls['nin_back'],
             $urls['vehicle_angled'], $urls['vehicle_front'], $urls['vehicle_back'], $urls['vehicle_side'], $submittedImagesJson]
        );
        $driverId = 0;
    }

    if ($driverId === 0) {
        // Only adopt a legacy driver row that no onboarding record (of any user) points at.
        $legacy = pm_q_one(
            'SELECT d.id FROM ride_drivers d
             LEFT JOIN ride_driver_onboarding o ON o.driver_id = d.id
             WHERE (d.phone = ? OR d.nin = ?) AND o.id IS NULL
             LIMIT 1 FOR UPDATE',
            'ss',
            [$phone, $nin]
        );
        $driverId = $legacy ? (int)$legacy['id'] : 0;
    }

    if ($driverId > 0) {
        pm_exec(
            "UPDATE ride_drivers SET name = ?, phone = ?, nin = ?, bank_name = ?, account_number = ?, vehicle_type = ?, car_model = ?,
                    allowed_ride_types = ?, vehicle_images = ?, car_image_url = ?, avatar_url = ?, is_online = 0, updated_at = NOW()
             WHERE id = ?",
            'sssssssssssi',
            [$legalName, $phone, $nin, $bankName, $accountNumber, $vehicleType, $vehicleModel, $rideTypesStr, $vehicleImagesJson,
             $urls['vehicle_front'], $urls['driver_face'], $driverId]
        );
    } else {
        // New profiles start offline; `rank` is assigned by an admin on approval.
        $driverId = pm_insert(
            'INSERT INTO ride_drivers (name, phone, nin, bank_name, account_number, vehicle_type, car_model, allowed_ride_types,
                                       vehicle_images, car_image_url, avatar_url, is_online)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)',
            'sssssssssss',
            [$legalName, $phone, $nin, $bankName, $accountNumber, $vehicleType, $vehicleModel, $rideTypesStr, $vehicleImagesJson,
             $urls['vehicle_front'], $urls['driver_face']]
        );
    }
    pm_exec('UPDATE ride_driver_onboarding SET driver_id = ?, updated_at = NOW() WHERE id = ?', 'ii', [$driverId, $onboardingId]);
    return ['onboarding_id' => $onboardingId, 'driver_id' => $driverId];
});

pm_activity($uid, 'Driver application submitted');

pm_json([
    'error'   => false,
    'message' => 'Driver application submitted successfully.',
    'data'    => ['onboarding_id' => $result['onboarding_id'], 'driver_id' => $result['driver_id'], 'status' => 'pending'],
]);
