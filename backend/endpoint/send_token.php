<?php
header('Content-Type: application/json');

require_once '../unique/unique_con.php'; 
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

// Get headers
$headers = apache_request_headers();
$authToken = isset($headers['Authorization']) ? $headers['Authorization'] : '';

// Authorization check
if (!checkAuthorization($authToken)) {
    $response = [
        "error" => true,
        "message" => "Unauthorized access",
        "data" => null
    ];
    http_response_code(401); // Unauthorized
    echo json_encode($response);
    exit();
}

// Retrieve FCM token, UID, and device info from POST request
$token = isset($_POST['token']) ? $_POST['token'] : '';
$token_uid = isset($_POST['uid']) ? $_POST['uid'] : '';
$device = isset($_POST['device']) ? $_POST['device'] : '';

// Normalize token_uid if 'null'
if($token_uid === 'null') {
    $token_uid = '';
}

// Ensure token, UID, and device are provided (not empty)
/*
if (empty($token) || empty($token_uid) || empty($device)) {
    $response = [
        "error" => true,
        "message" => "Token, UID, and device info are required",
        "data" => null
    ];
    http_response_code(400); // Bad Request
    echo json_encode($response);
    exit();
}
*/

// Check if the device already exists in the database
$deviceCheckQuery = "SELECT * FROM app_users WHERE device_info = '$device'";
$deviceCheckResult = mysqli_query($dbconn, $deviceCheckQuery);

// If device is found
if (mysqli_num_rows($deviceCheckResult) > 0) {
    $deviceRow = mysqli_fetch_assoc($deviceCheckResult);
    $existingToken = $deviceRow['u_token'];
    $existingUid = $deviceRow['uid'];

    // Check if either the token or UID has changed and only update if both token and UID are non-empty
    if (($existingToken !== $token && $token !=='')  || ($existingUid !== $token_uid && $token_uid !=='' )) {
        // Update the token and UID for this device
        $updateQuery = "UPDATE app_users SET u_token = '$token', uid = '$token_uid' WHERE device_info = '$device'";
        $updateResult = mysqli_query($dbconn, $updateQuery);

        if ($updateResult) {
            $response = [
                "error" => false,
                "message" => "Device token and UID updated successfully",
                "data" => null
            ];
            http_response_code(200); // OK
        } else {
            $response = [
                "error" => true,
                "message" => "Failed to update device token and UID",
                "data" => null
            ];
            http_response_code(500); // Internal Server Error
        }
    } else {
        // No changes detected, no need to update
        $response = [
            "error" => false,
            "message" => "No changes detected. Token and UID are the same.",
            "data" => null
        ];
        http_response_code(200); // OK
    }
} else {
    // Device not found, insert it
    $insertQuery = "INSERT INTO app_users (uid, u_token, device_info, date_time) VALUES ('$token_uid', '$token', '$device', NOW())";
    $insertResult = mysqli_query($dbconn, $insertQuery);

    if ($insertResult) {
        $response = [
            "error" => false,
            "message" => "Device logged successfully",
            "data" => null
        ];
        http_response_code(200); // OK
    } else {
        $response = [
            "error" => true,
            "message" => "Failed to log the device",
            "data" => null
        ];
        http_response_code(500); // Internal Server Error
    }
}

// Output the final response
echo json_encode($response);
?>
