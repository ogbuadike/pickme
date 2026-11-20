import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Release signing ──────────────────────────────────────────────────────────
// android/key.properties (git-ignored, NEVER commit) must contain:
//   storeFile=/absolute/path/to/upload-keystore.jks
//   storePassword=...
//   keyAlias=upload
//   keyPassword=...
// If it is missing, release builds fall back to the DEBUG key so that
// `flutter build apk --release` still works locally / in CI smoke tests.
// Such a build CANNOT be uploaded to Google Play.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

// ── Google Maps key ──────────────────────────────────────────────────────────
// Read from android/local.properties (git-ignored) `MAPS_API_KEY=...` or the
// MAPS_API_KEY environment variable (CI). Restrict the key in Google Cloud to
// package com.pickmee.pickmeeride + your signing SHA-1s.
val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    FileInputStream(localPropertiesFile).use { localProperties.load(it) }
}
// TEMPORARY testing fallback: the original project key. Replace it (or set
// MAPS_API_KEY in local.properties / env, which takes precedence) before release.
val defaultMapsApiKey = "AIzaSyDDg8yoVH4mPYiEErNCpVzRDKxu-iP4UN8"
val mapsApiKey: String =
    (localProperties.getProperty("MAPS_API_KEY") ?: System.getenv("MAPS_API_KEY") ?: "")
        .trim()
        .ifEmpty { defaultMapsApiKey }

android {
    namespace = "com.pickmee.pickmeeride"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.pickmee.pickmeeride"
        // Android 7.0+. Required by current Firebase / Maps SDKs.
        minSdk = 24
        // Google Play requires targeting a recent API level (35 since Aug 2025,
        // 36 for updates from Aug 2026). Flutter 3.35 defaults to 36.
        targetSdk = maxOf(35, flutter.targetSdkVersion)
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["mapsApiKey"] = mapsApiKey
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("android/key.properties not found: release build is signed with the DEBUG key and cannot be published.")
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

// Kotlin 2.2+: `kotlinOptions` is removed; configure the JVM target here.
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}
