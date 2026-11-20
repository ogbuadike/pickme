<?php
header('Content-Type: application/json');

require_once '../unique/unique_con.php'; 
require_once 'auth.php';
require_once '../unique/unique_code.php';

function sanitizeInput($input) {
    return trim(htmlspecialchars((string)$input, ENT_QUOTES, 'UTF-8'));
}

$headers = function_exists('apache_request_headers') ? apache_request_headers() : [];
$token = isset($headers['Authorization']) ? $headers['Authorization'] : '';

if (!checkAuthorization($token)) {
    http_response_code(401);
    echo json_encode(['error' => true, 'message' => 'Unauthorized access']);
    exit();
}

$user_ID = isset($_POST['user']) ? sanitizeInput($_POST['user']) : '';
$action = isset($_POST['action']) ? sanitizeInput($_POST['action']) : '';

if (empty($user_ID)) {
    echo json_encode(['error' => true, 'message' => 'User ID is required']);
    exit();
}

$user_ID = mysqli_real_escape_string($dbconn, $user_ID);

// 1. Ensure Table Exists
$table_check = "
CREATE TABLE IF NOT EXISTS `user_settings_table` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_uid` varchar(64) NOT NULL,
  `push_notif` tinyint(1) DEFAULT 1,
  `sms_notif` tinyint(1) DEFAULT 1,
  `email_promos` tinyint(1) DEFAULT 0,
  `loc_access` tinyint(1) DEFAULT 1,
  `share_ride` tinyint(1) DEFAULT 0,
  `language` varchar(20) DEFAULT 'English',
  `theme` varchar(20) DEFAULT 'System',
  PRIMARY KEY (`id`),
  UNIQUE KEY `user_uid` (`user_uid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
";
mysqli_query($dbconn, $table_check);

// 2. Ensure User row exists
mysqli_query($dbconn, "INSERT IGNORE INTO user_settings_table (user_uid) VALUES ('$user_ID')");


if ($action === 'get_settings') {
    $q = mysqli_query($dbconn, "SELECT * FROM user_settings_table WHERE user_uid='$user_ID' LIMIT 1");
    
    // Fetch App Settings (Terms & Privacy)
    $app_settings = [
        'terms_of_service_url' => 'https://phantomphones.store/pick_me/terms',
        'privacy_policy_url' => 'https://phantomphones.store/pick_me/privacy'
    ];
    $app_settings_q = mysqli_query($dbconn, "SELECT setting_key, setting_value FROM app_settings WHERE setting_key IN ('terms_of_service_url', 'privacy_policy_url')");
    if ($app_settings_q && mysqli_num_rows($app_settings_q) > 0) {
        while($row = mysqli_fetch_assoc($app_settings_q)) {
            $app_settings[$row['setting_key']] = $row['setting_value'];
        }
    }

    if ($q && mysqli_num_rows($q) > 0) {
        $settings = mysqli_fetch_assoc($q);
        echo json_encode([
            'error' => false,
            'message' => 'Settings retrieved',
            'settings' => [
                'push_notif' => (int)$settings['push_notif'],
                'sms_notif' => (int)$settings['sms_notif'],
                'email_promos' => (int)$settings['email_promos'],
                'loc_access' => (int)$settings['loc_access'],
                'share_ride' => (int)$settings['share_ride'],
                'language' => $settings['language'],
                'theme' => $settings['theme']
            ],
            'app_settings' => $app_settings
        ]);
    } else {
        echo json_encode(['error' => true, 'message' => 'Failed to load settings']);
    }
}
elseif ($action === 'update_setting') {
    $key = isset($_POST['setting_key']) ? sanitizeInput($_POST['setting_key']) : '';
    $val = isset($_POST['setting_value']) ? sanitizeInput($_POST['setting_value']) : '';

    $allowed_keys = ['push_notif', 'sms_notif', 'email_promos', 'loc_access', 'share_ride', 'language', 'theme'];

    if (in_array($key, $allowed_keys)) {
        // Prepare value for SQL based on expected type
        $sql_val = (in_array($key, ['language', 'theme'])) ? "'$val'" : (int)$val;
        
        $update_q = "UPDATE user_settings_table SET $key = $sql_val WHERE user_uid = '$user_ID'";
        if (mysqli_query($dbconn, $update_q)) {
            echo json_encode(['error' => false, 'message' => 'Setting updated']);
        } else {
            echo json_encode(['error' => true, 'message' => 'Database update failed']);
        }
    } else {
        echo json_encode(['error' => true, 'message' => 'Invalid setting key']);
    }
} 
else {
    echo json_encode(['error' => true, 'message' => 'Invalid action']);
}
?>