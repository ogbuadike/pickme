// lib/screens/send_me_landing_page.dart
import 'dart:convert';
import 'dart:ui' show ImageFilter;
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

class SendMeLandingPage extends StatefulWidget {
  const SendMeLandingPage({super.key});

  @override
  State<SendMeLandingPage> createState() => _SendMeLandingPageState();
}

class _SendMeLandingPageState extends State<SendMeLandingPage> with SingleTickerProviderStateMixin {
  static const double kHeaderVisualH = 88.0;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  late ApiClient _api;
  late SharedPreferences _prefs;

  Map<String, dynamic>? _user;
  bool _busyProfile = false;
  int _currentIndex = 2; // 2 = Send Me

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
    } catch (_) {
      // Ignore network errors on silent fetch
    } finally {
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final themeColor = Colors.blueAccent;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: theme.scaffoldBackgroundColor,
      drawer: AppMenuDrawer(user: _user),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // 1. Premium Glowing Orb Background (Send Me Theme)
          Positioned(
            top: -50, right: -100,
            child: Container(
              width: 400 * s, height: 400 * s,
              decoration: BoxDecoration(shape: BoxShape.circle, color: themeColor.withOpacity(isDark ? 0.15 : 0.08)),
            ),
          ),
          Positioned.fill(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 80, sigmaY: 80), child: const SizedBox())),

          // 2. Main Scrollable Content
          Positioned.fill(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: SlideTransition(
                position: _slideAnim,
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.only(top: safeTop + (kHeaderVisualH * s) + uiScale.inset(20), bottom: uiScale.inset(120), left: uiScale.inset(24), right: uiScale.inset(24)),
                  children: [
                    // Animated Hero Graphic
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: uiScale.inset(84), height: uiScale.inset(84),
                        decoration: BoxDecoration(
                          color: isDark ? cs.surface : Colors.white,
                          borderRadius: BorderRadius.circular(uiScale.radius(24)),
                          boxShadow: [BoxShadow(color: themeColor.withOpacity(0.3), blurRadius: 30, offset: const Offset(0, 10))],
                        ),
                        child: Icon(Icons.shopping_cart_checkout_rounded, size: uiScale.icon(42), color: themeColor),
                      ),
                    ),

                    SizedBox(height: uiScale.gap(32)),
                    Text('Send Me.', style: TextStyle(fontSize: uiScale.font(46), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary, letterSpacing: -1.5)),
                    SizedBox(height: uiScale.gap(8)),
                    Text('Your personal assistant on wheels. We go to the market, pick up groceries, and run your daily errands.', style: TextStyle(fontSize: uiScale.font(16), fontWeight: FontWeight.w600, color: cs.onSurfaceVariant, height: 1.4)),
                    SizedBox(height: uiScale.gap(40)),

                    // Feature Cards
                    _FeatureCard(uiScale: uiScale, icon: Icons.checklist_rounded, title: 'Custom Instructions', subtitle: 'Tell the rider exactly what to do or buy.', color: themeColor),
                    SizedBox(height: uiScale.gap(16)),
                    _FeatureCard(uiScale: uiScale, icon: Icons.store_rounded, title: 'Store Pickups', subtitle: 'Perfect for groceries, pharmacy, or food.', color: Colors.teal),
                    SizedBox(height: uiScale.gap(16)),
                    _FeatureCard(uiScale: uiScale, icon: Icons.motorcycle_rounded, title: 'Dedicated Rider', subtitle: 'A driver solely focused on your tasks.', color: Colors.purpleAccent),

                    SizedBox(height: uiScale.gap(48)),

                    // CTA Button
                    SizedBox(
                      width: double.infinity, height: uiScale.inset(64),
                      child: ElevatedButton(
                        onPressed: () {
                          HapticFeedback.heavyImpact();
                          Navigator.push(context, MaterialPageRoute(builder: (_) => LogisticsMapPicker(api: _api, userId: _prefs.getString('user_id') ?? '', rideType: 'send_me')));
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: themeColor, foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(20))),
                          elevation: 12, shadowColor: themeColor.withOpacity(0.5),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('Start an Errand', style: TextStyle(fontSize: uiScale.font(16), fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                            SizedBox(width: uiScale.gap(10)),
                            Icon(Icons.arrow_forward_rounded, size: uiScale.icon(20)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 3. Header Background Gradient
          Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: Container(
                height: safeTop + (kHeaderVisualH * s),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: isDark ? [theme.scaffoldBackgroundColor.withOpacity(0.95), theme.scaffoldBackgroundColor.withOpacity(0.0)] : [theme.scaffoldBackgroundColor.withOpacity(0.95), theme.scaffoldBackgroundColor.withOpacity(0.0)],
                  ),
                ),
              ),
            ),
          ),

          // 4. Custom Header Bar
          Positioned(
            top: safeTop, left: 0, right: 0,
            child: HeaderBar(
                user: _user,
                busyProfile: _busyProfile,
                onMenu: () => _scaffoldKey.currentState?.openDrawer(),
                onWallet: _openWallet,
                onNotifications: () => Navigator.pushNamed(context, AppRoutes.notifications)
            ),
          ),
        ],
      ),

      // 5. Custom Bottom Navigation Bar
      bottomNavigationBar: CustomBottomNavBar(
        currentIndex: _currentIndex,
        onTap: (i) {
          HapticFeedback.selectionClick();
          if (i == _currentIndex) return;
          setState(() => _currentIndex = i);
          switch (i) {
            case 0: Navigator.pushReplacementNamed(context, AppRoutes.home); break;
            case 1: Navigator.pushReplacementNamed(context, AppRoutes.campus_ride); break;
            case 2: break; // Already on Send Me
            case 3: Navigator.pushReplacementNamed(context, AppRoutes.dispatch); break;
            case 4: Navigator.pushNamed(context, AppRoutes.profile); break;
          }
        },
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final UIScale uiScale; final IconData icon; final String title; final String subtitle; final Color color;
  const _FeatureCard({required this.uiScale, required this.icon, required this.title, required this.subtitle, required this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.all(uiScale.inset(16)),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceVariant.withOpacity(0.4) : Colors.white,
        borderRadius: BorderRadius.circular(uiScale.radius(20)),
        border: Border.all(color: isDark ? cs.outline.withOpacity(0.3) : Colors.black.withOpacity(0.04)),
        boxShadow: isDark ? [] : [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(uiScale.inset(12)),
            decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(uiScale.radius(14))),
            child: Icon(icon, color: color, size: uiScale.icon(22)),
          ),
          SizedBox(width: uiScale.gap(16)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: uiScale.font(15), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary)),
                SizedBox(height: uiScale.gap(4)),
                Text(subtitle, style: TextStyle(fontSize: uiScale.font(12.5), fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}