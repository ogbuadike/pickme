// lib/main.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';

import 'themes/app_theme.dart';
import 'routes/routes.dart'; // Your AppRoutes class
import 'services/push_notification_service.dart'; // Import the service we built

// 1. Create a global key for navigation without BuildContext
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint('Handling a background message: ${message.messageId}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  await FirebaseMessaging.instance.setAutoInitEnabled(true);

  // 2. Initialize our custom Push Notification Service
  final pushService = PushNotificationService();
  await pushService.initialize();

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  static final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

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
    final savedTheme = prefs.getString('set_theme') ?? 'System';

    ThemeMode mode;
    if (savedTheme == 'Dark') {
      mode = ThemeMode.dark;
    } else if (savedTheme == 'Light') {
      mode = ThemeMode.light;
    } else {
      mode = ThemeMode.system;
    }

    MyApp.themeNotifier.value = mode;
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

          // 3. Attach the GlobalKey to the app
          navigatorKey: navigatorKey,

          initialRoute: AppRoutes.loading,
          routes: AppRoutes.getRoutes(),
        );
      },
    );
  }
}