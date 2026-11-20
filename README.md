# Pick Me

Rides, campus shuttles, parcel delivery ("Send Me") and dispatch for riders and drivers.
Flutter app (`lib/`) + PHP API (`backend/`). The client/server security rules are in
[`docs/SECURITY_CONTRACT.md`](docs/SECURITY_CONTRACT.md).

## Local setup

```bash
flutter pub get
flutter test
flutter run --dart-define-from-file=config/dart_defines.json   # optional, see below
```

### Secrets & keys (never commit them)

| What | Where | Template |
|---|---|---|
| Android Maps SDK key | `android/local.properties` → `MAPS_API_KEY=...` (or env `MAPS_API_KEY` in CI) | – |
| iOS Maps SDK key | `ios/Flutter/Secrets.xcconfig` → `GOOGLE_MAPS_IOS_API_KEY = ...` | `ios/Flutter/Secrets.xcconfig.example` |
| Dart build-time keys (app key, Maps web-services key, HERE key, terms URL) | `config/dart_defines.json` | `config/dart_defines.example.json` |
| Android upload keystore | `android/key.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`) | – |

Without `android/key.properties` a release build is signed with the **debug** key (a warning
is printed) — such a build cannot be uploaded to Google Play.

The keys that were previously committed (Google Maps, HERE, legacy app key) are in git history:
**rotate them** and restrict the new ones (Android: package `com.pickmee.pickmeeride` + signing
SHA-1s; iOS: bundle id; web-services key: API restrictions + server-side proxy if possible).
Once rotated, remove the `defaultValue:` fallbacks in `lib/api/url.dart`.

## Architecture notes

* `lib/api/api_client.dart` — one shared keep-alive HTTP client; per-request timeouts; safe
  retries (idempotent requests, pre-send network failures, 429 + `Retry-After`); contract headers
  (`Authorization`, `X-Session-Token`, `X-Client-Platform`, `X-Client-Version`); typed
  `ApiException` from the error envelope; de-duplicated global 401 → sign-out.
* `lib/utility/session_manager.dart` — session token in `flutter_secure_storage`; logout
  (`logout.php`) and account deletion (`account_delete.php`); local wipe.
* `lib/services/push_notification_service.dart` / `fcm_service.dart` — FCM token registration
  after sign-in + on refresh, foreground display, tap routing, notification permission requested
  from the home shell (not at launch).

## Store compliance checklist

| Item | Status |
|---|---|
| In-app account deletion (Profile → Delete Account, also Settings → Account) | done (needs `account_delete.php`) |
| Privacy Policy + Terms reachable in-app (login, sign-up, Settings, Profile) | done (`terms.php` must exist) |
| Location prominent disclosure before OS prompt | `lib/screens/state/location_permission_modal.dart` |
| Minimal Android permissions, no background location, cleartext off, backups off | done |
| targetSdk ≥ 35, R8 + resource shrinking | done |
| iOS usage strings, background modes, `ITSAppUsesNonExemptEncryption=false` | done |
| iOS privacy manifest `Runner/PrivacyInfo.xcprivacy` (in Runner target) | done |
| Push entitlement `Runner/Runner.entitlements` | done — enable Push Notifications for the App ID + upload APNs key to Firebase |
| Sign in with Apple | not required (no third-party/social login) |
| App Store Connect privacy labels / Play Data safety form | **manual** — must match `PrivacyInfo.xcprivacy` |
| Review demo accounts (rider + approved driver) | **manual** |
