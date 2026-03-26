// lib/pages/become_a_driver.dart
//
// Premium driver onboarding screen
// - Responsive pinned header
// - Compact hero card layout
// - Premium application steps timeline
// - Driver verification bottom sheet with guided uploads
// - Locked account identity fields (full name + email)
// - Keyboard-safe, drag-friendly modal sheet

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../utility/notification.dart';
import '../widgets/inner_background.dart';

String _normalizeDriverUiStatus(dynamic raw) {
  final value = (raw ?? '').toString().trim().toLowerCase();
  switch (value) {
    case 'pending':
      return 'pending';
    case 'approved':
    case 'activated':
      return 'activated';
    case 'rejected':
      return 'rejected';
    default:
      return 'not_started';
  }
}


class BecomeADriverPage extends StatefulWidget {
  const BecomeADriverPage({super.key});

  @override
  State<BecomeADriverPage> createState() => _BecomeADriverPageState();
}

class _BecomeADriverPageState extends State<BecomeADriverPage>
    with SingleTickerProviderStateMixin {
  static const String _userCacheKey = 'cached_user_profile';

  late final AnimationController _introCtrl;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  late ApiClient _api;
  late SharedPreferences _prefs;

  bool _isFetchingAccount = false;
  bool _hasError = false;
  bool _isCheckingApplicationStatus = true;

  Map<String, dynamic> _user = {};

  int _selectedBenefit = 0;
  String _applicationStatus = 'checking';
  String? _applicationStatusNote;

  @override
  void initState() {
    super.initState();
    _introCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );

    _fadeAnim = CurvedAnimation(
      parent: _introCtrl,
      curve: Curves.easeOutCubic,
    );

    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _introCtrl,
        curve: Curves.easeOutCubic,
      ),
    );

    _introCtrl.forward();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _api = ApiClient(http.Client(), context);
      _hydrateCachedUser();
      await _fetchUser(silent: _user.isNotEmpty);
      await _fetchApplicationStatus(silent: true);
    } catch (e) {
      _fail('Failed to initialize: $e');
      if (mounted) {
        setState(() {
          _applicationStatus = 'not_started';
          _isCheckingApplicationStatus = false;
        });
      }
    }
  }

  void _hydrateCachedUser() {
    try {
      final cached = _prefs.getString(_userCacheKey);
      if (cached == null || cached.trim().isEmpty) return;

      final decoded = jsonDecode(cached);
      if (decoded is! Map) return;

      final mapped = decoded.map(
            (k, v) => MapEntry<String, dynamic>(k.toString(), v),
      );

      if (!mounted) {
        _user = mapped;
        return;
      }

      setState(() {
        _user = mapped;
      });
    } catch (_) {
      // Ignore invalid local cache and continue with network fetch.
    }
  }

  Future<void> _cacheUser(Map<String, dynamic> user) async {
    try {
      await _prefs.setString(_userCacheKey, jsonEncode(user));
    } catch (_) {
      // Cache failure should not block page rendering.
    }
  }

  Future<void> _fetchUser({bool silent = false}) async {
    if (!mounted) return;

    if (silent) {
      _isFetchingAccount = true;
      if (_hasError) {
        setState(() => _hasError = false);
      }
    } else {
      setState(() {
        _isFetchingAccount = true;
        _hasError = false;
      });
    }

    try {
      final uid = _prefs.getString('user_id');
      if (uid == null || uid.isEmpty) {
        throw Exception('User ID missing');
      }

      final res = await _api.request(
        ApiConstants.userInfoEndpoint,
        method: 'POST',
        data: {'user': uid},
      );

      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data is Map && data['error'] == false) {
        final rawUser = data['user'];
        if (rawUser is Map) {
          final mapped = rawUser.map(
                (k, v) => MapEntry<String, dynamic>(k.toString(), v),
          );

          if (!mounted) return;
          setState(() {
            _user = mapped;
          });

          await _cacheUser(mapped);
        } else {
          throw Exception('User payload missing');
        }
      } else {
        throw Exception(data['error_msg'] ?? 'Unable to load profile');
      }
    } catch (e) {
      _fail('Failed to load profile: $e');
    } finally {
      if (!mounted) return;
      if (silent) {
        _isFetchingAccount = false;
      } else {
        setState(() => _isFetchingAccount = false);
      }
    }
  }


  Future<void> _fetchApplicationStatus({bool silent = false}) async {
    if (!mounted) return;

    if (silent) {
      _isCheckingApplicationStatus = true;
    } else {
      setState(() => _isCheckingApplicationStatus = true);
    }

    try {
      final uid = _prefs.getString('user_id')?.trim() ?? '';
      if (uid.isEmpty) {
        if (!mounted) return;
        setState(() {
          _applicationStatus = 'not_started';
          _applicationStatusNote = null;
        });
        return;
      }

      final res = await _api.request(
        ApiConstants.upgradeToDriverEndpoint,
        method: 'POST',
        data: {
          'action': 'status',
          'user': uid,
        },
      );

      final body = jsonDecode(res.body);
      if (!mounted) return;

      if (res.statusCode == 200 && body is Map && body['error'] == false) {
        final data = body['data'];
        final status = data is Map ? _normalizeDriverUiStatus(data['status']) : 'not_started';
        final note = data is Map
            ? ((data['message'] ?? data['admin_note'])?.toString())
            : null;

        setState(() {
          _applicationStatus = status;
          _applicationStatusNote = note;
        });
      } else {
        setState(() {
          _applicationStatus = 'not_started';
          _applicationStatusNote = null;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _applicationStatus = 'not_started';
        _applicationStatusNote = null;
      });
    } finally {
      if (!mounted) return;
      if (silent) {
        _isCheckingApplicationStatus = false;
      } else {
        setState(() => _isCheckingApplicationStatus = false);
      }
    }
  }

  bool get _applicationLocked =>
      _applicationStatus == 'pending' || _applicationStatus == 'activated';

  String get _applicationButtonLabel {
    if (_isCheckingApplicationStatus) return 'Checking Application...';
    switch (_applicationStatus) {
      case 'pending':
        return 'Application Pending';
      case 'activated':
        return 'Driver Activated';
      case 'rejected':
        return 'Resume Application';
      default:
        return 'Start Your Application';
    }
  }

  IconData get _applicationButtonIcon {
    if (_applicationStatus == 'activated') {
      return Icons.verified_rounded;
    }
    if (_applicationStatus == 'pending') {
      return Icons.hourglass_top_rounded;
    }
    if (_applicationStatus == 'rejected') {
      return Icons.refresh_rounded;
    }
    return Icons.arrow_forward_rounded;
  }

  String get _applicationStatusCaption {
    if (_isCheckingApplicationStatus) {
      return 'Syncing your driver application status.';
    }
    if (_applicationStatus == 'pending') {
      return _applicationStatusNote?.trim().isNotEmpty == true
          ? _applicationStatusNote!.trim()
          : 'Your onboarding is under review. You cannot submit another application now.';
    }
    if (_applicationStatus == 'activated') {
      return _applicationStatusNote?.trim().isNotEmpty == true
          ? _applicationStatusNote!.trim()
          : 'Your driver account is active. No further application is required.';
    }
    if (_applicationStatus == 'rejected') {
      return _applicationStatusNote?.trim().isNotEmpty == true
          ? _applicationStatusNote!.trim()
          : 'Your last application needs an update. Open the flow and resubmit.';
    }
    return 'Complete the guided onboarding once to submit your driver application.';
  }

  Color _applicationStatusColor(ColorScheme cs) {
    switch (_applicationStatus) {
      case 'pending':
        return const Color(0xFFE67E22);
      case 'activated':
        return const Color(0xFF1E8E3E);
      case 'rejected':
        return const Color(0xFFD64545);
      default:
        return AppColors.primary;
    }
  }

  bool get _canTriggerApplicationFlow =>
      _canOpenApplicationModal &&
          !_isCheckingApplicationStatus &&
          !_applicationLocked;

  void _fail(String msg) {
    if (!mounted) return;
    setState(() => _hasError = true);
    showToastNotification(
      context: context,
      title: 'Error',
      message: msg,
      isSuccess: false,
    );
  }

  String get _accountFullName {
    final first = (_user['user_fname'] ??
        _user['fname'] ??
        _user['first_name'] ??
        '')
        .toString()
        .trim();

    final last = (_user['user_lname'] ??
        _user['lname'] ??
        _user['last_name'] ??
        '')
        .toString()
        .trim();

    final legal = (_user['legal_full_name'] ??
        _user['full_name'] ??
        _user['name'] ??
        '')
        .toString()
        .trim();

    final combined = [first, last].where((e) => e.isNotEmpty).join(' ').trim();

    if (legal.isNotEmpty) return legal;
    if (combined.isNotEmpty) return combined;
    return '';
  }

  String get _accountEmail {
    return (_user['email'] ??
        _user['user_email'] ??
        _user['mail'] ??
        '')
        .toString()
        .trim();
  }

  String get _accountPhone {
    return (_user['phone'] ??
        _user['user_phone'] ??
        _user['mobile'] ??
        _user['phone_number'] ??
        '')
        .toString()
        .trim();
  }

  bool get _canOpenApplicationModal =>
      _accountFullName.isNotEmpty && _accountEmail.isNotEmpty;

  @override
  void dispose() {
    _introCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui = UIScale.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = cs.brightness == Brightness.dark;

    return Scaffold(
      body: Stack(
        children: [
          const BackgroundWidget(
            animate: true,
            intensity: 0.85,
            style: HoloStyle.flux,
          ),
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverAppBar(
                pinned: true,
                centerTitle: false,
                elevation: 0,
                surfaceTintColor: Colors.transparent,
                backgroundColor:
                theme.scaffoldBackgroundColor.withOpacity(isDark ? 0.88 : 0.96),
                titleSpacing: 0,
                leadingWidth: ui.inset(64).clamp(58.0, 72.0).toDouble(),
                automaticallyImplyLeading: false,
                leading: _HeaderBackButton(ui: ui, cs: cs),
                title: _HeaderTitle(ui: ui, cs: cs),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    ui.screenPadding.left,
                    ui.gap(14).clamp(12.0, 18.0).toDouble(),
                    ui.screenPadding.right,
                    0,
                  ),
                  child: FadeTransition(
                    opacity: _fadeAnim,
                    child: SlideTransition(
                      position: _slideAnim,
                      child: _HeroSection(ui: ui, cs: cs, isDark: isDark),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: ui.screenPadding.left,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(height: ui.gap(24).clamp(20.0, 28.0).toDouble()),
                      _SectionHeader(
                        ui: ui,
                        cs: cs,
                        title: 'Why Become a PickMe Driver',
                        icon: Icons.trending_up_rounded,
                      ),
                      SizedBox(height: ui.gap(16).clamp(12.0, 18.0).toDouble()),
                      _BenefitsCarousel(
                        ui: ui,
                        cs: cs,
                        isDark: isDark,
                        selectedIndex: _selectedBenefit,
                        onTap: (i) {
                          HapticFeedback.lightImpact();
                          setState(() => _selectedBenefit = i);
                        },
                      ),
                      SizedBox(height: ui.gap(28).clamp(24.0, 32.0).toDouble()),
                      _SectionHeader(
                        ui: ui,
                        cs: cs,
                        title: 'Quick Requirements',
                        icon: Icons.checklist_rounded,
                      ),
                      SizedBox(height: ui.gap(16).clamp(12.0, 18.0).toDouble()),
                      _RequirementsGrid(ui: ui, cs: cs, isDark: isDark),
                      SizedBox(height: ui.gap(28).clamp(24.0, 32.0).toDouble()),
                      _SectionHeader(
                        ui: ui,
                        cs: cs,
                        title: 'Earnings Potential',
                        icon: Icons.payments_rounded,
                      ),
                      SizedBox(height: ui.gap(16).clamp(12.0, 18.0).toDouble()),
                      _EarningsShowcase(ui: ui, cs: cs, isDark: isDark),
                      SizedBox(height: ui.gap(28).clamp(24.0, 32.0).toDouble()),
                      _SectionHeader(
                        ui: ui,
                        cs: cs,
                        title: 'Driver Success Stories',
                        icon: Icons.star_rounded,
                      ),
                      SizedBox(height: ui.gap(16).clamp(12.0, 18.0).toDouble()),
                      _TestimonialCards(ui: ui, cs: cs, isDark: isDark),
                      SizedBox(height: ui.gap(28).clamp(24.0, 32.0).toDouble()),
                      _SectionHeader(
                        ui: ui,
                        cs: cs,
                        title: 'Application Steps',
                        icon: Icons.directions_car_rounded,
                      ),
                      SizedBox(height: ui.gap(16).clamp(12.0, 18.0).toDouble()),
                      _ApplicationSteps(ui: ui, cs: cs, isDark: isDark),
                      SizedBox(height: ui.gap(44).clamp(38.0, 50.0).toDouble()),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: EdgeInsets.all(ui.inset(16).clamp(14.0, 18.0).toDouble()),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            border: Border(
              top: BorderSide(
                color: cs.onSurface.withOpacity(0.08),
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                margin: EdgeInsets.only(
                  bottom: ui.gap(12).clamp(10.0, 14.0).toDouble(),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: ui.inset(12).clamp(10.0, 14.0).toDouble(),
                  vertical: ui.inset(10).clamp(9.0, 12.0).toDouble(),
                ),
                decoration: BoxDecoration(
                  color: _applicationStatusColor(cs).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(
                    ui.radius(14).clamp(12.0, 16.0).toDouble(),
                  ),
                  border: Border.all(
                    color: _applicationStatusColor(cs).withOpacity(0.18),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: ui.inset(34).clamp(30.0, 36.0).toDouble(),
                      height: ui.inset(34).clamp(30.0, 36.0).toDouble(),
                      decoration: BoxDecoration(
                        color: _applicationStatusColor(cs).withOpacity(0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _applicationButtonIcon,
                        size: ui.icon(17).clamp(16.0, 18.0).toDouble(),
                        color: _applicationStatusColor(cs),
                      ),
                    ),
                    SizedBox(width: ui.gap(10).clamp(8.0, 12.0).toDouble()),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _applicationButtonLabel,
                            style: TextStyle(
                              fontSize: ui.font(12.6).clamp(12.0, 13.4).toDouble(),
                              fontWeight: FontWeight.w900,
                              color: cs.onSurface,
                            ),
                          ),
                          SizedBox(height: ui.gap(4).clamp(2.0, 6.0).toDouble()),
                          Text(
                            _applicationStatusCaption,
                            style: TextStyle(
                              fontSize: ui.font(10.8).clamp(10.3, 11.4).toDouble(),
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface.withOpacity(0.68),
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: double.infinity,
                height: ui.buttonHeight,
                child: ElevatedButton.icon(
                  onPressed: _canTriggerApplicationFlow
                      ? () {
                    HapticFeedback.mediumImpact();
                    _showApplicationModal(context, ui, cs);
                  }
                      : null,
                  icon: Icon(_applicationButtonIcon, size: ui.icon(18)),
                  label: Text(
                    _applicationButtonLabel,
                    style: TextStyle(
                      fontSize: ui.font(14).clamp(13.0, 15.0).toDouble(),
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.2,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    backgroundColor: _applicationLocked
                        ? _applicationStatusColor(cs)
                        : AppColors.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _applicationLocked
                        ? _applicationStatusColor(cs).withOpacity(0.90)
                        : cs.onSurface.withOpacity(0.16),
                    disabledForegroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        ui.radius(14).clamp(12.0, 16.0).toDouble(),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showApplicationModal(
      BuildContext context,
      UIScale ui,
      ColorScheme cs,
      ) async {
    if (!_canOpenApplicationModal) {
      showToastNotification(
        context: context,
        title: 'Account details unavailable',
        message: _isFetchingAccount
            ? 'Your account is still syncing. Please try again in a moment.'
            : 'We could not load your legal name and email from your profile.',
        isSuccess: false,
      );
      return;
    }

    if (_applicationLocked) {
      showToastNotification(
        context: context,
        title: _applicationStatus == 'activated'
            ? 'Driver already activated'
            : 'Application pending',
        message: _applicationStatusCaption,
        isSuccess: false,
      );
      return;
    }

    final didSubmit = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ApplicationModal(
        ui: ui,
        cs: cs,
        legalFullName: _accountFullName,
        email: _accountEmail,
        initialPhone: _accountPhone,
      ),
    );

    if (didSubmit == true && mounted) {
      await _fetchApplicationStatus(silent: false);
    }
  }
}

class _HeaderBackButton extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;

  const _HeaderBackButton({
    required this.ui,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    final radius = ui.radius(14).clamp(12.0, 16.0).toDouble();

    return Padding(
      padding: EdgeInsets.only(
        left: ui.gap(10).clamp(8.0, 12.0).toDouble(),
        top: ui.gap(6).clamp(4.0, 8.0).toDouble(),
        bottom: ui.gap(6).clamp(4.0, 8.0).toDouble(),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: () {
            HapticFeedback.selectionClick();
            Navigator.of(context).maybePop();
          },
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: cs.onSurface.withOpacity(0.10),
              ),
              color: cs.surface.withOpacity(0.72),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: SizedBox(
                  width: ui.inset(42).clamp(40.0, 46.0).toDouble(),
                  height: ui.inset(42).clamp(40.0, 46.0).toDouble(),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: ui.icon(18).clamp(16.0, 19.0).toDouble(),
                    color: cs.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderTitle extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;

  const _HeaderTitle({
    required this.ui,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScaleFactorOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final tightWidth = constraints.maxWidth < 230;
        final showSubtitle = !tightWidth && textScale <= 1.15;

        return Padding(
          padding: EdgeInsets.only(
            right: ui.screenPadding.right.clamp(12.0, 20.0).toDouble(),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: kToolbarHeight - 8,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Join the Movement',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: (tightWidth
                          ? ui.font(14.5).clamp(13.0, 15.0)
                          : ui.font(16).clamp(14.5, 17.0))
                          .toDouble(),
                      fontWeight: FontWeight.w900,
                      color: cs.onSurface,
                      letterSpacing: -0.3,
                      height: 1.0,
                    ),
                  ),
                  if (showSubtitle) ...[
                    SizedBox(height: ui.gap(2).clamp(1.0, 3.0).toDouble()),
                    Text(
                      'Become a PickMe driver',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: TextStyle(
                        fontSize:
                        ui.font(10.8).clamp(10.0, 11.2).toDouble(),
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface.withOpacity(0.62),
                        height: 1.0,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HeroSection extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final bool isDark;

  const _HeroSection({
    required this.ui,
    required this.cs,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final radius = ui.radius(24).clamp(20.0, 28.0).toDouble();

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(ui.inset(18).clamp(16.0, 22.0).toDouble()),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
            AppColors.primary.withOpacity(0.18),
            AppColors.secondary.withOpacity(0.12),
          ]
              : [
            AppColors.primary.withOpacity(0.10),
            AppColors.secondary.withOpacity(0.07),
          ],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: AppColors.primary.withOpacity(0.12),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HeroBadge(ui: ui, cs: cs),
          SizedBox(height: ui.gap(14).clamp(12.0, 18.0).toDouble()),
          Text(
            'Drive smarter.\nEarn faster.',
            style: TextStyle(
              fontSize: ui.font(ui.compact ? 26 : 30).clamp(24.0, 32.0).toDouble(),
              fontWeight: FontWeight.w900,
              height: 1.0,
              letterSpacing: -0.9,
              color: cs.onSurface,
            ),
          ),
          SizedBox(height: ui.gap(10).clamp(8.0, 12.0).toDouble()),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: ui.compact ? double.infinity : 560,
            ),
            child: Text(
              'Build flexible income with premium rider demand, fast payouts, and a guided onboarding experience designed to get you on the road quickly.',
              style: TextStyle(
                fontSize: ui.font(13).clamp(12.0, 14.0).toDouble(),
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withOpacity(0.72),
                height: 1.45,
              ),
            ),
          ),
          SizedBox(height: ui.gap(16).clamp(12.0, 18.0).toDouble()),
          Wrap(
            spacing: ui.gap(12).clamp(10.0, 14.0).toDouble(),
            runSpacing: ui.gap(12).clamp(10.0, 14.0).toDouble(),
            children: [
              SizedBox(
                width: ui.compact
                    ? double.infinity
                    : math.min(260, ui.width * 0.38),
                child: _HeroMetricCard(
                  ui: ui,
                  cs: cs,
                  title: 'Average Daily',
                  value: '₦12,500',
                  icon: Icons.payments_rounded,
                ),
              ),
              SizedBox(
                width: ui.compact
                    ? double.infinity
                    : math.min(260, ui.width * 0.38),
                child: _HeroMetricCard(
                  ui: ui,
                  cs: cs,
                  title: 'Activation',
                  value: '24–48 hrs',
                  icon: Icons.flash_on_rounded,
                ),
              ),
            ],
          ),
          SizedBox(height: ui.gap(14).clamp(12.0, 16.0).toDouble()),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(ui.inset(14).clamp(12.0, 16.0).toDouble()),
            decoration: BoxDecoration(
              color: cs.surface.withOpacity(isDark ? 0.72 : 0.92),
              borderRadius: BorderRadius.circular(
                ui.radius(18).clamp(16.0, 20.0).toDouble(),
              ),
              border: Border.all(
                color: AppColors.primary.withOpacity(0.14),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: ui.inset(46).clamp(42.0, 50.0).toDouble(),
                  height: ui.inset(46).clamp(42.0, 50.0).toDouble(),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      ui.radius(14).clamp(12.0, 16.0).toDouble(),
                    ),
                    color: AppColors.primary.withOpacity(0.12),
                  ),
                  child: Icon(
                    Icons.directions_car_rounded,
                    size: ui.icon(22).clamp(20.0, 24.0).toDouble(),
                    color: AppColors.primary,
                  ),
                ),
                SizedBox(width: ui.gap(12).clamp(10.0, 14.0).toDouble()),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Premium onboarding experience',
                        style: TextStyle(
                          fontSize: ui.font(12.5).clamp(12.0, 13.5).toDouble(),
                          fontWeight: FontWeight.w900,
                          color: cs.onSurface,
                        ),
                      ),
                      SizedBox(height: ui.gap(4).clamp(2.0, 6.0).toDouble()),
                      Text(
                        'Clean verification, guided setup, and faster go-live.',
                        style: TextStyle(
                          fontSize: ui.font(11.2).clamp(10.8, 11.8).toDouble(),
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface.withOpacity(0.66),
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroBadge extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;

  const _HeroBadge({
    required this.ui,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(12).clamp(10.0, 14.0).toDouble(),
        vertical: ui.inset(8).clamp(7.0, 9.0).toDouble(),
      ),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppColors.primary.withOpacity(0.18),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.workspace_premium_rounded,
            size: ui.icon(16).clamp(15.0, 17.0).toDouble(),
            color: AppColors.primary,
          ),
          SizedBox(width: ui.gap(6).clamp(4.0, 8.0).toDouble()),
          Text(
            'Driver onboarding',
            style: TextStyle(
              fontSize: ui.font(11).clamp(10.5, 11.5).toDouble(),
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroMetricCard extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final String title;
  final String value;
  final IconData icon;

  const _HeroMetricCard({
    required this.ui,
    required this.cs,
    required this.title,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(ui.inset(14).clamp(12.0, 16.0).toDouble()),
      decoration: BoxDecoration(
        color: cs.surface.withOpacity(0.84),
        borderRadius: BorderRadius.circular(
          ui.radius(18).clamp(16.0, 20.0).toDouble(),
        ),
        border: Border.all(
          color: cs.onSurface.withOpacity(0.08),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: ui.inset(38).clamp(36.0, 42.0).toDouble(),
            height: ui.inset(38).clamp(36.0, 42.0).toDouble(),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(
                ui.radius(12).clamp(10.0, 14.0).toDouble(),
              ),
              color: AppColors.primary.withOpacity(0.10),
            ),
            child: Icon(
              icon,
              size: ui.icon(18).clamp(17.0, 20.0).toDouble(),
              color: AppColors.primary,
            ),
          ),
          SizedBox(width: ui.gap(10).clamp(8.0, 12.0).toDouble()),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(10.8).clamp(10.3, 11.3).toDouble(),
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface.withOpacity(0.62),
                  ),
                ),
                SizedBox(height: ui.gap(3).clamp(2.0, 4.0).toDouble()),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(15.5).clamp(14.5, 17.0).toDouble(),
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final String title;
  final IconData icon;

  const _SectionHeader({
    required this.ui,
    required this.cs,
    required this.title,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: ui.inset(42).clamp(40.0, 46.0).toDouble(),
          height: ui.inset(42).clamp(40.0, 46.0).toDouble(),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary.withOpacity(0.12),
            border: Border.all(
              color: AppColors.primary.withOpacity(0.20),
              width: 1.4,
            ),
          ),
          child: Icon(
            icon,
            size: ui.icon(20).clamp(19.0, 22.0).toDouble(),
            color: AppColors.primary,
          ),
        ),
        SizedBox(width: ui.gap(12).clamp(10.0, 14.0).toDouble()),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: ui.font(18).clamp(16.5, 19.5).toDouble(),
              fontWeight: FontWeight.w900,
              color: cs.onSurface,
              letterSpacing: -0.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _BenefitsCarousel extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final bool isDark;
  final int selectedIndex;
  final ValueChanged<int> onTap;

  const _BenefitsCarousel({
    required this.ui,
    required this.cs,
    required this.isDark,
    required this.selectedIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const benefits = [
      (
      'Flexible Schedule',
      'Work on your own terms—mornings, nights, weekends, or only during peak demand.',
      Icons.schedule_rounded,
      Color(0xFF1E8E3E),
      ),
      (
      'Competitive Earnings',
      'Increase income with base fares, distance pricing, and peak-time surge opportunities.',
      Icons.trending_up_rounded,
      Color(0xFFB8860B),
      ),
      (
      '24/7 Support',
      'Reach a dedicated support team whenever you need help on the road.',
      Icons.support_agent_rounded,
      Color(0xFF6A5ACD),
      ),
      (
      'Instant Payouts',
      'Move earnings to your wallet faster with a frictionless payout experience.',
      Icons.payments_rounded,
      Color(0xFF1A73E8),
      ),
      (
      'Vehicle Protection',
      'Drive confidently with platform-backed insurance and safety coverage.',
      Icons.shield_rounded,
      Color(0xFFD64545),
      ),
    ];

    return Column(
      children: [
        SizedBox(
          height: ui.compact ? 214 : 246,
          child: PageView.builder(
            onPageChanged: onTap,
            itemCount: benefits.length,
            itemBuilder: (_, i) {
              final (title, desc, icon, color) = benefits[i];
              final active = i == selectedIndex;

              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: ui.gap(8).clamp(6.0, 10.0).toDouble(),
                ),
                child: AnimatedScale(
                  scale: active ? 1.0 : 0.965,
                  duration: const Duration(milliseconds: 220),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 240),
                    padding:
                    EdgeInsets.all(ui.inset(18).clamp(16.0, 20.0).toDouble()),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(
                        ui.radius(22).clamp(18.0, 24.0).toDouble(),
                      ),
                      border: Border.all(
                        color: active
                            ? color.withOpacity(0.34)
                            : cs.onSurface.withOpacity(0.08),
                        width: active ? 1.8 : 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: active
                              ? color.withOpacity(isDark ? 0.18 : 0.12)
                              : Colors.black.withOpacity(isDark ? 0.08 : 0.03),
                          blurRadius: active ? 24 : 14,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: ui.inset(50).clamp(46.0, 54.0).toDouble(),
                              height: ui.inset(50).clamp(46.0, 54.0).toDouble(),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: color.withOpacity(0.12),
                                border: Border.all(
                                  color: color.withOpacity(0.24),
                                ),
                              ),
                              child: Icon(
                                icon,
                                size: ui.icon(24).clamp(22.0, 26.0).toDouble(),
                                color: color,
                              ),
                            ),
                            const Spacer(),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 220),
                              padding: EdgeInsets.symmetric(
                                horizontal:
                                ui.inset(10).clamp(8.0, 12.0).toDouble(),
                                vertical: ui.inset(6).clamp(5.0, 7.0).toDouble(),
                              ),
                              decoration: BoxDecoration(
                                color: active
                                    ? color.withOpacity(0.10)
                                    : cs.onSurface.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                active ? 'Featured' : 'Benefit',
                                style: TextStyle(
                                  fontSize:
                                  ui.font(10.2).clamp(9.8, 10.8).toDouble(),
                                  fontWeight: FontWeight.w800,
                                  color: active
                                      ? color
                                      : cs.onSurface.withOpacity(0.52),
                                ),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(
                            height: ui.gap(14).clamp(12.0, 16.0).toDouble()),
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: ui.font(16).clamp(15.0, 17.0).toDouble(),
                            fontWeight: FontWeight.w900,
                            color: cs.onSurface,
                          ),
                        ),
                        SizedBox(height: ui.gap(8).clamp(6.0, 10.0).toDouble()),
                        Expanded(
                          child: Text(
                            desc,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize:
                              ui.font(12.1).clamp(11.6, 12.7).toDouble(),
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface.withOpacity(0.70),
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        SizedBox(height: ui.gap(12).clamp(10.0, 14.0).toDouble()),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            benefits.length,
                (i) => AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              margin: EdgeInsets.symmetric(
                horizontal: ui.gap(4).clamp(3.0, 5.0).toDouble(),
              ),
              width: (i == selectedIndex
                  ? ui.inset(22).clamp(18.0, 24.0)
                  : ui.inset(8))
                  .toDouble(),
              height: ui.inset(8).clamp(7.0, 9.0).toDouble(),
              decoration: BoxDecoration(
                color: i == selectedIndex
                    ? AppColors.primary
                    : cs.onSurface.withOpacity(0.18),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RequirementsGrid extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final bool isDark;

  const _RequirementsGrid({
    required this.ui,
    required this.cs,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    const requirements = [
      ('Valid Driver\'s License', Icons.badge_rounded, Color(0xFF1A73E8)),
      ('18 Years or Older', Icons.calendar_today_rounded, Color(0xFF1E8E3E)),
      ('Vehicle in Good Condition', Icons.directions_car_rounded, Color(0xFFB8860B)),
      ('Valid National ID', Icons.contact_mail_rounded, Color(0xFF6A5ACD)),
      ('Clean Driving Record', Icons.verified_rounded, Color(0xFFD64545)),
      ('Bank Account', Icons.account_balance_rounded, Color(0xFF00A366)),
    ];

    return GridView.count(
      crossAxisCount: ui.compact ? 2 : 3,
      crossAxisSpacing: ui.gap(12).clamp(10.0, 14.0).toDouble(),
      mainAxisSpacing: ui.gap(12).clamp(10.0, 14.0).toDouble(),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: ui.compact ? 1.03 : 1.08,
      children: requirements
          .map(
            (req) => _RequirementCard(
          ui: ui,
          cs: cs,
          title: req.$1,
          icon: req.$2,
          color: req.$3,
        ),
      )
          .toList(),
    );
  }
}

class _RequirementCard extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final String title;
  final IconData icon;
  final Color color;

  const _RequirementCard({
    required this.ui,
    required this.cs,
    required this.title,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(ui.inset(14).clamp(12.0, 16.0).toDouble()),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(
          ui.radius(18).clamp(14.0, 20.0).toDouble(),
        ),
        border: Border.all(
          color: color.withOpacity(0.20),
          width: 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: ui.inset(46).clamp(42.0, 50.0).toDouble(),
            height: ui.inset(46).clamp(42.0, 50.0).toDouble(),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withOpacity(0.10),
            ),
            child: Icon(
              icon,
              size: ui.icon(22).clamp(20.0, 24.0).toDouble(),
              color: color,
            ),
          ),
          SizedBox(height: ui.gap(10).clamp(8.0, 12.0).toDouble()),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: ui.font(11.6).clamp(11.0, 12.6).toDouble(),
              fontWeight: FontWeight.w800,
              color: cs.onSurface.withOpacity(0.88),
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

class _EarningsShowcase extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final bool isDark;

  const _EarningsShowcase({
    required this.ui,
    required this.cs,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(ui.inset(18).clamp(16.0, 20.0).toDouble()),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
            AppColors.primary.withOpacity(0.18),
            AppColors.secondary.withOpacity(0.12),
          ]
              : [
            AppColors.primary.withOpacity(0.08),
            AppColors.secondary.withOpacity(0.06),
          ],
        ),
        borderRadius: BorderRadius.circular(
          ui.radius(20).clamp(16.0, 22.0).toDouble(),
        ),
        border: Border.all(
          color: AppColors.primary.withOpacity(0.18),
          width: 1.4,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _EarningsStat(
                  ui: ui,
                  cs: cs,
                  label: 'Average Daily',
                  value: '₦12,500',
                  subtitle: '5–7 rides/day',
                ),
              ),
              SizedBox(width: ui.gap(16).clamp(12.0, 18.0).toDouble()),
              Expanded(
                child: _EarningsStat(
                  ui: ui,
                  cs: cs,
                  label: 'Monthly Potential',
                  value: '₦375,000+',
                  subtitle: 'Full-time drivers',
                ),
              ),
            ],
          ),
          SizedBox(height: ui.gap(16).clamp(12.0, 18.0).toDouble()),
          Container(
            padding: EdgeInsets.all(ui.inset(12).clamp(10.0, 14.0).toDouble()),
            decoration: BoxDecoration(
              color: cs.onSurface.withOpacity(0.04),
              borderRadius: BorderRadius.circular(
                ui.radius(12).clamp(10.0, 14.0).toDouble(),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_rounded,
                  size: ui.icon(18).clamp(17.0, 19.0).toDouble(),
                  color: AppColors.primary.withOpacity(0.80),
                ),
                SizedBox(width: ui.gap(10).clamp(8.0, 12.0).toDouble()),
                Expanded(
                  child: Text(
                    'Earnings vary by city, demand, trip volume, and peak-hour activity. Surge periods can significantly increase take-home income.',
                    style: TextStyle(
                      fontSize: ui.font(11).clamp(10.5, 11.5).toDouble(),
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface.withOpacity(0.70),
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EarningsStat extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final String label;
  final String value;
  final String subtitle;

  const _EarningsStat({
    required this.ui,
    required this.cs,
    required this.label,
    required this.value,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: ui.font(11).clamp(10.5, 11.5).toDouble(),
            fontWeight: FontWeight.w700,
            color: cs.onSurface.withOpacity(0.65),
          ),
        ),
        SizedBox(height: ui.gap(6).clamp(4.0, 8.0).toDouble()),
        Text(
          value,
          style: TextStyle(
            fontSize: ui.font(20).clamp(18.0, 22.0).toDouble(),
            fontWeight: FontWeight.w900,
            color: AppColors.primary,
            letterSpacing: -0.4,
          ),
        ),
        SizedBox(height: ui.gap(4).clamp(2.0, 6.0).toDouble()),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: ui.font(10).clamp(9.5, 10.5).toDouble(),
            fontWeight: FontWeight.w600,
            color: cs.onSurface.withOpacity(0.56),
          ),
        ),
      ],
    );
  }
}

class _TestimonialCards extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final bool isDark;

  const _TestimonialCards({
    required this.ui,
    required this.cs,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    const testimonials = [
      (
      'Chisom A.',
      '⭐⭐⭐⭐⭐',
      'Started 6 months ago as part-time, now earning ₦180k/month. Best decision ever!',
      'Full-time Driver',
      ),
      (
      'Tunde O.',
      '⭐⭐⭐⭐⭐',
      'Flexible schedule helped me balance with my main job. Extra ₦80k monthly is life-changing.',
      'Part-time Driver',
      ),
      (
      'Zainab M.',
      '⭐⭐⭐⭐⭐',
      'Customer ratings are excellent. Support team is responsive. Love driving with PickMe!',
      'Premium Driver',
      ),
    ];

    return SizedBox(
      height: ui.compact ? 216 : 246,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: testimonials.length,
        itemBuilder: (_, i) {
          final (name, rating, quote, badge) = testimonials[i];

          return Padding(
            padding: EdgeInsets.only(
              right: ui.gap(12).clamp(10.0, 14.0).toDouble(),
            ),
            child: Container(
              width: math.min(
                292,
                ui.width -
                    ui.screenPadding.left -
                    ui.screenPadding.right -
                    ui.gap(12),
              ),
              padding: EdgeInsets.all(ui.inset(16).clamp(14.0, 18.0).toDouble()),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(
                  ui.radius(18).clamp(14.0, 20.0).toDouble(),
                ),
                border: Border.all(
                  color: AppColors.secondary.withOpacity(0.20),
                  width: 1.4,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.08 : 0.04),
                    blurRadius: 16,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rating,
                    style: TextStyle(
                      fontSize: ui.font(14).clamp(13.0, 15.0).toDouble(),
                      height: 1.0,
                    ),
                  ),
                  SizedBox(height: ui.gap(10).clamp(8.0, 12.0).toDouble()),
                  Expanded(
                    child: Text(
                      quote,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: ui.font(12).clamp(11.5, 12.5).toDouble(),
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withOpacity(0.85),
                        height: 1.45,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                  SizedBox(height: ui.gap(12).clamp(10.0, 14.0).toDouble()),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: TextStyle(
                                fontSize:
                                ui.font(12).clamp(11.5, 12.5).toDouble(),
                                fontWeight: FontWeight.w900,
                                color: cs.onSurface,
                              ),
                            ),
                            SizedBox(
                                height:
                                ui.gap(3).clamp(2.0, 4.0).toDouble()),
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal:
                                ui.inset(8).clamp(7.0, 9.0).toDouble(),
                                vertical: ui.inset(5).clamp(4.0, 6.0).toDouble(),
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primary.withOpacity(0.10),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                badge,
                                style: TextStyle(
                                  fontSize:
                                  ui.font(9.8).clamp(9.3, 10.3).toDouble(),
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ApplicationSteps extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final bool isDark;

  const _ApplicationSteps({
    required this.ui,
    required this.cs,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    const steps = [
      (
      '01',
      'Create your profile',
      'Enter your personal details and upload the required identification documents.',
      '2 mins',
      'Basic setup',
      Icons.edit_note_rounded,
      Color(0xFF1A73E8),
      ),
      (
      '02',
      'Add vehicle details',
      'Submit your car information, vehicle photos, and insurance information for review.',
      '4 mins',
      'Vehicle verification',
      Icons.directions_car_filled_rounded,
      Color(0xFFB8860B),
      ),
      (
      '03',
      'Security review',
      'Your driving record and submitted details are checked to keep the platform safe.',
      'Fast review',
      'Background screening',
      Icons.verified_user_rounded,
      Color(0xFF6A5ACD),
      ),
      (
      '04',
      'Go live and drive',
      'Once approved, your account is activated and you can start receiving trip requests.',
      '24–48 hrs',
      'Activation',
      Icons.check_circle_rounded,
      Color(0xFF1E8E3E),
      ),
    ];

    return Container(
      padding: EdgeInsets.all(ui.inset(18).clamp(16.0, 20.0).toDouble()),
      decoration: BoxDecoration(
        color: cs.surface.withOpacity(isDark ? 0.72 : 0.96),
        borderRadius: BorderRadius.circular(
          ui.radius(22).clamp(18.0, 24.0).toDouble(),
        ),
        border: Border.all(
          color: AppColors.primary.withOpacity(0.12),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.08 : 0.04),
            blurRadius: 20,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: ui.gap(8).clamp(6.0, 10.0).toDouble(),
            runSpacing: ui.gap(8).clamp(6.0, 10.0).toDouble(),
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: ui.inset(10).clamp(8.0, 12.0).toDouble(),
                  vertical: ui.inset(6).clamp(5.0, 7.0).toDouble(),
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '4 simple steps',
                  style: TextStyle(
                    fontSize: ui.font(10.4).clamp(9.9, 10.9).toDouble(),
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
              ),
              Text(
                'From sign-up to activation in a clean guided flow.',
                style: TextStyle(
                  fontSize: ui.font(11.3).clamp(10.8, 11.8).toDouble(),
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface.withOpacity(0.62),
                ),
              ),
            ],
          ),
          SizedBox(height: ui.gap(18).clamp(14.0, 20.0).toDouble()),
          ...List.generate(
            steps.length,
                (i) {
              final step = steps[i];
              return _ApplicationStepTile(
                ui: ui,
                cs: cs,
                isDark: isDark,
                number: step.$1,
                title: step.$2,
                description: step.$3,
                eta: step.$4,
                tag: step.$5,
                icon: step.$6,
                color: step.$7,
                isLast: i == steps.length - 1,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ApplicationStepTile extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final bool isDark;
  final String number;
  final String title;
  final String description;
  final String eta;
  final String tag;
  final IconData icon;
  final Color color;
  final bool isLast;

  const _ApplicationStepTile({
    required this.ui,
    required this.cs,
    required this.isDark,
    required this.number,
    required this.title,
    required this.description,
    required this.eta,
    required this.tag,
    required this.icon,
    required this.color,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final railWidth = ui.inset(54).clamp(50.0, 58.0).toDouble();

    return Padding(
      padding: EdgeInsets.only(
        bottom: isLast ? 0 : ui.gap(14).clamp(12.0, 16.0).toDouble(),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: railWidth,
              child: Column(
                children: [
                  Container(
                    width: ui.inset(42).clamp(38.0, 46.0).toDouble(),
                    height: ui.inset(42).clamp(38.0, 46.0).toDouble(),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          color.withOpacity(0.18),
                          color.withOpacity(0.08),
                        ],
                      ),
                      border: Border.all(
                        color: color.withOpacity(0.32),
                        width: 1.8,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        number,
                        style: TextStyle(
                          fontSize: ui.font(12).clamp(11.5, 12.5).toDouble(),
                          fontWeight: FontWeight.w900,
                          color: color,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
                  if (!isLast) ...[
                    SizedBox(height: ui.gap(8).clamp(6.0, 10.0).toDouble()),
                    Expanded(
                      child: Container(
                        width: 2,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              color.withOpacity(0.34),
                              color.withOpacity(0.06),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(width: ui.gap(10).clamp(8.0, 12.0).toDouble()),
            Expanded(
              child: Container(
                padding: EdgeInsets.all(ui.inset(14).clamp(12.0, 16.0).toDouble()),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(
                    ui.radius(18).clamp(16.0, 20.0).toDouble(),
                  ),
                  border: Border.all(
                    color: color.withOpacity(0.18),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withOpacity(isDark ? 0.12 : 0.08),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: ui.inset(46).clamp(42.0, 50.0).toDouble(),
                          height: ui.inset(46).clamp(42.0, 50.0).toDouble(),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              ui.radius(14).clamp(12.0, 16.0).toDouble(),
                            ),
                            color: color.withOpacity(0.10),
                          ),
                          child: Icon(
                            icon,
                            size: ui.icon(22).clamp(20.0, 24.0).toDouble(),
                            color: color,
                          ),
                        ),
                        SizedBox(width: ui.gap(12).clamp(10.0, 14.0).toDouble()),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  fontSize:
                                  ui.font(14.5).clamp(13.8, 15.8).toDouble(),
                                  fontWeight: FontWeight.w900,
                                  color: cs.onSurface,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              SizedBox(
                                  height:
                                  ui.gap(4).clamp(2.0, 6.0).toDouble()),
                              Text(
                                description,
                                style: TextStyle(
                                  fontSize:
                                  ui.font(11.8).clamp(11.3, 12.4).toDouble(),
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface.withOpacity(0.68),
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: ui.gap(12).clamp(10.0, 14.0).toDouble()),
                    Wrap(
                      spacing: ui.gap(8).clamp(6.0, 10.0).toDouble(),
                      runSpacing: ui.gap(8).clamp(6.0, 10.0).toDouble(),
                      children: [
                        _StepChip(
                          ui: ui,
                          bg: color.withOpacity(0.10),
                          fg: color,
                          icon: Icons.schedule_rounded,
                          label: eta,
                        ),
                        _StepChip(
                          ui: ui,
                          bg: cs.onSurface.withOpacity(0.06),
                          fg: cs.onSurface.withOpacity(0.72),
                          icon: Icons.label_rounded,
                          label: tag,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepChip extends StatelessWidget {
  final UIScale ui;
  final Color bg;
  final Color fg;
  final IconData icon;
  final String label;

  const _StepChip({
    required this.ui,
    required this.bg,
    required this.fg,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(10).clamp(8.0, 12.0).toDouble(),
        vertical: ui.inset(6).clamp(5.0, 7.0).toDouble(),
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: ui.icon(14).clamp(13.0, 15.0).toDouble(),
            color: fg,
          ),
          SizedBox(width: ui.gap(6).clamp(4.0, 8.0).toDouble()),
          Text(
            label,
            style: TextStyle(
              fontSize: ui.font(10.2).clamp(9.8, 10.8).toDouble(),
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

enum _UploadGroup { identity, vehicle }

enum _GuideKind {
  documentFront,
  documentBack,
  carAngled3D,
  carFrontPlate,
  carBackPlate,
  carSide,
}

enum DriverUploadSlot {
  licenseFront(
    title: 'Driver License — Front',
    subtitle: 'Place the front side flat and capture all 4 corners clearly.',
    group: _UploadGroup.identity,
    guideKind: _GuideKind.documentFront,
    accent: Color(0xFF1A73E8),
    previewAspectRatio: 1.55,
  ),
  licenseBack(
    title: 'Driver License — Back',
    subtitle: 'Capture the full back side clearly with no glare or cut edges.',
    group: _UploadGroup.identity,
    guideKind: _GuideKind.documentBack,
    accent: Color(0xFF1A73E8),
    previewAspectRatio: 1.55,
  ),
  ninFront(
    title: 'National ID (NIN) — Front',
    subtitle: 'Show the full front side. Keep text readable and corners visible.',
    group: _UploadGroup.identity,
    guideKind: _GuideKind.documentFront,
    accent: Color(0xFF6A5ACD),
    previewAspectRatio: 1.55,
  ),
  ninBack(
    title: 'National ID (NIN) — Back',
    subtitle: 'Capture the back side fully and avoid blur or reflections.',
    group: _UploadGroup.identity,
    guideKind: _GuideKind.documentBack,
    accent: Color(0xFF6A5ACD),
    previewAspectRatio: 1.55,
  ),
  carAngled3D(
    title: 'Vehicle 3/4 View',
    subtitle: 'Take a 3D-looking angled shot showing front and side together.',
    group: _UploadGroup.vehicle,
    guideKind: _GuideKind.carAngled3D,
    accent: Color(0xFFB8860B),
    previewAspectRatio: 16 / 9,
  ),
  carFrontPlate(
    title: 'Vehicle Front View',
    subtitle: 'Front of the vehicle with plate number clearly visible.',
    group: _UploadGroup.vehicle,
    guideKind: _GuideKind.carFrontPlate,
    accent: Color(0xFF1E8E3E),
    previewAspectRatio: 16 / 9,
    plateRequired: true,
  ),
  carBackPlate(
    title: 'Vehicle Back View',
    subtitle: 'Rear of the vehicle with plate number clearly visible.',
    group: _UploadGroup.vehicle,
    guideKind: _GuideKind.carBackPlate,
    accent: Color(0xFFD64545),
    previewAspectRatio: 16 / 9,
    plateRequired: true,
  ),
  carSide(
    title: 'Vehicle Side View',
    subtitle: 'Capture a full side profile of the vehicle from wheel to wheel.',
    group: _UploadGroup.vehicle,
    guideKind: _GuideKind.carSide,
    accent: Color(0xFF00A366),
    previewAspectRatio: 16 / 9,
  );

  const DriverUploadSlot({
    required this.title,
    required this.subtitle,
    required this.group,
    required this.guideKind,
    required this.accent,
    required this.previewAspectRatio,
    this.plateRequired = false,
  });

  final String title;
  final String subtitle;
  final _UploadGroup group;
  final _GuideKind guideKind;
  final Color accent;
  final double previewAspectRatio;
  final bool plateRequired;
}

class _PickedUpload {
  final XFile file;
  final int sizeBytes;

  const _PickedUpload({
    required this.file,
    required this.sizeBytes,
  });
}


class _ApplicationModal extends StatefulWidget {
  final UIScale ui;
  final ColorScheme cs;
  final String legalFullName;
  final String email;
  final String initialPhone;

  const _ApplicationModal({
    required this.ui,
    required this.cs,
    required this.legalFullName,
    required this.email,
    required this.initialPhone,
  });

  @override
  State<_ApplicationModal> createState() => _ApplicationModalState();
}

class _ApplicationModalState extends State<_ApplicationModal> {
  static const Map<DriverUploadSlot, String> _uploadFieldMap = {
    DriverUploadSlot.licenseFront: 'license_front',
    DriverUploadSlot.licenseBack: 'license_back',
    DriverUploadSlot.ninFront: 'nin_front',
    DriverUploadSlot.ninBack: 'nin_back',
    DriverUploadSlot.carAngled3D: 'vehicle_angled',
    DriverUploadSlot.carFrontPlate: 'vehicle_front',
    DriverUploadSlot.carBackPlate: 'vehicle_back',
    DriverUploadSlot.carSide: 'vehicle_side',
  };

  final ImagePicker _picker = ImagePicker();
  final PageController _pageController = PageController();

  late final Map<DriverUploadSlot, _PickedUpload?> _uploads;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _ninCtrl;
  late final ApiClient _api;

  SharedPreferences? _prefs;
  int _currentStep = 0;
  bool _submitting = false;
  bool _showMissingState = false;
  bool _showAccountErrors = false;

  List<_WizardStepMeta> get _steps => const [
    _WizardStepMeta(
      title: 'Account Details',
      subtitle: 'Confirm your identity and fill the contact data used for onboarding.',
      icon: Icons.badge_rounded,
    ),
    _WizardStepMeta(
      title: 'Identity Uploads',
      subtitle: 'Upload the front and back of your driver license and NIN card.',
      icon: Icons.credit_card_rounded,
    ),
    _WizardStepMeta(
      title: 'Vehicle Uploads',
      subtitle: 'Upload the four required vehicle angles with plate visibility where needed.',
      icon: Icons.directions_car_filled_rounded,
    ),
    _WizardStepMeta(
      title: 'Review & Submit',
      subtitle: 'Review everything before sending the application to the backend.',
      icon: Icons.verified_user_rounded,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);
    _phoneCtrl = TextEditingController(text: widget.initialPhone);
    _ninCtrl = TextEditingController();
    _uploads = {for (final slot in DriverUploadSlot.values) slot: null};
    _bootstrapPrefs();
  }

  Future<void> _bootstrapPrefs() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      // Fallback handled during submit.
    }
  }

  List<DriverUploadSlot> get _identitySlots => DriverUploadSlot.values
      .where((slot) => slot.group == _UploadGroup.identity)
      .toList();

  List<DriverUploadSlot> get _vehicleSlots => DriverUploadSlot.values
      .where((slot) => slot.group == _UploadGroup.vehicle)
      .toList();

  List<DriverUploadSlot> get _missingUploads =>
      DriverUploadSlot.values.where((slot) => _uploads[slot] == null).toList();

  int get _totalUploads => DriverUploadSlot.values.length;
  int get _uploadedCount =>
      DriverUploadSlot.values.where((slot) => _uploads[slot] != null).length;

  bool get _identityComplete =>
      _identitySlots.every((slot) => _uploads[slot] != null);

  bool get _vehicleComplete =>
      _vehicleSlots.every((slot) => _uploads[slot] != null);

  bool get _allUploadsComplete => _missingUploads.isEmpty;

  double get _progress => (_currentStep + 1) / _steps.length;

  String? _validatePhone(String value) {
    final normalized = value.replaceAll(RegExp(r'[^0-9+]'), '');
    if (normalized.isEmpty) return 'Phone number is required.';
    final digits = normalized.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 10 || digits.length > 15) {
      return 'Enter a valid phone number.';
    }
    return null;
  }

  String? _validateNin(String value) {
    final normalized = value.replaceAll(' ', '').trim().toUpperCase();
    if (normalized.isEmpty) return 'NIN is required.';
    if (normalized.length < 6 || normalized.length > 64) {
      return 'Enter a valid NIN.';
    }
    return null;
  }

  void _showInlineError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  int _imageQualityFor(DriverUploadSlot slot) {
    switch (slot.group) {
      case _UploadGroup.identity:
        return 76;
      case _UploadGroup.vehicle:
        return 72;
    }
  }

  double _maxWidthFor(DriverUploadSlot slot) {
    switch (slot.group) {
      case _UploadGroup.identity:
        return 1680;
      case _UploadGroup.vehicle:
        return 1440;
    }
  }

  int _previewCacheWidthFor(DriverUploadSlot slot) {
    switch (slot.group) {
      case _UploadGroup.identity:
        return 960;
      case _UploadGroup.vehicle:
        return 1280;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    double value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    final decimals = value >= 100 || unitIndex == 0 ? 0 : 1;
    return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }

  Future<ImageSource?> _selectSource() async {
    final cs = widget.cs;

    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take Photo'),
                  subtitle: const Text('Use the camera'),
                  onTap: () => Navigator.of(context).pop(ImageSource.camera),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Choose from Gallery'),
                  subtitle: const Text('Pick an existing image'),
                  onTap: () => Navigator.of(context).pop(ImageSource.gallery),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickUpload(DriverUploadSlot slot) async {
    FocusManager.instance.primaryFocus?.unfocus();

    final source = await _selectSource();
    if (source == null) return;

    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: _imageQualityFor(slot),
        maxWidth: _maxWidthFor(slot),
        preferredCameraDevice: CameraDevice.rear,
      );

      if (picked == null) return;

      final sizeBytes = await picked.length();
      if (!mounted) return;

      setState(() {
        _uploads[slot] = _PickedUpload(file: picked, sizeBytes: sizeBytes);
      });

      HapticFeedback.selectionClick();
    } catch (_) {
      if (!mounted) return;
      _showInlineError('Unable to load this image. Please try again.');
    }
  }

  void _removeUpload(DriverUploadSlot slot) {
    setState(() {
      _uploads[slot] = null;
    });
    HapticFeedback.lightImpact();
  }

  Future<void> _goToStep(int step) async {
    if (!mounted) return;
    setState(() => _currentStep = step);
    await _pageController.animateToPage(
      step,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _nextStep() async {
    FocusManager.instance.primaryFocus?.unfocus();

    if (_currentStep == 0) {
      setState(() => _showAccountErrors = true);
      final phoneError = _validatePhone(_phoneCtrl.text.trim());
      if (phoneError != null) {
        _showInlineError(phoneError);
        return;
      }

      final ninError = _validateNin(_ninCtrl.text.trim());
      if (ninError != null) {
        _showInlineError(ninError);
        return;
      }
    }

    if (_currentStep == 1 && !_identityComplete) {
      setState(() => _showMissingState = true);
      _showInlineError('Upload all 4 identity images to continue.');
      return;
    }

    if (_currentStep == 2 && !_vehicleComplete) {
      setState(() => _showMissingState = true);
      _showInlineError('Upload all 4 vehicle images to continue.');
      return;
    }

    if (_currentStep >= _steps.length - 1) {
      await _submit();
      return;
    }

    await _goToStep(_currentStep + 1);
  }

  Future<void> _backStep() async {
    if (_currentStep == 0) {
      Navigator.of(context).maybePop();
      return;
    }
    await _goToStep(_currentStep - 1);
  }

  Future<void> _submit() async {
    FocusManager.instance.primaryFocus?.unfocus();

    final phone = _phoneCtrl.text.trim();
    final nin = _ninCtrl.text.trim().toUpperCase();

    final phoneError = _validatePhone(phone);
    if (phoneError != null) {
      _showInlineError(phoneError);
      await _goToStep(0);
      return;
    }

    final ninError = _validateNin(nin);
    if (ninError != null) {
      _showInlineError(ninError);
      await _goToStep(0);
      return;
    }

    if (!_allUploadsComplete) {
      setState(() => _showMissingState = true);
      _showInlineError('Please complete all required uploads before submitting.');
      await _goToStep(!_identityComplete ? 1 : 2);
      return;
    }

    setState(() => _submitting = true);
    HapticFeedback.heavyImpact();

    try {
      _prefs ??= await SharedPreferences.getInstance();
      final uid = _prefs?.getString('user_id')?.trim() ?? '';
      if (uid.isEmpty) {
        throw Exception('User ID missing');
      }

      final files = <String, File>{};
      for (final entry in _uploadFieldMap.entries) {
        final picked = _uploads[entry.key];
        if (picked != null) {
          files[entry.value] = File(picked.file.path);
        }
      }

      final res = await _api.request(
        ApiConstants.upgradeToDriverEndpoint,
        method: 'POST',
        data: {
          'action': 'submit',
          'user': uid,
          'legal_full_name': widget.legalFullName,
          'email': widget.email,
          'phone': phone,
          'nin': nin,
        },
        files: files,
      );

      final body = jsonDecode(res.body);
      if (!mounted) return;

      if (res.statusCode == 200 && body is Map && body['error'] == false) {
        showToastNotification(
          context: context,
          title: 'Success',
          message: (body['message'] ?? 'Driver application submitted successfully.')
              .toString(),
          isSuccess: true,
        );
        Navigator.of(context).pop(true);
      } else {
        throw Exception(
          (body is Map ? (body['message'] ?? body['error_msg']) : null) ??
              'Unable to submit driver application.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      showToastNotification(
        context: context,
        title: 'Submission Failed',
        message: e.toString().replaceFirst('Exception: ', ''),
        isSuccess: false,
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _phoneCtrl.dispose();
    _ninCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui = widget.ui;
    final cs = widget.cs;
    final isDark = cs.brightness == Brightness.dark;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.95,
        minChildSize: 0.72,
        maxChildSize: 0.98,
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(
                  ui.radius(28).clamp(24.0, 32.0).toDouble(),
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? 0.28 : 0.10),
                  blurRadius: 26,
                  offset: const Offset(0, -8),
                ),
              ],
            ),
            child: Column(
              children: [
                SizedBox(height: ui.gap(10).clamp(8.0, 12.0).toDouble()),
                Container(
                  width: 48,
                  height: 5,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    ui.inset(18).clamp(16.0, 22.0).toDouble(),
                    ui.gap(14).clamp(12.0, 16.0).toDouble(),
                    ui.inset(18).clamp(16.0, 22.0).toDouble(),
                    ui.gap(8).clamp(6.0, 10.0).toDouble(),
                  ),
                  child: _WizardHeader(
                    ui: ui,
                    cs: cs,
                    currentStep: _currentStep,
                    progress: _progress,
                    steps: _steps,
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _buildProfileStep(ui, cs),
                      _buildUploadStep(
                        ui: ui,
                        cs: cs,
                        title: 'Identity Verification',
                        subtitle: 'Upload the front and back of your driver license and NIN card.',
                        slots: _identitySlots,
                        accent: const Color(0xFF1A73E8),
                      ),
                      _buildUploadStep(
                        ui: ui,
                        cs: cs,
                        title: 'Vehicle Capture',
                        subtitle: 'Upload the required vehicle angles. Plate must be readable on front and back shots.',
                        slots: _vehicleSlots,
                        accent: const Color(0xFF1E8E3E),
                      ),
                      _buildReviewStep(ui, cs),
                    ],
                  ),
                ),
                Container(
                  padding: EdgeInsets.fromLTRB(
                    ui.inset(16).clamp(14.0, 18.0).toDouble(),
                    ui.gap(10).clamp(8.0, 12.0).toDouble(),
                    ui.inset(16).clamp(14.0, 18.0).toDouble(),
                    ui.gap(14).clamp(12.0, 16.0).toDouble(),
                  ),
                  decoration: BoxDecoration(
                    color: cs.surface,
                    border: Border(
                      top: BorderSide(color: cs.onSurface.withOpacity(0.08)),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _submitting ? null : _backStep,
                              icon: Icon(
                                _currentStep == 0
                                    ? Icons.close_rounded
                                    : Icons.arrow_back_rounded,
                                size: ui.icon(18),
                              ),
                              label: Text(_currentStep == 0 ? 'Cancel' : 'Back'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: Size(0, ui.buttonHeight),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    ui.radius(14).clamp(12.0, 16.0).toDouble(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: ui.gap(12).clamp(10.0, 14.0).toDouble()),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton.icon(
                              onPressed: _submitting ? null : _nextStep,
                              icon: _submitting
                                  ? SizedBox(
                                width: ui.icon(18),
                                height: ui.icon(18),
                                child: const CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              )
                                  : Icon(
                                _currentStep == _steps.length - 1
                                    ? Icons.cloud_upload_rounded
                                    : Icons.arrow_forward_rounded,
                                size: ui.icon(18),
                              ),
                              label: Text(
                                _currentStep == _steps.length - 1
                                    ? 'Submit Application'
                                    : 'Next',
                              ),
                              style: ElevatedButton.styleFrom(
                                minimumSize: Size(0, ui.buttonHeight),
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    ui.radius(14).clamp(12.0, 16.0).toDouble(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: ui.gap(8).clamp(6.0, 10.0).toDouble()),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _currentStep == _steps.length - 1
                              ? 'Review complete. Submit once. Pending and activated users cannot upload again.'
                              : 'Step ${_currentStep + 1} of ${_steps.length}',
                          style: TextStyle(
                            fontSize: ui.font(10.8).clamp(10.3, 11.4).toDouble(),
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface.withOpacity(0.62),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildProfileStep(UIScale ui, ColorScheme cs) {
    final phoneError = _showAccountErrors ? _validatePhone(_phoneCtrl.text.trim()) : null;
    final ninError = _showAccountErrors ? _validateNin(_ninCtrl.text.trim()) : null;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        ui.inset(18).clamp(16.0, 22.0).toDouble(),
        ui.gap(8).clamp(6.0, 10.0).toDouble(),
        ui.inset(18).clamp(16.0, 22.0).toDouble(),
        ui.gap(16).clamp(14.0, 18.0).toDouble(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _WizardIntroCard(
            ui: ui,
            cs: cs,
            icon: Icons.badge_rounded,
            title: 'Step 1 — Account & Contact',
            subtitle:
            'Your full name and email address are automatically pulled from your account. Please enter the phone number and National Identification Number (NIN) you wish to use for your driver application.\n'
                '\nImportant: The name registered to your NIN must exactly match the full name on your account. If the names do not match, your application will be rejected.',
          ),
          SizedBox(height: ui.gap(14).clamp(12.0, 16.0).toDouble()),
          _LockedProfileField(
            ui: ui,
            cs: cs,
            label: 'Legal Full Name',
            value: widget.legalFullName,
            icon: Icons.person_outline_rounded,
          ),
          SizedBox(height: ui.gap(12).clamp(10.0, 14.0).toDouble()),
          _LockedProfileField(
            ui: ui,
            cs: cs,
            label: 'Email Address',
            value: widget.email,
            icon: Icons.email_outlined,
          ),
          SizedBox(height: ui.gap(12).clamp(10.0, 14.0).toDouble()),
          _WizardInputField(
            ui: ui,
            cs: cs,
            controller: _phoneCtrl,
            label: 'Phone Number',
            hint: 'e.g. 08031234567',
            icon: Icons.phone_rounded,
            keyboardType: TextInputType.phone,
            errorText: phoneError,
          ),
          SizedBox(height: ui.gap(12).clamp(10.0, 14.0).toDouble()),
          _WizardInputField(
            ui: ui,
            cs: cs,
            controller: _ninCtrl,
            label: 'National Identification Number (NIN)',
            hint: 'Enter your NIN',
            icon: Icons.perm_identity_rounded,
            textCapitalization: TextCapitalization.characters,
            errorText: ninError,
          ),
          SizedBox(height: ui.gap(16).clamp(14.0, 18.0).toDouble()),
          _ChecklistBox(
            ui: ui,
            cs: cs,
            title: 'Before you continue',
            items: const [
              'Use a reachable phone number.',
              'Use the NIN that matches your uploaded ID.',
              'All 8 uploads are still required in the next steps.',
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUploadStep({
    required UIScale ui,
    required ColorScheme cs,
    required String title,
    required String subtitle,
    required List<DriverUploadSlot> slots,
    required Color accent,
  }) {
    final completed = slots.where((slot) => _uploads[slot] != null).length;
    final total = slots.length;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        ui.inset(18).clamp(16.0, 22.0).toDouble(),
        ui.gap(8).clamp(6.0, 10.0).toDouble(),
        ui.inset(18).clamp(16.0, 22.0).toDouble(),
        ui.gap(16).clamp(14.0, 18.0).toDouble(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _WizardIntroCard(
            ui: ui,
            cs: cs,
            icon: _currentStep == 1
                ? Icons.credit_card_rounded
                : Icons.directions_car_filled_rounded,
            title: title,
            subtitle: subtitle,
            trailing: _CompactStatPill(
              ui: ui,
              bg: accent.withOpacity(0.10),
              fg: accent,
              label: '$completed / $total uploaded',
            ),
          ),
          SizedBox(height: ui.gap(14).clamp(12.0, 16.0).toDouble()),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: slots.length,
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: ui.width > 680 ? 320 : 420,
              mainAxisSpacing: ui.gap(12).clamp(10.0, 14.0).toDouble(),
              crossAxisSpacing: ui.gap(12).clamp(10.0, 14.0).toDouble(),
              childAspectRatio: ui.width > 680 ? 0.96 : 1.18,
            ),
            itemBuilder: (context, index) {
              final slot = slots[index];
              return _WizardUploadTile(
                ui: ui,
                cs: cs,
                slot: slot,
                upload: _uploads[slot],
                highlightMissing: _showMissingState && _uploads[slot] == null,
                onPick: () => _pickUpload(slot),
                onRemove: () => _removeUpload(slot),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildReviewStep(UIScale ui, ColorScheme cs) {
    final phone = _phoneCtrl.text.trim();
    final nin = _ninCtrl.text.trim().toUpperCase();

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        ui.inset(18).clamp(16.0, 22.0).toDouble(),
        ui.gap(8).clamp(6.0, 10.0).toDouble(),
        ui.inset(18).clamp(16.0, 22.0).toDouble(),
        ui.gap(16).clamp(14.0, 18.0).toDouble(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _WizardIntroCard(
            ui: ui,
            cs: cs,
            icon: Icons.verified_user_rounded,
            title: 'Step 4 — Review & Submit',
            subtitle:
            'Confirm the data below. When you submit, the onboarding record is sent to the backend and the page status becomes pending.',
          ),
          SizedBox(height: ui.gap(14).clamp(12.0, 16.0).toDouble()),
          _ReviewSummaryCard(
            ui: ui,
            cs: cs,
            fullName: widget.legalFullName,
            email: widget.email,
            phone: phone.isEmpty ? '—' : phone,
            nin: nin.isEmpty ? '—' : nin,
            uploadedCount: _uploadedCount,
            totalUploads: _totalUploads,
          ),
          SizedBox(height: ui.gap(14).clamp(12.0, 16.0).toDouble()),
          _ChecklistBox(
            ui: ui,
            cs: cs,
            title: 'Submission checklist',
            items: [
              'Name is pulled from your account profile.',
              'Email is pulled from your account profile.',
              'Phone number is ready: ${phone.isEmpty ? 'No' : 'Yes'}',
              'NIN is ready: ${nin.isEmpty ? 'No' : 'Yes'}',
              'Identity uploads complete: ${_identityComplete ? 'Yes' : 'No'}',
              'Vehicle uploads complete: ${_vehicleComplete ? 'Yes' : 'No'}',
            ],
          ),
        ],
      ),
    );
  }

}

class _WizardStepMeta {
  final String title;
  final String subtitle;
  final IconData icon;

  const _WizardStepMeta({
    required this.title,
    required this.subtitle,
    required this.icon,
  });
}

class _WizardHeader extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final int currentStep;
  final double progress;
  final List<_WizardStepMeta> steps;

  const _WizardHeader({
    required this.ui,
    required this.cs,
    required this.currentStep,
    required this.progress,
    required this.steps,
  });

  @override
  Widget build(BuildContext context) {
    final current = steps[currentStep];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Driver Onboarding',
                style: TextStyle(
                  fontSize: ui.font(20).clamp(18.0, 22.0).toDouble(),
                  fontWeight: FontWeight.w900,
                  color: cs.onSurface,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded),
              label: const Text('Close'),
            ),
          ],
        ),
        Text(
          'Step ${currentStep + 1} of ${steps.length} · ${current.title}',
          style: TextStyle(
            fontSize: ui.font(11.6).clamp(11.0, 12.2).toDouble(),
            fontWeight: FontWeight.w700,
            color: cs.onSurface.withOpacity(0.64),
          ),
        ),
        SizedBox(height: ui.gap(10).clamp(8.0, 12.0).toDouble()),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: cs.onSurface.withOpacity(0.08),
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
          ),
        ),
        SizedBox(height: ui.gap(12).clamp(10.0, 14.0).toDouble()),
        Row(
          children: List.generate(steps.length, (index) {
            final active = index <= currentStep;
            return Expanded(
              child: Container(
                margin: EdgeInsets.only(
                  right: index == steps.length - 1 ? 0 : ui.gap(8).clamp(6.0, 10.0).toDouble(),
                ),
                padding: EdgeInsets.symmetric(
                  vertical: ui.inset(8).clamp(7.0, 9.0).toDouble(),
                ),
                decoration: BoxDecoration(
                  color: active
                      ? AppColors.primary.withOpacity(index == currentStep ? 0.14 : 0.08)
                      : cs.onSurface.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: active
                        ? AppColors.primary.withOpacity(0.20)
                        : cs.onSurface.withOpacity(0.08),
                  ),
                ),
                child: Center(
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontSize: ui.font(11.2).clamp(10.6, 11.8).toDouble(),
                      fontWeight: FontWeight.w900,
                      color: active ? AppColors.primary : cs.onSurface.withOpacity(0.44),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}

class _WizardIntroCard extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _WizardIntroCard({
    required this.ui,
    required this.cs,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(ui.inset(14).clamp(12.0, 16.0).toDouble()),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(
          ui.radius(18).clamp(16.0, 20.0).toDouble(),
        ),
        border: Border.all(
          color: AppColors.primary.withOpacity(0.12),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: ui.inset(42).clamp(38.0, 46.0).toDouble(),
            height: ui.inset(42).clamp(38.0, 46.0).toDouble(),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(
                ui.radius(14).clamp(12.0, 16.0).toDouble(),
              ),
            ),
            child: Icon(
              icon,
              color: AppColors.primary,
              size: ui.icon(22).clamp(20.0, 24.0).toDouble(),
            ),
          ),
          SizedBox(width: ui.gap(12).clamp(10.0, 14.0).toDouble()),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: ui.font(14.2).clamp(13.4, 15.2).toDouble(),
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface,
                  ),
                ),
                SizedBox(height: ui.gap(4).clamp(2.0, 6.0).toDouble()),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: ui.font(11.4).clamp(10.9, 12.0).toDouble(),
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.68),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            SizedBox(width: ui.gap(10).clamp(8.0, 12.0).toDouble()),
            trailing!,
          ],
        ],
      ),
    );
  }
}


class _LockedProfileField extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final String label;
  final String value;
  final IconData icon;

  const _LockedProfileField({
    required this.ui,
    required this.cs,
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(ui.inset(14).clamp(12.0, 16.0).toDouble()),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(
          ui.radius(16).clamp(14.0, 18.0).toDouble(),
        ),
        border: Border.all(color: cs.onSurface.withOpacity(0.10)),
      ),
      child: Row(
        children: [
          Container(
            width: ui.inset(40).clamp(36.0, 44.0).toDouble(),
            height: ui.inset(40).clamp(36.0, 44.0).toDouble(),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.10),
              borderRadius: BorderRadius.circular(
                ui.radius(12).clamp(10.0, 14.0).toDouble(),
              ),
            ),
            child: Icon(
              icon,
              color: AppColors.primary,
              size: ui.icon(20).clamp(18.0, 22.0).toDouble(),
            ),
          ),
          SizedBox(width: ui.gap(12).clamp(10.0, 14.0).toDouble()),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: ui.font(11.0).clamp(10.5, 11.5).toDouble(),
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface.withOpacity(0.58),
                  ),
                ),
                SizedBox(height: ui.gap(4).clamp(2.0, 6.0).toDouble()),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: ui.font(13.0).clamp(12.4, 13.8).toDouble(),
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: ui.inset(10).clamp(8.0, 12.0).toDouble(),
              vertical: ui.inset(6).clamp(5.0, 7.0).toDouble(),
            ),
            decoration: BoxDecoration(
              color: cs.onSurface.withOpacity(0.06),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'Locked',
              style: TextStyle(
                fontSize: ui.font(9.8).clamp(9.2, 10.3).toDouble(),
                fontWeight: FontWeight.w900,
                color: cs.onSurface.withOpacity(0.60),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WizardInputField extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final String? errorText;

  const _WizardInputField({
    required this.ui,
    required this.cs,
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: errorText,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: cs.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(
            ui.radius(16).clamp(14.0, 18.0).toDouble(),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(
            ui.radius(16).clamp(14.0, 18.0).toDouble(),
          ),
          borderSide: BorderSide(color: cs.onSurface.withOpacity(0.10)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(
            ui.radius(16).clamp(14.0, 18.0).toDouble(),
          ),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
        ),
      ),
    );
  }
}

int _wizardPreviewCacheWidthFor(DriverUploadSlot slot) {
  switch (slot.group) {
    case _UploadGroup.identity:
      return 960;
    case _UploadGroup.vehicle:
      return 1280;
  }
}

String _wizardFormatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  double value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final decimals = value >= 100 || unitIndex == 0 ? 0 : 1;
  return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
}

class _WizardUploadTile extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final DriverUploadSlot slot;
  final _PickedUpload? upload;
  final bool highlightMissing;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  const _WizardUploadTile({
    required this.ui,
    required this.cs,
    required this.slot,
    required this.upload,
    required this.highlightMissing,
    required this.onPick,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final uploaded = upload != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPick,
        borderRadius: BorderRadius.circular(
          ui.radius(18).clamp(16.0, 20.0).toDouble(),
        ),
        child: Ink(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(
              ui.radius(18).clamp(16.0, 20.0).toDouble(),
            ),
            border: Border.all(
              color: highlightMissing
                  ? AppColors.error.withOpacity(0.46)
                  : (uploaded
                  ? slot.accent.withOpacity(0.28)
                  : cs.onSurface.withOpacity(0.10)),
              width: highlightMissing ? 1.6 : 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.03),
                blurRadius: 12,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(ui.inset(12).clamp(10.0, 14.0).toDouble()),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: ui.inset(38).clamp(34.0, 42.0).toDouble(),
                      height: ui.inset(38).clamp(34.0, 42.0).toDouble(),
                      decoration: BoxDecoration(
                        color: slot.accent.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(
                          ui.radius(12).clamp(10.0, 14.0).toDouble(),
                        ),
                      ),
                      child: Icon(
                        uploaded ? Icons.check_rounded : Icons.upload_file_rounded,
                        color: slot.accent,
                        size: ui.icon(20).clamp(18.0, 22.0).toDouble(),
                      ),
                    ),
                    const Spacer(),
                    if (uploaded)
                      IconButton(
                        onPressed: onRemove,
                        icon: const Icon(Icons.delete_outline_rounded),
                        tooltip: 'Remove',
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                SizedBox(height: ui.gap(10).clamp(8.0, 12.0).toDouble()),
                Text(
                  slot.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(12.6).clamp(12.0, 13.4).toDouble(),
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface,
                  ),
                ),
                SizedBox(height: ui.gap(4).clamp(2.0, 6.0).toDouble()),
                Text(
                  slot.subtitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(10.8).clamp(10.2, 11.4).toDouble(),
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.64),
                    height: 1.35,
                  ),
                ),
                SizedBox(height: ui.gap(10).clamp(8.0, 12.0).toDouble()),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      ui.radius(14).clamp(12.0, 16.0).toDouble(),
                    ),
                    child: Container(
                      width: double.infinity,
                      color: slot.accent.withOpacity(0.08),
                      child: uploaded
                          ? Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(
                            File(upload!.file.path),
                            fit: BoxFit.cover,
                            cacheWidth: _wizardPreviewCacheWidthFor(slot),
                            filterQuality: FilterQuality.low,
                            gaplessPlayback: true,
                          ),
                          Positioned(
                            right: 8,
                            bottom: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.58),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                _wizardFormatBytes(upload!.sizeBytes),
                                style: TextStyle(
                                  fontSize: ui.font(9.8).clamp(9.2, 10.4).toDouble(),
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                          : Center(
                        child: Text(
                          'Tap to upload',
                          style: TextStyle(
                            fontSize: ui.font(11.2).clamp(10.6, 11.8).toDouble(),
                            fontWeight: FontWeight.w800,
                            color: slot.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: ui.gap(10).clamp(8.0, 12.0).toDouble()),
                _CompactStatPill(
                  ui: ui,
                  bg: uploaded
                      ? slot.accent.withOpacity(0.10)
                      : cs.onSurface.withOpacity(0.06),
                  fg: uploaded ? slot.accent : cs.onSurface.withOpacity(0.58),
                  label: uploaded ? 'Uploaded' : 'Required',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReviewSummaryCard extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final String fullName;
  final String email;
  final String phone;
  final String nin;
  final int uploadedCount;
  final int totalUploads;

  const _ReviewSummaryCard({
    required this.ui,
    required this.cs,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.nin,
    required this.uploadedCount,
    required this.totalUploads,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(ui.inset(14).clamp(12.0, 16.0).toDouble()),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(
          ui.radius(18).clamp(16.0, 20.0).toDouble(),
        ),
        border: Border.all(color: cs.onSurface.withOpacity(0.10)),
      ),
      child: Column(
        children: [
          _ReviewRow(label: 'Legal Full Name', value: fullName),
          _ReviewRow(label: 'Email', value: email),
          _ReviewRow(label: 'Phone', value: phone),
          _ReviewRow(label: 'NIN', value: nin),
          _ReviewRow(label: 'Uploads', value: '$uploadedCount / $totalUploads complete', isLast: true),
        ],
      ),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isLast;

  const _ReviewRow({
    required this.label,
    required this.value,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12, top: 4),
      margin: EdgeInsets.only(bottom: isLast ? 0 : 10),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
          bottom: BorderSide(color: cs.onSurface.withOpacity(0.08)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: cs.onSurface.withOpacity(0.62),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 6,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChecklistBox extends StatelessWidget {
  final UIScale ui;
  final ColorScheme cs;
  final String title;
  final List<String> items;

  const _ChecklistBox({
    required this.ui,
    required this.cs,
    required this.title,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(ui.inset(14).clamp(12.0, 16.0).toDouble()),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(
          ui.radius(18).clamp(16.0, 20.0).toDouble(),
        ),
        border: Border.all(color: cs.onSurface.withOpacity(0.10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: ui.font(13.0).clamp(12.4, 13.8).toDouble(),
              fontWeight: FontWeight.w900,
              color: cs.onSurface,
            ),
          ),
          SizedBox(height: ui.gap(10).clamp(8.0, 12.0).toDouble()),
          ...items.map(
                (item) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.check_circle_rounded,
                      size: 16,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withOpacity(0.72),
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactStatPill extends StatelessWidget {
  final UIScale ui;
  final Color bg;
  final Color fg;
  final String label;

  const _CompactStatPill({
    required this.ui,
    required this.bg,
    required this.fg,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(10).clamp(8.0, 12.0).toDouble(),
        vertical: ui.inset(6).clamp(5.0, 7.0).toDouble(),
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: ui.font(10.0).clamp(9.5, 10.6).toDouble(),
          fontWeight: FontWeight.w900,
          color: fg,
        ),
      ),
    );
  }
}
