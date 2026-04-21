import 'dart:io' show Platform;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Import your notification utilities and the main file for the key
import '../utility/notification.dart';
import '../main.dart';

class PushNotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    if (!kIsWeb && Platform.isIOS) {
      await _requestIOSPermissions();
      final apns = await _messaging.getAPNSToken();
      if (kDebugMode) debugPrint('APNs token: $apns');
    }

    FirebaseMessaging.onMessage.listen(_handleForegroundMessages);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);

    _initialized = true;
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
      final title = message.notification!.title ?? 'New Notification';
      final body = message.notification!.body ?? '';

      // Attempt to get an image URL if one was sent in the FCM payload
      final imageUrl = Platform.isAndroid
          ? message.notification!.android?.imageUrl
          : message.notification!.apple?.imageUrl;

      // Ensure we have a valid context before trying to show a dialog
      final context = navigatorKey.currentContext;
      if (context != null) {
        showInAppNotification(
          context,
          title: title,
          message: body,
          imageUrl: imageUrl,
        );
      } else {
        debugPrint('Warning: Could not find Context to show In-App Message.');
      }
    }
  }

  void _handleMessageOpenedApp(RemoteMessage message) {
    debugPrint('onMessageOpenedApp: ${message.messageId}');
    // Handle navigation based on message.data here
    // Example: navigatorKey.currentState?.pushNamed('/someRoute');
  }
}