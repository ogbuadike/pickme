<?php


function generateToken($userId, $deviceUniqueId, $userPinCode) {
    $secretKey = 'your_secure_secret_key';
    $tokenDuration = 20; // Token expiration time in seconds

    $currentTime = time();
    $interval = floor($currentTime / 3600); // Code changes every 1 hrs

    // Combine user data, device ID, PIN, and time interval
    $dataToHash = $userId . $deviceUniqueId . $userPinCode . $interval;

    // Generate HMAC using SHA-256 and convert to numeric representation
    $token = hexdec(substr(hash_hmac('sha256', $dataToHash, $secretKey), 0, 15)) % 10000000000000000000; // Ensure 12 digits

    return ['token' => str_pad($token, 20, '0', STR_PAD_LEFT), 'expiryTime' => $currentTime + $tokenDuration];
}

// Token Validator
function validateToken($userInput, $originalToken, $userId, $deviceUniqueId, $userPinCode) {
    $currentTime = time();

    // Check if the token is expired
    if ($currentTime > $originalToken['expiryTime']) {
        return false;
    }

    // Calculate the current interval
    $currentInterval = floor($currentTime / 3600);

    // Recreate the original token for comparison
    $dataToHash = $userId . $deviceUniqueId . $userPinCode . $currentInterval;
    $generatedToken = hexdec(substr(hash_hmac('sha256', $dataToHash, 'your_secure_secret_key'), 0, 15)) % 10000000000000000000; // Ensure 12 digits

    // Compare user input with the original token
    return $generatedToken == $userInput;
}

//$MainUserToken = generateToken($userId, $deviceUniqueId, $userPinCode);



/*
// Validate the user input
if (validateToken($MainUserToken['token'], $MainUserToken, $userId, $deviceUniqueId, $userPinCode)) {
    echo "Token is valid!";
} else {
    echo "Token is invalid!";
}
*/
?>
