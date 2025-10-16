// lib/main.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart'; // flutterfire configure output

import 'themes/app_theme.dart';
import 'routes/routes.dart';
// import your root widget(s)

@pragma('vm:entry-point') // required so Android can find it in background isolate
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Firebase must be initialized in the background isolate
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // TODO: handle the background message (logging / analytics / schedule local notif)
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Always initialize with DefaultFirebaseOptions
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Register the background handler ONCE here (not in any service/widget)
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // Optional but helpful to avoid racing getToken():
  await FirebaseMessaging.instance.setAutoInitEnabled(true);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pick Me',
      theme: Theme.of(context),
      initialRoute: AppRoutes.loading,
      routes: AppRoutes.getRoutes(),
    );
  }
}
