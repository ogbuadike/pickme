<?php

$domain = "mpsev.com"; // Replace with your domain

$ch = curl_init();
curl_setopt($ch, CURLOPT_URL, "https://api64.ipify.org?format=json");
curl_setopt($ch, CURLOPT_RETURNTRANSFER, 1);
$response = curl_exec($ch);
curl_close($ch);

if ($response) {
    $data = json_decode($response, true);
    if (isset($data['ip'])) {
        echo "The IP address of $domain is: " . $data['ip'];
    } else {
        echo "Unable to retrieve IP address for $domain";
    }
} else {
    echo "Unable to fetch IP address for $domain";
}



?>