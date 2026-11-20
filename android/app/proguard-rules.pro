# R8 rules for release builds. Flutter, Firebase, Google Maps and the AndroidX
# plugins ship their own consumer rules; these cover the remaining gaps.

# Flutter engine references Play Core (deferred components) which this app
# does not bundle.
-dontwarn com.google.android.play.core.**
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep annotations / generic signatures used by Gson-style reflection in
# Firebase & Maps.
-keepattributes Signature,*Annotation*,EnclosingMethod,InnerClasses

# Firebase Messaging background handler entry point.
-keep class io.flutter.plugins.firebase.messaging.** { *; }

# Google Maps / Play services location.
-keep class com.google.android.gms.maps.** { *; }
-dontwarn com.google.android.gms.**

# flutter_secure_storage (EncryptedSharedPreferences / Tink).
-keep class androidx.security.crypto.** { *; }
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
