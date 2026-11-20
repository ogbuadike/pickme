// lib/api/url.dart
//
// Endpoint names and build-time configuration.
//
// Keys can be injected at build time instead of living in source:
//   flutter build ... --dart-define-from-file=config/dart_defines.json
// (see config/dart_defines.example.json). The legacy literals below are kept
// only as fallbacks so existing developer builds keep working; they MUST be
// rotated and restricted in Google Cloud / HERE consoles (see README).
class ApiConstants {
  ApiConstants._();

  static const String baseUrl = 'https://realpickme.com/endpoint/';

  /// Legacy app key sent as `Authorization` (identifies the app build, NOT the
  /// user – docs/SECURITY_CONTRACT.md §1). Never trusted for identity.
  static const String appKey = String.fromEnvironment(
    'PICKME_APP_KEY',
    defaultValue: '3cc61939065188f6cee59d4aae99e34e9cbcb24ccf76301c4bd88919e3afde7e',
  );

  // Session lifecycle (contract §6)
  static const String logoutEndpoint = 'logout.php';
  static const String accountDeleteEndpoint = 'account_delete.php';

  // Legal pages (must be reachable without signing in – store requirement)
  static const String privacyPolicyUrl = 'https://realpickme.com/endpoint/privacy.php';
  static const String termsOfServiceUrl = String.fromEnvironment(
    'PICKME_TERMS_URL',
    defaultValue: 'https://realpickme.com/endpoint/terms.php',
  );

  static const String sendTokenEndpoint = 'send_token.php';
  static const String restPwdEndpoint = 'reset_pwd.php';
  static const String logInEndpoint = 'user_login.php';
  static const String registerEndpoint = 'user_register.php';
  static const String setPinEndpoint = 'set_pin.php';
  static const String validatePinEndpoint = 'validate_pin.php';

  static const String userInfoEndpoint = 'user_info.php';
  static const String updateProfilePictureEndpoint = 'user_info.php';
  static const String updateUserInfoEndpoint = 'user_info.php';
  static const String updatePasswordEndpoint = 'user_info.php';
  static const String updateTransactionCodeEndpoint = 'user_info.php';

  static const String countryEndpoint = 'get_countries.php';

  static const String updateSettingsEndpoint = 'user_settings.php';

  static const String helpEndpoint = 'help_api.php';


  static const String rideOffersEndpoint = 'ride_offers.php';
  static const String driversNearbyEndpoint = 'drivers_nearby.php';
  static const String driversPollEndpoint = 'drivers_poll.php';

  static const String sendMeDispatchEndpoint = 'user_logistics.php';

  static const String rideBookEndpoint = 'ride_book.php';
  static const String rideStatusEndpoint = 'ride_status.php';
  static const String rideStartEndpoint = 'ride_start_trip.php';
  static const String rideCancelEndpoint = 'ride_cancel_booking.php';
  static const String rideCompleteEndpoint = 'ride_complete_trip.php';
  static const String driversUpdateLocationEndpoint = 'drivers_update_location.php';

  static const String rideHistoryEndpoint = 'ride_history.php';

  static const String upgradeToDriverEndpoint = 'become_driver.php';
  static const String driverHubEndpoint = 'driver_hub.php';

  static const String upgradeKYCEndpoint = 'kyc_upgrade.php';
  static const String billList = 'flutter_bill_list.php';
  static const String transactionsEndpoint = 'transaction_history.php';
  static const String billInfoEndpoint = 'flutter_bill_information.php';
  static const String billDetailsEndpoint = 'flutter_bill_details.php';
  static const String billCreatePaymentEndpoint = 'flutter_create_payment.php';

  /// Google Maps web-services key (Directions/Places/Geocoding over HTTP).
  static const String kGoogleApiKey = String.fromEnvironment(
    'GOOGLE_MAPS_WEB_API_KEY',
    defaultValue: 'AIzaSyDDg8yoVH4mPYiEErNCpVzRDKxu-iP4UN8',
  );
  static const String kDirectionsUrl = "https://maps.googleapis.com/maps/api/directions/json";
  static const String kHereApiKey = String.fromEnvironment(
    'HERE_API_KEY',
    defaultValue: 'V7bxswfVHsva9-1rMXXmkmQ-ukRwxHJ3eLb6A0NC2vE',
  );
}


