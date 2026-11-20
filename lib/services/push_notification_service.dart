// lib/services/push_notification_service.dart
//
// Incoming push handling:
//  * foreground display (iOS: system banner via presentation options;
//    Android: in-app banner, because FCM does not show notifications while
//    the app is in the foreground);
//  * tap routing through the global navigatorKey, including cold starts
//    (the initial message is held until the signed-in shell is on screen);
//  * notification permission is requested at a sensible moment
//    ([requestPermissionIfAppropriate], called from the home shell after
//    sign-in) – never on the first frame.
import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../routes/routes.dart';
import '../utility/notification.dart';
import '../utility/session_manager.dart';

class PushNotificationService {
  PushNotificationService._();

  static final PushNotificationService instance = PushNotificationService._();

  /// `PushNotificationService()` keeps returning the singleton.
  factory PushNotificationService() => instance;

  /// Navigator used for routing; set by main.dart.
  GlobalKey<NavigatorState>? navigatorKey;

  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  bool _initialized = false;
  bool _permissionAsked = false;
  Map<String, dynamic>? _pendingTap;
  final List<StreamSubscription<RemoteMessage>> _subs = [];

  Future<void> initialize({GlobalKey<NavigatorState>? navigatorKey}) async {
    if (navigatorKey != null) this.navigatorKey = navigatorKey;
    if (_initialized) return;
    _initialized = true;

    // iOS: let the OS present banners while the app is open.
    await _messaging.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);

    _subs.add(FirebaseMessaging.onMessage.listen(_onForegroundMessage));
    _subs.add(FirebaseMessaging.onMessageOpenedApp.listen((m) => _onTap(m.data)));

    final initial = await _messaging.getInitialMessage();
    if (initial != null) _pendingTap = Map<String, dynamic>.from(initial.data);
  }

  /// Asks for notification permission (Android 13+ POST_NOTIFICATIONS and
  /// iOS) once per run, only if the user has not decided yet and has not
  /// switched push off in Settings. Call after sign-in, once the home UI is
  /// visible, so the prompt has context.
  Future<void> requestPermissionIfAppropriate() async {
    if (_permissionAsked) return;
    _permissionAsked = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('set_push_notif') == false) return;
      final current = await _messaging.getNotificationSettings();
      if (current.authorizationStatus != AuthorizationStatus.notDetermined) return;
      final settings = await _messaging.requestPermission(alert: true, badge: true, sound: true);
      if (kDebugMode) debugPrint('[Push] permission: ${settings.authorizationStatus}');
    } catch (e) {
      if (kDebugMode) debugPrint('[Push] permission request failed: ${e.runtimeType}');
    }
  }

  /// Runs a tap that arrived before the signed-in UI existed (cold start).
  void consumePendingNavigation() {
    final pending = _pendingTap;
    if (pending == null) return;
    _pendingTap = null;
    unawaited(_route(pending));
  }

  void _onForegroundMessage(RemoteMessage message) {
    final data = message.data;
    final title = message.notification?.title ?? data['title']?.toString() ?? 'Pick Me';
    final body = message.notification?.body ?? data['body']?.toString() ?? '';
    final isInApp = data['is_inapp']?.toString() == 'true';

    // iOS already shows a system banner for notification messages.
    final systemShown = defaultTargetPlatform == TargetPlatform.iOS && message.notification != null;
    if (systemShown && !isInApp) return;
    if (title.isEmpty && body.isEmpty) return;

    final context = navigatorKey?.currentContext;
    if (context == null) return;

    if (isInApp) {
      final imageUrl = defaultTargetPlatform == TargetPlatform.android
          ? message.notification?.android?.imageUrl
          : message.notification?.apple?.imageUrl;
      showInAppNotification(
        context,
        title: title,
        message: body,
        imageUrl: imageUrl,
        onTap: () => unawaited(_route(data)),
      );
    } else {
      showBannerNotification(context: context, title: title, message: body, isSuccess: true);
    }
  }

  void _onTap(Map<String, dynamic> data) {
    if (navigatorKey?.currentState == null) {
      _pendingTap = Map<String, dynamic>.from(data);
      return;
    }
    unawaited(_route(data));
  }

  Future<void> _route(Map<String, dynamic> data) async {
    // Never deep-link into user screens without a session.
    if (!await SessionManager.instance.hasValidSession()) return;
    final nav = navigatorKey?.currentState;
    if (nav == null) return;

    final clickAction = data['click_action']?.toString();
    final key2 = data['key2']?.toString();

    if (clickAction == 'transaction_page' || key2 == 'transaction') {
      nav.pushNamed(AppRoutes.transactions);
    } else if (clickAction == 'ride_options') {
      nav.pushNamed(AppRoutes.rideOptions, arguments: Map<String, dynamic>.from(data));
    } else if (clickAction == 'notifications_page') {
      nav.pushNamed(AppRoutes.notifications);
    }
  }
}
