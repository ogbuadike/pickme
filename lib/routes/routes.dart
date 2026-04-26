import 'package:flutter/material.dart';

// EXISTING
import '../screens/home_page.dart';
import '../screens/loading_screen.dart';
import '../screens/authentication/onboarding_screen.dart';
import '../screens/authentication/login_screen.dart';
import '../screens/authentication/authentication_screen.dart';
import '../screens/authentication/registration_screen.dart';
import '../screens/authentication/forgotpassword_screen.dart';
import '../screens/authentication/set_pin.dart';
import '../screens/TransactionList.dart';
import '../screens/profile.dart';

// NEW
import '../screens/ride_options_screen.dart';
import '../screens/notifications_screen.dart';
import '../screens/ride_history_screen.dart';
import '../screens/payments_screen.dart';
import '../screens/offers_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/help_screen.dart';
import '../screens/become_a_driver.dart';
import '../screens/campus_ride_page.dart';

class AppRoutes {
  // Existing
  static const String loading = '/';
  static const String onboarding = '/onboarding';
  static const String login = '/login';
  static const String registration = '/registration';
  static const String forgot_password = '/fpw';
  static const String authentication = '/authentication';
  static const String set_user_pin = '/pin';
  static const String home = '/home';
  static const String history = '/history';
  static const String profile = '/profile';
  static const String campus_ride = '/campus';

  static const String become_a_driver = '/become_a_driver';

  // Added to satisfy Home/Booking
  static const String rideOptions = '/ride-options';
  static const String notifications = '/notifications';
  static const String rideHistory = '/ride-history';
  static const String payments = '/payments';
  static const String offers = '/offers';
  static const String transactions = '/transactions';
  static const String settings = '/settings';
  static const String help = '/help';

  static Map<String, WidgetBuilder> getRoutes() {
    return {
      loading: (context) => const SplashScreen(),
      onboarding: (context) => const OnboardingScreen(),
      login: (context) => const LoginScreen(),
      registration: (context) => const RegistrationScreen(),
      forgot_password: (context) => const ForgotPasswordScreen(),
      authentication: (context) => const AuthenticationScreen(),
      set_user_pin: (context) => const SetPinScreen(),
      home: (context) => const HomePage(),
      profile: (context) => const ProfileScreen(),
      campus_ride: (context) => const CampusRidePage(),

      // You already had "history" for transactions; keep it
      history: (context) => const TransactionHistoryPage(),

      // Map the new menu entries
      transactions: (context) => const TransactionHistoryPage(),
      notifications: (context) => const NotificationsScreen(),
      rideHistory: (context) => const RideHistoryScreen(),
      payments: (context) => const PaymentsScreen(),
      offers: (context) => const OffersScreen(),
      settings: (context) => const SettingsScreen(),
      help: (context) => const HelpScreen(),

      become_a_driver: (context) => const BecomeADriverPage(),

      // Ride options expects a Map argument from HomePage
      rideOptions: (context) {
        final args = ModalRoute.of(context)!.settings.arguments
        as Map<String, dynamic>?;
        return RideOptionsScreen(args: args);
      },
    };
  }
}
