<?php
header('Content-Type: application/json');

require_once '../unique/unique_con.php'; 
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

// Sanitize input to prevent XSS and other attacks
function sanitizeInput($input) {
    return trim(htmlspecialchars($input));
}

// Generate a unique user ID
$user_id  = $code2.$code3.$code4.$code5.$code6.$code1.$code9.$code8.$code7;

function register($user_name, $user_email, $user_phone, $user_pass, $device_id) {
    global $dbconn, $user_id, $DateTime, $QDateDescrip, $API_KEY, $curl, $QTimeGMT;

    $curl = curl_init();
    
    $hashedPassword = hash('sha256', $user_pass);

    $escapedUsername = mysqli_real_escape_string($dbconn, $user_name);
    $escapedUseremail = mysqli_real_escape_string($dbconn, $user_email);
    $escapedUserphone = mysqli_real_escape_string($dbconn, $user_phone);
    $escapedDeviceId = mysqli_real_escape_string($dbconn, $device_id);
    

    // Strict validation including Phone
    if (empty($escapedUsername) || empty($escapedUseremail) || empty($escapedUserphone)) {
        return array(
            'error' => true,
            'login_msg' => array(
                'title_msg' => 'Failed',
                'title_msg_body' => 'Please fill out all required fields correctly.'
            )
        );
    }

    // Check if user already exists by email, phone, or user_id
    $check_user = "SELECT * FROM unique_user_table WHERE email='$escapedUseremail' OR phone='$escapedUserphone' OR u_uid='$user_id'";
    $check_user_q = mysqli_query($dbconn, $check_user);
    if (mysqli_num_rows($check_user_q) > 0) {
        return array(
            'error' => true,
            'login_msg' => array(
                'title_msg' => 'Failed',
                'title_msg_body' => 'A user with this email or phone number already exists.'
            )
        );
    }

    // Split the full name into first and last name
    $nameParts = explode(" ", $escapedUsername);
    $firstName = $nameParts[0];
    $lastName = isset($nameParts[1]) ? $nameParts[1] : '';
    
    // Call Flutterwave API to create a virtual account
    curl_setopt_array($curl, array(
        CURLOPT_URL => "https://api.flutterwave.com/v3/virtual-account-numbers",
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_ENCODING => "",
        CURLOPT_MAXREDIRS => 10,
        CURLOPT_TIMEOUT => 0,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_1_1,
        CURLOPT_CUSTOMREQUEST => "POST",
        CURLOPT_POSTFIELDS => json_encode(array(
            "email" => $escapedUseremail,
            "is_permanent" => true,
            "bvn" => "22442590235",  
            "firstname" => $firstName,
            "lastname" => $lastName,
            "phonenumber" => $escapedUserphone, // Pass the phone number to FLW
            "tx_ref" => $user_id,
            "narration" => $escapedUsername
        )),
        CURLOPT_HTTPHEADER => array(
            "Authorization: Bearer ".$API_KEY,
            "Content-Type: application/json"
        ),
    ));

    $response_Validate = curl_exec($curl);
    curl_close($curl);

    $data = json_decode($response_Validate);
    
    if ($data->status !== 'success') {
        return array(
            'error' => true,
            'login_msg' => array(
                'title_msg' => 'Failed',
                'title_msg_body' => 'Failed to create virtual account. Please check your details.'
            )
        );
    }

    $order_ref = $data->data->order_ref;
    $account_number = $data->data->account_number;
    $bank_name = $data->data->bank_name;
    $account_name = $escapedUsername;
    
    $data_json = json_encode($data);

    // Register the new user (Now inserting phone)
    $regis_user = "INSERT INTO unique_user_table (u_uid, fname, lname, email, phone, pass_code, AID, datetime, date, time, Account_URF, Account_Name, Account_Number, Bank_Name, account) 
                   VALUES ('$user_id', '$firstName', '$lastName', '$escapedUseremail', '$escapedUserphone', '$hashedPassword', '$escapedDeviceId', '$DateTime', '$QDateDescrip', '$QTimeGMT', '$order_ref', '$account_name', '$account_number','$bank_name', '$data_json')";
    $regis_user_q = mysqli_query($dbconn, $regis_user);

    if ($regis_user_q) {
        return array(
            'error' => false,
            'login_msg' => array(
                'title_msg' => 'Success',
                'title_msg_body' => 'Registration successful',
                'uid' => $user_id
            )
        );
    } else {
        return array(
            'error' => true,
            'login_msg' => array(
                'title_msg' => 'Failed',
                'title_msg_body' => 'Registration failed. Please try again.'
            )
        );
    }
}

// Fetch request headers for authorization
$headers = apache_request_headers();
$token = isset($headers['Authorization']) ? $headers['Authorization'] : '';

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

// Retrieve POST data
$user_name = isset($_POST['full_name']) ? sanitizeInput($_POST['full_name']) : '';
$user_email = isset($_POST['email']) ? sanitizeInput($_POST['email']) : '';
$user_phone = isset($_POST['phone']) ? sanitizeInput($_POST['phone']) : '';
$user_pass = isset($_POST['password']) ? $_POST['password'] : '';
$device_id = isset($_POST['device']) ? $_POST['device'] : '';

// Validate required fields
if (empty($user_name) || empty($user_pass) || empty($user_phone)) {
    http_response_code(200);
    $response = array(
        'error' => true,
        'login_msg' => array(
            'title_msg' => 'Failed',
            'title_msg_body' => 'Full name, email, phone, and password are required.'
        )
    );
    echo json_encode($response);
    exit();
}

$response = register($user_name, $user_email, $user_phone, $user_pass, $device_id);

http_response_code(200);
echo json_encode($response);
?>