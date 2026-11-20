<?php


$curl = curl_init();

#TEST
#$API_KEY = env_data('API_KEY_TEST');

#TEST 2
#$API_KEY = env_data('API_KEY_flutter-test');


#LIVE
$API_KEY = env_data('API_KEY_live');

$SECRET_KEY = env_data('SECRET_KEY'); 

$secretHash = env_data('SECRET_Hash_Webhook'); 





$Host = env_data('HOST');
$Email = env_data('EMAIL');
$Passw = env_data('EMAIL_PASSWORD');

$Tremendous_api = env_data('Tremendous_key');





?>