<?php
header('Content-Type: application/json');

require_once '../unique/unique_con.php'; 
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
//require_once '../unique/unique_all_pg.php'; //unique_pg.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

$headers = function_exists('apache_request_headers') ? apache_request_headers() : array();
$token = isset($headers['Authorization']) ? $headers['Authorization'] : '';

// Check authorization
$authorized = checkAuthorization($token);
if (!$authorized) {
    http_response_code(401);
    $response = array(
        'error' => true,
        'message' => 'Unauthorized access',
        'data' => null
    );

    echo json_encode($response);
    exit();
}

function sanitizeInput($input) {
    return trim(htmlspecialchars((string)$input));
}

function normalizeDriverStatus($status) {
    $status = strtolower(trim((string)$status));

    if ($status === 'approved' || $status === 'activated') {
        return 'activated';
    }

    if ($status === 'pending') {
        return 'pending';
    }

    if ($status === 'rejected') {
        return 'rejected';
    }

    return 'not_started';
}

function getDriverLoginMeta($userUid) {
    global $dbconn;

    $default = array(
        'is_driver' => false,
        'driver_status' => 'not_started',
        'driver_id' => '',
        'driver_online' => 0,
        'driver_rank' => '',
        'driver_category' => '',
        'driver_car_plate' => '',
        'post_login_home' => 'home',
    );

    if (empty($userUid)) {
        return $default;
    }

    $escapedUid = mysqli_real_escape_string($dbconn, $userUid);

    $driver_sql = "SELECT 
            o.status AS onboarding_status,
            o.driver_id AS onboarding_driver_id,
            d.id AS driver_id,
            d.is_online,
            d.rank,
            d.category,
            d.car_plate
        FROM ride_driver_onboarding o
        LEFT JOIN ride_drivers d ON d.id = o.driver_id
        WHERE o.user_uid='$escapedUid'
        ORDER BY o.id DESC
        LIMIT 1";

    $driver_q = mysqli_query($dbconn, $driver_sql);
    if (!$driver_q || mysqli_num_rows($driver_q) < 1) {
        return $default;
    }

    $driver_fet = mysqli_fetch_assoc($driver_q);
    $driver_status = normalizeDriverStatus(isset($driver_fet['onboarding_status']) ? $driver_fet['onboarding_status'] : '');

    $resolved_driver_id = '';
    if (isset($driver_fet['driver_id']) && $driver_fet['driver_id'] !== null && $driver_fet['driver_id'] !== '') {
        $resolved_driver_id = (string)$driver_fet['driver_id'];
    } elseif (isset($driver_fet['onboarding_driver_id']) && $driver_fet['onboarding_driver_id'] !== null && $driver_fet['onboarding_driver_id'] !== '') {
        $resolved_driver_id = (string)$driver_fet['onboarding_driver_id'];
    }

    $is_driver = ($resolved_driver_id !== '' && ($driver_status === 'activated'));

    return array(
        'is_driver' => $is_driver,
        'driver_status' => $driver_status,
        'driver_id' => $is_driver ? $resolved_driver_id : '',
        'driver_online' => $is_driver ? (int)$driver_fet['is_online'] : 0,
        'driver_rank' => $is_driver ? (string)$driver_fet['rank'] : '',
        'driver_category' => $is_driver ? (string)$driver_fet['category'] : '',
        'driver_car_plate' => $is_driver ? (string)$driver_fet['car_plate'] : '',
        'post_login_home' => $is_driver ? 'driver_home' : 'home',
    );
}

function login($username, $password) {
    global $dbconn;

    // Hash the password using SHA-256
    $hashedPassword = hash('sha256', $password);

    // Escape user input (You can use mysqli_real_escape_string here if needed)
    $escapedUsername = mysqli_real_escape_string($dbconn, $username);

    $user_login = "SELECT * FROM unique_user_table WHERE (email='$escapedUsername' AND pass_code='$hashedPassword') OR (phone='$escapedUsername' AND pass_code='$hashedPassword') LIMIT 1";
    $user_login_q = mysqli_query($dbconn, $user_login);
    $user_login_num = $user_login_q ? mysqli_num_rows($user_login_q) : 0;
    $user_login_fet = $user_login_q ? mysqli_fetch_assoc($user_login_q) : null;

    if ($user_login_num == 1 && $user_login_fet) {
        if ((int)$user_login_fet['sta'] == 0) {
            $driver_meta = getDriverLoginMeta($user_login_fet['u_uid']);

            $my_user_uid = $user_login_fet['u_uid'];
            
            Activities("Logged in to account",$my_user_uid);

            return array(
                'error' => false,
                'login_msg' => array(
                    'title_msg' => 'Success!',
                    'title_msg_body' => 'Congratulations! You have successfully logged in to your account.',
                    'uid' => $user_login_fet['u_uid'],
                    'fname' => $user_login_fet['fname'],
                    'lname' => $user_login_fet['lname'],
                    'oname' => $user_login_fet['oname'],
                    'email' => $user_login_fet['email'],
                    'phone' => $user_login_fet['phone'],
                    'accountname' => $user_login_fet['Account_Name'],
                    'accountnumber' => $user_login_fet['Account_Number'],
                    'bankname' => $user_login_fet['Bank_Name'],
                    'user_mode' => $user_login_fet['user_mode'],
                    'u_type' => (string)$user_login_fet['u_type'],
                    'is_driver' => $driver_meta['is_driver'],
                    'driver_status' => $driver_meta['driver_status'],
                    'driver_id' => $driver_meta['driver_id'],
                    'driver_online' => $driver_meta['driver_online'],
                    'driver_rank' => $driver_meta['driver_rank'],
                    'driver_category' => $driver_meta['driver_category'],
                    'driver_car_plate' => $driver_meta['driver_car_plate'],
                    'post_login_home' => $driver_meta['post_login_home'],
                )
            );
        } elseif ((int)$user_login_fet['sta'] == 1) {
            return array(
                'error' => true,
                'login_msg' => array(
                    'title_msg' => 'Account Suspended',
                    'title_msg_body' => 'Your account has been suspended. Please contact support for further assistance.'
                )
            );
        }
    }

    return array(
        'error' => true,
        'login_msg' => array(
            'title_msg' => 'Invalid Username or Password',
            'title_msg_body' => 'Oops! The username or password you entered is incorrect. Please double-check and try again.'
        )
    );
}

$user_name = isset($_POST['email']) ? sanitizeInput($_POST['email']) : '';
$user_pass = isset($_POST['password']) ? (string)$_POST['password'] : '';

$response = login($user_name, $user_pass);

http_response_code(200);
echo json_encode($response);
