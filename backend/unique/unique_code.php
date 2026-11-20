<?php 

function randomString($length = 10, $chars = '1234567892') {

        // Alpha lowercase
        if ($chars == 'alphalower') {
            $chars = 'abcdefghjklmnpqrstuvwxyz';
        }

        // Alpha lowercase
        if ($chars == 'alphalower2') {
            $chars = 'abcdefghjklmnpqrstuvwxyz';
        }

        // Alpha lowercase
        if ($chars == 'alphalower3') {
            $chars = 'abcdefghjklmnpqrstuvwxyz';
        }

        // Alpha uppercase
        if ($chars == 'alphaupper') {
            $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
        }

        // Alpha uppercase
        if ($chars == 'zulu') {
            $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
        }

        // Numeric
        if ($chars == 'numeric') {
            $chars = '23456789';
        }

        // Numeric
        if ($chars == 'nume') {
            $chars = '23456789';
        }

        // Morenumeric
        if ($chars == 'morenumeric') {
            $chars = '23456789';
        }

        // Alpha Numeric
        if ($chars == 'alphanumeric') {
            $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
        }

        // Hex
        if ($chars == 'hex') {
            $chars = 'ABCDEF23456789';
        }

        if ($chars == 'hex2') {
            $chars = '199024850';
        }

    // Hex
        if ($chars == 'doble') {
            $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        }

        $charLength = strlen($chars)-1;

        for($i = 0 ; $i < $length ; $i++)
            {
                $randomString = $chars[mt_rand(0, $charLength)];
            }
        return $randomString;

    }

    $regit=randomString(5,'doble');
    $catchaques=randomString(6,'hex');
    $catchaques2=randomString(6,'hex2');
    $catcha=randomString(8,'numeric');
    $catcha2=randomString(6,'alphaupper');
    $newcode=randomString(8,'alphanumeric');
    $passalpha=randomString(1,'zulu');
    $passcode=randomString(3,'nume');
    $passkey=randomString(4,'morenumeric');
    $code11=randomString(6,'alphlower');
    $code22=randomString(8,'alphlower2');
    $code33=randomString(5,'alphlower3');
    
/////////////////////////////////////////////////////

    $numecode1 = $catcha;
    $numecode2 = $passcode;
    $numecode3 = $passkey;
    $numecode4 = $catchaques2;
    $numecode5 = $catchaques;
 

    $reg_code1 = $newcode;
    $reg_code2 = $catchaques;
    $reg_code3 = $catcha;
    $reg_code4 = $regit;
    $reg_code5 = $passkey;
    $reg_code6 = $passcode;
    $reg_code7 = $code22;
    $reg_code8 = $code33;


    $CODE1 = $catchaques[0];
    $CODE2 = $catcha[0];
    $CODE3 = $passcode[0];
    $CODE4 = $passkey[0];
    $CODE5 = $catcha2[0];
    $CODE6 = $regit[0];
    $CODE7 = $code11[0];
    $CODE8 = $code22[0];
    $CODE9 = $code33[0];

  

$alphanumeric1 = '123456789abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ';
$alphanumeric2 = 'abcdefghjkmnpqrstuvwxyz123456789ABCDEFGHJKMNPQRSTUVWXYZ';
$alphanumeric3 = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz123456789';
$alphanumeric4 = 'abcdefghjkmnpqrstuvwxyz';
$alphanumeric5 = 'ABCDEFGHJKMNOPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz';
$alphanumeric6 = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNOPQRSTUVWXYZ';
$alphanumeric7 = 'ABCDEFGHJKMNOPQRSTUVWXYZ';
$alphanumeric8 = '123456789';
$alphanumeric9 = '987654321';
$alphanumeric10 = '59569273';
$alphanumeric11 = '55938028';



$chr1 = substr(str_shuffle($alphanumeric1), 0, 1);
$chr2 = substr(str_shuffle($alphanumeric2), 0, 1);
$chr3 = substr(str_shuffle($alphanumeric3), 0, 1);
$chr4 = substr(str_shuffle($alphanumeric4), 0, 1);
$chr5 = substr(str_shuffle($alphanumeric5), 0, 1);
$chr6 = substr(str_shuffle($alphanumeric6), 0, 1);
$chr7 = substr(str_shuffle($alphanumeric7), 0, 1);
$chr8 = substr(str_shuffle($alphanumeric8), 0, 1);
$chr9 = substr(str_shuffle($alphanumeric9), 0, 1);
$chr10 = substr(str_shuffle($alphanumeric10), 0, 1);
$chr11 = substr(str_shuffle($alphanumeric11), 0, 1);


    $numecode1 = $chr9;
    $numecode2 = $chr8;
    $numecode3 = $chr10;
    $numecode4 = $chr10;
    $numecode5 = $chr11;

    $visit=number_format($numecode1.$numecode2.$numecode3.$numecode4.$numecode5,2);


$code1 = substr(str_shuffle($chr9.$chr2.$chr1.$chr3.$chr4.$chr5.$chr6.$chr7.$chr8), 0, 1);
$code2 = substr(str_shuffle($chr6.$CODE7.$chr4.$chr1.$chr9.$chr2.$chr5.$chr8.$chr3), 0, 1);
$code3 = substr(str_shuffle($chr1.$chr8.$chr2.$chr6.$chr3.$chr5.$chr7.$chr4.$chr9), 0, 1);
$code4 = substr(str_shuffle($chr8.$chr1.$chr9.$chr3.$chr2.$chr4.$chr5.$chr7.$chr6), 0, 1);
$code5 = substr(str_shuffle($chr5.$chr1.$chr2.$chr3.$chr8.$chr7.$chr8.$chr9.$chr4), 0, 1);
$code6 = substr(str_shuffle($chr9.$chr8.$chr2.$chr1.$chr6.$chr4.$chr7.$chr3.$chr5), 0, 1);
$code7 = substr(str_shuffle($chr7.$chr6.$chr8.$chr3.$chr9.$chr2.$chr4.$chr5.$chr1), 0, 1);
$code8 = substr(str_shuffle($chr8.$chr1.$chr7.$chr4.$chr9.$chr2.$chr3.$chr6.$chr5), 0, 1);
$code9 = substr(str_shuffle($chr1.$chr6.$chr3.$chr7.$chr4.$chr8.$chr9.$chr5.$chr2), 0, 1);

$Key1 = substr(str_shuffle($CODE9.$chr2.$chr1.$numecode4.$alphanumeric3.$CODE2.$chr6.$reg_code2.$chr8), 0, 1);
$Key2 = substr(str_shuffle($reg_code7.$chr9.$chr2.$CODE4.$reg_code8.$alphanumeric1.$reg_code7.$chr6.$reg_code2.$chr8), 0, 1);
$Key3 = substr(str_shuffle($numecode2.$chr2.$chr1.$reg_code8.$alphanumeric3.$CODE2.$chr6.$reg_code2.$alphanumeric8), 0, 1);
$Key4 = substr(str_shuffle($alphanumeric7.$chr2.$CODE4.$numecode4.$alphanumeric8.$reg_code1.$chr6.$reg_code2.$chr8), 0, 1);
$Key5 = substr(str_shuffle($CODE9.$chr2.$chr1.$numecode4.$alphanumeric3.$numecode3.$chr6.$reg_code2.$CODE4), 0, 1);
$Key6 = substr(str_shuffle($alphanumeric8.$chr2.$chr1.$numecode4.$alphanumeric3.$CODE2.$chr6.$reg_code2.$CODE1), 0, 1);
$Key7 = substr(str_shuffle($CODE5.$chr2.$chr1.$numecode4.$alphanumeric3.$CODE2.$chr6.$reg_code2.$alphanumeric8), 0, 1);
$Key8 = substr(str_shuffle($CODE9.$chr2.$chr1.$numecode4.$alphanumeric3.$CODE9.$numecode3.$reg_code2.$chr8), 0, 1);
$Key9 = substr(str_shuffle($reg_code7.$chr2.$chr1.$alphanumeric8.$reg_code5.$CODE2.$chr6.$numecode2.$chr8), 0, 1);



// Function to generate a random 11-digit number for UPC
function generateUPC() {
    $upc = '';
    for ($i = 0; $i < 11; $i++) {
        $upc .= mt_rand(0, 9); // Append random digit
    }
    return $upc;
}

// Function to calculate the UPC checksum
function calculateChecksum($upc) {
    $sum = 0;
    for ($i = 0; $i < strlen($upc); $i++) {
        $digit = (int)$upc[$i];
        $sum += ($i % 2 === 0) ? $digit * 3 : $digit;
    }
    $checksum = (10 - ($sum % 10)) % 10;
    return $checksum;
}

// Function to generate a complete 12-digit UPC
function generateCompleteUPC() {
    $upc = generateUPC();
    $checksum = calculateChecksum($upc);
    return $upc . $checksum;
}

// Example of generating a UPC for a product
$upc = generateCompleteUPC();

?>