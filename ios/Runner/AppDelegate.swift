import UIKit
import Flutter
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // Google Maps key comes from Info.plist (GMSApiKey), which is filled from
    // GOOGLE_MAPS_IOS_API_KEY in ios/Flutter/Secrets.xcconfig at build time.
    if let key = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String,
       !key.isEmpty, !key.hasPrefix("$(") {
      GMSServices.provideAPIKey(key)
    } else {
      NSLog("[PickMe] GMSApiKey missing: set GOOGLE_MAPS_IOS_API_KEY in ios/Flutter/Secrets.xcconfig")
    }

    // Register Flutter plugins (Firebase, etc.).
    GeneratedPluginRegistrant.register(with: self)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
