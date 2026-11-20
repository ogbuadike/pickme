<?php
header('Content-Type: application/json');

require_once '../unique/unique_con.php'; 
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
//require_once '../unique/unique_all_pg.php'; //unique_pg.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

$headers = apache_request_headers();
$token = isset($headers['Authorization']) ? $headers['Authorization'] : '';

// Check authorization
$authorized = checkAuthorization($token);
if (!$authorized) {
    http_response_code(401); // Set Unauthorized HTTP response code
    $response = array(
        'error' => true,
        'message' => 'Unauthorized access',
        'data' => null
    );

    echo json_encode($response);
    exit();
}

function sanitizeInput($input) {
    return trim(htmlspecialchars($input));
}

function set_pin($user_pin, $uid) {
    global $dbconn;

    // Hash the PIN with bcrypt
    $hashedPin = password_hash($user_pin, PASSWORD_BCRYPT);

    // Escape the inputs to prevent SQL injection
    $hashedPinEscaped = mysqli_real_escape_string($dbconn, $hashedPin);
    $uidEscaped = mysqli_real_escape_string($dbconn, $uid);

    // Prepare the SQL query
    $user_login = "UPDATE unique_user_table SET access='$hashedPinEscaped' WHERE u_uid='$uidEscaped'";

    // Execute the query and check the result
    if (mysqli_query($dbconn, $user_login)) {
        return array(
            'error' => false,
            'message' => 'Pin set successfully.'
        );
    } else {
        return array(
            'error' => true,
            'message' => 'Error setting pin',
        );
    }
}





$user_id = isset($_POST['uid']) ? sanitizeInput($_POST['uid']) : '';
$user_pin = isset($_POST['pin']) ? sanitizeInput($_POST['pin']) : '';

if($user_id !='' && $user_pin !=''){
    $response = set_pin($user_pin, $user_id);
}else{
    $response = array(
        'error' => true,
        'message' => 'Pin can\'t be empty',
        'data' => null
    );
}




http_response_code(200);
echo json_encode($response);

