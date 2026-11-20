<?php
header('Content-Type: application/json');

require_once '../unique/unique_con.php';
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

$headers = function_exists('apache_request_headers') ? apache_request_headers() : array();
$token = isset($headers['Authorization']) ? $headers['Authorization'] : '';

$authorized = checkAuthorization($token);
if (!$authorized) {
    http_response_code(401);
    echo json_encode(array(
        'error' => true,
        'message' => 'Unauthorized access',
        'data' => null,
    ));
    exit();
}

function sanitizeInput($input) {
    return trim(htmlspecialchars((string)$input, ENT_QUOTES, 'UTF-8'));
}

function jsonResponse($payload, $statusCode = 200) {
    http_response_code($statusCode);
    echo json_encode($payload);
    exit();
}

function validateRequired($value, $label) {
    if (trim((string)$value) === '') {
        throw new Exception($label . ' is required.');
    }
}

function normalizeDriverStatus($status) {
    $value = strtolower(trim((string)$status));
    if ($value === 'approved' || $value === 'activated') {
        return 'activated';
    }
    if ($value === 'pending') {
        return 'pending';
    }
    if ($value === 'rejected') {
        return 'rejected';
    }
    return 'not_started';
}

function uploadBaseDir() {
    return 'uploads/driver_applications';
}

function uploadRelativeDir() {
    return 'uploads/driver_applications';
}

function ensureUploadDir($userUid) {
    $safeUid = preg_replace('/[^A-Za-z0-9_-]/', '', (string)$userUid);
    if ($safeUid === '') {
        $safeUid = 'unknown_user';
    }

    $absoluteDir = uploadBaseDir() . '/' . $safeUid;
    if (!is_dir($absoluteDir)) {
        @mkdir($absoluteDir, 0775, true);
    }

    if (!is_dir($absoluteDir)) {
        throw new Exception('Unable to prepare upload directory.');
    }

    return array(
        'absolute' => $absoluteDir,
        'relative' => uploadRelativeDir() . '/' . $safeUid,
    );
}

/**
 * Advanced Image Processor: 
 * Resizes to max 1200px, converts to highly compressed WebP, and returns the absolute URL.
 */
function compressAndUploadWebp($fieldName, $userUid, $required = true) {
    if (!isset($_FILES[$fieldName]) || $_FILES[$fieldName]['error'] !== UPLOAD_ERR_OK) {
        if ($required) {
            throw new Exception("Missing required upload: $fieldName.");
        }
        return null;
    }

    $file = $_FILES[$fieldName];
    $tmpPath = $file['tmp_name'];
    $info = @getimagesize($tmpPath);
    
    if (!$info) {
        throw new Exception("Invalid image file uploaded for $fieldName.");
    }

    $mime = $info['mime'];
    
    // Create image resource based on original format
    switch ($mime) {
        case 'image/jpeg':
            $img = imagecreatefromjpeg($tmpPath);
            break;
        case 'image/png':
            $img = imagecreatefrompng($tmpPath);
            break;
        case 'image/webp':
            $img = imagecreatefromwebp($tmpPath);
            break;
        default:
            throw new Exception("Unsupported image format for $fieldName. Please use JPG, PNG, or WEBP.");
    }

    if (!$img) {
        throw new Exception("Failed to process image for $fieldName.");
    }

    // Resize logic (Max width/height 1200px)
    $width = $info[0];
    $height = $info[1];
    $maxDim = 1200;

    if ($width > $maxDim || $height > $maxDim) {
        $ratio = $width / $height;
        if ($ratio > 1) {
            $newWidth = $maxDim;
            $newHeight = (int)($maxDim / $ratio);
        } else {
            $newHeight = $maxDim;
            $newWidth = (int)($maxDim * $ratio);
        }
        
        $newImg = imagecreatetruecolor($newWidth, $newHeight);
        
        // Preserve transparency
        if ($mime === 'image/png' || $mime === 'image/webp') {
            imagealphablending($newImg, false);
            imagesavealpha($newImg, true);
            $transparent = imagecolorallocatealpha($newImg, 255, 255, 255, 127);
            imagefilledrectangle($newImg, 0, 0, $newWidth, $newHeight, $transparent);
        }
        
        imagecopyresampled($newImg, $img, 0, 0, 0, 0, $newWidth, $newHeight, $width, $height);
        imagedestroy($img);
        $img = $newImg;
    }

    // Save as WebP
    $dirs = ensureUploadDir($userUid);
    $safeBase = preg_replace('/[^A-Za-z0-9_-]/', '_', $fieldName);
    $fileName = $safeBase . '_' . time() . '_' . mt_rand(1000, 9999) . '.webp';
    $absolutePath = $dirs['absolute'] . '/' . $fileName;
    $relativePath = $dirs['relative'] . '/' . $fileName;

    // WebP conversion at 80% quality (excellent balance of size vs quality)
    if (!imagewebp($img, $absolutePath, 80)) {
        imagedestroy($img);
        throw new Exception("Failed to save optimized image for $fieldName.");
    }
    imagedestroy($img);

    // Return the absolute public URL
    $baseUrl = 'https://realpickme.com/endpoint/';
    return $baseUrl . $relativePath;
}

function fetchUserAccount($userUid) {
    global $dbconn;
    $escapedUid = mysqli_real_escape_string($dbconn, $userUid);
    $query = "SELECT u_uid, fname, lname, email, phone FROM unique_user_table WHERE u_uid='$escapedUid' LIMIT 1";
    $result = mysqli_query($dbconn, $query);

    if (!$result || mysqli_num_rows($result) === 0) {
        throw new Exception('User account not found.');
    }
    return mysqli_fetch_assoc($result);
}

function fetchExistingOnboarding($userUid) {
    global $dbconn;
    $escapedUid = mysqli_real_escape_string($dbconn, $userUid);
    $query = "SELECT * FROM ride_driver_onboarding WHERE user_uid='$escapedUid' LIMIT 1";
    $result = mysqli_query($dbconn, $query);

    if ($result && mysqli_num_rows($result) > 0) {
        return mysqli_fetch_assoc($result);
    }
    return null;
}

function buildStatusPayload($row) {
    if (!$row) {
        return array(
            'status' => 'not_started',
            'raw_status' => null,
            'can_submit' => true,
            'driver_id' => null,
            'admin_note' => null,
            'submitted_at' => null,
            'updated_at' => null,
            'message' => 'No driver application found.',
        );
    }

    $status = normalizeDriverStatus(isset($row['status']) ? $row['status'] : '');

    return array(
        'status' => $status,
        'raw_status' => isset($row['status']) ? $row['status'] : null,
        'can_submit' => !in_array($status, array('pending', 'activated'), true),
        'driver_id' => isset($row['driver_id']) ? (int)$row['driver_id'] : null,
        'admin_note' => isset($row['admin_note']) ? $row['admin_note'] : null,
        'submitted_at' => isset($row['submitted_at']) ? $row['submitted_at'] : null,
        'updated_at' => isset($row['updated_at']) ? $row['updated_at'] : null,
        'message' => $status === 'pending'
            ? 'Your driver application is pending review.'
            : ($status === 'activated'
                ? 'Your driver profile is already activated.'
                : ($status === 'rejected'
                    ? 'Your previous application was rejected. You may update and resubmit.'
                    : 'No driver application found.')),
    );
}

function getDriverApplicationStatus($userUid) {
    validateRequired($userUid, 'User ID');
    $row = fetchExistingOnboarding($userUid);

    return array(
        'error' => false,
        'message' => 'Driver application status loaded.',
        'data' => buildStatusPayload($row),
    );
}

function saveDriverApplication($userUid, $legalFullName, $email, $phone, $nin, $bankName, $accountNumber, $vehicleType, $vehicleModel, $allowedRideTypesJson) {
    global $dbconn;

    validateRequired($userUid, 'User ID');
    validateRequired($legalFullName, 'Legal full name');
    validateRequired($phone, 'Phone number');
    validateRequired($nin, 'NIN');
    validateRequired($bankName, 'Bank Name');
    validateRequired($accountNumber, 'Account Number');

    $user = fetchUserAccount($userUid);
    $existing = fetchExistingOnboarding($userUid);
    $existingStatus = normalizeDriverStatus($existing ? $existing['status'] : '');

    if ($existingStatus === 'pending') {
        throw new Exception('Your driver application is already pending review.');
    }
    if ($existingStatus === 'activated') {
        throw new Exception('Your driver profile is already activated.');
    }

    // 1. Process all 9 images through the WebP compression engine
    $driverFace = compressAndUploadWebp('driver_face', $userUid, true);
    $licenseFront = compressAndUploadWebp('license_front', $userUid, true);
    $licenseBack = compressAndUploadWebp('license_back', $userUid, true);
    $ninFront = compressAndUploadWebp('nin_front', $userUid, true);
    $ninBack = compressAndUploadWebp('nin_back', $userUid, true);
    $vehicleAngled = compressAndUploadWebp('vehicle_angled', $userUid, true);
    $vehicleFront = compressAndUploadWebp('vehicle_front', $userUid, true);
    $vehicleBack = compressAndUploadWebp('vehicle_back', $userUid, true);
    $vehicleSide = compressAndUploadWebp('vehicle_side', $userUid, true);

    // 2. Format Vehicle Images into standard JSON Array
    $vehicleImagesArr = [$vehicleAngled, $vehicleFront, $vehicleBack, $vehicleSide];
    $vehicleImagesJson = json_encode($vehicleImagesArr, JSON_UNESCAPED_SLASHES);
    
    // Front car goes to explicit column
    $carImageUrl = $vehicleFront; 

    // Store tracking data for onboarding table
    $submittedImagesJson = json_encode(array(
        'driver_face_url' => $driverFace,
        'license_front_url' => $licenseFront,
        'license_back_url' => $licenseBack,
        'nin_front_url' => $ninFront,
        'nin_back_url' => $ninBack,
        'vehicle_angled_url' => $vehicleAngled,
        'vehicle_front_url' => $vehicleFront,
        'vehicle_back_url' => $vehicleBack,
        'vehicle_side_url' => $vehicleSide,
    ), JSON_UNESCAPED_SLASHES);

    // 3. Process Ride Types (Decode from Flutter's JSON array and comma-separate)
    $rideTypesDecoded = json_decode($allowedRideTypesJson, true);
    $rideTypesStr = is_array($rideTypesDecoded) ? implode(',', $rideTypesDecoded) : 'street_ride';

    // 4. Resolve Strings
    $resolvedName = trim($legalFullName) !== '' ? trim($legalFullName) : trim(($user['fname'] ?? '') . ' ' . ($user['lname'] ?? ''));
    $resolvedEmail = trim($email) !== '' ? trim($email) : trim($user['email'] ?? '');
    $resolvedPhone = trim($phone) !== '' ? trim($phone) : trim($user['phone'] ?? '');
    $resolvedNin = strtoupper(trim($nin));

    // 5. Escaping for SQL
    $escapedUid = mysqli_real_escape_string($dbconn, $userUid);
    $escapedName = mysqli_real_escape_string($dbconn, $resolvedName);
    $escapedEmail = mysqli_real_escape_string($dbconn, $resolvedEmail);
    $escapedPhone = mysqli_real_escape_string($dbconn, $resolvedPhone);
    $escapedNin = mysqli_real_escape_string($dbconn, $resolvedNin);
    $escapedBankName = mysqli_real_escape_string($dbconn, trim($bankName));
    $escapedAccountNumber = mysqli_real_escape_string($dbconn, trim($accountNumber));
    $escapedVehicleType = mysqli_real_escape_string($dbconn, trim($vehicleType));
    $escapedVehicleModel = mysqli_real_escape_string($dbconn, trim($vehicleModel));
    $escapedRideTypes = mysqli_real_escape_string($dbconn, $rideTypesStr);
    
    // Escaping JSON fields
    $escapedVehicleImagesJson = mysqli_real_escape_string($dbconn, $vehicleImagesJson);
    $escapedCarImageUrl = mysqli_real_escape_string($dbconn, $carImageUrl);
    $escapedDriverFace = mysqli_real_escape_string($dbconn, $driverFace);
    
    // Onboarding table escape specifics
    $licenseFrontEsc = mysqli_real_escape_string($dbconn, $licenseFront);
    $licenseBackEsc = mysqli_real_escape_string($dbconn, $licenseBack);
    $ninFrontEsc = mysqli_real_escape_string($dbconn, $ninFront);
    $ninBackEsc = mysqli_real_escape_string($dbconn, $ninBack);
    $vehicleAngledEsc = mysqli_real_escape_string($dbconn, $vehicleAngled);
    $vehicleFrontEsc = mysqli_real_escape_string($dbconn, $vehicleFront);
    $vehicleBackEsc = mysqli_real_escape_string($dbconn, $vehicleBack);
    $vehicleSideEsc = mysqli_real_escape_string($dbconn, $vehicleSide);
    $submittedImagesEsc = mysqli_real_escape_string($dbconn, $submittedImagesJson);

    mysqli_begin_transaction($dbconn);

    try {
        $onboardingId = null;
        $driverId = null;

        // --- UPDATE PHONE GLOBALLY FOR THIS USER ---
        $updateUserPhone = "UPDATE unique_user_table SET phone='$escapedPhone' WHERE u_uid='$escapedUid'";
        if (!mysqli_query($dbconn, $updateUserPhone)) {
            throw new Exception('Unable to sync phone number to global profile.');
        }

        // --- HANDLE ONBOARDING RECORD ---
        if ($existing) {
            $onboardingId = (int)$existing['id'];

            $updateOnboarding = "UPDATE ride_driver_onboarding SET
                legal_full_name='$escapedName',
                email='$escapedEmail',
                phone='$escapedPhone',
                nin='$escapedNin',
                license_front_url='$licenseFrontEsc',
                license_back_url='$licenseBackEsc',
                nin_front_url='$ninFrontEsc',
                nin_back_url='$ninBackEsc',
                vehicle_angled_url='$vehicleAngledEsc',
                vehicle_front_url='$vehicleFrontEsc',
                vehicle_back_url='$vehicleBackEsc',
                vehicle_side_url='$vehicleSideEsc',
                submitted_images='$submittedImagesEsc',
                status='pending',
                admin_note=NULL,
                updated_at=NOW()
                WHERE id='$onboardingId'";

            if (!mysqli_query($dbconn, $updateOnboarding)) {
                throw new Exception('Unable to update driver onboarding record.');
            }

            $driverId = isset($existing['driver_id']) && $existing['driver_id'] !== null ? (int)$existing['driver_id'] : null;
        } else {
            $insertOnboarding = "INSERT INTO ride_driver_onboarding (
                user_uid, legal_full_name, email, phone, nin, license_front_url, license_back_url, nin_front_url, nin_back_url, vehicle_angled_url, vehicle_front_url, vehicle_back_url, vehicle_side_url, submitted_images, status
            ) VALUES (
                '$escapedUid', '$escapedName', '$escapedEmail', '$escapedPhone', '$escapedNin', '$licenseFrontEsc', '$licenseBackEsc', '$ninFrontEsc', '$ninBackEsc', '$vehicleAngledEsc', '$vehicleFrontEsc', '$vehicleBackEsc', '$vehicleSideEsc', '$submittedImagesEsc', 'pending'
            )";
            
            Activities("Driver application submitted",$escapedUid);

            if (!mysqli_query($dbconn, $insertOnboarding)) {
                throw new Exception('Unable to create driver onboarding record.');
            }
            $onboardingId = mysqli_insert_id($dbconn);
        }

        // --- HANDLE DRIVER RECORD ---
        if ($driverId === null) {
            $driverLookup = "SELECT id FROM ride_drivers WHERE phone='$escapedPhone' OR nin='$escapedNin' LIMIT 1";
            $driverLookupResult = mysqli_query($dbconn, $driverLookup);
            if ($driverLookupResult && mysqli_num_rows($driverLookupResult) > 0) {
                $driverRow = mysqli_fetch_assoc($driverLookupResult);
                $driverId = (int)$driverRow['id'];
            }
        }

        if ($driverId !== null) {
            $updateDriver = "UPDATE ride_drivers SET
                name='$escapedName',
                phone='$escapedPhone',
                nin='$escapedNin',
                bank_name='$escapedBankName',
                account_number='$escapedAccountNumber',
                vehicle_type='$escapedVehicleType',
                car_model='$escapedVehicleModel',
                allowed_ride_types='$escapedRideTypes',
                vehicle_images='$escapedVehicleImagesJson',
                car_image_url='$escapedCarImageUrl',
                avatar_url='$escapedDriverFace',
                rank='Verified',
                updated_at=NOW()
                WHERE id='$driverId'";

            if (!mysqli_query($dbconn, $updateDriver)) {
                throw new Exception('Unable to update driver record.');
            }
        } else {
            $insertDriver = "INSERT INTO ride_drivers (
                name, phone, nin, bank_name, account_number, vehicle_type, car_model, 
                allowed_ride_types, vehicle_images, car_image_url, avatar_url, rank
            ) VALUES (
                '$escapedName', '$escapedPhone', '$escapedNin', '$escapedBankName', '$escapedAccountNumber', 
                '$escapedVehicleType', '$escapedVehicleModel', '$escapedRideTypes', '$escapedVehicleImagesJson',
                '$escapedCarImageUrl', '$escapedDriverFace', 'Verified'
            )";
            if (!mysqli_query($dbconn, $insertDriver)) {
                throw new Exception('Unable to create driver record: ' . mysqli_error($dbconn));
            }
            $driverId = mysqli_insert_id($dbconn);
        }

        // --- LINK RECORDS ---
        $linkOnboarding = "UPDATE ride_driver_onboarding SET driver_id='$driverId', updated_at=NOW() WHERE id='$onboardingId'";
        if (!mysqli_query($dbconn, $linkOnboarding)) {
            throw new Exception('Unable to link onboarding record to driver record.');
        }

        mysqli_commit($dbconn);

        return array(
            'error' => false,
            'message' => 'Driver application submitted successfully.',
            'data' => array(
                'onboarding_id' => $onboardingId,
                'driver_id' => $driverId,
                'status' => 'pending',
            ),
        );
    } catch (Exception $e) {
        mysqli_rollback($dbconn);
        throw $e;
    }
}

try {
    $action = isset($_POST['action']) ? strtolower(sanitizeInput($_POST['action'])) : 'submit';
    $userUid = isset($_POST['user']) ? sanitizeInput($_POST['user']) : '';

    if ($action === 'status') {
        jsonResponse(getDriverApplicationStatus($userUid), 200);
    }

    $legalFullName = isset($_POST['legal_full_name']) ? sanitizeInput($_POST['legal_full_name']) : '';
    $email = isset($_POST['email']) ? sanitizeInput($_POST['email']) : '';
    $phone = isset($_POST['phone']) ? sanitizeInput($_POST['phone']) : '';
    $nin = isset($_POST['nin']) ? strtoupper(sanitizeInput($_POST['nin'])) : '';
    $bankName = isset($_POST['bank_name']) ? sanitizeInput($_POST['bank_name']) : '';
    $accountNumber = isset($_POST['account_number']) ? sanitizeInput($_POST['account_number']) : '';
    $vehicleType = isset($_POST['vehicle_type']) ? sanitizeInput($_POST['vehicle_type']) : 'car';
    $vehicleModel = isset($_POST['vehicle_model']) ? sanitizeInput($_POST['vehicle_model']) : '';
    $allowedRideTypes = isset($_POST['allowed_ride_types']) ? $_POST['allowed_ride_types'] : '["street_ride"]';

    jsonResponse(saveDriverApplication($userUid, $legalFullName, $email, $phone, $nin, $bankName, $accountNumber, $vehicleType, $vehicleModel, $allowedRideTypes), 200);
} catch (Exception $e) {
    jsonResponse(array(
        'error' => true,
        'message' => $e->getMessage(),
        'data' => null,
    ), 200);
}