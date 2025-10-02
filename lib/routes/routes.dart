import 'package:flutter/material.dart';
import '../screens/home_page.dart';
import '../screens/loading_screen.dart';
import '../screens/authentication/onboarding_screen.dart';
import '../screens/authentication/login_screen.dart';
import '../screens/authentication/authentication_screen.dart';
import '../screens/authentication/registration_screen.dart';
import '../screens/authentication/forgotpassword_screen.dart';
import '../screens/authentication/set_pin.dart';
//import '../screens/pay_bills.dart';
import '../screens/TransactionList.dart';
import '../screens/profile.dart';



class AppRoutes {
  static const String loading = '/';
  static const String onboarding = '/onboarding';
  static const String login = '/login';
  static const String registration = '/registration';
  static const String forgot_password = '/fpw';
  static const String authentication = '/authentication';
  static const String set_user_pin = '/pin';
  static const String home = '/home';
  //static const String pay_bill = '/pay_bill';
  static const String history = '/history';
  static const String profile = '/profile';

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
      history: (context) => const TransactionHistoryPage(),

      /* pay_bill: (context) {
        final args = ModalRoute.of(context)!.settings.arguments as Map<String, String>?;
        return PayBillsScreen(
          quickPayName: args?['name'],
          quickPayCode: args?['code'],
        );
      },*/
      profile: (context) => const ProfileScreen(),
    };
  }
}
