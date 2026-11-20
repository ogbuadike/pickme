<?php

use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\Exception;

require 'mail/PHPMailer-master/src/Exception.php';
require 'mail/PHPMailer-master/src/PHPMailer.php';
require 'mail/PHPMailer-master/src/SMTP.php';

$mail_PHPMailer = new PHPMailer(true);
    

$currency = "&#x20A6;";

if(isset($_GET['logout']) && $_GET['logout']=='0'){
    //Activities('A User ['.$_SESSION['login'].'] logged_out ');
    session_destroy();
    unset($_SESSION['login']);
    setcookie('keep-alive', '', time() - (86400 * 30), "/"); // 86400 = 1 day
    header('location: ../');
    die();
}

if(isset($_COOKIE['keep-alive'])) {
    $_SESSION['login']=$_COOKIE['keep-alive'];
    $my_user_uid = $_SESSION['login'];
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$my_user_uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    
    $is_Logged_in = true;
    
    $active_uname = $current_user_fet['fname'];
    
    $complet_info = $current_user_fet['b_name'];
    
    $home_btn = "Dashboard";
}else{
    $is_Logged_in = false;
    
    $active_uname = "Account";
    $home_btn = "Explore";
}

if(!isset($_SESSION['login'])){
    header('location: ../v2_auth_login.php');
    die();
}

$my_user_uid = $_SESSION['login'];
$get_live_user = unknown_user($my_user_uid);

function get_server_ips(){
    exec('ifconfig -a|grep inet|grep -v 127.0.0.1|grep -v inet6|awk \'{print $2}\'|tr -d "addr:"',$arr);

        if(empty($arr)){
           return $_SERVER['REMOTE_ADDR'];
        }else{
            return $arr[0];
        }
}

function unknown_user($user=''){
    global $coded_datetime,$visit;
    if($user==''){
        if(!isset($_COOKIE['unknown_user'])){
         $visitor_id = $coded_datetime.'_'.$visit;
         setcookie('unknown_user', $visitor_id, time() + (86400 * 365), "/"); // 86400 = 1 day   
         return $visitor_id;
        }else{
            return $_COOKIE['unknown_user'];
        }
    }else{
        return $user;
    }
}


$current_ip_add = get_server_ips();

function name($uid){
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $uname = $current_user_fet['fname'];

    return $uname;
}

function is_password_reset($uid){  
    global $dbconn;
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
    $uname = $current_user_fet['reset'];
    
    if($uname==1){
        return true;
    }else{
        return false;
    }

    
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


function generateSKU($product_name) {
    global $numecode1,$numecode2;
    // Convert product name to lowercase and remove special characters
    $product_name = strtolower($product_name);
    $product_name = preg_replace('/[^a-z0-9\s]/', '', $product_name);
    
    // Generate a random alphanumeric string using product name as salt
    $random_string = substr(str_shuffle($product_name . uniqid()), 0, 11);
    
    // Ensure the length of the SKU is between 5 and 11 characters
    $sku_length = strlen($random_string);
    if ($sku_length < 5) {
        $random_string .= substr(str_shuffle($product_name . uniqid()), 0, 5 - $sku_length);
    } elseif ($sku_length > 11) {
        $random_string = substr($random_string, 0, 11);
    }
    
    $random_string = str_replace(" ", "-", $random_string);
    return $random_string.'-'.$numecode1.$numecode2;
}

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

function image_upload($fileName, $fileTemp, $location, $qlty) {
    global $numecode4, $numecode2, $numecode1, $CODE1, $CODE4, $code1, $code5, $code9;
    $imageEncoder = $numecode4.$numecode2.$numecode1.$CODE1.$CODE4.$code1.$code5.$code9;

    $qlty = 90;
    
    $allowed_types = array('jpg', 'png', 'jpeg', 'gif', 'webp');
    $countfiles = count($fileName);
    $HD_image_list = array();

    for ($i=0; $i<$countfiles; $i++) {
        $img_code = $imageEncoder.$i;
        $temp = explode(".", $fileName[$i]);
        $p2p_img = $img_code . '.' . end($temp);
        $filename = $p2p_img;
        $tmp_name = $fileTemp[$i];
        $file_ext = pathinfo($filename, PATHINFO_EXTENSION);

        if (in_array(strtolower($file_ext), $allowed_types)) {
            $size = getimagesize($tmp_name);
            if ($size[0] < 300 || $size[1] < 300) {
                return 1; // Image is less than 300x300
            } else {
                if (($size[0] >= 800 || $size[1] >= 800) && ($size[0] >= 1200 || $size[1] >= 1200)) {
                    //$width = 1200;
                    //$height = 1200;
                    $width = $size[0];
                    $height = $size[1];
                } else {
                    $width = $size[0];
                    $height = $size[1];
                }

                $src_image = imagecreatefromstring(file_get_contents($tmp_name));
                $dst_image = imagecreatetruecolor($width, $height);
                imagecopyresampled($dst_image, $src_image, 0, 0, 0, 0, $width, $height, $size[0], $size[1]);

                // Convert the resized image to WebP format and store in the specified location
                ob_start();
                imagepng($dst_image);
                $image_data = ob_get_clean();
                $webp_image = convertImageToWebP($image_data, $location, $img_code . '.webp', $qlty);

                // Add the WebP image to the list
                $HD_image_list[] = $webp_image;
            }
        } else {
            return 2; // File format not supported
        }
    }

    return implode(",", $HD_image_list);
}

function convertImageToWebP($image_data, $location, $webp_filename, $quality = 80) {
    // Check if the Imagick extension is loaded
    if (!extension_loaded('imagick')) {
        throw new Exception('Imagick extension is not installed or not enabled.');
    }

    // Create a new Imagick object
    $imagick = new Imagick();

    // Read the image data
    if (!$imagick->readImageBlob($image_data)) {
        throw new Exception('Unable to read image data.');
    }

    // Convert the image to WebP format
    $imagick->setImageFormat('webp');

    // Set the quality of the WebP image
    $imagick->setImageCompressionQuality($quality);

    // Get the WebP image as a string
    $webpData = $imagick->getImagesBlob();

    // Clear the Imagick object
    $imagick->clear();

    // Free up resources
    $imagick->destroy();

    // Save the WebP image to the specified location
    $webp_location = $location . $webp_filename;
    file_put_contents($webp_location, $webpData);

    return $webp_filename;
}

        
function last_trn($uid){
    global $dbconn;
    
    $query_trn = "SELECT amount,type FROM unique_account_table WHERE user_uid='$uid' AND sta='1' ORDER BY id DESC ";
    $query_trn_q = mysqli_query($dbconn,$query_trn);
    $query_trn_f = mysqli_fetch_assoc($query_trn_q);
    $query_trn_n = mysqli_num_rows($query_trn_q);
        if($query_trn_n==0){
            $last_tran = "+ ".number_format(bal($uid),2);
        }else{
            if($query_trn_f['type']=='Deposit'){
                $last_tran = "- ".number_format($query_trn_f['amount'],2);
            }elseif($query_trn_f['type']=='Fund'){
                $last_tran = "+ ".number_format($query_trn_f['amount'],2);
            }
        }
    
    return $last_tran;
}


if(isset($_POST['set_psw']) && $_POST['set_psw']!=''){
    $get_fetch_user = "SELECT * FROM unique_user_table WHERE u_uid='$my_user_uid' ";
    $get_fetch_user_q = mysqli_query($dbconn,$get_fetch_user);
    $current_user_fet = mysqli_fetch_assoc($get_fetch_user_q);
            
    $old_psw = mysqli_real_escape_string($dbconn,$_POST['old_pass']);
    $new_psw = mysqli_real_escape_string($dbconn,$_POST['new_pass']);
    $new_psw2 = mysqli_real_escape_string($dbconn,$_POST['new_pass2']);
    
    $old_password = hash('sha256',$old_psw);
    $db_oldpass = $current_user_fet['pass_code'];
    
    if($old_password != $db_oldpass){
        $hold_psw = "The entered password does not match the previous one.";
    }else{
        if($new_psw === $new_psw2){
            $new_password = hash('sha256',$new_psw);
            $update_pass = "UPDATE unique_user_table SET pass_code='$new_password', reset='0' WHERE u_uid='$my_user_uid' ";
            if(mysqli_query($dbconn,$update_pass)){
                
		        $email = $current_user_fet['email'];
		        $name = $current_user_fet['fname'].' '.$current_user_fet['lname'].' '.$current_user_fet['oname'];
                
                //Email
                $mail = new PHPMailer(true);
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
                $mail->setFrom('support@mpsev.com', 'Michael Prime Services');
        
    			$mail->addAddress($email, $name);     // Add a recipient
    			
    			// Content
                $mail->isHTML(true);                                  // Set email format to HTML
                $mail->Subject = 'Security alert';
                $mail->Body    = $headers_mail.'
                
                <h2>Hi '.$name.',</h2>
                <p>This is to inform you that your password has been successfully changed. If you recently changed your password, you can disregard this message.</p>
                <p>If you did not authorize this change, please take immediate action to secure your account:</p>
                <ol style="text-align:left;font-size:18px;">
                    <li><strong>Login:</strong> Visit <a href="https://mpsev.com/crm/v2_auth_login">login page</a> and log in using your credentials.</li>
                    <li><strong>Reset Password:</strong> Once logged in, proceed to <a href="https://mpsev.com/settings#rest_passwrod">change your password</a> to a secure and unique one. Avoid using easily guessable passwords.</li>
                    <li><strong>Review Account Activity:</strong> Check your recent account activity to ensure no unauthorized access has occurred. If you notice any suspicious activity, please report it to our support team immediately.</li>
                </ol>
                
                <p>Remember, keeping your account secure is our top priority. If you have any concerns or need further assistance, feel free to contact our support team at <a href="mailto:support@mpsev.com">support@mpsev.com</a>.</p>
                <p>Thank you for your prompt attention to this matter.</p>
                
                '.$sub_footer.$footers_mail;
                $mail->AltBody = 'Security alert your password has been changed';
    
                $mail->send();
                    //echo 'Message has been sent';
                } catch (Exception $e) {
                  //  echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
                }
                Activities('Password Changed ['.$get_live_user.'] ');
                
                
                $hold_psw = 'updated';
            }else{
                $hold_psw = "Error updating password";
            }
        }else{
            $hold_psw = "The two passwords do not match.";
        }
    }
}


$current_user = "SELECT * FROM unique_user_table WHERE u_uid='$my_user_uid' ";
$current_user_q = mysqli_query($dbconn,$current_user);
$current_user_fet = mysqli_fetch_assoc($current_user_q);

$user_activity = "SELECT * FROM unique_activities WHERE uid='$my_user_uid' ORDER by id DESC ";
$user_activity_q = mysqli_query($dbconn,$user_activity);
$user_activity_n = mysqli_num_rows($user_activity_q);


function email_credit_account($to,$user_name,$pay_method,$amount,$bal,$from='support@mpsev.com') {
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

        $mail->setFrom($from, 'Payment | Michael Prime');
        $mail->addAddress($to, $user_name);

        $mail->isHTML(true);
        $mail->Subject = 'Account Credit ['.number_format($amount,2).'] Confirmation - Michael Prime Services';
        
        $mail->Body = $headers_mail.'
        <div class="body">
            <h1>Dear '.$user_name.',</h1>
            <p>We are writing to confirm that your account on Michael Prime Services has been credited with <b>NGN '.number_format($amount,2).'</b> via '.$pay_method.'. This credit will allow you to fully utilize our platform and find success as a business owner or job seeker.</p>
                            
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
                                <td>Credit</td> 
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
            <p>If you have any questions or need assistance, our customer support team is here to help. Just visit our Help Center or send us an email at support@mpsev.com.</p>
            <p>Best regards,</p>
            <p>The Michael Prime Services Team</p>
        </div>
        '.$sub_footer.$footers_mail;
        
        $mail->AltBody = '';

        $mail->send();
        echo 'Message has been sent';
    } catch (Exception $e) {
        echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
    }
}

function email_debit_account($to,$user_name,$pay_method,$amount,$reason,$bal,$from='support@mpsev.com'){
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
            $mail->Subject = 'Account Debit ['.number_format($amount,2).'] Confirmation - Michael Prime Services';
            $mail->Body    = $headers_mail.'
                <div class="body">
                    <h1>Dear '.$user_name.',</h1>
                    <p>We are writing to confirm that your account on Michael Prime Services has been debited with <b>NGN '.number_format($amount,2).'</b> via '.$pay_method.'. This debit was made for '.$reason.'.</p>
                    <p>We understand that every penny counts, and we want to ensure that you have complete transparency and control over your account balance. If you have any questions or concerns about this debit, please don'."'".'t hesitate to contact us at support@mpsev.com.</p>
                    <p>We are committed to providing the best possible experience for our users, and we thank you for being a part of the Michael Prime Services community.</p>
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
                    <p>The Michael Prime Services Team</p>
                </div>
                '.$sub_footer.$footers_mail;
            $mail->AltBody = '';

            $mail->send();
                //echo 'Message has been sent';
            } catch (Exception $e) {
                //echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
            }
}

function email_product_pending($to,$user_name,$pay_method,$product,$from='support@mpsev.com'){
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
            $mail->Subject = 'Product Upload Confirmation - Michael Prime Services';
            $mail->Body    = $headers_mail.'
                <div class="body">
                    <h1>Dear '.$user_name.',</h1>
                    <p>We are writing to confirm that your product <b>[ '.$product.' ]</b> has been successfully uploaded to your account on Michael Prime Services. Our team is currently reviewing the product to ensure that it meets our quality standards and terms of service.</p>
                    <p>Please note that while your product is under review, it will not be visible to other users on the platform. Once it has been approved, it will be made available for marketing and showcasing, allowing other users to get to know more about your product.</p>
                    <p>If you have any questions or concerns, please don'."'".'t hesitate to contact us at support@mpsev.com. Our customer support team is here to help and we are always working to improve your experience on Michael Prime Services.</p>
                    <p>Best regards,</p>
                    <p>The Michael Prime Services Team</p>
                </div>
                '.$sub_footer.$footers_mail;
            $mail->AltBody = '';

            $mail->send();
                //echo 'Message has been sent';
            } catch (Exception $e) {
                //echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
            }
}

function email_payment_approved($to,$user_name,$pay_method,$pay_type,$amount,$from='support@mpsev.com'){
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
            $mail->Subject = 'Payment Approval Confirmation - Michael Prime Services';
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
                    <p>The Michael Prime Services Team</p>
                </div>
                '.$sub_footer.$footers_mail;
            $mail->AltBody = '';

            $mail->send();
                //echo 'Message has been sent';
            } catch (Exception $e) {
                //echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
            }
}


function email_token($to,$user_name,$code,$from='support@mpsev.com'){
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
                            <img src="https://phantomphones.store/safegloxuser/panel/assets/img/logo.png" alt="Gloxwallet Logo" style="width: 180px; height: auto;">
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



$ad_users="SELECT * FROM unique_user_table";
$ad_users_q = mysqli_query($dbconn,$ad_users);
$ad_users_n = mysqli_num_rows($ad_users_q);

function total_users(){
    global $dbconn;
    
    $ad_users="SELECT * FROM unique_user_table";
    $ad_users_q = mysqli_query($dbconn,$ad_users);
    $ad_users_n = mysqli_num_rows($ad_users_q);
    
    return number_format($ad_users_n);

}

function active_users() {
    global $dbconn;
    
    $ad_users="SELECT * FROM unique_user_table";
    $ad_users_q = mysqli_query($dbconn,$ad_users);
    $ad_users_n = mysqli_num_rows($ad_users_q);

    
    // Generate dynamic data for each month
    $data = [
        [
            'month' => 'January',
            'count' => 120,
        ],
        [
            'month' => 'February',
            'count' => 95,
        ],
        [
            'month' => 'March',
            'count' => 110,
        ],
        [
            'month' => 'April',
            'count' => 130,
        ],
        [
            'month' => 'May',
            'count' => 145,
        ],
        [
            'month' => 'June',
            'count' => 160,
        ],
        [
            'month' => 'July',
            'count' => 175,
        ],
        [
            'month' => 'August',
            'count' => 200,
        ],
        [
            'month' => 'September',
            'count' => 180,
        ],
        [
            'month' => 'October',
            'count' => 170,
        ],
        [
            'month' => 'November',
            'count' => 150,
        ],
        [
            'month' => 'December',
            'count' => 140,
        ],
    ];
    
    // Shuffle the array
    shuffle($data);
    
    $chart_data = json_encode($data);
   

    // Return active users
     return [
        'active_users_count' => $ad_users_n,
        'chart_data' => $chart_data
    ];
} 



function getTotalUsersBalance() {
    global $dbconn;
    
    $query = "SELECT SUM(bal) AS total_bal FROM unique_user_table";
    $result = mysqli_query($dbconn, $query);
    $row = mysqli_fetch_assoc($result);

    $totalUsersBalance = $row['total_bal'];

    return $totalUsersBalance;
}






?>