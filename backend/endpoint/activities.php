<?php


use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\Exception;

require_once '../unique/mail/PHPMailer-master/src/Exception.php';
require_once '../unique/mail/PHPMailer-master/src/PHPMailer.php';
require_once '../unique/mail/PHPMailer-master/src/SMTP.php';
require_once '3third_party_req.php';
require_once 'push_alert.php'; 

//require_once 'flutter_validate_bill.php';
//require_once 'flutter_payment_status.php';





$headers_mail = '
<!DOCTYPE html>
<html>
<head>
    <style>
        body {
            font-family: "Segoe UI", Roboto, Arial, sans-serif;
            margin: 0;
            padding: 0;
            background-color: #f2f2f2;
            color: #333;
        }

        .container {
            width: 100%;
            max-width: 650px;
            margin: 20px auto;
            background-color: #ffffff;
            border-radius: 12px;
            box-shadow: 0px 4px 8px rgba(0, 0, 0, 0.1);
            overflow: hidden;
        }

        .header {
            background-color: #ffc107; /* Bright golden background */
            padding: 30px;
            text-align: center;
            border-bottom: 3px solid #e0a800;
        }

        .header img {
            max-width: 120px;
            height: auto;
            border-radius: 10%;
            box-shadow: 0 0 8px rgba(0, 0, 0, 0.2);
        }

        .content {
            padding: 30px;
        }

        h1 {
            font-size: 28px;
            color: #333;
            margin-bottom: 10px;
        }

        h4 {
            font-size: 20px;
            color: #555;
            margin-bottom: 20px;
        }

        p {
            font-size: 16px;
            line-height: 1.8;
            margin-bottom: 20px;
            color: #444;
        }

        a {
            color: #ffffff;
            text-decoration: none;
            font-weight: bold;
        }

        .cta-button {
            background-color: #007bff;
            color: #ffffff;
            padding: 12px 30px;
            text-align: center;
            display: inline-block;
            border-radius: 8px;
            font-size: 18px;
            text-decoration: none;
            margin: 20px 0;
            box-shadow: 0px 4px 6px rgba(0, 0, 0, 0.1);
            transition: background-color 0.3s ease;
        }

        .cta-button:hover {
            background-color: #0056b3;
        }

        .footer {
            background-color: #f8f9fa;
            padding: 25px;
            text-align: center;
            border-top: 3px solid #e0e0e0;
        }

        .footer p {
            font-size: 14px;
            color: #666;
            line-height: 1.5;
        }

        .footer a {
            color: #007bff;
            text-decoration: none;
        }

        .footer a:hover {
            text-decoration: underline;
        }

        .play-store img {
            width: 160px;
            height: auto;
            margin: 20px 0;
        }

        hr {
            border: none;
            border-top: 1px solid #ddd;
            margin: 40px 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <img src="https://realpickme.com/logo.png" alt="Pick Me Logo">
        </div>
        <div class="content">
';
$sub_footer = '
</div>
<center>
<a href="https://play.google.com/store/apps/details?id=com.pickme.pickmeride&pli=1" class="play-store">
    <img src="https://cdn.freebiesupply.com/logos/large/2x/google-play-badge-logo-png-transparent.png" alt="Download on Google Play">
</a>
</center>
<hr>
<div style="text-align: center;">
    <p style="color:#808080;font-size:12px;">
        Pick Me 2024. All rights reserved.
        <br>NO 229, ZIK AVENUE OLD ROAD, AWKA, ANAMBRA STATE, NIGERIA
        <br>
        <a href="https://phantomphones.store/Terms&conditions.php" style="color:#808080;">Terms & Conditions</a> | 
        <a href="https://phantomphones.store/Privacy-Policy.php" style="color:#808080;">Privacy Policy</a> | 
        <a href="https://phantomphones.store/Disclaimer.php" style="color:#808080;">Disclaimer</a>
    </p>
</div>
';
$footers_mail = '
        </div>
        <div class="footer">
            <p>For more information, visit our <a href="https://gloxwallet.com">website</a>.</p>
            <p>&copy; 2024 Pick Me. All rights reserved.<br>NO 229, ZIK AVENUE OLD ROAD, AWKA, ANAMBRA STATE, NIGERIA<br></p>
            <p>
                <a href="https://gloxwallet.com/terms">Terms & Conditions</a> | 
                <a href="https://gloxwallet.com/privacy">Privacy Policy</a> | 
                <a href="https://gloxwallet.com/disclaimer">Disclaimer</a>
            </p>
        </div>
    </div>
</body>
</html>
';









    // Server status monitoring - reset timeout if using Apache
    if (function_exists('apache_reset_timeout')) {
        apache_reset_timeout();
    }

    // Set appropriate memory limit for the operation
    ini_set('memory_limit', '256M');




$mail_PHPMailer = new PHPMailer(true);
    
function user_app_id($uid){
    global $dbconn;
    $get_fetch_user = "SELECT * FROM app_users WHERE uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $app_id = $current_user_fet['u_token'];

    return $app_id;
}


function name($uid){
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $uname = $current_user_fet['fname'];

    return $uname;
}

function IsVerified($uid){
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' AND visibility = '1' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_num_rows($get_fetch_user_q);
    $output = $current_user_fet;
    
    if($output==1){
        return true;
    }else{
        return false;
    }

}

function full_name($uid){ 
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $uname = $current_user_fet['fname'].' '.$current_user_fet['lname'].' '.$current_user_fet['oname'];

    return $uname;
}

function normalizePhoneNumber($phoneNumber) {
    // Check if the phone number starts with the country code '234'
    if (preg_match('/^234(\d+)$/', $phoneNumber, $matches)) {
        $phoneNumberPart = $matches[1];  // Extract the phone number part

        // Replace the country code '234' with '0'
        return '0' . $phoneNumberPart;
    }

    // If the phone number doesn't match the expected pattern, return the original number
    return $phoneNumber;
}

function phone($uid) {
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn, $get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $uname = $current_user_fet['phone'];

    $normalizedPhoneNumber = normalizePhoneNumber($uname);

    // Add debugging statements
    //echo "Original Phone: $uname<br>";
    //echo "Normalized Phone: $normalizedPhoneNumber<br>";

    // Return the normalized phone number
    return $normalizedPhoneNumber;
}

function user_logo($uid){
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $uname = $current_user_fet['b_logo'];

    return $uname;
}

function bname($uid){
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $uname = $current_user_fet['b_name'];

    return $uname;
}

function img($uid){
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $img = $current_user_fet['img'];

    return $img;
}

function email($uid){
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $email = $current_user_fet['email'];

    return $email;
}

function greetUser($currentTime) {
    $hour = intval(substr($currentTime, 0, 2));
    $greeting = "";

    if ($hour >= 0 && $hour < 12) {
        $greeting = "Good morning";
    } elseif ($hour >= 12 && $hour < 18) {
        $greeting = "Good afternoon";
    } else {
        $greeting = "Good evening";
    }

    return $greeting;
}

function tel($uid){
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $tel = $current_user_fet['phone'];

    return $tel;
}

function encrypt_balance($balance, $key) {
            $iv = openssl_random_pseudo_bytes(openssl_cipher_iv_length('aes-256-cbc'));
            $encrypted_balance = openssl_encrypt($balance, 'aes-256-cbc', $key, 0, $iv);
            //return $iv . $encrypted_balance;
            return $balance;
}
        
function decrypt_balance($encrypted_balance, $key) {
    $iv = substr($encrypted_balance, 0, openssl_cipher_iv_length('aes-256-cbc'));
    $encrypted_balance = substr($encrypted_balance, openssl_cipher_iv_length('aes-256-cbc'));
    $decrypted_balance = openssl_decrypt($encrypted_balance, 'aes-256-cbc', $key, 0, $iv);
    if (!$decrypted_balance) {
        //return 0;
    }else{
        //return $decrypted_balance;
    }
    
    return $encrypted_balance;
    
}



function account_status($uid){
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $sta = $current_user_fet['sta'];
    
    $user_status = '';
    if($sta == 0){
        $user_status = '<span class="badge badge-light-success">Active</span>';
    }elseif($sta == 1){
        $user_status = '<span class="badge badge-light-danger">Suspended</span>';
    }

    return $user_status;
}

function user_profile($uid){
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    
    $b_logo = $current_user_fet['b_logo'];
    $b_name = $current_user_fet['b_name'];
    $b_catego = $current_user_fet['b_catego'];
    $b_abou = $current_user_fet['b_abou'];
    $b_addr = $current_user_fet['b_addr'];
    $b_city = $current_user_fet['b_city'];
    $b_state = $current_user_fet['b_state'];
    
    $pofile_status = '';
    
    if($b_name !='' && $b_catego !='' && $b_addr !='' && $b_city !='' && $b_state !='' ){
        $pofile_status = '<span class="text-success">Complete Profile</span>';
    }else{
        $pofile_status = '<span class="text-danger">Incomplete Profile</span>';
    }
    
    return $pofile_status;
    
}


function creditUser($amount, $my_user_uid) {
    global $dbconn;
    $encrypted_balance = null;
    $user_bal = null;
    
    mysqli_begin_transaction($dbconn);
    try {
        // Step 1: Select the current balance of the user
        $get_fetch_user = "SELECT bal FROM unique_user_table WHERE u_uid='$my_user_uid'";
        $get_fetch_user_q = mysqli_query($dbconn, $get_fetch_user);
        
        // Check if query executed successfully
        if (!$get_fetch_user_q) {
            throw new Exception(mysqli_error($dbconn));
        }
        
        $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
        $encrypted_balance = $current_user_fet['bal'];
        
        // Step 2: Compute the new balance
        $balance = bal($my_user_uid);
        $new_bal = $amount + $balance;
        $user_bal = $new_bal;
        
        // Step 3: Update the user's balance in the database
        $update_user = "UPDATE unique_user_table SET bal='$user_bal' WHERE u_uid='$my_user_uid'";
        $update_user_q = mysqli_query($dbconn, $update_user);
        
        // Check if query executed successfully
        if (!$update_user_q) {
            throw new Exception(mysqli_error($dbconn));
        }
        
        mysqli_commit($dbconn);
    } catch (Exception $e) {
        mysqli_rollback($dbconn);
        throw $e;
    }
}

function debitUser($amount, $my_user_uid){
    global $dbconn;
    
    $balance = bal($my_user_uid);
    
    $new_bal = $balance-$amount;
    
    $user_bal = $new_bal;
    
    mysqli_begin_transaction($dbconn);
    try {
        $update_user = "UPDATE unique_user_table SET bal=? WHERE u_uid=?";
        $stmt = mysqli_prepare($dbconn, $update_user);
        mysqli_stmt_bind_param($stmt, "is", $user_bal, $my_user_uid);
        mysqli_stmt_execute($stmt);
        mysqli_commit($dbconn);
    } catch (Exception $e) {
        mysqli_rollback($dbconn);
        throw $e;
    }
}

function bal($uid){
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $encrypted_balance = $current_user_fet['bal'];
    $key = hash('sha256',$uid);
    
    //$balance = decrypt_balance($encrypted_balance, $key);
    
    $balance = $encrypted_balance;

    return $balance;
}


function transaction($ref_num, $amount, $staus, $uid, $network, $minus_or_plus, $payment_mode, $response_store, $customer_id){
    global $CODE4,$numecode1,$code1,$code5,$numecode4,$numecode2,$QTimeGMT,$QDateDescrip,$DateTime,$dbconn;
    
    $utid = $code1.$numecode2.$numecode1.$code1.$code5.$numecode4.'-Glox';
    
    if($network == ''){
        $network = 'Failed App Transaction ';
        $minus_or_plus = 'minus';
    }
    

    $add_tran="INSERT INTO unique_account_table (descTxt, reference, user_tran_id, user_uid, rec_uid, type, amount, staus, pay_mode, datetime, date, time, data) VALUES 
    ('$network', '$ref_num', '$customer_id','$uid', 'admin', '$minus_or_plus','$amount','$staus','$payment_mode','$DateTime','$QDateDescrip','$QTimeGMT', '$response_store')";
    $add_tran_q=mysqli_query($dbconn,$add_tran);
    
}


/*
function sanitizeInput($data) {
    // --- Step 1: Recursive Sanitization for Arrays ---
    // If the input is an array, iterate through each element and sanitize recursively.
    if (is_array($data)) {
        foreach ($data as $key => $value) {
            // Recursively sanitize each array element.
            $data[$key] = sanitizeInput($value);
        }
        return $data;
    }
    
    // --- Step 2: Non-Scalar Data Handling ---
    // If the input is not a scalar (i.e., not a string, int, float, or bool), return null.
    if (!is_scalar($data)) {
        return null;
    }
    
    // --- Step 3: Convert to String ---
    // Cast the data to a string so further processing is consistent.
    $data = (string) $data;
    
    // --- Step 4: Remove Null Bytes and BOM ---
    // Null bytes and Byte Order Mark (BOM) can be used to bypass filters.
    $data = str_replace(["\0", "\xEF\xBB\xBF"], '', $data);
    
    // --- Step 5: Remove Unwanted Control Characters ---
    // Strip control characters except for tab (\t), newline (\n), and carriage return (\r).
    $data = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u', '', $data);
    
    // --- Step 6: Validate UTF-8 Encoding ---
    // Ensure the string is valid UTF-8 to prevent encoding-based attacks.
    if (!mb_check_encoding($data, 'UTF-8')) {
        // Optionally, you could log or throw an exception here.
        return ''; // Reject the input if it is not valid UTF-8.
    }
    
    // --- Step 7: Trim Whitespace ---
    // Remove any leading or trailing whitespace.
    $data = trim($data);
    
    // --- Step 8: HTML and XSS Sanitization ---
    // Prefer using HTMLPurifier for robust sanitization if it is available.
    if (class_exists('HTMLPurifier')) {
        // Create a default configuration for HTMLPurifier.
        $config = HTMLPurifier_Config::createDefault();
        // Define a strict allowlist of HTML elements and attributes.
        $config->set('HTML.Allowed', 'p,a[href],em,strong,ul,ol,li,br');
        $purifier = new HTMLPurifier($config);
        // Purify the input, removing all disallowed HTML.
        $data = $purifier->purify($data);
    } else {
        // Fallback: Use PHP built-in functions for basic sanitization.
        
        // Convert special characters to HTML entities to mitigate XSS.
        $data = htmlspecialchars($data, ENT_QUOTES | ENT_HTML5 | ENT_SUBSTITUTE, 'UTF-8');
        
        // Remove dangerous HTML attributes such as event handlers (e.g., onclick) and style attributes.
        $data = preg_replace('/\s*(on\w+|style|xmlns)\s*=\s*([\'"]).*?\2/i', '', $data);
        
        // Remove potential JavaScript and data URLs.
        $data = preg_replace('/\s*(javascript:|data:(?:text|application)\/(?:javascript|xml))/i', '', $data);
        
        // Allow only a limited set of HTML tags; any other tags will be stripped.
        $allowedTags = '<p><a><em><strong><ul><ol><li><br>';
        $data = strip_tags($data, $allowedTags);
    }
    
    // --- Step 9: Numeric Conversion ---
    // If the string represents a numeric value, convert it to the appropriate type.
    if (ctype_digit($data)) {
        // If the data is composed only of digits, convert to integer.
        return (int) $data;
    } elseif (is_numeric($data)) {
        // If the data is numeric (e.g., includes decimals), convert to float.
        return (float) $data;
    }
    
    // Return the sanitized string.
    return $data;
}
*/


function encryptData(string $data, string $password, string $associatedData = ''): string {
    // Validate password length
    if (strlen($password) < MIN_PASSWORD_LENGTH) {
        throw new InvalidArgumentException("Password must be at least " . MIN_PASSWORD_LENGTH . " characters");
    }
    
    // Compress data before encryption if it's compressible and over a minimum size
    if (strlen($data) > 100) { // Only compress data larger than 100 bytes
        $compressedData = gzcompress($data, 9); // Maximum compression level
        // Only use compressed data if it actually results in smaller size
        if ($compressedData !== false && strlen($compressedData) < strlen($data)) {
            $data = $compressedData;
            $isCompressed = 1;
        } else {
            $isCompressed = 0;
        }
    } else {
        $isCompressed = 0;
    }
    
    // Generate a secure random salt and nonce
    $salt = random_bytes(SODIUM_CRYPTO_PWHASH_SALTBYTES);
    $nonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
    
    // Derive an encryption key from the password
    $key = sodium_crypto_pwhash(
        SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES,
        $password,
        $salt,
        OPS_LIMIT,
        MEM_LIMIT
    );
    
    // Encrypt the data using XChaCha20-Poly1305
    $ciphertext = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
        $data,
        $associatedData,
        $nonce,
        $key
    );
    
    // Clear the key from memory
    sodium_memzero($key);
    
    // Set flags for metadata
    $adFlag = !empty($associatedData) ? 1 : 0;
    
    // Build binary payload with flags packed into a single byte
    // Bit 0: AD flag (0 = no AD, 1 = AD included)
    // Bit 1: Compression flag (0 = not compressed, 1 = compressed)
    // Bits 2-7: Version info (current version = 2 << 2 = 8)
    $flags = ($adFlag) | ($isCompressed << 1) | (2 << 2);
    
    // Pack all data into a single binary string
    $format = 'Ca' . SODIUM_CRYPTO_PWHASH_SALTBYTES .
              'a' . SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES .
              'a*';
    
    $binaryPayload = pack(
        $format,
        $flags,     // All flags in one byte
        $salt,      // Salt for key derivation
        $nonce,     // Nonce for encryption
        $ciphertext // Encrypted ciphertext
    );
    
    // Use base64url encoding (saves ~2% over standard base64)
    return rtrim(strtr(base64_encode($binaryPayload), '+/', '-_'), '=');
}

function decryptData(string $encodedData, string $password, string $associatedData = ''): string {
    // Restore padding for base64 decoding if needed
    $paddedData = $encodedData;
    $mod4 = strlen($paddedData) % 4;
    if ($mod4) {
        $paddedData .= substr('====', $mod4);
    }
    
    // Convert from base64url to standard base64 then decode
    $binaryPayload = base64_decode(strtr($paddedData, '-_', '+/'), true);
    if ($binaryPayload === false) {
        throw new RuntimeException("Base64 decoding failed");
    }
    
    // Calculate header size: flags (1) + salt + nonce
    $headerSize = 1 + SODIUM_CRYPTO_PWHASH_SALTBYTES + SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES;
    if (strlen($binaryPayload) < $headerSize) {
        throw new RuntimeException("Invalid payload size");
    }
    
    // Unpack the binary payload
    $format = 'Cflags/a' . SODIUM_CRYPTO_PWHASH_SALTBYTES .
              'salt/a' . SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES .
              'nonce/a*ciphertext';
    $unpacked = unpack($format, $binaryPayload);
    if ($unpacked === false) {
        throw new RuntimeException("Failed to unpack payload");
    }
    
    // Extract flags
    $flags = $unpacked['flags'];
    $adFlag = $flags & 1;
    $isCompressed = ($flags >> 1) & 1;
    $version = $flags >> 2;
    
    // Verify version is supported
    if ($version !== 2) {
        throw new RuntimeException("Unsupported encryption version");
    }
    
    // Verify associated data flag matches
    $expectedAdFlag = !empty($associatedData) ? 1 : 0;
    if ($adFlag !== $expectedAdFlag) {
        throw new RuntimeException("Associated data mismatch");
    }
    
    // Extract components
    $salt = $unpacked['salt'];
    $nonce = $unpacked['nonce'];
    $ciphertext = $unpacked['ciphertext'];
    
    // Validate lengths
    if (strlen($salt) !== SODIUM_CRYPTO_PWHASH_SALTBYTES) {
        throw new RuntimeException("Invalid salt length");
    }
    if (strlen($nonce) !== SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES) {
        throw new RuntimeException("Invalid nonce length");
    }
    
    // Derive the decryption key
    $key = sodium_crypto_pwhash(
        SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES,
        $password,
        $salt,
        OPS_LIMIT,
        MEM_LIMIT
    );
    
    // Decrypt
    $plaintext = sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
        $ciphertext,
        $associatedData,
        $nonce,
        $key
    );
    
    // Clear key from memory
    sodium_memzero($key);
    
    if ($plaintext === false) {
        throw new RuntimeException("Decryption failed - integrity check");
    }
    
    // Decompress if data was compressed
    if ($isCompressed) {
        $decompressed = gzuncompress($plaintext);
        if ($decompressed === false) {
            throw new RuntimeException("Decompression failed");
        }
        return $decompressed;
    }
    
    return $plaintext;
}





function Activities($activity,$my_user_uid){

    global $dbconn,$QTimeGMT,$QDateDescrip,$DateTime,$numecode1,$numecode2,$numecode3,$numecode4;

    $aid=$numecode1.$numecode2.$numecode3.$numecode4;

    $recode_activites = "INSERT INTO unique_activities (activity_id,activity,uid,time,date,datetime) VALUES ('$aid','$activity','$my_user_uid','$QTimeGMT','$QDateDescrip','$DateTime') ";
    $recode_activites_q = mysqli_query($dbconn,$recode_activites);

}

function short_word($text='', $maxchar='', $end='...') {
    if (!is_numeric($maxchar) || !is_string($text)) {
        return "Invalid input";
    }
    if (strlen($text) <= $maxchar) {
        return $text;
    }
    $words = preg_split('/\s+|[^\w\s]/u', $text);
    $output = "";
    $i = 0;
    while ($i < count($words)) {
        $word = $words[$i];
        if (strlen($output) + strlen($word) + strlen($end) <= $maxchar) {
            $output .= $word . " ";
        }
        else {
            break;
        }
        $i++;
    }
    return rtrim($output) . $end;
}

function discribeDateTime($datetime){
    $my_date = new DateTime($datetime);
    return $my_date->format('jS F Y');
}

function discribeTime($datetime){
    $time = strtotime($datetime);
    return date("h:i:s A", $time);
}

/**
 * Uploads image(s), converts them to WebP, and returns the stored filename(s).
 * Returns 1 if any image is less than 300x300 or 2 if a file format is not supported.
 *
 * @param array  $fileName Array of image file names.
 * @param array  $fileTemp Array of temporary file paths.
 * @param string $location Directory where images should be stored.
 * @param int    $qlty     Quality parameter (overridden to 90 in this function).
 *
 * @return string|int Comma-separated list of filenames or error code (1 or 2).
 */
function image_upload($fileName, $fileTemp, $location, $qlty) {
    // Global variables for image encoding (assumed defined elsewhere in production)
    global $numecode4, $numecode2, $numecode1, $CODE1, $CODE4, $code1, $code5, $code9;
    $imageEncoder = $numecode4 . $numecode2 . $numecode1 . $CODE1 . $CODE4 . $code1 . $code5 . $code9;

    // Force quality to 90
    $qlty = 90;
    
    // Allowed file types
    $allowed_types = array('jpg', 'png', 'jpeg', 'gif', 'webp');
    $countfiles = count($fileName);
    $HD_image_list = array();

    // Process each uploaded file
    for ($i = 0; $i < $countfiles; $i++) {
        $img_code = $imageEncoder . $i;
        $temp = explode(".", $fileName[$i]);
        $p2p_img = $img_code . '.' . end($temp);
        $filename = $p2p_img;
        $tmp_name = $fileTemp[$i];
        $file_ext = pathinfo($filename, PATHINFO_EXTENSION);

        // Validate file type
        if (in_array(strtolower($file_ext), $allowed_types)) {
            $size = getimagesize($tmp_name);
            if ($size[0] < 300 || $size[1] < 300) {
                return 1; // Image dimensions too small
            } else {
                // Use original dimensions (resizing logic can be extended if needed)
                $width  = $size[0];
                $height = $size[1];

                // Create source and destination images
                $src_image = imagecreatefromstring(file_get_contents($tmp_name));
                $dst_image = imagecreatetruecolor($width, $height);
                imagecopyresampled($dst_image, $src_image, 0, 0, 0, 0, $width, $height, $size[0], $size[1]);

                // Convert the resized image to PNG temporarily and capture the output
                ob_start();
                imagepng($dst_image);
                $image_data = ob_get_clean();

                // Convert the image data to WebP format and store it in the specified location
                $webp_image = convertImageToWebP($image_data, $location, $img_code . '.webp', $qlty);
                $HD_image_list[] = $webp_image;
            }
        } else {
            return 2; // Unsupported file format
        }
    }
    // Return comma-separated list of stored image filenames
    return implode(",", $HD_image_list);
}

/**
 * Converts image data to WebP format using the Imagick extension.
 *
 * @param string $image_data    The raw image data.
 * @param string $location      Directory to save the WebP image.
 * @param string $webp_filename Filename for the WebP image.
 * @param int    $quality       Compression quality (default 80).
 *
 * @return string The WebP filename.
 *
 * @throws Exception if the Imagick extension is not available or if conversion fails.
 */
function convertImageToWebP($image_data, $location, $webp_filename, $quality = 80) {
    // Ensure the Imagick extension is loaded
    if (!extension_loaded('imagick')) {
        throw new Exception('Imagick extension is not installed or not enabled.');
    }

    $imagick = new Imagick();
    if (!$imagick->readImageBlob($image_data)) {
        throw new Exception('Unable to read image data.');
    }
    $imagick->setImageFormat('webp');
    $imagick->setImageCompressionQuality($quality);
    $webpData = $imagick->getImagesBlob();
    $imagick->clear();
    $imagick->destroy();

    // Build the full path for the new image and save it
    $webp_location = rtrim($location, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . $webp_filename;
    file_put_contents($webp_location, $webpData);

    return $webp_filename;
}
        



function email_credit_account($to,$user_name,$pay_method,$amount,$bal,$from='support@realpickme.com') {
    global $Host,$Email,$Passw,$headers_mail,$sub_footer,$footers_mail;

    $mail = new PHPMailer(true);

    try {
        $mail->SMTPDebug = 0;
        $mail->isSMTP();
        $mail->Host = $Host;
        $mail->SMTPAuth = true;
        $mail->Username = $Email;
        $mail->Password = $Passw;
        $mail->SMTPSecure = 'tls';
        $mail->Port = 587;

        $mail->setFrom($from, 'Payment | Pick Me');
        $mail->addAddress($to, $user_name);

        $mail->isHTML(true); 
        $mail->Subject = 'Account Credit ['.number_format($amount,2).'] Confirmation - Pick Me';
        
        $mail->Body = $headers_mail.'
        <div class="body">
            <h1>Dear '.$user_name.',</h1>
            <p>We are pleased to inform you that your Pick Me account has been credited with <b>NGN '.number_format($amount,2).'</b> via '.$pay_method.'. This credit allows you to fully utilize our platform and conveniently make bill payments.</p>
                            
                            <div style="display: flex; justify-content: center; padding: 20px;">
                              <table style="width: 60%; border-collapse: collapse; font-family: Arial, sans-serif; font-size: 14px;">
                                <tr>
                                  <td colspan="2" style="text-align: center; font-weight: bold; padding: 12px 0; background-color: #f5f5f5; color: #333; font-size: 16px; border-bottom: 1px solid #ccc;">
                                    Transaction Details
                                  </td>
                                </tr>
                                <tr>
                                  <td style="padding: 10px; border-bottom: 1px solid #eee; color: #555;">Amount</td>
                                  <td style="padding: 10px; border-bottom: 1px solid #eee; text-align: right; color: #000;">NGN '.number_format($amount, 2).' </td>
                                </tr>
                                <tr>
                                  <td style="padding: 10px; border-bottom: 1px solid #eee; color: #555;">Transaction Type</td>
                                  <td style="padding: 10px; border-bottom: 1px solid #eee; text-align: right; color: #000;">Credit</td>
                                </tr>
                                <tr>
                                  <td style="padding: 10px; border-bottom: 1px solid #eee; color: #555;">Payment Method</td>
                                  <td style="padding: 10px; border-bottom: 1px solid #eee; text-align: right; color: #000;">'.$pay_method.'</td>
                                </tr>
                                <tr>
                                  <td style="padding: 10px; color: #555;">Current Balance</td>
                                  <td style="padding: 10px; text-align: right; color: #000;">NGN '.number_format($bal, 2).'</td>
                                </tr>
                              </table>
                            </div>


            <p>If you have any questions or need assistance, our customer support team is here to help. Just visit our Help Center or send us an email at support@realpickme.com.</p>
            <p>Best regards,</p>
            <p>The Pick Me Team</p>
        </div>
        '.$sub_footer.$footers_mail;
        
        $mail->AltBody = '';

        $mail->send();
        echo 'Message has been sent';
    } catch (Exception $e) {
        echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
    }
}

function email_debit_account($to,$user_name,$pay_method,$amount,$reason,$bal,$from='support@realpickme.com'){
            global $Host,$Email,$Passw,$headers_mail,$sub_footer,$footers_mail;
            
            $mail = new PHPMailer(true);

            //Email Trigger
			try {
            // Server settings
            $mail->SMTPDebug = 0;                      // Enable verbose debug output
            $mail->isSMTP();                                            // Send using SMTP
            $mail->Host       = $Host;                    // Set the SMTP server to send through
            $mail->SMTPAuth   = true;                                   // Enable SMTP authentication
            $mail->Username   = $Email;                     // SMTP username
            $mail->Password   = $Passw;                               // SMTP password
            $mail->SMTPSecure = 'tls';         // Enable TLS encryption; `PHPMailer::ENCRYPTION_SMTPS` also accepted
            $mail->Port       = 587;                                    // TCP port to connect to
        
            // Recipients
            $mail->setFrom($from, 'Payment | Michael Prime');
    
			$mail->addAddress($to, $user_name);     // Add a recipient
			
			// Content
            $mail->isHTML(true);                                  // Set email format to HTML
            $mail->Subject = 'Account Debit ['.number_format($amount,2).'] Confirmation - Pick Me';
            $mail->Body    = $headers_mail.'
                <div class="body">
                    <h1>Dear '.$user_name.',</h1>
                    <p>We are writing to confirm that your account on Pick Me has been debited with <b>NGN '.number_format($amount,2).'</b> via '.$pay_method.'. This debit was made for '.$reason.'.</p>
                    <p>We understand that every penny counts, and we want to ensure that you have complete transparency and control over your account balance. If you have any questions or concerns about this debit, please don'."'".'t hesitate to contact us at support@realpickme.com.</p>
                    <p>We are committed to providing the best possible experience for our users, and we thank you for being a part of the Pick Me community.</p>
                            <table>
                              <tr>
                                <td colspan=2><center><b>Transaction Details</b></center></td>
                              <tr>
                              <tr>
                                <td>Amount</td>
                                <td>NGN '.number_format($amount,2).'</td>
                              </tr>
                              <tr>
                                <td>Transaction Type</td> 
                                <td>Debit</td> 
                              </tr>
                              <tr>
                                <td>Payment Method</td>
                                <td>'.$pay_method.'</td>
                              </tr>
                              <tr>
                                <td>Current Balance</td>
                                <td>NGN '.number_format($bal,2).'</td>
                              </tr>
                            </table>
                    <p>Best regards,</p>
                    <p>The Pick Me Team</p>
                </div>
                '.$sub_footer.$footers_mail;
            $mail->AltBody = '';

            $mail->send();
                //echo 'Message has been sent';
            } catch (Exception $e) {
                //echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
            }
}





/**
function email_product_pending($to,$user_name,$pay_method,$product,$from='support@realpickme.com'){
            global $Host,$Email,$Passw,$headers_mail,$sub_footer,$footers_mail;
            
            $mail = new PHPMailer(true);

            //Email Trigger
			try {
            // Server settings
            $mail->SMTPDebug = 0;                      // Enable verbose debug output
            $mail->isSMTP();                                            // Send using SMTP
            $mail->Host       = $Host;                    // Set the SMTP server to send through
            $mail->SMTPAuth   = true;                                   // Enable SMTP authentication
            $mail->Username   = $Email;                     // SMTP username
            $mail->Password   = $Passw;                               // SMTP password
            $mail->SMTPSecure = 'tls';         // Enable TLS encryption; `PHPMailer::ENCRYPTION_SMTPS` also accepted
            $mail->Port       = 587;                                    // TCP port to connect to
        
            // Recipients
            $mail->setFrom($from, 'Pending | Michael Prime');
    
			$mail->addAddress($to, $user_name);     // Add a recipient
			
			// Content
            $mail->isHTML(true);                                  // Set email format to HTML
            $mail->Subject = 'Product Upload Confirmation - Pick Me';
            $mail->Body    = $headers_mail.'
                <div class="body">
                    <h1>Dear '.$user_name.',</h1>
                    <p>We are writing to confirm that your product <b>[ '.$product.' ]</b> has been successfully uploaded to your account on Pick Me. Our team is currently reviewing the product to ensure that it meets our quality standards and terms of service.</p>
                    <p>Please note that while your product is under review, it will not be visible to other users on the platform. Once it has been approved, it will be made available for marketing and showcasing, allowing other users to get to know more about your product.</p>
                    <p>If you have any questions or concerns, please don'."'".'t hesitate to contact us at support@realpickme.com. Our customer support team is here to help and we are always working to improve your experience on Pick Me.</p>
                    <p>Best regards,</p>
                    <p>The Pick Me Team</p>
                </div>
                '.$sub_footer.$footers_mail;
            $mail->AltBody = '';

            $mail->send();
                //echo 'Message has been sent';
            } catch (Exception $e) {
                //echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
            }
}

function email_payment_approved($to,$user_name,$pay_method,$pay_type,$amount,$from='support@realpickme.com'){
            global $Host,$Email,$Passw,$headers_mail,$sub_footer,$footers_mail,$QDateDescrip;
            
            $mail = new PHPMailer(true);

            //Email Trigger
			try {
            // Server settings
            $mail->SMTPDebug = 0;                      // Enable verbose debug output
            $mail->isSMTP();                                            // Send using SMTP
            $mail->Host       = $Host;                    // Set the SMTP server to send through
            $mail->SMTPAuth   = true;                                   // Enable SMTP authentication
            $mail->Username   = $Email;                     // SMTP username
            $mail->Password   = $Passw;                               // SMTP password
            $mail->SMTPSecure = 'tls';         // Enable TLS encryption; `PHPMailer::ENCRYPTION_SMTPS` also accepted
            $mail->Port       = 587;                                    // TCP port to connect to
        
            // Recipients
            $mail->setFrom($from, 'Payment | Michael Prime');
    
			$mail->addAddress($to, $user_name);     // Add a recipient
			
			// Content
            $mail->isHTML(true);                                  // Set email format to HTML
            $mail->Subject = 'Payment Approval Confirmation - Pick Me';
            $mail->Body    = $headers_mail.'
                <div class="body">
                    <h1>Dear '.$user_name.',</h1>
                    <p>I hope this email finds you well. I am writing to inform you that your payment has been approved.</p>
                    <p>Your payment of NGN'.number_format($amount,2).' was received on '.$QDateDescrip.' and has been verified and confirmed by our team. We would like to thank you for choosing us and for your prompt payment. Your cooperation and timely payment has allowed us to process your order and move forward with our business relationship.</p>
                            <table>
                              <tr>
                                <td colspan=2><center><b>Transaction Details</b></center></td>
                              <tr>
                              <tr>
                                <td>Amount</td>
                                <td>NGN '.number_format($amount,2).'</td>
                              </tr>
                              <tr>
                                <td>Transaction Type</td> 
                                <td>'.$pay_type.'</td> 
                              </tr>
                              <tr>
                                <td>Payment Method</td>
                                <td>'.$pay_method.'</td>
                              </tr>
                            </table>
                    <p>Best regards,</p>
                    <p>The Pick Me Team</p>
                </div>
                '.$sub_footer.$footers_mail;
            $mail->AltBody = '';

            $mail->send();
                //echo 'Message has been sent';
            } catch (Exception $e) {
                //echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
            }
}



function email_token($to,$user_name,$code,$from='support@realpickme.com'){
            global $Host,$Email,$Passw,$headers_mail,$sub_footer,$footers_mail,$QDateDescrip;
            
            $mail = new PHPMailer(true);

            //Email Trigger
			try {
            // Server settings
            $mail->SMTPDebug = 0;                      // Enable verbose debug output
            $mail->isSMTP();                                            // Send using SMTP
            $mail->Host       = $Host;                    // Set the SMTP server to send through
            $mail->SMTPAuth   = true;                                   // Enable SMTP authentication
            $mail->Username   = $Email;                     // SMTP username
            $mail->Password   = $Passw;                               // SMTP password
            $mail->SMTPSecure = 'tls';         // Enable TLS encryption; `PHPMailer::ENCRYPTION_SMTPS` also accepted
            $mail->Port       = 587;                                    // TCP port to connect to
        
            // Recipients
            $mail->setFrom($from, 'Token | Gloxwallet');
    
			$mail->addAddress($to, $user_name);     // Add a recipient
			
			// Content
            $mail->isHTML(true);                                  // Set email format to HTML
            $mail->Subject = $code.' - Gloxwallet';
            $mail->Body = '
                <html>
                <body style="font-family: Arial, sans-serif; color: #333; margin: 0; padding: 0; width: 100%; background-color: #f4f4f4;">
                    <div style="max-width: 600px; margin: 0 auto; background-color: #ffffff; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1);">
                        <div style="text-align: center; margin-bottom: 20px;">
                            <img src="https://realpickme.com/logo.php" alt="Gloxwallet Logo" style="width: 180px; height: auto;">
                        </div>
                        <div style="padding: 20px;">
                            <h1 style="font-size: 26px; color: #2d2d2d; margin-top: 0;">Hello ' . htmlspecialchars($user_name) . ',</h1>
                            <p style="font-size: 16px; color: #555; line-height: 1.6;">We are excited to share your token with you. Below are the details:</p>
                            <div style="background-color: #e9f5ff; border-left: 4px solid #007bff; padding: 15px; margin: 20px 0;">
                                <p style="font-size: 18px; color: #333; margin: 0;"><strong>Token:</strong> ' . htmlspecialchars($code) . '</p>
                            </div>
                            <p style="font-size: 16px; color: #555; line-height: 1.6;">If you have any questions or need further assistance, please do not hesitate to reach out to us.</p>
                            <p style="font-size: 16px; color: #555; line-height: 1.6;">Best regards,</p>
                            <p style="font-size: 16px; color: #555; margin-bottom: 0;">The Gloxwallet Team</p>
                            <div style="text-align: center; margin-top: 30px;">
                                <a href="https://gloxwallet.com" style="display: inline-block; font-size: 16px; color: #ffffff; background-color: #007bff; padding: 12px 20px; text-decoration: none; border-radius: 5px; font-weight: bold;">Visit Our Website</a>
                            </div>
                        </div>
                    </div>
                </body>
                </html>
            ';

            $mail->AltBody = 'Dear ' . htmlspecialchars($user_name) . ', Token: ' . htmlspecialchars($code) . ' Best regards, The Gloxwallet Team';


            $mail->send();
                //echo 'Message has been sent';
            } catch (Exception $e) {
                //echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
            }
}

**/




?>



