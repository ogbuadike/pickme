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
    // TEMPORARY testing fallback (the original project key). Remove before release.
    let fallbackMapsKey = "AIzaSyDDg8yoVH4mPYiEErNCpVzRDKxu-iP4UN8"
    let plistKey = (Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String) ?? ""
    // Google API keys always start with "AIza"; placeholders fall back to the test key.
    let mapsKey = plistKey.hasPrefix("AIza") ? plistKey : fallbackMapsKey
    if !plistKey.hasPrefix("AIza") {
      NSLog("[PickMe] GMSApiKey not set; using testing fallback key")
    }
    GMSServices.provideAPIKey(mapsKey)

    // Register Flutter plugins (Firebase, etc.).
    GeneratedPluginRegistrant.register(with: self)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
