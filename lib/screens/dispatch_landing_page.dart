// lib/screens/dispatch_landing_page.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../routes/routes.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../utility/notification.dart';
import '../widgets/app_menu_drawer.dart';
import '../widgets/bottom_navigation_bar.dart';
import '../widgets/fund_account_sheet.dart';
import '../widgets/header_bar.dart';
import 'logistics_map_picker.dart';

class DispatchLandingPage extends StatefulWidget {
  const DispatchLandingPage({super.key});

  @override
  State<DispatchLandingPage> createState() => _DispatchLandingPageState();
}

class _DispatchLandingPageState extends State<DispatchLandingPage> with SingleTickerProviderStateMixin {
  static const double kHeaderVisualH = 88.0;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  late ApiClient _api;
  late SharedPreferences _prefs;

  Map<String, dynamic>? _user;
  bool _busyProfile = false;
  int _currentIndex = 3; // 3 = Dispatch

  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);

    _animCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));

    _bootstrap();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    _prefs = await SharedPreferences.getInstance();
    await _fetchUser();
    if (mounted) _animCtrl.forward();
  }

  Future<void> _fetchUser() async {
    if (!mounted) return;
    setState(() => _busyProfile = true);
    try {
      final uid = _prefs.getString('user_id') ?? '';
      if (uid.isEmpty) return;
      final res = await _api.request(ApiConstants.userInfoEndpoint, method: 'POST', data: {'user': uid});
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body['error'] == false) {
          if (mounted) setState(() => _user = body['user']);
        }
      }
    } catch (_) {} finally {
      if (mounted) setState(() => _busyProfile = false);
    }
  }

  void _openWallet() {
    final balance = _user != null ? double.tryParse(_user!['user_bal']?.toString() ?? _user!['bal']?.toString() ?? '0.0') ?? 0.0 : null;
    final currency = _user?['user_currency']?.toString() ?? 'NGN';
    showModalBottomSheet(
        context: context,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (_) => FundAccountSheet(account: _user, balance: balance, currency: currency)
    );
  }

  double _scaleFromUi(UIScale uiScale) {
    double scale = (uiScale.shortest / 390.0).clamp(0.58, 1.12);
    if (uiScale.tiny) scale *= 0.88;
    if (uiScale.compact) scale *= 0.94;
    return scale.clamp(0.56, 1.12);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final safeTop = mq.padding.top;
    final uiScale = UIScale.of(context);
    final s = _scaleFromUi(uiScale);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Industrial Theme Color (Forces Dark/Heavy look globally)
    final Color dispatchColor = Colors.amber.shade600;
    final Color bgDark = isDark ? const Color(0xFF0A0A0A) : const Color(0xFF1E1E1E);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: bgDark,
      drawer: AppMenuDrawer(user: _user),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // 1. Industrial Grid Background Effect
          Positioned.fill(
            child: CustomPaint(
              painter: _GridPainter(color: Colors.white.withOpacity(0.03)),
            ),
          ),

          // 2. Heavy Light Beam
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              height: 400 * s,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  colors: [dispatchColor.withOpacity(0.25), Colors.transparent],
                ),
              ),
            ),
          ),

          // 3. Main Scrollable Content
          Positioned.fill(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: SlideTransition(
                position: _slideAnim,
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.only(top: safeTop + (kHeaderVisualH * s) + uiScale.inset(20), bottom: uiScale.inset(120), left: uiScale.inset(24), right: uiScale.inset(24)),
                  children: [
                    // Industrial Hero
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: EdgeInsets.all(uiScale.inset(22)),
                        decoration: BoxDecoration(
                          color: const Color(0xFF222222),
                          borderRadius: BorderRadius.circular(uiScale.radius(20)),
                          border: Border.all(color: dispatchColor.withOpacity(0.5), width: 2),
                          boxShadow: [BoxShadow(color: dispatchColor.withOpacity(0.2), blurRadius: 40, offset: const Offset(0, 10))],
                        ),
                        child: Icon(Icons.inventory_2_rounded, size: uiScale.icon(50), color: dispatchColor),
                      ),
                    ),

                    SizedBox(height: uiScale.gap(32)),
                    Text('Dispatch.', style: TextStyle(fontSize: uiScale.font(46), fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -1.5)),
                    SizedBox(height: uiScale.gap(8)),
                    Text('Send anything, anywhere. From lightweight documents to heavy pallets.', style: TextStyle(fontSize: uiScale.font(16), fontWeight: FontWeight.w500, color: Colors.white70, height: 1.4)),
                    SizedBox(height: uiScale.gap(40)),

                    // Rugged Features
                    _IndustrialFeature(uiScale: uiScale, icon: Icons.scale_rounded, title: 'All Sizes & Weights', subtitle: 'Bikes for envelopes, trucks for freight.', color: dispatchColor),
                    SizedBox(height: uiScale.gap(20)),
                    _IndustrialFeature(uiScale: uiScale, icon: Icons.domain_verification_rounded, title: 'Secure OTP Handoff', subtitle: 'Recipients must provide a PIN to receive.', color: Colors.greenAccent),
                    SizedBox(height: uiScale.gap(20)),
                    _IndustrialFeature(uiScale: uiScale, icon: Icons.route_rounded, title: 'Live Tracking', subtitle: 'Track your shipment every step of the way.', color: Colors.lightBlueAccent),

                    SizedBox(height: uiScale.gap(48)),

                    // Heavy Call to Action
                    SizedBox(
                      width: double.infinity, height: uiScale.inset(64),
                      child: ElevatedButton(
                        onPressed: () {
                          HapticFeedback.heavyImpact();
                          Navigator.push(context, MaterialPageRoute(builder: (_) => LogisticsMapPicker(api: _api, userId: _prefs.getString('user_id') ?? '', rideType: 'dispatch')));
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: dispatchColor, foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(16))),
                          elevation: 0,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('Send a Package', style: TextStyle(fontSize: uiScale.font(17), fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                            SizedBox(width: uiScale.gap(10)),
                            Icon(Icons.arrow_forward_rounded, size: uiScale.icon(24)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 4. Header Background Gradient
          Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: Container(
                height: safeTop + (kHeaderVisualH * s),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [bgDark.withOpacity(0.95), Colors.transparent],
                  ),
                ),
              ),
            ),
          ),

          // 5. Custom Header Bar - Forced to Dark Mode to match the industrial bg
          Positioned(
            top: safeTop, left: 0, right: 0,
            child: Theme(
              data: Theme.of(context).copyWith(brightness: Brightness.dark),
              child: HeaderBar(
                  user: _user,
                  busyProfile: _busyProfile,
                  onMenu: () => _scaffoldKey.currentState?.openDrawer(),
                  onWallet: _openWallet,
                  onNotifications: () => Navigator.pushNamed(context, AppRoutes.notifications)
              ),
            ),
          ),
        ],
      ),

      // 6. Custom Bottom Navigation Bar
      bottomNavigationBar: Theme(
        data: Theme.of(context).copyWith(brightness: Brightness.dark, scaffoldBackgroundColor: bgDark),
        child: CustomBottomNavBar(
          currentIndex: _currentIndex,
          onTap: (i) {
            HapticFeedback.selectionClick();
            if (i == _currentIndex) return;
            setState(() => _currentIndex = i);
            switch (i) {
              case 0: Navigator.pushReplacementNamed(context, AppRoutes.home); break;
              case 1: Navigator.pushReplacementNamed(context, AppRoutes.campus_ride); break;
              case 2: Navigator.pushReplacementNamed(context, AppRoutes.send_me); break;
              case 3: break; // Already on Dispatch
              case 4: Navigator.pushNamed(context, AppRoutes.profile); break;
            }
          },
        ),
      ),
    );
  }
}

class _IndustrialFeature extends StatelessWidget {
  final UIScale uiScale; final IconData icon; final String title; final String subtitle; final Color color;
  const _IndustrialFeature({required this.uiScale, required this.icon, required this.title, required this.subtitle, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(uiScale.inset(16)),
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(uiScale.radius(16)),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: uiScale.icon(28)),
          SizedBox(width: uiScale.gap(16)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: uiScale.font(15), fontWeight: FontWeight.w800, color: Colors.white)),
                SizedBox(height: uiScale.gap(4)),
                Text(subtitle, style: TextStyle(fontSize: uiScale.font(12.5), fontWeight: FontWeight.w500, color: Colors.white54)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final Color color;
  _GridPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 1;
    for (double i = 0; i < size.width; i += 40) {
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), paint);
    }
    for (double i = 0; i < size.height; i += 40) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), paint);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}