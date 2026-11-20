<?php 

use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\Exception;

require 'mail/PHPMailer-master/src/Exception.php';
require 'mail/PHPMailer-master/src/PHPMailer.php';
require 'mail/PHPMailer-master/src/SMTP.php';

$mail = new PHPMailer(true);
    


if(isset($_POST['recover_btn-send'])){
    
    $user_email = mysqli_real_escape_string($dbconn,$_POST['email1']);
    
        $check_user = "SELECT * FROM unique_user_table WHERE email='$user_email' AND sta<>'1' ";
		$check_user_q=mysqli_query($dbconn,$check_user);
		$check_user_f = mysqli_fetch_assoc($check_user_q);
		$check_user_num=mysqli_num_rows($check_user_q);
		
		if($check_user_num != 1){
		    $msg='<b style="color:red;"> You enterd a wrong email address please try again </b>';
		}else{
		    
		    $new_pass  = $code2.$code3.$code4.'M'.$code6.'p'.$code3.'s'.$code5.$code6.$code1;
		    $save_password = hash('sha256',$new_pass);
		    
		    $set_psw = "UPDATE unique_user_table SET pass_code = '$save_password', reset = '1' WHERE email='$user_email' "; 
		    if(mysqli_query($dbconn,$set_psw)){
		        
		        $email_password = $new_pass;
		        $email = $user_email;
		        $name = $check_user_f['lname'];
		        
		        //Email
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
            $mail->setFrom('support@mpsev.com', 'Password Reset | Michael Prime Services');
    
			$mail->addAddress($email, $name);     // Add a recipient
			
			// Content
            $mail->isHTML(true);                                  // Set email format to HTML
            $mail->Subject = 'Password Reset | Michael Prime Services';
            $mail->Body    = $headers_mail.'
            
            <h2>Dear '.$name.',</h2>
            <p>We have received a request to reset your password. Your new temporary password is:</p>
            <p style="font-size: 20px; font-weight: bold; text-align:center;border:1px solid #004d00; background-color: #b3ffb3; padding:10px;color:#000000;">'.$email_password.'</p>
            <p>Please login using the provided password and proceed to change it to your preferred password.</p>
            <a href="https://mpsev.com/crm/v2_auth_login" class="cta-button" style="border:1px solid red; border-radius:10px; padding:10px; margin:10px; text-align:center; width:100%">Login Now</a>
            <p>If you did not request a password reset, please log in and change your password immediately to avoid any potential threats. Your account is secure.</p>
            
            '.$sub_footer.$footers_mail;
            $mail->AltBody = 'New password: '.$email_password.' please login and change you password';

            $mail->send();
                //echo 'Message has been sent';
            } catch (Exception $e) {
              //  echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
            }
            Activities('Password reset by ['.$email.'] ');
		        
		        
		        
		        
		        $msg='<b> Password reset successfull! Please login to your mail to view your password </b>';
		    }
		    
		    
		    
		    
		}
	
}

if(isset($_POST['login_btn-send']) && $_POST['login_btn-send']=='send' ){
	$user_info = mysqli_real_escape_string($dbconn,$_POST['username']);
	$user_pass = $_POST['password'];

	if(loginusers($user_info,$user_pass)==true){
		if($_SESSION['sta101']==0){
				if(isset($_POST['keep-logged-in']) && $_POST['keep-logged-in']=='keep'){
					setcookie('keep-alive', $_SESSION['login'], time() + (86400 * 365), "/"); // 86400 = 1 day
				}
				if($_SESSION['reset']==1){
				    header('location: ../settings#rest_passwrod');
				}else{
				    header('location: /safegloxuser/panel/access.php');
				}
		}elseif($_SESSION['sta101']==1){
			unset($_SESSION['login']);
			$msg='<b style="color:red;"> Your account is suspended please login to your mail to verify your account </b>';
		}
	}elseif(loginusers($user_info,$user_pass)==false) {
			$msg='<b style="color:red;">Invalid username or password</b>';
	}

}

if(isset($_POST['signup']) && $_POST['signup']=='register'){

	$fname = mysqli_real_escape_string($dbconn,$_POST['fname']);
    $lname = mysqli_real_escape_string($dbconn,$_POST['lname']);
    $oname = mysqli_real_escape_string($dbconn,$_POST['oname']);
    $email = mysqli_real_escape_string($dbconn,$_POST['email']);
    $tel   = mysqli_real_escape_string($dbconn,$_POST['tel']);
    $pass  = mysqli_real_escape_string($dbconn,$_POST['password']);
  $get_v2  = mysqli_real_escape_string($dbconn, $_POST['mpsCAPTCHA']);
  $country = mysqli_real_escape_string($dbconn,$_POST['con']);
  	if(isset($_SESSION['rr_link']) && $_SESSION['rr_link']!='' ){
  		$ref_link = $_SESSION['rr_link'];
  		$ref_link_id =$_SESSION['rr_link_id'];
  	}else{
  		$ref_link='';
  		$ref_link_id='';
  	}
  	
  	    $password = hash('sha256',$pass);
		$user_id  = $code2.$code3.$code4.$code5.$code6.$code1.$code9.$code8.$code7;
		$key = hash('sha256',$user_id);
		$balance = 1000;
		$check_user = "SELECT * FROM unique_user_table WHERE email='$email' OR phone='$tel' OR u_uid='$user_id' ";
		$check_user_q=mysqli_query($dbconn,$check_user);
		$check_user_num=mysqli_num_rows($check_user_q);
		if($check_user_num>0){
		    $msg='<b style="color:red;">User Already Exists</b>';
		}else{
		    if($get_v2 == $_SESSION["human_otp"] ){
		        $regis_user="INSERT INTO unique_user_table(u_uid, s_u_uid, link_id, bal, fname, lname, oname, email, phone, pass_code, country, sta, u_type,datetime, date, time) VALUES('$user_id','$ref_link','$ref_link_id', '$balance','$fname','$lname','$oname','$email','$tel','$password','$country','0','0','$DateTime','$QDateDescrip','$QTimeGMT')";
				$regis_user_q=mysqli_query($dbconn,$regis_user);
				
				//Email Trigger
			try {
            // Server settings
            $mail->SMTPDebug = 0;                      // Enable verbose debug output
            $mail->isSMTP();                                            // Send using SMTP
            $mail->Host       = $Host;                    // Set the SMTP server to send through
            $mail->SMTPAuth   = true;                                   // Enable SMTP authentication
            $mail->Username   = $Email;                     // SMTP username
            $mail->Password   = $Passw;                                   // SMTP password
            $mail->SMTPSecure = 'tls';         // Enable TLS encryption; `PHPMailer::ENCRYPTION_SMTPS` also accepted
            $mail->Port       = 587;                                    // TCP port to connect to
        
            // Recipients
            $mail->setFrom('support@mpsev.com', 'Michael Prime');
    
			$mail->addAddress($email, $lname.$fname);     // Add a recipient
			
			// Content
            $mail->isHTML(true);                                  // Set email format to HTML
            $mail->Subject = 'Welcome to Michael Prime Services';
            $mail->Body    = $headers_mail.'
            <!--body-->
            <div class="body">
                <h1>Hello, '.$lname .'!</h1>
                <p>Welcome to Michael Prime Services! Get ready to embark on a journey of success and fulfillment, where you can showcase your products, build your business portfolio, and find your dream job all in one place.</p>
                <p>You'."'".'re now part of a community of driven and talented individuals who are taking control of their careers and businesses. With the tools and resources we provide, you can make your mark and stand out in your industry.</p>
                <p>We hope you have a blast exploring all the amazing opportunities available to you. Whether you'."'".'re a business owner looking to showcase your products or a job seeker in search of your next adventure, we'."'".'ve got you covered.</p>
                
                <p>So, put on your seatbelt and let'."'".'s get ready for take off! Visit mpsev.com today and join the thousands who have already found success. We can'."'".'t wait to see what you'."'".'ll accomplish!"</p>

                <p>Thanks for choosing us,</p>
                <p>The Michael Prime Services Team</p>

                <hr>
                <div style="font-size:16px;line-height:26px;padding-bottom:24px;text-align: center;">
                  <p style="color:#808080;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol;font-size:12px;letter-spacing:0;line-height:16px;margin:0;padding-bottom:0;text-decoration:unset">
                    <span>Michael Prime Services 2021 all rights reserved.</span>
                    <br>NO 229, ZIK AVENUE OLD ROAD, AWKA, ANAMBRA STATE, NIGERIA<br>
                    <a href="">
                      <span style="color:#808080;text-decoration:underline">Unsubscribe</span>
                    </a><br>
                    <a href="">
                      <span style="color:#808080;text-decoration:underline">Terms & Conditions</span>
                    </a> | 
                    <a href="">
                      <span style="color:#808080;text-decoration:underline">Privacy Policy</span>
                    </a> | 
                    <a href="">
                      <span style="color:#808080;text-decoration:underline">Disclaimer</span>
                    </a>
                  </p>
                </div>

            </div>
    	    <!--End-->
            '.$footers_mail;
            $mail->AltBody = 'This is the body in plain text for non-HTML mail clients';

            $mail->send();
                //echo 'Message has been sent';
            } catch (Exception $e) {
              //  echo "Message could not be sent. Mailer Error: {$mail->ErrorInfo}";
            }
			
			/*
            $to = $email;
            $from = $get_site_fet['sender_email'];
            $subject = $get_site_fet['pageInfo'];
            $message = ;

            $headers  = "From: $from\r\n";
            $headers .= "Reply-To: $from\r\n";
            $headers .= "Return-Path: $from\r\n";
            $headers .= "CC: $from\r\n";
            $headers .= "BCC: $from\r\n";
            $headers .= "Content-type: text/html\r\n";
            mail($to, $subject, $message, $headers);
            */
            Activities('New user ['.$email.'] joined ');
  		    header('location: v2_auth_login.php?sk=OG');
		    }else{
		        $msg='<b style="color:red;">mpsCAPTCHA failed</b>';
		    }
		    
		}

    
}




function loginusers($user,$password){
		global $dbconn;
		$password_code = hash('sha256',$password);
		$username=mysqli_real_escape_string($dbconn,$user);
	$user_login="SELECT * FROM unique_user_table WHERE email='$username' AND pass_code='$password_code' OR phone='$username' AND pass_code='$password_code' ";
	$user_login_q=mysqli_query($dbconn, $user_login);
	$user_login_num=mysqli_num_rows($user_login_q);
	$user_login_fet=mysqli_fetch_assoc($user_login_q);
		if($user_login_num==1){
			$_SESSION['sta101']=$user_login_fet['sta'];
			$_SESSION['login']=$user_login_fet['u_uid'];
			$_SESSION['reset']=$user_login_fet['reset'];
			return true;
		}else{
			return false;
		}
}



?>