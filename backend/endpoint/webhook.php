<?php
// Prevent caching
header("Cache-Control: no-store, no-cache, must-revalidate, max-age=0");
header("Cache-Control: post-check=0, pre-check=0", false);
header("Pragma: no-cache");

header('Content-Type: application/json'); 

// Include necessary files
require_once '../unique/unique_con.php'; 
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';


// Initialize variables
$app_name = $get_site_fet['pageInfo'];
//$API_KEY = 'YOUR_FLUTTERWAVE_API_KEY'; // Replace with your actual API key
//$secretHash = ''; // Replace with your actual secret hash

// Function to log data
function logData($filename, $data) {
    $formattedData = is_array($data) ? json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) : $data;
    if (file_put_contents($filename, date('[Y-m-d H:i:s] ') . $formattedData . "\n", FILE_APPEND | LOCK_EX) === false) {
        error_log("Failed to write to " . $filename);
    }
}

// Get webhook content
$webhookContent = file_get_contents('php://input');
//logData('1_webhook_raw_input.log', $webhookContent); // Log raw input

// Verify Flutterwave signature
$signature = isset($_SERVER['HTTP_VERIF_HASH']) ? $_SERVER['HTTP_VERIF_HASH'] : '';

if (!$signature || ($signature !== $secretHash)) {
    //logData('2_webhook_error.log', "Invalid signature: " . $signature);
    http_response_code(401);
    echo json_encode(["error" => true, "message" => "Unauthorized access", "data" => null]);
    exit();
}

$data = json_decode($webhookContent, true);

if ($data !== null) {
    // Log the incoming data
    //logData('webhook_incoming.log', $data);

    // Extract data from the webhook payload
    $id = $data['data']['id'] ?? null;
    $tx_ref = $data['data']['tx_ref'] ?? null;
    $flw_ref = $data['data']['flw_ref'] ?? null;
    $amount = $data['data']['amount'] ?? 0;
    $currency = $data['data']['currency'] ?? null;
    $app_fee = $data['data']['app_fee'] ?? 0;
    $processor_response = $data['data']['processor_response'] ?? null;
    $narration = $data['data']['narration'] ?? null;
    $status = $data['data']['status'] ?? null;
    $payment_type = $data['data']['payment_type'] ?? null;
    $created_at = $data['data']['created_at'] ?? null;

    $user_id = $tx_ref;
    $user_fullname = name($user_id);
    $user_email = email($user_id);
    $app_id = user_app_id($user_id);
    $tnx_amount = $amount;
    $minus_or_plus = "+";
    $user_bal = bal($user_id);

    // Verify the transaction
    $curl = curl_init();
    curl_setopt_array($curl, array(
        CURLOPT_URL => "https://api.flutterwave.com/v3/transactions/".$id."/verify",
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_ENCODING => "",
        CURLOPT_MAXREDIRS => 10,
        CURLOPT_TIMEOUT => 30,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_1_1,
        CURLOPT_CUSTOMREQUEST => "GET",
        CURLOPT_HTTPHEADER => array(
            "Authorization: Bearer ".$API_KEY,
            "Content-Type: application/json"
        ),
    ));
    $response = curl_exec($curl);
    $err = curl_error($curl);
    curl_close($curl);

    if ($err) {
        //logData('2_webhook_error.log', "cURL Error: " . $err);
        http_response_code(500);
        echo json_encode(["error" => true, "message" => "Failed to verify transaction", "data" => null]);
        exit;
    }

    $verificationData = json_decode($response, true);
    logData('webhook_verification.log', $verificationData);

    if ($verificationData['status'] === 'success' && $verificationData['data']['status'] === 'successful') {
        $accountname = $verificationData['data']['meta']['originatorname'] ?? '';
        $bankname = $verificationData['data']['meta']['bankname'] ?? '';
 
        // Process the transaction
        try {
            // Start transaction
            mysqli_begin_transaction($dbconn);

            // Update user balance
            creditUser($tnx_amount, $user_id);
            
            $newBalance = bal($user_id);
            
            $currency_symbol = "₦"; 

            Activities("Funded $currency_symbol".number_format($tnx_amount,2)." new balance $currency_symbol".number_format($newBalance,2) ,$user_id);

            // Log the main transaction
            transaction($flw_ref, $tnx_amount, $status, $user_id, $bankname.'\n'.$accountname, ($status == 'success' ? 'plus' : 'plus'), $payment_type, $response, '');
            //transaction($flw_ref, $tnx_amount, $status, $user_id, $payment_type, $id, $minus_or_plus, $accountname, $bankname);
            
            // Process app fee
            $newBalanceAfterFee = debitUser($app_fee, $user_id);
            transaction($flw_ref, $app_fee, $status, $user_id, $payment_type, $id, '-', 'Transfer charge', $app_name);
            
            Activities("Debited user $currency_symbol".number_format($app_fee,2)." for (Transfer charge)",$user_id);

            // Credit alert for the app
            //credit_alert_app($tnx_amount, $app_id);
            credit_alert_app($tnx_amount, $app_id); 

            // Commit transaction
            mysqli_commit($dbconn);

            // Send email notification
            email_credit_account($user_email, $user_fullname, $payment_type, $tnx_amount, $newBalance, 'gloxwallet@phantomphones.store');

            //logData('5_webhook_success.log', "Transaction processed successfully for user: " . $user_id);
            http_response_code(200);
            echo json_encode(["status" => "success", "message" => "Transaction processed successfully", "data" => null]);
        } catch (Exception $e) {
            mysqli_rollback($dbconn);
            //logData('2_webhook_error.log', "Transaction processing failed: " . $e->getMessage());
            http_response_code(500);
            echo json_encode(["error" => true, "message" => "Transaction processing failed", "data" => null]);
        }
    } else {
        //logData('2_webhook_error.log', "Transaction verification failed");
        http_response_code(400);
        echo json_encode(["error" => true, "message" => "Transaction verification failed", "data" => null]);
    }
} else {
    //logData('2_webhook_error.log', "Invalid JSON: " . $webhookContent);
    http_response_code(400);
    echo json_encode(["error" => true, "message" => "Invalid JSON payload", "data" => null]);
}



?>