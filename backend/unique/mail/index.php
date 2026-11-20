<?php

use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\Exception;

require 'PHPMailer-master/src/Exception.php';
require 'PHPMailer-master/src/PHPMailer.php';
require 'PHPMailer-master/src/SMTP.php';

$mail = new PHPMailer(true);

try {
    // Server settings
    $mail->SMTPDebug = 0;                      // Enable verbose debug output
    $mail->isSMTP();                                            // Send using SMTP
    $mail->Host       = 'www.mpsev.com';                    // Set the SMTP server to send through
    $mail->SMTPAuth   = true;                                   // Enable SMTP authentication
    $mail->Username   = 'help@mpsev.com';                     // SMTP username
    $mail->Password   = 'pLl@8?Kk#pd.';                               // SMTP password
    $mail->SMTPSecure = 'tls';         // Enable TLS encryption; `PHPMailer::ENCRYPTION_SMTPS` also accepted
    $mail->Port       = 587;                                    // TCP port to connect to

    // Recipients
    $mail->setFrom('support@mpsev.com', 'Michael Prime');
    $mail->addAddress('ogbuadikechibuikem@gmail.com', 'Chibuikem Ogbuadike');     // Add a recipient

    // Attachments
    //$mail->addAttachment('/var/tmp/file.tar.gz');         // Add attachments

    // Content
    $mail->isHTML(true);                                  // Set email format to HTML
    $mail->Subject = 'Welcome to Michael Prime Services';
    $mail->Body    = '
<!DOCTYPE html>
<html>
  <head>
    <title>Michael Prime Services</title>
    <style>
      /* Add your CSS styles here */
      @media only screen and (max-width: 600px) {
        table[class="container"] {
          width: 100% !important;
        }
      }
      
      /* Add your CSS styles here */
      body {
        font-family: Arial, sans-serif;
        color: #333333;
        background-color: #ac9595;
      }

      h1 {
        font-size: 24px;
        color: #333333;
        margin-bottom: 20px;
      }

      p {
        font-size: 16px;
        line-height: 1.5;
        margin-bottom: 20px;
      }

      .cta {
        background-color: #0084FF;
        color: #FFFFFF;
        padding: 10px 20px;
        text-decoration: none;
        border-radius: 5px;
      }
      /* Add your CSS styles here */
      table {
        font-size: 16px;
        line-height: 1.5;
        margin-bottom: 20px;
      }
      .head>img{
        border-radius:10px;
      }
      .content{
        border: 1px solid gray;
        border-radius:10px;
        background-color: #e6dfdf;
      }
      .body{
        padding: 10px;
      }
    </style>
  </head>
  <body>
    <table class="container" width="600" align="center">
      <tr>
        <td>
          <div class="content">
            <div class="head">
                <img src="https://mpsev.com/img/email_banner.png" alt="Company banner" style="display:block; margin: 0 auto;width: 100%; height: 200px;">
            </div>
            
            <div class="body">
                <h1>Hello, Chibuikem!</h1>
                <p>Thank you for signing up for our newsletter. We'."'".'re excited to share our latest updates and offers with you.</p>
                <p>In this email, you'."'".'ll find:</p>
                <ul>
                  <li>New product releases</li>
                  <li>Special promotions</li>
                  <li>Exclusive discounts</li>
                </ul>
                <p>Don'."'".'t miss out on these deals. Shop now and save!</p>
                <a href="https://mpsev.com" class="cta">Shop Now</a>
                <p>Thanks for choosing us,</p>
                <p>The Michael Prime Services Team</p>

                <hr>
                <div style="font-size:16px;line-height:26px;padding-bottom:24px;text-align: center;">
                  <p style="color:#808080;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol;font-size:12px;letter-spacing:0;line-height:16px;margin:0;padding-bottom:0;text-decoration:unset">
                    <span>Michael Prime Services 2021 all rights reserved.</span>
                    <br>Km 42 Atani Road Onitsha, Anambra State <br>
                    <a href="">
                      <span style="color:#808080;text-decoration:underline">Unsubscribe</span>
                    </a><br>
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

            </div>
            
            </div>
        </td>
      </tr>
    </table>
  </body>
</html>
    
    ';
    $mail->AltBody = 'This is the body in plain text for non-HTML mail clients';

    $mail->send();
    echo 'Message has been sent';
} catch (Exception $e) {
    echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
}

?>