// lib/screens/logistics/logistics_landing_view.dart
//
// Shared landing screen for Send Me and Dispatch (they were two copy-pasted
// 344-line files). Product specifics come from [LogisticsLandingConfig].
//
// Also resumes an in-flight delivery after an app restart: the server's
// active ride (ride_status.php by rider) is offered as a "Track" banner.
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../routes/routes.dart';
import '../../services/booking_controller.dart';
import '../../services/logistics_service.dart';
import '../../themes/app_theme.dart';
import '../../ui/ui_scale.dart';
import '../../widgets/app_menu_drawer.dart';
import '../../widgets/fund_account_sheet.dart';
import '../../widgets/header_bar.dart';
import '../../widgets/inner_background.dart';
import '../logistics_map_picker.dart';
import 'logistics_tracking_page.dart';

@immutable
class LogisticsFeature {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  const LogisticsFeature(this.icon, this.color, this.title, this.subtitle);
}

@immutable
class LogisticsLandingConfig {
  final LogisticsKind kind;
  final IconData heroIcon;
  final String headline;
  final String tagline;
  final String ctaLabel;
  final List<LogisticsFeature> features;
  const LogisticsLandingConfig({
    required this.kind,
    required this.heroIcon,
    required this.headline,
    required this.tagline,
    required this.ctaLabel,
    required this.features,
  });
}

class LogisticsLandingView extends StatefulWidget {
  final LogisticsLandingConfig config;
  const LogisticsLandingView({super.key, required this.config});

  @override
  State<LogisticsLandingView> createState() => _LogisticsLandingViewState();
}

class _LogisticsLandingViewState extends State<LogisticsLandingView> with SingleTickerProviderStateMixin {
  static const double kHeaderVisualH = 88.0;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final ApiClient _api = ApiClient();

  String _userId = '';
  Map<String, dynamic>? _user;
  bool _busyProfile = false;
  bool _ready = false;
  Map<String, dynamic>? _activeRide; // ride_status payload of an active delivery

  late final AnimationController _animCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  late final Animation<double> _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slideAnim = Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero)
      .animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));

  LogisticsKind get _kind => widget.config.kind;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString('user_id') ?? '';
    if (!mounted) return;
    setState(() => _ready = true);
    _animCtrl.forward();
    await Future.wait<void>(<Future<void>>[_fetchUser(), _checkActiveDelivery()]);
  }

  Future<void> _fetchUser() async {
    if (_userId.isEmpty || !mounted) return;
    setState(() => _busyProfile = true);
    try {
      final res = await _api.request(
        ApiConstants.userInfoEndpoint,
        method: 'POST',
        data: <String, String>{'user': _userId},
        idempotent: true,
      );
      final dynamic body = jsonDecode(res.body);
      if (body is Map && body['error'] == false && body['user'] is Map && mounted) {
        setState(() => _user = (body['user'] as Map).cast<String, dynamic>());
      }
    } catch (_) {
      // Header shows a placeholder; nothing else depends on the profile.
    } finally {
      if (mounted) setState(() => _busyProfile = false);
    }
  }

  Future<void> _checkActiveDelivery() async {
    if (_userId.isEmpty) return;
    final Map<String, dynamic>? active = await BookingController.fetchActiveRide(_api, _userId);
    if (!mounted) return;
    final dynamic ride = active?['ride'];
    final LogisticsKind? kind = ride is Map ? LogisticsKindX.tryParse(ride['ride_type']) : null;
    setState(() => _activeRide = kind == _kind ? active : null);
  }

  double? get _walletBalance =>
      _user == null ? null : double.tryParse((_user!['user_bal'] ?? _user!['bal'] ?? '').toString());

  void _openWallet() {
    final double? balance = _user == null ? null : (_walletBalance ?? 0.0);
    final String currency = _user?['user_currency']?.toString() ?? 'NGN';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FundAccountSheet(account: _user, balance: balance, currency: currency),
    );
  }

  Future<void> _start() async {
    if (!_ready) return;
    if (_userId.isEmpty) {
      Navigator.pushNamed(context, AppRoutes.login);
      return;
    }
    HapticFeedback.heavyImpact();
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => LogisticsMapPicker(
          api: _api,
          userId: _userId,
          rideType: _kind.wire,
          walletBalance: _walletBalance,
        ),
      ),
    );
    if (mounted) _checkActiveDelivery();
  }

  Future<void> _trackActive() async {
    final Map<String, dynamic>? active = _activeRide;
    if (active == null) return;
    final Map<String, dynamic> ride = (active['ride'] as Map).cast<String, dynamic>();
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => LogisticsTrackingPage(
          api: _api,
          userId: _userId,
          kind: _kind,
          rideId: '${ride['id'] ?? active['ride_id']}',
          initialPayload: active,
        ),
      ),
    );
    if (mounted) _checkActiveDelivery();
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final double safeTop = mq.padding.top;
    final UIScale ui = UIScale.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool isDark = theme.brightness == Brightness.dark;
    final Color brand = _kind.brandColor;
    final LogisticsLandingConfig c = widget.config;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: isDark ? Colors.black : AppColors.offWhite,
      drawer: AppMenuDrawer(user: _user),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: <Widget>[
          BackgroundWidget(style: HoloStyle.vapor, intensity: isDark ? 0.15 : 0.5, animate: true),
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
                  children: <Widget>[
                    if (_activeRide != null) ...<Widget>[
                      _ActiveDeliveryBanner(
                        kind: _kind,
                        status: RideStatusCode.normalize((_activeRide!['ride'] as Map)['status']),
                        onTap: _trackActive,
                      ),
                      SizedBox(height: ui.gap(20)),
                    ],
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: EdgeInsets.all(ui.inset(20)),
                        decoration: BoxDecoration(
                          color: brand.withValues(alpha: isDark ? 0.15 : 0.1),
                          borderRadius: BorderRadius.circular(ui.radius(24)),
                          border: Border.all(color: brand.withValues(alpha: 0.4), width: 2),
                          boxShadow: <BoxShadow>[
                            BoxShadow(color: brand.withValues(alpha: 0.2), blurRadius: 30, offset: const Offset(0, 10)),
                          ],
                        ),
                        child: Icon(c.heroIcon, size: ui.icon(42).clamp(36.0, 50.0).toDouble(), color: brand),
                      ),
                    ),
                    SizedBox(height: ui.gap(28)),
                    Text(
                      c.headline,
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
                      c.tagline,
                      style: TextStyle(
                        fontSize: ui.font(15).clamp(14.0, 16.0).toDouble(),
                        fontWeight: FontWeight.w600,
                        color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    SizedBox(height: ui.gap(36)),
                    for (int i = 0; i < c.features.length; i++) ...<Widget>[
                      if (i > 0) SizedBox(height: ui.gap(16)),
                      _FeatureCard(feature: c.features[i]),
                    ],
                    SizedBox(height: ui.gap(48)),
                    SizedBox(
                      width: double.infinity,
                      height: ui.inset(60).clamp(54.0, 64.0).toDouble(),
                      child: ElevatedButton(
                        onPressed: _ready ? _start : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: brand,
                          foregroundColor: _kind.onBrandColor,
                          elevation: 8,
                          shadowColor: brand.withValues(alpha: 0.4),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ui.radius(20))),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Text(
                              c.ctaLabel,
                              style: TextStyle(
                                fontSize: ui.font(16).clamp(15.0, 17.0).toDouble(),
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                              ),
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
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: ClipRRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    height: safeTop + kHeaderVisualH,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          (isDark ? Colors.black : Colors.white).withValues(alpha: 0.8),
                          (isDark ? Colors.black : Colors.white).withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: safeTop,
            left: 0,
            right: 0,
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
    );
  }
}

class _ActiveDeliveryBanner extends StatelessWidget {
  final LogisticsKind kind;
  final String status;
  final VoidCallback onTap;
  const _ActiveDeliveryBanner({required this.kind, required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final UIScale ui = UIScale.of(context);
    final Color brand = kind.brandColor;
    return Material(
      color: brand.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(ui.radius(18)),
      child: InkWell(
        borderRadius: BorderRadius.circular(ui.radius(18)),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(ui.inset(14)),
          child: Row(
            children: <Widget>[
              Icon(Icons.radar_rounded, color: brand),
              SizedBox(width: ui.gap(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('You have an active ${kind.productName} request',
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: ui.font(13.5))),
                    SizedBox(height: ui.gap(2)),
                    Text(logisticsStatusLabel(status, kind),
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: ui.font(12))),
                  ],
                ),
              ),
              Text('Track', style: TextStyle(fontWeight: FontWeight.w900, color: brand)),
              Icon(Icons.chevron_right_rounded, color: brand),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final LogisticsFeature feature;
  const _FeatureCard({required this.feature});

  @override
  Widget build(BuildContext context) {
    final UIScale ui = UIScale.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool isDark = theme.brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(ui.radius(20)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: EdgeInsets.all(ui.inset(16)),
          decoration: BoxDecoration(
            color: isDark ? cs.surface.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(ui.radius(20)),
            border: Border.all(
              color: isDark ? cs.outline.withValues(alpha: 0.4) : AppColors.mintBgLight.withValues(alpha: 0.3),
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.04),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: <Widget>[
              Container(
                padding: EdgeInsets.all(ui.inset(12)),
                decoration: BoxDecoration(color: feature.color.withValues(alpha: 0.15), shape: BoxShape.circle),
                child: Icon(feature.icon, color: feature.color, size: ui.icon(24).clamp(20.0, 26.0).toDouble()),
              ),
              SizedBox(width: ui.gap(16)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      feature.title,
                      style: TextStyle(
                        fontSize: ui.font(14.5).clamp(13.5, 16.0).toDouble(),
                        fontWeight: FontWeight.w800,
                        color: isDark ? cs.onSurface : AppColors.textPrimary,
                      ),
                    ),
                    SizedBox(height: ui.gap(4)),
                    Text(
                      feature.subtitle,
                      style: TextStyle(
                        fontSize: ui.font(12).clamp(11.0, 13.0).toDouble(),
                        fontWeight: FontWeight.w600,
                        color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                        height: 1.3,
                      ),
                    ),
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
