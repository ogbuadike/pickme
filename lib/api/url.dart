class ApiConstants {
  static const String baseUrl = 'https://phantomphones.store/safegloxuser/rest/';

  // User-related endpoints
  static const String sendTokenEndpoint = 'send_token.php';
  static const String restPwdEndpoint = 'reset_pwd.php';
  static const String logInEndpoint = 'user_login.php';
  static const String registerEndpoint = 'user_register.php';
  static const String setPinEndpoint = 'set_pin.php';
  static const String validatePinEndpoint = 'validate_pin.php';

  // User info endpoints
  static const String userInfoEndpoint = 'user_info.php'; // Fetch user info
  static const String updateProfilePictureEndpoint = 'user_info.php'; // Update profile picture
  static const String updateUserInfoEndpoint = 'user_info.php'; // Update profile info
  static const String updatePasswordEndpoint = 'user_info.php'; // Update password
  static const String updateTransactionCodeEndpoint = 'user_info.php'; // Update transaction code

  // Other endpoints
  static const String upgradeKYCEndpoint = 'kyc_upgrade.php';
  static const String billList = 'flutter_bill_list.php';
  static const String transactionsEndpoint = 'transaction_history.php';
  static const String billInfoEndpoint = 'flutter_bill_information.php';
  static const String billDetailsEndpoint = 'flutter_bill_details.php';
  static const String billCreatePaymentEndpoint = 'flutter_create_payment.php';

  static const String kGoogleApiKey = "AIzaSyDDg8yoVH4mPYiEErNCpVzRDKxu-iP4UN8"; // Restrict to Android apps + places/directions
  static const String kDirectionsUrl = "https://maps.googleapis.com/maps/api/directions/json";

  static const String kHereApiKey = 'V7bxswfVHsva9-1rMXXmkmQ-ukRwxHJ3eLb6A0NC2vE';




}