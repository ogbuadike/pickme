<?php
header('Content-Type: application/json');

require_once '../unique/unique_con.php'; 
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

function sanitizeInput($input) {
    return trim(htmlspecialchars((string)$input, ENT_QUOTES, 'UTF-8'));
}

$headers = function_exists('apache_request_headers') ? apache_request_headers() : [];
$token = isset($headers['Authorization']) ? $headers['Authorization'] : '';

// Check authorization
$authorized = checkAuthorization($token);
if (!$authorized) {
    http_response_code(401);
    echo json_encode([
        'error' => true,
        'message' => 'Unauthorized access',
        'data' => null
    ]);
    exit();
}

$user_ID = isset($_POST['user']) ? sanitizeInput($_POST['user']) : '';

$response = array();
$response["error"] = false;
$response["user"] = array();

if ($user_ID != '') {
    $user_ID = mysqli_real_escape_string($dbconn, $user_ID);

    if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['action'])) {
        $action = sanitizeInput($_POST['action']);

        if ($action === 'delete_account') {
            mysqli_begin_transaction($dbconn);
            try {
                mysqli_query($dbconn, "DELETE FROM ride_driver_locations WHERE driver_id IN (SELECT id FROM ride_drivers WHERE phone = (SELECT phone FROM unique_user_table WHERE u_uid='$user_ID'))");
                mysqli_query($dbconn, "DELETE FROM ride_drivers WHERE phone = (SELECT phone FROM unique_user_table WHERE u_uid='$user_ID')");
                mysqli_query($dbconn, "DELETE FROM ride_driver_onboarding WHERE user_uid='$user_ID'");
                
                $del_q = "DELETE FROM unique_user_table WHERE u_uid = '$user_ID'";
                if (!mysqli_query($dbconn, $del_q)) {
                    throw new Exception("Failed to delete core user record.");
                }

                mysqli_commit($dbconn);
                $response["error"] = false;
                $response["message"] = "Account completely deleted.";
            } catch (Exception $e) {
                mysqli_rollback($dbconn);
                $response["error"] = true;
                $response["message"] = "Failed to delete account: " . $e->getMessage();
            }
        }
        
        // ---> NEW: DEDICATED EMERGENCY CONTACT HANDLER <---
        elseif ($action === 'update_emergency_contact') {
            $emergency = isset($_POST['emergency_contact']) ? sanitizeInput($_POST['emergency_contact']) : '';
            
            // Ensure column exists
            mysqli_query($dbconn, "ALTER TABLE unique_user_table ADD COLUMN IF NOT EXISTS emergency_contact VARCHAR(100) DEFAULT ''");
            
            $update_query = "UPDATE unique_user_table SET emergency_contact = '$emergency' WHERE u_uid = '$user_ID'";
            if (mysqli_query($dbconn, $update_query)) {
                $response["error"] = false;
                $response["message"] = "Emergency contact updated successfully!";
            } else {
                $response["error"] = true;
                $response["message"] = "Failed to update emergency contact.";
            }
        }
        
        elseif ($action === 'update_password') {
            function hashpass($code) {
                return hash('sha256', $code);
            }
        
            $oldPasswordInput = $_POST['old_password'] ?? null;
            $oldPassword = $oldPasswordInput !== null ? sanitizeInput(hashpass($oldPasswordInput)) : '';
        
            $newPasswordInput = $_POST['new_password'] ?? null;
            $newPassword = $newPasswordInput !== null ? sanitizeInput(hashpass($newPasswordInput)) : '';
        
            $user_query = "SELECT pass_code FROM unique_user_table WHERE u_uid = '$user_ID'";
            $user_result = mysqli_query($dbconn, $user_query);
            $user_data = mysqli_fetch_assoc($user_result);
        
            if ($oldPassword === $user_data['pass_code']) {
                $update_query = "UPDATE unique_user_table SET pass_code = '$newPassword' WHERE u_uid = '$user_ID'";
        
                if (mysqli_query($dbconn, $update_query)) {
                    $response["error"] = false;
                    $response["message"] = "Password updated successfully!";
                } else {
                    $response["error"] = true;
                    $response["message"] = "Failed to update password.";
                }
            } else {
                $response["error"] = true;
                $response["message"] = "Old password is incorrect.";
            }
        } 
        
        elseif ($action === 'update_transaction_code') {
            $oldCode = isset($_POST['old_transaction_code']) ? sanitizeInput($_POST['old_transaction_code']) : '';
            $newCode = isset($_POST['new_transaction_code']) ? sanitizeInput($_POST['new_transaction_code']) : '';
        
            $user_query = "SELECT access FROM unique_user_table WHERE u_uid = '$user_ID'";
            $user_result = mysqli_query($dbconn, $user_query);
            $user_data = mysqli_fetch_assoc($user_result);
        
            if (password_verify($oldCode, $user_data['access'])) {
                $hashedPin = password_hash($newCode, PASSWORD_BCRYPT);
                $hashedPinEscaped = mysqli_real_escape_string($dbconn, $hashedPin);
                
                $update_query = "UPDATE unique_user_table SET access = '$hashedPinEscaped' WHERE u_uid = '$user_ID'";
        
                if (mysqli_query($dbconn, $update_query)) {
                    $response["error"] = false;
                    $response["message"] = "Transaction code updated successfully!";
                } else {
                    $response["error"] = true;
                    $response["message"] = "Failed to update transaction code.";
                }
            } else {
                $response["error"] = true;
                $response["message"] = "Old transaction code is incorrect.";
            }
        } 
        
        elseif ($action === 'update_profile_picture') {
             if (isset($_FILES['profile_picture'])) {
                if ($_FILES["profile_picture"]["size"] > 5 * 1024 * 1024) {
                    $response["error"] = true;
                    $response["message"] = "Image size should be less than 5MB.";
                } else {
                    $uploadResult = image_upload(
                        [$_FILES['profile_picture']['name']],   
                        [$_FILES['profile_picture']['tmp_name']], 
                        'img/users/',                            
                        90                                       
                    );
            
                    if (is_numeric($uploadResult)) {
                        $response["error"] = true;
                        $response["message"] = $uploadResult == 1 
                            ? "Image dimensions are too small" 
                            : "Invalid file format";
                    } else {
                        $publicBaseUrl = 'https://realpickme.com/endpoint/img/users/';
                        $image_link = $publicBaseUrl . $uploadResult;
            
                        $update_query = "UPDATE unique_user_table SET b_logo = '$image_link' WHERE u_uid = '$user_ID'";
                        
                        if (mysqli_query($dbconn, $update_query)) {
                            $response["error"] = false;
                            $response["message"] = "Profile picture updated successfully!";
                            $response["user_logo"] = $image_link;
                        } else {
                            $response["error"] = true;
                            $response["message"] = "Failed to update profile picture in the database.";
                        }
                    }
                }
            } else {
                $response["error"] = true;
                $response["message"] = "No profile picture uploaded.";
            }
        }
        
    } else {
        // GET USER INFO
        
        mysqli_query($dbconn, "ALTER TABLE unique_user_table ADD COLUMN IF NOT EXISTS emergency_contact VARCHAR(100) DEFAULT ''");
        
        $user_info = "SELECT * FROM unique_user_table WHERE u_uid='$user_ID' ";
        $user_info_q = mysqli_query($dbconn, $user_info);
        $user_info_f = mysqli_fetch_assoc($user_info_q);
        $user_info_n = mysqli_num_rows($user_info_q);

        // Fetch driver stats if they are a driver
        $driver_stats = "SELECT completed_trips FROM ride_drivers WHERE phone = '" . mysqli_real_escape_string($dbconn, $user_info_f['phone'] ?? '') . "' LIMIT 1";
        $driver_q = mysqli_query($dbconn, $driver_stats);
        $driver_f = mysqli_fetch_assoc($driver_q);
        $total_trips = $driver_f ? (int)$driver_f['completed_trips'] : 0;

        $last_tran = "SELECT * FROM unique_account_table WHERE user_uid='$user_ID' ORDER BY id DESC LIMIT 1";
        $last_tran_q = mysqli_query($dbconn, $last_tran);
        $last_tran_f = mysqli_fetch_assoc($last_tran_q);

        $user_last_type = '';
        $user_last_tran = '0.00';

        if (isset($last_tran_f['amount']) && is_numeric($last_tran_f['amount'])) {
            $user_last_tran = number_format((float) $last_tran_f['amount'], 2, '.', '');
        }

        if (($last_tran_f['type'] ?? 'minus') === 'minus') {
            $user_last_type = '-';
        } elseif (($last_tran_f['type'] ?? 'plus') === 'plus') {
            $user_last_type = '+';
        }

        $user_last_tran = $user_last_type . $user_last_tran;
        if ($user_last_tran === '' || $user_last_tran === '0.00' || $user_last_tran === '-0.00') {
            $user_last_tran = '+0.00';
        }

        // Fetch App Settings (Privacy Policy)
        $privacy_url = "https://realpickme.com/endpoint/privacy"; // Default Fallback
        $app_settings_q = mysqli_query($dbconn, "SELECT setting_value FROM app_settings WHERE setting_key = 'privacy_policy_url' LIMIT 1");
        if ($app_settings_q && mysqli_num_rows($app_settings_q) > 0) {
            $setting_f = mysqli_fetch_assoc($app_settings_q);
            $privacy_url = $setting_f['setting_value'];
        }

        if ($user_info_n > 0) {
            http_response_code(200);

            $userData = array(
                'user_fname' => $user_info_f['fname'] ?? '',
                'user_bal' => $user_info_f['bal'] ?? '0.00',
                'user_lname' => $user_info_f['lname'] ?? '',
                'user_oname' => $user_info_f['oname'] ?? '',
                'user_email' => $user_info_f['email'] ?? '',
                'user_phone' => $user_info_f['phone'] ?? '',
                'user_base_location' => $user_info_f['base_location'] ?? '',
                'user_last_location' => $user_info_f['last_location'] ?? '',
                'user_country' => $user_info_f['country'] ?? '',
                'user_logo' => $user_info_f['b_logo'] ?? '',
                'user_date_registered' => $user_info_f['datetime'] ?? '',
                'emergency_contact' => $user_info_f['emergency_contact'] ?? '',
                'user_approved_user' => $user_info_f['visibility'] ?? '',
                'user_last_tran' => $user_last_tran,
                'user_currency' => "₦",
                'user_bank' => $user_info_f['Bank_Name'],
                'user_account_name' => $user_info_f['Account_Name'],
                'user_account_number' => $user_info_f['Account_Number'],
                'user_mode' => $user_info_f['user_mode'] ?? '',
                'total_trips' => $total_trips 
            );

            $response["error"] = false;
            $response["user"] = $userData;
            $response["app_settings"] = [
                'privacy_policy_url' => $privacy_url
            ];
        } else {
            $response["error"] = true;
            $response["error_msg"] = "Invalid user ID";
        }
    }
} else {
    $response["error"] = true;
    $response["error_msg"] = "User ID is required";
}

echo json_encode($response);