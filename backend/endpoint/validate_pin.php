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

function validate_pin($user_pin, $uid) {
    global $dbconn;

    // Escape the inputs to prevent SQL injection
    $uidEscaped = mysqli_real_escape_string($dbconn, $uid);

    // Prepare the SQL query
    $user_login = "SELECT access FROM unique_user_table WHERE u_uid='$uidEscaped'";
    $query = mysqli_query($dbconn, $user_login);
    $query_n = mysqli_num_rows($query);

    if ($query_n == 1) {
        // Fetch the stored hashed PIN
        $row = mysqli_fetch_assoc($query);
        $storedHashedPin = $row['access'];

        // Verify the provided PIN against the stored hash
        if (password_verify($user_pin, $storedHashedPin)) {
            return array(
                'error' => false,
                'message' => 'Authenticated'
            );
        } else {
            return array(
                'error' => true,
                'message' => 'Error Authenticating pin',
            );
        }
    } else {
        return array(
            'error' => true,
            'message' => 'Error Authenticating pin',
        );
    }
}





$user_id = isset($_POST['uid']) ? sanitizeInput($_POST['uid']) : '';
$user_pin = isset($_POST['pin']) ? sanitizeInput($_POST['pin']) : '';

if($user_id !='' && $user_pin !=''){
    $response = validate_pin($user_pin, $user_id);
}else{
    $response = array(
        'error' => true,
        'message' => 'Pin can\'t be empty',
        'data' => null
    );
}




http_response_code(200);
echo json_encode($response);

