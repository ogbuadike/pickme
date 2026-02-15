import UIKit
import Flutter
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // Google Maps
    GMSServices.provideAPIKey("AIzaSyDDg8yoVH4mPYiEErNCpVzRDKxu-iP4UN8")

    // ✅ CRITICAL: register Flutter plugins (Firebase, etc.)
    GeneratedPluginRegistrant.register(with: self)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
