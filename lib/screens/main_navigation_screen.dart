// lib/screens/main_navigation_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/push_notification_service.dart';

import '../widgets/bottom_navigation_bar.dart';
import 'home_page.dart';
import 'campus_ride_page.dart';
import 'send_me_landing_page.dart';
import 'dispatch_landing_page.dart';
import 'profile.dart';
import 'TransactionList.dart';
import 'settings_screen.dart';
import 'ride_history_screen.dart';
import '../driver/driver_home_page.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  bool _isDriver = false;
  bool _isLoading = true;

  /// Tabs are built the first time they are shown (then kept alive by the
  /// IndexedStack) so we do not start several maps/pollers at once.
  final Set<int> _visited = {};
  Timer? _permissionTimer;

  @override
  void initState() {
    super.initState();
    _checkDriverStatus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Cold-start notification tap, now that the signed-in UI exists.
      PushNotificationService.instance.consumePendingNavigation();
      // Ask for notification permission once the user has settled on the
      // home screen – not on the first frame of the app.
      _permissionTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) PushNotificationService.instance.requestPermissionIfAppropriate();
      });
    });
  }

  @override
  void dispose() {
    _permissionTimer?.cancel();
    super.dispose();
  }

  /// Synchronize the initial index based on whether the user is a driver or rider
  Future<void> _checkDriverStatus() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isDriver = prefs.getBool('user_is_driver') ?? false;
        // Drivers land on the map console (index 2), riders on Street Ride (0).
        _currentIndex = _isDriver ? 2 : 0;
        _visited.add(_currentIndex);
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // --- USER TABS ---
    // 0: Street Ride, 1: Campus Ride, 2: Send Me, 3: Dispatch, 4: Profile
    final List<Widget> userPages = [
      const HomePage(),
      const CampusRidePage(),
      const SendMeLandingPage(),
      const DispatchLandingPage(),
      const ProfileScreen(),
    ];

    // --- DRIVER TABS ---
    // 0: My Ride (History), 1: Transaction, 2: Home (Driver Console), 3: Settings, 4: Profile
    final List<Widget> driverPages = [
      const RideHistoryScreen(),
      const TransactionHistoryPage(),
      const DriverHomePage(), // Updated to the specialized high-performance Driver Console
      const SettingsScreen(),
      const ProfileScreen(),
    ];

    // Select the stack based on role
    final pages = _isDriver ? driverPages : userPages;

    return Scaffold(
      // extendBody allows the map to render behind the glassmorphic navigation bar
      extendBody: true,
      body: IndexedStack(
        index: _currentIndex,
        children: [
          for (var i = 0; i < pages.length; i++)
            // TickerMode lets hidden tabs pause animations, GPS and polling
            // (Home and Campus read TickerMode.of to detect visibility).
            TickerMode(
              enabled: i == _currentIndex,
              child: _visited.contains(i) ? pages[i] : const SizedBox.shrink(),
            ),
        ],
      ),
      bottomNavigationBar: CustomBottomNavBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          HapticFeedback.selectionClick();
          setState(() {
            _currentIndex = index;
            _visited.add(index);
          });
        },
      ),
    );
  }
}