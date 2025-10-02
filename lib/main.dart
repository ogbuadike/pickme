import 'package:flutter/material.dart';
import 'themes/app_theme.dart';
import 'routes/routes.dart';
// Import the reusable notification function

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Ensure proper initialization
  //await Firebase.initializeApp();
  // Perform any async initialization tasks here if needed

  runApp(const MyApp()); // Start the app
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pick Me',
      theme: Theme.of(context),


      initialRoute: AppRoutes.loading, // Use initialRoute to navigate immediately
      routes: AppRoutes.getRoutes(),
    );
  }
}
