// lib/main.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';

import 'themes/app_theme.dart';
import 'routes/routes.dart';

// 1. Create a global key for navigation
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

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  // This global notifier is what the SettingsScreen talks to.
  // When this changes, the whole app instantly repaints with the new theme!
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

  // Fetch the saved theme from SharedPreferences the second the app opens
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
    // ValueListenableBuilder listens to MyApp.themeNotifier.
    // When the value changes, it rebuilds the MaterialApp instantly.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: MyApp.themeNotifier,
      builder: (_, ThemeMode currentMode, __) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Pick Me',

          // Connect to the AppTheme we built earlier
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: currentMode, // This dynamically switches based on the setting

          // 2. Attach the key to your MaterialApp
          navigatorKey: navigatorKey,
          initialRoute: AppRoutes.loading,
          routes: AppRoutes.getRoutes(),
        );
      },
    );
  }
}