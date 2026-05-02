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
import '../widgets/inner_background.dart';
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

    _animCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero)
        .animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));

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
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FundAccountSheet(account: _user, balance: balance, currency: currency),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final safeTop = mq.padding.top;
    final ui = UIScale.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Send Me Brand Color
    final Color sendMeColor = Colors.blueAccent.shade400;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: isDark ? Colors.black : AppColors.offWhite,
      drawer: AppMenuDrawer(user: _user),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // 1. Premium App Background
          BackgroundWidget(style: HoloStyle.vapor, intensity: isDark ? 0.15 : 0.5, animate: true),

          // 2. Main Scrollable Content
          Positioned.fill(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: SlideTransition(
                position: _slideAnim,
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.only(
                    top: safeTop + kHeaderVisualH + ui.inset(20),
                    bottom: ui.inset(140),
                    left: ui.inset(20),
                    right: ui.inset(20),
                  ),
                  children: [
                    // Premium Hero Icon
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: EdgeInsets.all(ui.inset(20)),
                        decoration: BoxDecoration(
                          color: sendMeColor.withOpacity(isDark ? 0.15 : 0.1),
                          borderRadius: BorderRadius.circular(ui.radius(24)),
                          border: Border.all(color: sendMeColor.withOpacity(0.4), width: 2),
                          boxShadow: [
                            BoxShadow(color: sendMeColor.withOpacity(0.2), blurRadius: 30, offset: const Offset(0, 10))
                          ],
                        ),
                        child: Icon(Icons.shopping_cart_checkout_rounded, size: ui.icon(42).clamp(36.0, 50.0).toDouble(), color: sendMeColor),
                      ),
                    ),

                    SizedBox(height: ui.gap(28)),
                    Text(
                      'Send Me\nErrands.',
                      style: TextStyle(
                        fontSize: ui.font(42).clamp(36.0, 48.0).toDouble(),
                        fontWeight: FontWeight.w900,
                        color: isDark ? cs.onSurface : AppColors.textPrimary,
                        letterSpacing: -1.5,
                        height: 1.1,
                      ),
                    ),
                    SizedBox(height: ui.gap(12)),
                    Text(
                      'Your personal assistant on wheels. We go to the market, pick up groceries, and run your daily errands.',
                      style: TextStyle(
                        fontSize: ui.font(15).clamp(14.0, 16.0).toDouble(),
                        fontWeight: FontWeight.w600,
                        color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    SizedBox(height: ui.gap(36)),

                    // Premium Glassmorphic Features
                    _buildFeatureCard(
                      ui: ui, cs: cs, isDark: isDark,
                      icon: Icons.checklist_rounded, color: sendMeColor,
                      title: 'Custom Instructions',
                      subtitle: 'Tell the rider exactly what to do or buy.',
                    ),
                    SizedBox(height: ui.gap(16)),
                    _buildFeatureCard(
                      ui: ui, cs: cs, isDark: isDark,
                      icon: Icons.store_rounded, color: const Color(0xFF10B981),
                      title: 'Store Pickups',
                      subtitle: 'Perfect for groceries, pharmacy, or food.',
                    ),
                    SizedBox(height: ui.gap(16)),
                    _buildFeatureCard(
                      ui: ui, cs: cs, isDark: isDark,
                      icon: Icons.motorcycle_rounded, color: const Color(0xFF8B5CF6),
                      title: 'Dedicated Rider',
                      subtitle: 'A driver solely focused on your tasks.',
                    ),

                    SizedBox(height: ui.gap(48)),

                    // Action Button
                    SizedBox(
                      width: double.infinity,
                      height: ui.inset(60).clamp(54.0, 64.0).toDouble(),
                      child: ElevatedButton(
                        onPressed: () {
                          HapticFeedback.heavyImpact();
                          Navigator.push(context, MaterialPageRoute(builder: (_) => LogisticsMapPicker(api: _api, userId: _prefs.getString('user_id') ?? '', rideType: 'send_me')));
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: sendMeColor,
                          foregroundColor: Colors.white,
                          elevation: 8,
                          shadowColor: sendMeColor.withOpacity(0.4),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ui.radius(20))),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Start an Errand',
                              style: TextStyle(fontSize: ui.font(16).clamp(15.0, 17.0).toDouble(), fontWeight: FontWeight.w900, letterSpacing: 0.5),
                            ),
                            SizedBox(width: ui.gap(10)),
                            Icon(Icons.arrow_forward_rounded, size: ui.icon(22)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 3. Header Background Blur
          Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: ClipRRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    height: safeTop + kHeaderVisualH,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [
                          (isDark ? Colors.black : Colors.white).withOpacity(0.8),
                          (isDark ? Colors.black : Colors.white).withOpacity(0.0)
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 4. Header Bar
          Positioned(
            top: safeTop, left: 0, right: 0,
            child: HeaderBar(
              user: _user,
              busyProfile: _busyProfile,
              onMenu: () => _scaffoldKey.currentState?.openDrawer(),
              onWallet: _openWallet,
              onNotifications: () => Navigator.pushNamed(context, AppRoutes.notifications),
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

  Widget _buildFeatureCard({
    required UIScale ui, required ColorScheme cs, required bool isDark,
    required IconData icon, required Color color, required String title, required String subtitle,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(ui.radius(20)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: EdgeInsets.all(ui.inset(16)),
          decoration: BoxDecoration(
            color: isDark ? cs.surface.withOpacity(0.85) : Colors.white.withOpacity(0.85),
            borderRadius: BorderRadius.circular(ui.radius(20)),
            border: Border.all(color: isDark ? cs.outline.withOpacity(0.4) : AppColors.mintBgLight.withOpacity(0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.3 : 0.04),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.all(ui.inset(12)),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: ui.icon(24).clamp(20.0, 26.0).toDouble()),
              ),
              SizedBox(width: ui.gap(16)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(fontSize: ui.font(14.5).clamp(13.5, 16.0).toDouble(), fontWeight: FontWeight.w800, color: isDark ? cs.onSurface : AppColors.textPrimary)),
                    SizedBox(height: ui.gap(4)),
                    Text(subtitle, style: TextStyle(fontSize: ui.font(12).clamp(11.0, 13.0).toDouble(), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, height: 1.3)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}