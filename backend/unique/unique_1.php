<?php


/*
function env_data($͏_) {
    // Build "file_get_contents" by concatenating hex escapes.
    $__ = "\x66" . "\x69\x6c" . "\x65" . "\x5f" . "\x67\x65\x74\x5f\x63\x6f\x6e\x74\x65\x6e\x74\x73";
    
    // Decode the file path suffix (this decodes to "/.required/.env")
    $ϟ = base64_decode('Ly5yZXF1aXJlZC8uZW52');
    
    // Read the contents of the .env file by concatenating DOCUMENT_ROOT and the decoded suffix.
    $͟_ = $__(
        $_SERVER[("\x44\x4f\x43\x55\x4d\x45\x4e\x54\x5f\x52\x4f\x4f\x54")] . $ϟ
    );
    
    // Obfuscate by calling explode() via call_user_func.
    // The delimiter is produced by a callback that returns a computed character.
    $̿_ = call_user_func(
        (function(){ return explode; }),
        (function($̉_){ return $̉_ ? (chr(010+2) . chr(0x4B-3)) : null; })(1),
        preg_replace_callback(
            '/./',
            function($͌_){ return chr(ord($͌_[0]) ^ 0x0F); },
            base64_decode('FhUYBA==')
        )
    );
    
    // Split the file content into lines.
    $̿_ = explode(
        chr(0x50-40),
        str_replace(["\r", "\n", "\t", "\0"], (('') . chr(010*1.2)), $͟_)
    );
    
    $ͯ_ = '';
    // Process each line.
    foreach ($̿_ as $̐_) {
        // Skip lines that are empty or start with '#' (using an obfuscated callback).
        if (
            (function($ͥ_){
                return !$ͥ_ || (strpos(ltrim($ͥ_), call_user_func((function(){ return '#'; }))) === 0);
            })(call_user_func('trim', $̐_))
        )
            continue;
        
        // Split the line on the first '=' using preg_split
        // The '=' delimiter is decoded from Base64.
        $ͫ_ = preg_split(
            '/' . base64_decode('PQ==') . '/',
            $̐_,
            2,
            PREG_SPLIT_NO_EMPTY
        );
        if (($ͦ_ = count($ͫ_)) !== 2 || $ͦ_ >> 1 !== 1)
            continue;
        
        // Destructure the key/value pair (both parts are trimmed).
        list($ͨ_, $ͩ_) = [
            trim($ͫ_[0]),
            trim(implode(('' . chr(0144-133)), array_slice($ͫ_, 1)))
        ];
        
        // If the key matches the input parameter, process the value with extra reversals.
        $ͯ_ = ($ͨ_ == $͏_)
            ? strrev(
                  str_rot13(
                      str_replace(['',''], '', base64_decode(strrev('dlYzVjRwRlY=')))
                  )
              ) . $ͩ_
            : $ͯ_;
    }
    
    // Return the extracted value (or an empty string if not found),
    // after stripping any stray carriage returns.
    return $ͯ_ = @$ͯ_ ?: '';
}
*/








function env_data($evn_name){
    
    $env = file_get_contents($_SERVER['DOCUMENT_ROOT'] . "/.required/.env");

    // Split the content of the .env file by lines
    $lines = explode("\n", $env);
    
    $data = '';
    // Loop through each line
    foreach ($lines as $line) {
        // Skip empty lines or lines that start with a #
        if (empty($line) || strpos($line, '#') === 0) {
            continue;
        }
        
        // Split the line by the '=' sign
        $parts = explode('=', $line, 2);
        
        // If the line does not contain '=', continue to the next line
        if (count($parts) !== 2) {
            continue;
        }
        
        // Trim whitespace from the variable name and value
        $variable = trim($parts[0]);
        $value = trim($parts[1]);
        
        if($variable == $evn_name){
            
            $data = $value;
        }
        // Output the variable name and its corresponding value
        //echo "Variable: $variable, Value: $value <br>";
    }
    
    return $data;
}     


$db_user = env_data('DATAUSER');
$db_name = env_data('DATANAME');
$db_pass = env_data('DATAPASS');

$Host = env_data('HOST');
$Email= env_data('EMAIL');
$Passw= env_data('EMAIL_PASSWORD');


?>