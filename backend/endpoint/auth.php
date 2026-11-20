<?php



function checkAuthorization($token) {
    
    $auth_code = 'byco101###!';
    $hashed_auth_code = hash('sha256', $auth_code);

   
    $validTokens = [$hashed_auth_code]; 

    if (in_array($token, $validTokens)) {
        return true; // Authorization successful
    } else {
        return false; // Authorization failed
    }
    
}



