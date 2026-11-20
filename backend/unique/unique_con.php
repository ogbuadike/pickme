<?php
if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

header("Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none';");

require_once'unique_1.php';



    

$currency = "&#x20A6;";


$dbconn=mysqli_connect('localhost',$db_user,$db_pass,$db_name);


$get_site="SELECT * FROM site_info";
$get_site_q=mysqli_query($dbconn,$get_site);
$get_site_fet=mysqli_fetch_assoc($get_site_q);


$to="/safegloxuser";
if(!isset($_SESSION['pageTo'])){ 

    $_SESSION['pageTo']=$_SERVER['SCRIPT_URL'];
    if($_SESSION['pageTo']=='/safegloxuser/v2_auth_login.php'){
        $to="/safegloxuser";
    }else{
        $to=$_SESSION['pageTo'];
    } 
}
$_SESSION['loginTo']=$to;




define('OPS_LIMIT', SODIUM_CRYPTO_PWHASH_OPSLIMIT_INTERACTIVE);
define('MEM_LIMIT', SODIUM_CRYPTO_PWHASH_MEMLIMIT_INTERACTIVE);
define('MIN_PASSWORD_LENGTH', 1);
















$headers_mail='
<!DOCTYPE html>
<html>
<head>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 0;
            background-color: #f8f9fa;
            color: #333;
        }

        .container {
            width: 100%;
            max-width: 600px;
            margin: 0 auto;
            background-color: #ffffff;
            border-radius: 8px;
            overflow: hidden;
        }

        .header {
            background-color: #f5a623; /* Golden background */
            padding: 20px;
            text-align: center;
        }

        .header img {
            max-width: 150px;
            height: auto;
            border-radius: 5px;
        }

        .content {
            padding: 20px;
        }

        h1 {
            font-size: 24px;
            color: #333;
            margin-bottom: 10px;
        }

        h4 {
            font-size: 18px;
            color: #555;
            margin-bottom: 20px;
        }

        p {
            font-size: 16px;
            line-height: 1.6;
            margin-bottom: 20px;
        }

        a {
            color: #ffffff;
            text-decoration: none;
            font-weight: bold;
        }

        .cta-button {
            background-color: #007bff;
            color: #ffffff;
            padding: 15px 25px;
            text-align: center;
            display: inline-block;
            border-radius: 5px;
            font-size: 16px;
            text-decoration: none;
            margin: 10px 0;
        }

        .footer {
            background-color: #f5f5f5;
            padding: 20px;
            text-align: center;
            font-size: 14px;
            color: #888;
        }

        .footer a {
            color: #007bff;
            text-decoration: none;
        }

        .footer a:hover {
            text-decoration: underline;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <img src="https://phantomphones.store/safegloxuser/panel/assets/img/logo.png" alt="Company Logo">
        </div>
        <div class="content">
';
$sub_footer = '
</div>
<center>
<a href="https://play.google.com/store/apps/details?id=com.michaelprime.mpsev"><img src="https://mpsev.com/img/61662ab10e98dd3583bc7d2c_google-play-badge.png" alt="google-play" style="display:block; margin: 0 auto;width: 50%; height: auto;"></a>
</center>
<hr>
                <div style="font-size:16px;line-height:26px;padding-bottom:24px;text-align: center;">
                  <p style="color:#808080;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol;font-size:12px;letter-spacing:0;line-height:16px;margin:0;padding-bottom:0;text-decoration:unset">
                    <span>Michael Prime Services 2021 all rights reserved.</span>
                    <br>Km 42 Atani Road Onitsha, Anambra State <br>
                    <a href="https://mpsev.com/Terms&conditions.php">
                      <span style="color:#808080;text-decoration:underline">Terms & Conditions</span>
                    </a> | 
                    <a href="https://mpsev.com/Privacy-Policy.php">
                      <span style="color:#808080;text-decoration:underline">Privacy Policy</span>
                    </a> | 
                    <a href="https://mpsev.com/Disclaimer.php">
                      <span style="color:#808080;text-decoration:underline">Disclaimer</span>
                    </a>
                  </p>
                </div>
';
$footers_mail='</div>
        <div class="footer">
            <p>For more information, visit our <a href="https://gloxwallet.com">website</a>.</p>
            <p>&copy; {{current_year}} Gloxwallet. All rights reserved.
                <br>NO 229, ZIK AVENUE OLD ROAD, AWKA, ANAMBRA STATE, NIGERIA<br>
            </p>
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


?>
