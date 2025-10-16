import 'dart:io' show Platform;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

class PushNotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    // iOS notification permission (Android 13+ is handled by the system)
    if (Platform.isIOS) {
      await _requestIOSPermissions();
    }

    // Foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessages);

    // App opened from a notification
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);

    // Get token with recovery
    final token = await _getFcmTokenWithRecovery();
    if (kDebugMode) debugPrint('FCM token: $token');

    // Listen for token refreshes
    FirebaseMessaging.instance.onTokenRefresh.listen((t) {
      if (kDebugMode) debugPrint('FCM token refreshed: $t');
      // TODO: send to backend here (or via your FCMService)
    });

    // APNs token only on iOS
    if (Platform.isIOS) {
      final apns = await _messaging.getAPNSToken();
      if (kDebugMode) debugPrint('APNs token: $apns');
    }

    _initialized = true;
  }

  Future<String?> _getFcmTokenWithRecovery() async {
    try {
      return await _messaging.getToken();
    } catch (e) {
      final msg = e.toString();
      final isFisAuthError = msg.contains('FIS_AUTH_ERROR') ||
          msg.contains('Firebase Installations Service is unavailable');
      if (isFisAuthError) {
        // reset and backoff-retry
        try { await _messaging.deleteToken(); } catch (_) {}
        for (int i = 0; i < 3; i++) {
          await Future<void>.delayed(Duration(milliseconds: 400 * (1 << i)));
          try {
            final t = await _messaging.getToken();
            if (t != null) return t;
          } catch (_) {}
        }
      }
      rethrow;
    }
  }

  Future<void> _requestIOSPermissions() async {
    final settings = await _messaging.requestPermission(
      alert: true, badge: true, sound: true,
    );
    if (kDebugMode) {
      debugPrint('iOS notif status: ${settings.authorizationStatus}');
    }
  }

  void _handleForegroundMessages(RemoteMessage message) {
    debugPrint('Foreground message → data: ${message.data}');
    if (message.notification != null) {
      debugPrint('Foreground notification: '
          '${message.notification!.title} | ${message.notification!.body}');
    }
    // Optional: show in-app banner/local notification
  }

  void _handleMessageOpenedApp(RemoteMessage message) {
    debugPrint('onMessageOpenedApp: ${message.messageId}');
    // TODO: navigate based on message.data
  }
}
