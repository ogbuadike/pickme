<?php
header('Content-Type: application/json');
// user_logistics.php
require_once '../unique/unique_con.php';
require_once 'auth.php'; 
require_once '../unique/unique_func.php';

function jsonResponse(array $payload, int $statusCode = 200): void {
    http_response_code($statusCode);
    echo json_encode($payload);
    exit();
}

function sanitizeInput($input): string {
    return trim(htmlspecialchars((string)$input, ENT_QUOTES, 'UTF-8'));
}

function calculatePrice(float $distanceKm, string $rideType, string $packageSize = 'envelope', float $weightKg = 0): float {
    if ($rideType === 'send_me') {
        $baseFare = 1200.0;
        $perKmRate = 150.0;
        return round($baseFare + ($distanceKm * $perKmRate), 2);
    } else {
        $baseFare = 800.0;
        $perKmRate = 120.0;
        $sizeMultiplier = ($packageSize === 'box') ? 1.3 : (($packageSize === 'heavy') ? 2.0 : 1.0);
        $weightPenalty = ($weightKg > 10) ? ($weightKg - 10) * 40.0 : 0;
        return round(($baseFare + ($distanceKm * $perKmRate)) * $sizeMultiplier + $weightPenalty, 2);
    }
}

// --- EXACT UPLOAD LOGIC COPIED FROM YOUR ONBOARDING SCRIPT ---

function uploadBaseDir() {
    // REMOVED the '../' so it saves in the exact same root level as your driver applications!
    return 'uploads/packages'; 
}

function uploadRelativeDir() {
    return 'uploads/packages';
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

function movePackageUpload($fieldName, $userUid, $required = true) {
    if (!isset($_FILES[$fieldName])) {
        if ($required) {
            throw new Exception('Missing required upload: ' . $fieldName . '.');
        }
        return null;
    }

    $file = $_FILES[$fieldName];
    if (!isset($file['error']) || $file['error'] === UPLOAD_ERR_NO_FILE) {
        if ($required) {
            throw new Exception('Missing required upload: ' . $fieldName . '.');
        }
        return null;
    }

    if ($file['error'] !== UPLOAD_ERR_OK) {
        throw new Exception('Upload failed for ' . $fieldName . '.');
    }

    $allowedExtensions = array('jpg', 'jpeg', 'png', 'webp');
    $originalName = isset($file['name']) ? $file['name'] : ($fieldName . '.jpg');
    $extension = strtolower(pathinfo($originalName, PATHINFO_EXTENSION));

    if (!in_array($extension, $allowedExtensions, true)) {
        throw new Exception('Invalid file type for ' . $fieldName . '. Only JPG, JPEG, PNG and WEBP are allowed.');
    }

    if ((int)$file['size'] > 8 * 1024 * 1024) {
        throw new Exception('File too large for ' . $fieldName . '.');
    }

    $dirs = ensureUploadDir($userUid);
    $safeBase = preg_replace('/[^A-Za-z0-9_-]/', '_', $fieldName);
    $fileName = $safeBase . '_' . time() . '_' . mt_rand(1000, 9999) . '.' . $extension;
    $absolutePath = $dirs['absolute'] . '/' . $fileName;
    $relativePath = $dirs['relative'] . '/' . $fileName;

    if (!move_uploaded_file($file['tmp_name'], $absolutePath)) {
        throw new Exception('Unable to save uploaded file for ' . $fieldName . '.');
    }

    // Return the full public URL formatted exactly like your DB expects
    return 'https://phantomphones.store/pick_me/' . $relativePath;
}

// -------------------------------------------------------------

try {
    $action = isset($_POST['action']) ? sanitizeInput($_POST['action']) : '';
    $userUid = isset($_POST['user']) ? sanitizeInput($_POST['user']) : '';
    if ($userUid === '') throw new Exception('User ID is required.');

    switch ($action) {
        case 'estimate_delivery':
            $distanceKm = (float)sanitizeInput($_POST['distance_km'] ?? '0');
            $rideType = sanitizeInput($_POST['ride_type'] ?? 'dispatch');
            $packageSize = sanitizeInput($_POST['package_size'] ?? 'envelope');
            $weightKg = (float)sanitizeInput($_POST['weight_kg'] ?? '0');
            
            jsonResponse(['error' => false, 'data' => ['estimated_price' => calculatePrice($distanceKm, $rideType, $packageSize, $weightKg)]]);
            break;

        case 'book_service':
            global $dbconn;
            $rideType = sanitizeInput($_POST['ride_type']); 
            $distanceKm = (float)sanitizeInput($_POST['distance_km'] ?? '1.0');
            $payMethod = sanitizeInput($_POST['pay_method'] ?? 'cash');
            
            $pickupLat = (float)sanitizeInput($_POST['pickup_lat']);
            $pickupLng = (float)sanitizeInput($_POST['pickup_lng']);
            $pickupText = sanitizeInput($_POST['pickup_text']);
            $destLat = (float)sanitizeInput($_POST['dest_lat']);
            $destLng = (float)sanitizeInput($_POST['dest_lng']);
            $destText = sanitizeInput($_POST['dest_text']);

            // Both Send Me and Dispatch get a Secure PIN to guarantee completion
            $deliveryOtp = str_pad((string)mt_rand(0, 9999), 4, '0', STR_PAD_LEFT);

            if ($rideType === 'send_me') {
                $instructions = mysqli_real_escape_string($dbconn, sanitizeInput($_POST['instructions'] ?? ''));
                if (empty($instructions)) throw new Exception('Errand instructions are required.');
                
                $finalPrice = calculatePrice($distanceKm, 'send_me');
                
                $sql = "INSERT INTO ride_rides (
                            rider_id, status, ride_type, category, vehicle_type,
                            pickup_lat, pickup_lng, pickup_text, dest_lat, dest_lng, dest_text,
                            price, currency, pay_method, instructions, delivery_otp
                        ) VALUES (
                            '$userUid', 'searching', 'send_me', 'errand', 'bike',
                            $pickupLat, $pickupLng, '$pickupText', $destLat, $destLng, '$destText',
                            $finalPrice, 'NGN', '$payMethod', '$instructions', '$deliveryOtp'
                        )";

                if (!mysqli_query($dbconn, $sql)) throw new Exception('Errand booking failed: ' . mysqli_error($dbconn));
                jsonResponse(['error' => false, 'message' => 'Errand booked.', 'data' => ['ride_id' => mysqli_insert_id($dbconn), 'delivery_otp' => $deliveryOtp]]);

            } else {
                $packageSize = sanitizeInput($_POST['package_size'] ?? 'envelope');
                $weightKg = (float)sanitizeInput($_POST['weight_kg'] ?? '1.0');
                $recipientPhone = sanitizeInput($_POST['recipient_phone'] ?? '');
                
                if (empty($recipientPhone)) throw new Exception('Recipient phone is required for OTP handoff.');

                // Using your exact custom function to move the file!
                $packageImageUrl = movePackageUpload('package_image', $userUid, true);

                if (empty($packageImageUrl)) {
                    throw new Exception('A clear photo of the package is required.');
                }

                $finalPrice = calculatePrice($distanceKm, 'dispatch', $packageSize, $weightKg);
                $imgSafe = mysqli_real_escape_string($dbconn, $packageImageUrl);

                $sql = "INSERT INTO ride_rides (
                            rider_id, status, ride_type, category, vehicle_type,
                            pickup_lat, pickup_lng, pickup_text, dest_lat, dest_lng, dest_text,
                            price, currency, pay_method, package_size, package_weight, delivery_otp, recipient_phone, package_image
                        ) VALUES (
                            '$userUid', 'searching', 'dispatch', 'logistics', 'delivery',
                            $pickupLat, $pickupLng, '$pickupText', $destLat, $destLng, '$destText',
                            $finalPrice, 'NGN', '$payMethod', '$packageSize', $weightKg, '$deliveryOtp', '$recipientPhone', '$imgSafe'
                        )";

                if (!mysqli_query($dbconn, $sql)) throw new Exception('Dispatch booking failed: ' . mysqli_error($dbconn));
                jsonResponse(['error' => false, 'message' => 'Dispatch booked.', 'data' => ['ride_id' => mysqli_insert_id($dbconn), 'delivery_otp' => $deliveryOtp]]);
            }
            break;
    }
} catch (Exception $e) {
    jsonResponse(['error' => true, 'message' => $e->getMessage()], 400);
}
?>