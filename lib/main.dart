// lib/main.dart
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/api_client.dart';
import 'firebase_options.dart';
import 'routes/routes.dart';
import 'services/fcm_service.dart';
import 'services/push_notification_service.dart';
import 'themes/app_theme.dart';
import 'utility/session_manager.dart';

/// Global navigator, used where no BuildContext is available
/// (push-notification routing, forced sign-out on 401).
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Notification messages are displayed by the OS; nothing to do for data-only
  // messages yet. Firebase must be initialised in this background isolate.
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await PushNotificationService.instance.initialize(navigatorKey: navigatorKey);
  } catch (e) {
    // Push is optional; the app must still start (e.g. Play Services missing).
    if (kDebugMode) debugPrint('Firebase init failed: $e');
  }

  _wireSession();
  unawaited(SessionManager.instance.migrateLegacyStorage());

  runApp(const MyApp());
}

bool _forcedSignOutRouting = false;

void _wireSession() {
  final session = SessionManager.instance;
  session.addSignInHook(() => FCMService.instance.syncTokenWithBackend());
  session.addSignOutHook(() => FCMService.instance.unregister());

  // Global, de-duplicated 401 handler (docs/SECURITY_CONTRACT.md §4). The
  // transport already removed the rejected token and coalesces bursts.
  ApiTransport.shared.onUnauthorized = (ApiException error) async {
    if (_forcedSignOutRouting) return;
    _forcedSignOutRouting = true;
    try {
      await session.wipeLocalData();
      navigatorKey.currentState?.pushNamedAndRemoveUntil(
        AppRoutes.login,
        (_) => false,
        arguments: const {'reason': 'session_expired'},
      );
    } finally {
      // Allow a later, separate expiry to be handled again.
      Future<void>.delayed(const Duration(seconds: 3), () => _forcedSignOutRouting = false);
    }
  };
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  // Start with Light mode instantly instead of System to prevent flashes.
  static final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    _loadSavedTheme();
  }

  Future<void> _loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTheme = prefs.getString('set_theme') ?? 'Light';
    MyApp.themeNotifier.value = switch (savedTheme) {
      'Dark' => ThemeMode.dark,
      'System' => ThemeMode.system,
      _ => ThemeMode.light,
    };
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: MyApp.themeNotifier,
      builder: (_, ThemeMode currentMode, __) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Pick Me',
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: currentMode,
          navigatorKey: navigatorKey,
          initialRoute: AppRoutes.loading,
          routes: AppRoutes.getRoutes(),
        );
      },
    );
  }
}
