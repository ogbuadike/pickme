// lib/services/push_notification_service.dart
import 'dart:io' show Platform;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Import your notification utilities and routes
import '../utility/notification.dart';
import '../routes/routes.dart'; // To access AppRoutes
import '../main.dart'; // To access navigatorKey

class PushNotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    // 1. Request Permissions for BOTH iOS and Android 13+
    await _requestPermissions();

    // 2. Get the APNs token if it's iOS
    if (!kIsWeb && Platform.isIOS) {
      final apns = await _messaging.getAPNSToken();
      if (kDebugMode) debugPrint('APNs token: $apns');
    }

    // 3. App is in Foreground
    FirebaseMessaging.onMessage.listen(_handleForegroundMessages);

    // 4. App is in Background (but running)
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);

    // 5. App is Terminated (Cold Start from notification)
    final RemoteMessage? initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      _handleMessageOpenedApp(initialMessage);
    }

    _initialized = true;
  }

  // Request system permissions for notifications
  Future<void> _requestPermissions() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    if (kDebugMode) {
      debugPrint('User granted permission: ${settings.authorizationStatus}');
    }
  }

  // ==========================================
  // FOREGROUND LOGIC
  // ==========================================
  void _handleForegroundMessages(RemoteMessage message) {
    debugPrint('Foreground message → data: ${message.data}');

    // 1. Check custom flag from PHP
    final bool isInApp = message.data['is_inapp'] == 'true';

    // 2. Extract content (Fallback to 'data' if 'notification' is missing)
    final String title = message.notification?.title ?? message.data['title'] ?? 'New Notification';
    final String body = message.notification?.body ?? message.data['body'] ?? '';

    final imageUrl = Platform.isAndroid
        ? message.notification?.android?.imageUrl
        : message.notification?.apple?.imageUrl;

    if (isInApp) {
      final context = navigatorKey.currentContext;
      if (context != null) {
        // Show custom UI. Pass the routing function to the onTap callback.
        showInAppNotification(
          context,
          title: title,
          message: body,
          imageUrl: imageUrl,
          onTap: () {
            _navigateBasedOnPayload(message.data);
          },
        );
      } else {
        debugPrint('Warning: Could not find Context for In-App Message.');
      }
    } else {
      // Standard push ($is_inapp = false). OS natively suppresses banners in foreground.
      debugPrint('Standard push received in foreground. System suppressed banner.');
    }
  }

  // ==========================================
  // BACKGROUND / TERMINATED LOGIC
  // ==========================================
  void _handleMessageOpenedApp(RemoteMessage message) {
    debugPrint('User tapped system notification. Message ID: ${message.messageId}');
    _navigateBasedOnPayload(message.data);
  }

  // ==========================================
  // ROUTER
  // ==========================================
  void _navigateBasedOnPayload(Map<String, dynamic> data) {
    debugPrint('Evaluating routing payload: $data');

    final clickAction = data['click_action'];
    final key2 = data['key2'];

    if (clickAction == 'transaction_page' || key2 == 'transaction') {
      navigatorKey.currentState?.pushNamed(AppRoutes.transactions);

    } else if (clickAction == 'ride_options') {
      // Passing the data payload directly into the route arguments
      navigatorKey.currentState?.pushNamed(
        AppRoutes.rideOptions,
        arguments: data,
      );

    } else if (clickAction == 'notifications_page') {
      navigatorKey.currentState?.pushNamed(AppRoutes.notifications);
    }
  }
}