// lib/screens/main_navigation_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/bottom_navigation_bar.dart';
import 'home_page.dart';
import 'campus_ride_page.dart';
import 'send_me_landing_page.dart';
import 'dispatch_landing_page.dart';
import 'profile.dart';
import 'TransactionList.dart';
import 'settings_screen.dart';
import 'ride_history_screen.dart';
import '../driver/driver_home_page.dart'; // Correctly imported

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  bool _isDriver = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkDriverStatus();
  }

  /// Synchronize the initial index based on whether the user is a driver or rider
  Future<void> _checkDriverStatus() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isDriver = prefs.getBool('user_is_driver') ?? false;
        if (_isDriver) {
          // Drivers naturally land on the center map console (Index 2)[cite: 20]
          _currentIndex = 2;
        } else {
          // Normal users land on Street Ride (Index 0)[cite: 20]
          _currentIndex = 0;
        }
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
    // 0: Street Ride, 1: Campus Ride, 2: Send Me, 3: Dispatch, 4: Profile[cite: 20]
    final List<Widget> userPages = [
      const HomePage(),
      const CampusRidePage(),
      const SendMeLandingPage(),
      const DispatchLandingPage(),
      const ProfileScreen(),
    ];

    // --- DRIVER TABS ---
    // 0: My Ride (History), 1: Transaction, 2: Home (Driver Console), 3: Settings, 4: Profile[cite: 20]
    final List<Widget> driverPages = [
      const RideHistoryScreen(),
      const TransactionHistoryPage(),
      const DriverHomePage(), // Updated to the specialized high-performance Driver Console[cite: 20]
      const SettingsScreen(),
      const ProfileScreen(),
    ];

    // Select the stack based on role[cite: 20]
    final pages = _isDriver ? driverPages : userPages;

    return Scaffold(
      // extendBody allows the map to render behind the glassmorphic navigation bar[cite: 20]
      extendBody: true,
      body: IndexedStack(
        index: _currentIndex,
        children: pages,
      ),
      bottomNavigationBar: CustomBottomNavBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          HapticFeedback.selectionClick();
          setState(() {
            _currentIndex = index;
          });
        },
      ),
    );
  }
}