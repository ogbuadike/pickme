import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../routes/routes.dart';
import '../../themes/app_theme.dart';
import '../../utility/notification.dart';
import '../../widgets/inner_background.dart';
import '../../ui/ui_scale.dart';
import '../../driver/driver_home_page.dart';
import '../home_page.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  late final ApiClient _api;

  bool _busy = false;
  bool _showPass = false;

  late final AnimationController _logoController;
  late final AnimationController _fadeController;
  late final AnimationController _slideController;

  late final Animation<double> _logoRotation;
  late final Animation<double> _fadeIn;
  late final Animation<Offset> _slideUp;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);

    _logoController = AnimationController(
      duration: const Duration(seconds: 20),
      vsync: this,
    )..repeat();

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..forward();

    _slideController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    )..forward();

    _logoRotation = Tween<double>(begin: 0, end: 2 * math.pi).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.linear),
    );

    _fadeIn = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeOut),
    );

    _slideUp = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _slideController, curve: Curves.easeOutBack),
    );
  }

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    _logoController.dispose();
    _fadeController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    try {
      final res = await _api.request(
        ApiConstants.logInEndpoint,
        method: 'POST',
        data: {
          'email': _email.text.trim(),
          'password': _pass.text.trim(),
        },
      );

      final body = jsonDecode(res.body);
      if (res.statusCode == 200 && body['error'] == false) {
        final loginMsg = (body['login_msg'] is Map)
            ? Map<String, dynamic>.from(body['login_msg'] as Map)
            : <String, dynamic>{};

        final prefs = await SharedPreferences.getInstance();
        final existingPin = prefs.getString('user_pin') ?? '';

        final isDriver = _isApprovedDriver(loginMsg);
        final driverStatus = (loginMsg['driver_status'] ?? 'not_started').toString();
        final driverId = (loginMsg['driver_id'] ?? '').toString();
        final postLoginHome = isDriver ? 'driver_home' : 'home';

        await prefs.setString('user_id', (loginMsg['uid'] ?? '').toString());
        await prefs.setString('user_name', (loginMsg['fname'] ?? '').toString());
        await prefs.setString(
          'user_account_name',
          (loginMsg['accountname'] ?? '').toString(),
        );
        await prefs.setString(
          'user_account_number',
          (loginMsg['accountnumber'] ?? '').toString(),
        );
        await prefs.setString(
          'user_account_bank',
          (loginMsg['bankname'] ?? '').toString(),
        );
        await prefs.setString('user_driver_status', driverStatus);
        await prefs.setString('user_driver_id', driverId);
        await prefs.setBool('user_is_driver', isDriver);
        await prefs.setString('post_login_home', postLoginHome);
        await prefs.setString('user_pin', existingPin);

        if (!mounted) return;
        showToastNotification(
          context: context,
          title: 'Success',
          message: (loginMsg['title_msg_body'] ?? 'Welcome back!').toString(),
          isSuccess: true,
        );

        if (existingPin.trim().isEmpty) {
          Navigator.of(context).pushReplacementNamed(AppRoutes.set_user_pin);
        } else {
          await _goToResolvedHome(isDriver: isDriver);
        }
      } else {
        if (!mounted) return;
        showBannerNotification(
          context: context,
          title: body['login_msg']?['title_msg'] ?? 'Login Failed',
          message: body['login_msg']?['title_msg_body'] ??
              'Please check your credentials',
          isSuccess: false,
        );
      }
    } catch (_) {
      if (!mounted) return;
      showToastNotification(
        context: context,
        title: 'Connection Error',
        message: 'Please check your internet connection',
        isSuccess: false,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _isApprovedDriver(Map<String, dynamic> loginMsg) {
    final status = (loginMsg['driver_status'] ?? '').toString().trim().toLowerCase();
    final hasDriverId = (loginMsg['driver_id'] ?? '').toString().trim().isNotEmpty;
    return hasDriverId && (status == 'approved' || status == 'activated');
  }

  Future<void> _goToResolvedHome({required bool isDriver}) async {
    if (!mounted) return;
    final route = MaterialPageRoute<void>(
      builder: (_) => isDriver ? const DriverHomePage() : const HomePage(),
    );
    Navigator.of(context).pushAndRemoveUntil(route, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final ui = UIScale.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Theme.of(context).colorScheme.background,
      body: Stack(
        children: [
          BackgroundWidget(
            style: HoloStyle.vapor,
            animate: true,
            intensity: isDark ? 0.3 : 0.8,
          ),
          SafeArea(
            child: FadeTransition(
              opacity: _fadeIn,
              child: ui.useSplitAuth
                  ? _buildSplitLayout(ui, isDark, cs)
                  : _buildCompactLayout(ui, isDark, cs),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactLayout(UIScale ui, bool isDark, ColorScheme cs) {
    return Center(
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: ui.screenPadding.copyWith(
          bottom: ui.screenPadding.bottom + ui.viewInsets.bottom,
        ),
        child: SlideTransition(
          position: _slideUp,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: ui.authCardMaxWidth),
            child: _buildLoginCard(ui, isLandscape: false, isDark: isDark, cs: cs),
          ),
        ),
      ),
    );
  }

  Widget _buildSplitLayout(UIScale ui, bool isDark, ColorScheme cs) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: ui.screenPadding.copyWith(
            bottom: ui.screenPadding.bottom + ui.viewInsets.bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight - ui.safePadding.vertical,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  flex: 11,
                  child: Align(
                    alignment: Alignment.center,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: ui.tablet ? 500 : 380,
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: ui.gap(10)),
                        child: _buildBrandingSection(ui, isDark, cs),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: ui.gap(24)),
                Expanded(
                  flex: 10,
                  child: Align(
                    alignment: Alignment.center,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: ui.authCardMaxWidth),
                      child: _buildLoginCard(ui, isLandscape: true, isDark: isDark, cs: cs),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBrandingSection(UIScale ui, bool isDark, ColorScheme cs) {
    final featureIconSize = ui.icon(18);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildAnimatedLogo(ui.heroLogoSize, isDark, cs),
        SizedBox(height: ui.gap(18)),
        Text(
          'Pick Me',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: ui.font(ui.tablet ? 42 : 34),
            fontWeight: FontWeight.w900,
            color: isDark ? cs.onSurface : AppColors.textPrimary,
            letterSpacing: -1,
          ),
        ),
        SizedBox(height: ui.gap(8)),
        Text(
          'Your Smart Ride & Delivery Solution',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: ui.font(15),
            color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
            letterSpacing: 0.3,
          ),
        ),
        SizedBox(height: ui.gap(20)),
        Container(
          padding: EdgeInsets.all(ui.inset(ui.compact ? 14 : 18)),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isDark
                  ? [cs.primary.withOpacity(0.15), cs.secondary.withOpacity(0.15)]
                  : [AppColors.primary.withOpacity(0.08), AppColors.secondary.withOpacity(0.08)],
            ),
            borderRadius: BorderRadius.circular(ui.radius(16)),
            border: Border.all(
              color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.35),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildFeatureItemWidget(
                SizedBox(
                  width: featureIconSize,
                  height: featureIconSize,
                  child: SvgPicture.asset(
                    'assets/icons/street_ride.svg',
                    fit: BoxFit.contain,
                    colorFilter: ColorFilter.mode(
                      isDark ? cs.primary : AppColors.primary,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
                'Street Rides',
                ui,
                isDark,
                cs,
              ),
              SizedBox(height: ui.gap(10)),
              _buildFeatureItemWidget(
                SizedBox(
                  width: featureIconSize,
                  height: featureIconSize,
                  child: SvgPicture.asset(
                    'assets/icons/campus_ride_monochrome.svg',
                    fit: BoxFit.contain,
                    colorFilter: ColorFilter.mode(
                      isDark ? cs.primary : AppColors.primary,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
                'Campus Rides',
                ui,
                isDark,
                cs,
              ),
              SizedBox(height: ui.gap(10)),
              _buildFeatureItemWidget(
                SizedBox(
                  width: featureIconSize,
                  height: featureIconSize,
                  child: SvgPicture.asset(
                    'assets/icons/dispatch.svg',
                    fit: BoxFit.contain,
                    colorFilter: ColorFilter.mode(
                      isDark ? cs.primary : AppColors.primary,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
                'Package Dispatch',
                ui,
                isDark,
                cs,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFeatureItemWidget(
      Widget icon,
      String label,
      UIScale ui,
      bool isDark,
      ColorScheme cs,
      ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: EdgeInsets.all(ui.inset(8)),
          decoration: BoxDecoration(
            color: isDark ? cs.surfaceVariant.withOpacity(0.8) : AppColors.surface.withOpacity(0.85),
            shape: BoxShape.circle,
          ),
          child: SizedBox(width: ui.icon(20), height: ui.icon(20), child: icon),
        ),
        SizedBox(width: ui.gap(10)),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isDark ? cs.onSurface : AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: ui.font(14),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAnimatedLogo(double size, bool isDark, ColorScheme cs) {
    return AnimatedBuilder(
      animation: _logoRotation,
      builder: (context, child) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [cs.surfaceVariant, cs.primary.withOpacity(0.2)]
                  : [AppColors.surface, AppColors.mintBgLight.withOpacity(0.9)],
              transform: GradientRotation(_logoRotation.value),
            ),
            boxShadow: [
              BoxShadow(
                color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.28),
                blurRadius: 24,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: (isDark ? cs.secondary : AppColors.secondary).withOpacity(0.18),
                blurRadius: 18,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(size * 0.24),
            child: Image.asset(
              'image/pickme.png',
              fit: BoxFit.contain,
            ),
          ),
        );
      },
    );
  }

  Widget _buildLoginCard(UIScale ui, {required bool isLandscape, required bool isDark, required ColorScheme cs}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(ui.cardRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: ui.blur(20),
          sigmaY: ui.blur(20),
        ),
        child: Container(
          padding: EdgeInsets.all(ui.compact ? ui.inset(18) : ui.inset(28)),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [cs.surface.withOpacity(0.95), cs.surfaceVariant.withOpacity(0.8)]
                  : [AppColors.surface.withOpacity(0.92), AppColors.mintBgLight.withOpacity(0.28)],
            ),
            borderRadius: BorderRadius.circular(ui.cardRadius),
            border: Border.all(
              color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.45),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black.withOpacity(0.5) : AppColors.deep.withOpacity(ui.reduceFx ? 0.05 : 0.10),
                blurRadius: ui.reduceFx ? 12 : 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: 0,
                    maxWidth: constraints.maxWidth,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isLandscape) ...[
                          _buildCompactLogo(ui, isDark, cs),
                          SizedBox(height: ui.gap(16)),
                        ],
                        Text(
                          isLandscape ? 'Sign In' : 'Welcome Back',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: ui.font(ui.compact ? 22 : 28),
                            fontWeight: FontWeight.w800,
                            color: isDark ? cs.onSurface : AppColors.textPrimary,
                          ),
                        ),
                        SizedBox(height: ui.gap(6)),
                        Text(
                          'Sign in to continue',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: ui.font(13),
                            color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                          ),
                        ),
                        SizedBox(height: ui.gap(18)),
                        _buildEmailField(ui, isDark, cs),
                        SizedBox(height: ui.gap(12)),
                        _buildPasswordField(ui, isDark, cs),
                        SizedBox(height: ui.gap(10)),
                        _buildOptionsRow(ui, isDark, cs),
                        SizedBox(height: ui.gap(16)),
                        _buildLoginButton(ui, isDark, cs),
                        SizedBox(height: ui.gap(14)),
                        _buildRegisterLink(ui, isDark, cs),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCompactLogo(UIScale ui, bool isDark, ColorScheme cs) {
    final size = ui.compactLogoSize;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: isDark ? [cs.primary, cs.secondary] : [AppColors.primary, AppColors.secondary],
        ),
        boxShadow: [
          BoxShadow(
            color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.22),
            blurRadius: ui.reduceFx ? 10 : 20,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(ui.inset(14)),
        child: Image.asset(
          'image/pickme.png',
          fit: BoxFit.contain,
          color: isDark ? cs.onPrimary : AppColors.surface,
        ),
      ),
    );
  }

  Widget _buildEmailField(UIScale ui, bool isDark, ColorScheme cs) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ui.radius(16)),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black.withOpacity(0.3) : AppColors.deep.withOpacity(0.05),
            blurRadius: ui.reduceFx ? 6 : 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TextFormField(
        controller: _email,
        textInputAction: TextInputAction.next,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.username, AutofillHints.email],
        style: TextStyle(
          fontSize: ui.font(14),
          color: isDark ? cs.onSurface : AppColors.textPrimary,
        ),
        decoration: InputDecoration(
          isDense: ui.compact,
          labelText: 'Email Address',
          labelStyle: TextStyle(
            color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(.9),
          ),
          hintText: 'your@email.com',
          hintStyle: TextStyle(
            color: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : AppColors.textSecondary.withOpacity(.65),
          ),
          contentPadding: EdgeInsets.symmetric(
            horizontal: ui.inset(14),
            vertical: ui.inputVerticalPadding,
          ),
          prefixIcon: Padding(
            padding: EdgeInsets.all(ui.inset(8)),
            child: Container(
              decoration: BoxDecoration(
                color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.email_rounded,
                size: ui.icon(18),
                color: isDark ? cs.primary : AppColors.primary,
              ),
            ),
          ),
          filled: true,
          fillColor: isDark ? cs.surfaceVariant.withOpacity(0.5) : AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ui.radius(16)),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ui.radius(16)),
            borderSide: BorderSide(
              color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.30),
              width: 1,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ui.radius(16)),
            borderSide: BorderSide(color: isDark ? cs.primary : AppColors.primary, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ui.radius(16)),
            borderSide: BorderSide(color: cs.error, width: 1),
          ),
        ),
        validator: (v) {
          final s = (v ?? '').trim();
          if (s.isEmpty) return 'Email is required';
          final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);
          return ok ? null : 'Please enter a valid email';
        },
      ),
    );
  }

  Widget _buildPasswordField(UIScale ui, bool isDark, ColorScheme cs) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ui.radius(16)),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black.withOpacity(0.3) : AppColors.deep.withOpacity(0.05),
            blurRadius: ui.reduceFx ? 6 : 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TextFormField(
        controller: _pass,
        textInputAction: TextInputAction.done,
        obscureText: !_showPass,
        autofillHints: const [AutofillHints.password],
        style: TextStyle(
          fontSize: ui.font(14),
          color: isDark ? cs.onSurface : AppColors.textPrimary,
        ),
        decoration: InputDecoration(
          isDense: ui.compact,
          labelText: 'Password',
          labelStyle: TextStyle(
            color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(.9),
          ),
          hintText: '••••••••',
          hintStyle: TextStyle(
            color: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : AppColors.textSecondary.withOpacity(.65),
          ),
          contentPadding: EdgeInsets.symmetric(
            horizontal: ui.inset(14),
            vertical: ui.inputVerticalPadding,
          ),
          prefixIcon: Padding(
            padding: EdgeInsets.all(ui.inset(8)),
            child: Container(
              decoration: BoxDecoration(
                color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.lock_rounded,
                size: ui.icon(18),
                color: isDark ? cs.primary : AppColors.primary,
              ),
            ),
          ),
          suffixIcon: IconButton(
            onPressed: () => setState(() => _showPass = !_showPass),
            icon: Icon(
              _showPass
                  ? Icons.visibility_rounded
                  : Icons.visibility_off_rounded,
              color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
            ),
          ),
          filled: true,
          fillColor: isDark ? cs.surfaceVariant.withOpacity(0.5) : AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ui.radius(16)),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ui.radius(16)),
            borderSide: BorderSide(
              color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.30),
              width: 1,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ui.radius(16)),
            borderSide: BorderSide(color: isDark ? cs.primary : AppColors.primary, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ui.radius(16)),
            borderSide: BorderSide(color: cs.error, width: 1),
          ),
        ),
        validator: (v) => (v == null || v.isEmpty) ? 'Password is required' : null,
        onFieldSubmitted: (_) => _busy ? null : _login(),
      ),
    );
  }

  Widget _buildOptionsRow(UIScale ui, bool isDark, ColorScheme cs) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final inline = constraints.maxWidth >= 340;

        final forgot = TextButton(
          onPressed: () => Navigator.pushNamed(context, AppRoutes.forgot_password),
          style: TextButton.styleFrom(
            foregroundColor: isDark ? cs.primary : AppColors.primary,
            padding: EdgeInsets.symmetric(
              horizontal: ui.inset(10),
              vertical: ui.inset(6),
            ),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            'Forgot Password?',
            style: TextStyle(fontSize: ui.font(12.5)),
          ),
        );

        final toggle = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Show Password',
              style: TextStyle(
                color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                fontSize: ui.font(12),
              ),
            ),
            SizedBox(width: ui.gap(6)),
            Transform.scale(
              scale: ui.compact ? 0.78 : 0.88,
              child: Switch(
                value: _showPass,
                onChanged: (v) => setState(() => _showPass = v),
                activeColor: isDark ? cs.primary : AppColors.primary,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        );

        if (inline) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              forgot,
              Flexible(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: toggle,
                ),
              ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            forgot,
            SizedBox(height: ui.gap(6)),
            toggle,
          ],
        );
      },
    );
  }

  Widget _buildLoginButton(UIScale ui, bool isDark, ColorScheme cs) {
    return Container(
      width: double.infinity,
      height: ui.buttonHeight,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark ? [cs.primary, cs.secondary] : [AppColors.primary, AppColors.secondary],
        ),
        borderRadius: BorderRadius.circular(ui.radius(30)),
        boxShadow: [
          BoxShadow(
            color: (isDark ? cs.primary : AppColors.primary).withOpacity(ui.reduceFx ? 0.18 : 0.30),
            blurRadius: ui.reduceFx ? 12 : 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: _busy
            ? null
            : () {
          HapticFeedback.lightImpact();
          _login();
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ui.radius(30)),
          ),
        ),
        child: _busy
            ? SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(isDark ? cs.onPrimary : AppColors.surface),
          ),
        )
            : Text(
          'Sign In',
          style: TextStyle(
            fontSize: ui.font(15.5),
            fontWeight: FontWeight.w700,
            color: isDark ? cs.onPrimary : AppColors.surface,
          ),
        ),
      ),
    );
  }

  Widget _buildRegisterLink(UIScale ui, bool isDark, ColorScheme cs) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      children: [
        Text(
          "Don't have an account?",
          style: TextStyle(
            color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
            fontSize: ui.font(13),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pushNamed(context, AppRoutes.registration),
          style: TextButton.styleFrom(foregroundColor: isDark ? cs.primary : AppColors.primary),
          child: Text(
            'Sign Up',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: ui.font(13.5),
            ),
          ),
        ),
      ],
    );
  }
}