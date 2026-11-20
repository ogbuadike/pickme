<?php
// Include required files and functions
require_once '../unique/unique_con.php';      // Database connection (expects $dbconn)
require_once 'auth.php';                       // Authentication functions
require_once '../unique/unique_code.php';      // Utilities
require_once '../unique/unique_gtm.php';       // GTM functions
require_once '../unique/unique_func.php';      // image_upload() and sanitizeInput()
require_once 'activities.php';                 // Activity logging (not used for virtual account update as per instruction)

// Response helper: sends a JSON response and terminates the script.
function sendResponse($error, $message, $data = [], $status = 200) {
    header("HTTP/1.1 $status $message");
    echo json_encode([
        "error"   => $error,
        "message" => $message,
        "data"    => $data
    ]);
    exit();
}

// Unified API request function using cURL.
// It supports GET (default) and other HTTP methods (POST, PUT, etc.).
function makeApiRequest($url, $method, $data = [], $headers = []) {
    $curl = curl_init();

    curl_setopt_array($curl, [
        CURLOPT_URL            => $url,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_HTTPHEADER     => $headers,
    ]);

    // For methods other than GET, encode the data as JSON and attach it.
    if ($method !== 'GET') {
        curl_setopt($curl, CURLOPT_POSTFIELDS, json_encode($data));
    }

    $response   = curl_exec($curl);
    $httpCode   = curl_getinfo($curl, CURLINFO_HTTP_CODE);
    $curlError  = curl_error($curl);
    curl_close($curl);

    if ($curlError) {
        return ["error" => true, "message" => "cURL Error: $curlError", "status" => $httpCode];
    }

    $decoded = json_decode($response, true);
    return $decoded ?: ["error" => true, "message" => "Invalid JSON response"];
}

try {
    // Retrieve and validate the authorization header.
    $headers    = apache_request_headers();
    $authHeader = $headers['Authorization'] ?? '';
    if (!checkAuthorization($authHeader)) {
        throw new Exception("Unauthorized", 401);
    }

    // Validate action parameter from POST data.
    $action = sanitizeInput($_POST['action'] ?? '');
    if ($action !== 'create_kyc') {
        throw new Exception("Invalid action", 400);
    }

    // Validate and sanitize the user ID.
    $user_ID = sanitizeInput($_POST['uid'] ?? '');
    if (!$user_ID) {
        throw new Exception("User ID required", 400);
    }
    $user_ID = mysqli_real_escape_string($dbconn, $user_ID);

    // Fetch user data from the database.
    $user_query  = "SELECT * FROM unique_user_table WHERE u_uid = '$user_ID'";
    $user_result = mysqli_query($dbconn, $user_query);
    if (!$user_result) {
        throw new Exception("Database error: " . mysqli_error($dbconn), 500);
    }
    $user_data = mysqli_fetch_assoc($user_result);
    if (!$user_data) {
        throw new Exception("User not found", 404);
    }

    // Validate required fields.
    $required = ['phone', 'address', 'state', 'country', 'postal_code', 'bvn'];
    foreach ($required as $field) {
        if (empty($_POST[$field])) {
            throw new Exception("Missing $field", 400);
        }
    }

    // Validate BVN: it must be an 11-digit number.
    $bvn = sanitizeInput($_POST['bvn']);
    if (!preg_match('/^\d{11}$/', $bvn)) {
        throw new Exception("Invalid BVN", 400);
    }
    $bvn = (string)$bvn; // Ensure BVN is a string

    // Retrieve the virtual account order reference from the user's account data.
    $account = $user_data['account'];
    // Decode the JSON string into an associative array.
    $accountData = json_decode($account, true);
    
    // Check if decoding was successful and 'order_ref' exists.
    if ($accountData !== null && isset($accountData['data']['order_ref'])) {
        $orderRef = $accountData['data']['order_ref'];
    } else {
        $orderRef = null;
    }
    
    // ========================================================
    // Update Virtual Account BVN using Flutterwave's API endpoint.
    // ========================================================
    if (!$orderRef) {
        throw new Exception("Order reference not found in account data", 400);
    }
    
    // Prepare payload with the BVN to update the virtual account.
    $updatePayload = ['bvn' => $bvn];
    
    // Construct the update endpoint URL by appending the order reference.
    $updateUrl = "https://api.flutterwave.com/v3/virtual-account-numbers/".$orderRef;
    
    // Make a PUT request to update the BVN on the virtual account.
    $updateResp = makeApiRequest(
        $updateUrl,
        'PUT',
        $updatePayload,
        [
            "Authorization: Bearer " . $API_KEY,
            "Content-Type: application/json"
        ]
    );
    
    // Check if the update response indicates an error.
    if (!isset($updateResp['status']) || $updateResp['status'] !== 'success') {
        //throw new Exception("Virtual account BVN update failed: " . json_encode($updateResp), 400);
    }
    // ========================================================
    // End of Virtual Account BVN Update
    // ========================================================

    /* 
     * Initiate BVN verification (consent) using Flutterwave’s updated endpoint.
     * The consent process is asynchronous. The payload includes:
     * - bvn: the BVN provided by the customer.
     * - firstname & lastname: taken from the user record.
     * - redirect_url: your callback URL where the customer will be redirected after giving consent.
     */
    $consentPayload = [
        'bvn'          => $bvn,
        'firstname'    => $user_data['fname'],
        'lastname'     => $user_data['lname'],
        'redirect_url' => 'http://phantomphones.store/bvnconsent' // Replace with your actual callback URL.
    ];

    // Make a POST request to initiate the BVN consent process.
    $flutterwaveResp = makeApiRequest(
        "https://api.flutterwave.com/v3/bvn/verifications",
        'POST',
        $consentPayload,
        [
            "Authorization: Bearer " . $API_KEY, // Ensure your secret key is securely stored.
            "Content-Type: application/json"
        ]
    );

    // Check if the BVN consent initiation was successful.
    if (empty($flutterwaveResp) || !isset($flutterwaveResp['data'])) {
        //throw new Exception("BVN verification initiation failed: " . json_encode($flutterwaveResp), 400);
    }

    // Retrieve the reference and redirect URL from the response.
    $bvReference   = $flutterwaveResp['data']['reference'] ?? null;
    $bvRedirectUrl = $flutterwaveResp['data']['redirect_url'] ?? null;

    if (!$bvReference || !$bvRedirectUrl) {
        //throw new Exception("Incomplete BVN verification response", 400);
    }

    // Validate phone number format.
    $phone = sanitizeInput($_POST['phone']);
    if (!preg_match('/^\+?[0-9]{7,15}$/', $phone)) {
        throw new Exception("Invalid phone number", 400);
    }

    // Process selfie image upload.
    if (!isset($_FILES['selfie_image']['tmp_name'])) {
        throw new Exception("Selfie image required", 400);
    }
    $uploadResult = image_upload(
        [$_FILES['selfie_image']['name']],
        [$_FILES['selfie_image']['tmp_name']],
        'img/kyc/',
        90
    );
    if (is_numeric($uploadResult)) {
        $errors = [1 => "Image too small", 2 => "Invalid format"];
        throw new Exception($errors[$uploadResult] ?? "Upload error", 400);
    }
    $selfieUrl = "https://phantomphones.store/pick_me/img/kyc/" . $uploadResult;

    /*
     * Build the Ufitpay payload for creating the KYC record.
     * Note: This uses the BVN provided by the customer.
     * In a full implementation, you may want to update the KYC record once
     * the asynchronous BVN verification process completes.
     */
    $payload = [
        'first_name'   => $user_data['fname'],
        'last_name'    => $user_data['lname'],
        'email'        => $user_data['email'],
        'phone'        => '09072396316',
        'address'      => sanitizeInput($_POST['address']),
        'state'        => sanitizeInput($_POST['state']),
        'country'      => sanitizeInput($_POST['country']),
        'postal_code'  => sanitizeInput($_POST['postal_code']),
        'kyc_method'   => 'SELFIE_IMAGE',
        'bvn'          => $bvn,
        'selfie_image' => $selfieUrl
    ];

    // Create KYC record with Ufitpay.
    $ufitResp = makeApiRequest(
        'https://api.ufitpay.com/v1/create_card_holder',
        'POST',
        $payload,
        [
            "Api-Key: pub-e6fa9cfc6ac9cd99c6f58ad4e3437767",
            "Api-Token: sec-022954bf873f3788ece72c8d5828b164",
            "Content-Type: application/json"
        ]
    );

    if (empty($ufitResp['data'])) {
        throw new Exception("KYC creation failed". json_encode($ufitResp), 500);
    }

    // Final response: Include Ufitpay KYC data, BVN consent details, and virtual account update response.
    sendResponse(
        false,
        "KYC created successfully. Please complete BVN verification by following the provided URL.",
        [
            'virtual_account' => $updateResp, // Virtual account update API response
            'card_holder'     => $ufitResp['data'],
            'bvn_consent'     => [
                'consent_reference' => $bvReference,
                'redirect_url'      => $bvRedirectUrl
            ]
        ],
        201
    );

} catch (Exception $e) {
    $status = $e->getCode() ?: 500;
    sendResponse(true, $e->getMessage(), [], $status);
}
?>





<?php
/** Include required files and functions
require_once '../unique/unique_con.php';      // Database connection (expects $dbconn)
require_once 'auth.php';                       // Authentication functions
require_once '../unique/unique_code.php';      // Utilities
require_once '../unique/unique_gtm.php';       // GTM functions
require_once '../unique/unique_func.php';      // image_upload() and sanitizeInput()
require_once 'activities.php';                 // Activity logging

// Response helper: sends a JSON response and terminates the script.
function sendResponse($error, $message, $data = [], $status = 200) {
    header("HTTP/1.1 $status $message");
    echo json_encode([
        "error"   => $error,
        "message" => $message,
        "data"    => $data
    ]);
    exit();
}

// Unified API request function using cURL.
// It supports GET (default) and other HTTP methods (POST, etc.).
function makeApiRequest($url, $method, $data = [], $headers = []) {
    $curl = curl_init();

    curl_setopt_array($curl, [
        CURLOPT_URL            => $url,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_HTTPHEADER     => $headers,
    ]);

    // If the method is not GET, encode data as JSON and attach it.
    if ($method !== 'GET') {
        curl_setopt($curl, CURLOPT_POSTFIELDS, json_encode($data));
    }

    $response   = curl_exec($curl);
    $httpCode   = curl_getinfo($curl, CURLINFO_HTTP_CODE);
    $curlError  = curl_error($curl);
    curl_close($curl);

    if ($curlError) {
        return ["error" => true, "message" => "cURL Error: $curlError", "status" => $httpCode];
    }

    $decoded = json_decode($response, true);
    return $decoded ?: ["error" => true, "message" => "Invalid JSON response"];
}

try {
    // Retrieve and validate authorization header
    $headers    = apache_request_headers();
    $authHeader = $headers['Authorization'] ?? '';
    if (!checkAuthorization($authHeader)) {
        throw new Exception("Unauthorized", 401);
    }

    // Validate action parameter from POST data.
    $action = sanitizeInput($_POST['action'] ?? '');
    if ($action !== 'create_kyc') {
        throw new Exception("Invalid action", 400);
    }

    // Validate and sanitize user ID.
    $user_ID = sanitizeInput($_POST['uid'] ?? '');
    if (!$user_ID) {
        throw new Exception("User ID required", 400);
    }
    $user_ID = mysqli_real_escape_string($dbconn, $user_ID);

    // Fetch user data from the database.
    $user_query  = "SELECT * FROM unique_user_table WHERE u_uid = '$user_ID'";
    $user_result = mysqli_query($dbconn, $user_query);
    if (!$user_result) {
        throw new Exception("Database error: " . mysqli_error($dbconn), 500);
    }
    $user_data = mysqli_fetch_assoc($user_result);
    if (!$user_data) {
        throw new Exception("User not found", 404);
    }

    // Validate required fields.
    $required = ['phone', 'address', 'state', 'country', 'postal_code', 'bvn'];
    foreach ($required as $field) {
        if (empty($_POST[$field])) {
            throw new Exception("Missing $field", 400);
        }
    }

    // Validate BVN: it must be an 11-digit number.
    $bvn = sanitizeInput($_POST['bvn']);
    if (!preg_match('/^\d{11}$/', $bvn)) {
        throw new Exception("Invalid BVN", 400);
    }
    $bvn = (string)$bvn; // Ensure BVN is a string
    
    $account = $user_data['account'];
    
    // Decode the JSON string into a PHP associative array
    $accountData = json_decode($account, true);
    
    // Check if decoding was successful and 'order_ref' exists
    if ($accountData !== null && isset($accountData['data']['order_ref'])) {
        $orderRef = $accountData['data']['order_ref'];
    } else {
        $orderRef = null;
    }
    
    /*here is where the account number bvn should be implemented
    
    then after a successful account bvn update it should now proceed with the rest 
    that  is only if the account bvn update as a success 
    
    
    
    
    
    *


    /* 
     * Initiate BVN verification (consent) using Flutterwave’s updated endpoint.
     * The consent process is asynchronous. The payload includes:
     * - bvn: the BVN provided by the customer.
     * - firstname & lastname: taken from the user record.
     * - redirect_url: your callback URL where the customer will be redirected after giving consent.
     *
    $consentPayload = [
        'bvn'          => $bvn,
        'firstname'    => $user_data['fname'],
        'lastname'     => $user_data['lname'],
        'redirect_url' => 'http://phantomphones.store/bvnconsent' // Replace with your actual callback URL.
    ];

    // Make a POST request to initiate the BVN consent process.
    $flutterwaveResp = makeApiRequest(
        "https://api.flutterwave.com/v3/bvn/verifications",
        'POST',
        $consentPayload,
        [
            "Authorization: Bearer " . $API_KEY, // Ensure your secret key is securely stored.
            "Content-Type: application/json"
        ]
    );

    // Check if the BVN consent initiation was successful.
    if (empty($flutterwaveResp) || !isset($flutterwaveResp['data'])) {
        throw new Exception("BVN verification initiation failed: " . json_encode($flutterwaveResp), 400);
    }

    // Retrieve the reference and redirect URL from the response.
    $bvReference   = $flutterwaveResp['data']['reference'] ?? null;
    $bvRedirectUrl = $flutterwaveResp['data']['redirect_url'] ?? null;

    if (!$bvReference || !$bvRedirectUrl) {
        throw new Exception("Incomplete BVN verification response", 400);
    }

    // Log the BVN consent initiation activity.
    logActivity($user_ID, "BVN consent initiated with reference: " . $bvReference);

    // Validate phone number format.
    $phone = sanitizeInput($_POST['phone']);
    if (!preg_match('/^\+?[0-9]{7,15}$/', $phone)) {
        throw new Exception("Invalid phone number", 400);
    }

    // Process selfie image upload.
    if (!isset($_FILES['selfie_image']['tmp_name'])) {
        throw new Exception("Selfie image required", 400);
    }
    $uploadResult = image_upload(
        [$_FILES['selfie_image']['name']],
        [$_FILES['selfie_image']['tmp_name']],
        'img/kyc/',
        90
    );
    if (is_numeric($uploadResult)) {
        $errors = [1 => "Image too small", 2 => "Invalid format"];
        throw new Exception($errors[$uploadResult] ?? "Upload error", 400);
    }
    $selfieUrl = "https://phantomphones.store/pick_me/img/kyc/" . $uploadResult;

    /*
     * Build the Ufitpay payload for creating the KYC record.
     * Note: This uses the BVN provided by the customer.
     * In a full implementation, you may want to update the KYC record once
     * the asynchronous BVN verification process completes.
     *
    $payload = [
        'first_name'   => $user_data['fname'],
        'last_name'    => $user_data['lname'],
        'email'        => $user_data['email'],
        'phone'        => $phone,
        'address'      => sanitizeInput($_POST['address']),
        'state'        => sanitizeInput($_POST['state']),
        'country'      => sanitizeInput($_POST['country']),
        'postal_code'  => sanitizeInput($_POST['postal_code']),
        'kyc_method'   => 'SELFIE_IMAGE',
        'bvn'          => $bvn,
        'selfie_image' => $selfieUrl
    ];

    // Create KYC record with Ufitpay.
    $ufitResp = makeApiRequest(
        'https://api.ufitpay.com/v1/create_card_holder',
        'POST',
        $payload,
        [
            "Api-Key: pub-e6fa9cfc6ac9cd99c6f58ad4e3437767",
            "Api-Token: sec-022954bf873f3788ece72c8d5828b164",
            "Content-Type: application/json"
        ]
    );

    if ($ufitResp['error'] || empty($ufitResp['data'])) {
        throw new Exception("KYC creation failed", 500);
    }

    // Success response: Return Ufitpay KYC data along with BVN consent details.
    sendResponse(
        false,
        "KYC created successfully. Please complete BVN verification by following the provided URL.",
        [
            'card_holder'       => $ufitResp['data'],
            'bvn_consent'       => [
                'consent_reference' => $bvReference,
                'redirect_url'      => $bvRedirectUrl
            ]
        ],
        201
    );

} catch (Exception $e) {
    $status = $e->getCode() ?: 500;
    sendResponse(true, $e->getMessage(), [], $status);
}
*/
?>
