// lib/screens/login.dart
import 'dart:convert';
import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../routes/routes.dart';
import '../../themes/app_theme.dart';
import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../utility/notification.dart';
import '../../widgets/inner_background.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with TickerProviderStateMixin {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _auth = FirebaseAuth.instance;

  late ApiClient _api;
  bool _busy = false;
  bool _showPass = false;

  // Animations
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

    // Setup animations
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

    _logoRotation = Tween<double>(
      begin: 0,
      end: 2 * math.pi,
    ).animate(CurvedAnimation(
      parent: _logoController,
      curve: Curves.linear,
    ));

    _fadeIn = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    ));

    _slideUp = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutBack,
    ));
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

  // ── Google Sign-In (Firebase) ──────────────────────────────────────────
  Future<void> _google() async {
    setState(() => _busy = true);
    try {
      final googleSignIn = GoogleSignIn();
      final account = await googleSignIn.signIn();
      if (account == null) {
        setState(() => _busy = false);
        return;
      }
      final auth = await account.authentication;
      final cred = GoogleAuthProvider.credential(
        accessToken: auth.accessToken,
        idToken: auth.idToken,
      );

      final userCred = await _auth.signInWithCredential(cred);
      final user = userCred.user;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_id', user?.uid ?? '');
      await prefs.setString('user_name', user?.displayName ?? '');
      await prefs.setString('user_logo', user?.photoURL ?? '');
      await prefs.setString('user_pin', '');

      if (!mounted) return;
      showToastNotification(
        context: context,
        title: 'Welcome',
        message: 'Signed in as ${user?.displayName ?? 'User'}',
        isSuccess: true,
      );

      Navigator.of(context).pushReplacementNamed(AppRoutes.set_user_pin);
    } catch (e) {
      showToastNotification(
        context: context,
        title: 'Sign-In Failed',
        message: 'Please try again',
        isSuccess: false,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Email/Password login ──────────────────────────────────────────────
  Future<void> _login() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    try {
      final data = {'email': _email.text.trim(), 'password': _pass.text.trim()};
      final res = await _api.request(
        ApiConstants.logInEndpoint,
        method: 'POST',
        data: data,
      );

      final body = jsonDecode(res.body);
      if (res.statusCode == 200 && body['error'] == false) {
        showToastNotification(
          context: context,
          title: 'Success',
          message: body['login_msg']['title_msg_body'] ?? 'Welcome back!',
          isSuccess: true,
        );

        final p = await SharedPreferences.getInstance();
        await p.setString('user_id', body['login_msg']['uid'] ?? '');
        await p.setString('user_name', body['login_msg']['fname'] ?? '');
        await p.setString('user_account_name', body['login_msg']['accountname'] ?? '');
        await p.setString('user_account_number', body['login_msg']['accountnumber'] ?? '');
        await p.setString('user_account_bank', body['login_msg']['bankname'] ?? '');
        await p.setString('user_pin', '');

        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(AppRoutes.set_user_pin);
      } else {
        showBannerNotification(
          context: context,
          title: body['login_msg']?['title_msg'] ?? 'Login Failed',
          message: body['login_msg']?['title_msg_body'] ?? 'Please check your credentials',
          isSuccess: false,
        );
      }
    } catch (e) {
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

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isLandscape = size.width > size.height;
    final isTablet = size.shortestSide > 600;
    final isSmallPhone = size.width < 360;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Stack(
        children: [
          // Premium holographic background
          const BackgroundWidget(
            style: HoloStyle.vapor,
            animate: true,
            intensity: 0.8,
          ),

          // Main content
          SafeArea(
            child: FadeTransition(
              opacity: _fadeIn,
              child: isLandscape
                  ? _buildLandscapeLayout(size, isTablet)
                  : _buildPortraitLayout(size, isTablet, isSmallPhone),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitLayout(Size size, bool isTablet, bool isSmallPhone) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: isTablet ? 64 : (isSmallPhone ? 20 : 32),
          vertical: 24,
        ),
        child: SlideTransition(
          position: _slideUp,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isTablet ? 520 : 420,
            ),
            child: _buildLoginCard(isTablet, isSmallPhone, false),
          ),
        ),
      ),
    );
  }

  Widget _buildLandscapeLayout(Size size, bool isTablet) {
    return Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Container(
          width: math.max(size.width, 900),
          padding: EdgeInsets.symmetric(
            horizontal: isTablet ? 64 : 32,
            vertical: 24,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // LEFT: Branding (now scrollable to avoid vertical overflow)
              Flexible(
                flex: 5,
                child: Align(
                  alignment: Alignment.center,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _buildBrandingSection(isTablet),
                  ),
                ),
              ),

              const SizedBox(width: 48),

              // RIGHT: Login (already scrollable)
              Flexible(
                flex: 5,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: SingleChildScrollView(
                    child: _buildLoginCard(isTablet, false, true),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBrandingSection(bool isTablet) {
    const double featureIconSize = 20;

    return Column(
      mainAxisSize: MainAxisSize.min, // <- keeps height to content
      children: [
        _buildAnimatedLogo(isTablet ? 140 : 120),
        const SizedBox(height: 20),
        Text(
          'Pick Me',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: isTablet ? 42 : 36,
            fontWeight: FontWeight.w900,
            color: AppColors.textPrimary,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Your Smart Ride & Delivery Solution',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: isTablet ? 18 : 16,
            color: AppColors.textSecondary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 22),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.primary.withOpacity(0.08),
                AppColors.secondary.withOpacity(0.08),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.mintBgLight.withOpacity(0.35),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // SVG Street Ride
              _buildFeatureItemWidget(
                SizedBox(
                  width: featureIconSize,
                  height: featureIconSize,
                  child: SvgPicture.asset(
                    'assets/icons/street_ride.svg',
                    fit: BoxFit.contain,
                    colorFilter: const ColorFilter.mode(AppColors.primary, BlendMode.srcIn),
                  ),
                ),
                'Street Rides',
              ),
              const SizedBox(height: 10),
              _buildFeatureItemWidget(
                  SizedBox(
                    width: featureIconSize,
                    height: featureIconSize,
                    child: SvgPicture.asset(
                      'assets/icons/campus_ride_monochrome.svg',
                      fit: BoxFit.contain,
                      colorFilter: const ColorFilter.mode(AppColors.primary, BlendMode.srcIn),
                    ),
                  ),
                  'Campus Rides'),
              const SizedBox(height: 10),
              _buildFeatureItemWidget(
                  SizedBox(
                    width: featureIconSize,
                    height: featureIconSize,
                    child: SvgPicture.asset(
                      'assets/icons/dispatch.svg',
                      fit: BoxFit.contain,
                      colorFilter: const ColorFilter.mode(AppColors.primary, BlendMode.srcIn),
                    ),
                  ),
                  'Package Dispatch'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFeatureItem(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.surface.withOpacity(0.85),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: AppColors.primary),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  // Helper that allows any widget (e.g., SVG) as the icon
  Widget _buildFeatureItemWidget(Widget icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.surface.withOpacity(0.85),
            shape: BoxShape.circle,
          ),
          child: SizedBox(width: 20, height: 20, child: icon),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAnimatedLogo(double size) {
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
              colors: [
                AppColors.surface,
                AppColors.mintBgLight.withOpacity(0.9),
              ],
              transform: GradientRotation(_logoRotation.value),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withOpacity(0.3),
                blurRadius: 30,
                spreadRadius: 5,
              ),
              BoxShadow(
                color: AppColors.secondary.withOpacity(0.2),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(size * 0.25),
            child: Image.asset(
              'image/pickme.png', // keep your original path
              fit: BoxFit.contain,
            ),
          ),
        );
      },
    );
  }

  Widget _buildLoginCard(bool isTablet, bool isSmallPhone, bool isLandscape) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: EdgeInsets.all(isTablet ? 40 : (isSmallPhone ? 24 : 32)),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.surface.withOpacity(0.9),
                AppColors.mintBgLight.withOpacity(0.3),
              ],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: AppColors.mintBgLight.withOpacity(0.5),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.deep.withOpacity(0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          // Prevent inner overflow on short screens
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isLandscape) ...[
                        _buildCompactLogo(),
                        const SizedBox(height: 24),
                      ],
                      Text(
                        isLandscape ? 'Sign In' : 'Welcome Back',
                        style: TextStyle(
                          fontSize: isTablet ? 32 : (isSmallPhone ? 24 : 28),
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Sign in to continue',
                        style: TextStyle(
                          fontSize: isTablet ? 16 : 14,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 28),
                      _buildEmailField(isTablet),
                      SizedBox(height: isSmallPhone ? 14 : 18),
                      _buildPasswordField(isTablet),
                      const SizedBox(height: 12),
                      _buildOptionsRow(),
                      const SizedBox(height: 20),
                      _buildLoginButton(isTablet),
                      const SizedBox(height: 18),
                      _buildDivider(),
                      const SizedBox(height: 18),
                      _buildGoogleButton(isTablet),
                      const SizedBox(height: 18),
                      _buildRegisterLink(),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCompactLogo() {
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.secondary],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.3),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Image.asset(
          'image/pickme.png',
          fit: BoxFit.contain,
          color: AppColors.surface,
        ),
      ),
    );
  }

  Widget _buildEmailField(bool isTablet) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.deep.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TextFormField(
        controller: _email,
        textInputAction: TextInputAction.next,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.username, AutofillHints.email],
        style: TextStyle(fontSize: isTablet ? 16 : 14),
        decoration: InputDecoration(
          labelText: 'Email Address',
          hintText: 'your@email.com',
          prefixIcon: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.email_rounded, size: 20, color: AppColors.primary),
          ),
          filled: true,
          fillColor: AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: AppColors.mintBgLight.withOpacity(0.3),
              width: 1,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(
              color: AppColors.primary,
              width: 2,
            ),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(
              color: AppColors.error,
              width: 1,
            ),
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

  Widget _buildPasswordField(bool isTablet) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.deep.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TextFormField(
        controller: _pass,
        textInputAction: TextInputAction.done,
        obscureText: !_showPass,
        autofillHints: const [AutofillHints.password],
        style: TextStyle(fontSize: isTablet ? 16 : 14),
        decoration: InputDecoration(
          labelText: 'Password',
          hintText: '••••••••',
          prefixIcon: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.lock_rounded, size: 20, color: AppColors.primary),
          ),
          suffixIcon: IconButton(
            onPressed: () => setState(() => _showPass = !_showPass),
            icon: Icon(
              _showPass ? Icons.visibility_rounded : Icons.visibility_off_rounded,
              color: AppColors.textSecondary,
            ),
          ),
          filled: true,
          fillColor: AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: AppColors.mintBgLight.withOpacity(0.3),
              width: 1,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(
              color: AppColors.primary,
              width: 2,
            ),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(
              color: AppColors.error,
              width: 1,
            ),
          ),
        ),
        validator: (v) => (v == null || v.isEmpty) ? 'Password is required' : null,
        onFieldSubmitted: (_) => _busy ? null : _login(),
      ),
    );
  }

  Widget _buildOptionsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        TextButton(
          onPressed: () => Navigator.pushNamed(context, AppRoutes.forgot_password),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          child: const Text('Forgot Password?'),
        ),
        Row(
          children: [
            const Text(
              'Show Password',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 8),
            Transform.scale(
              scale: 0.9,
              child: Switch(
                value: _showPass,
                onChanged: (v) => setState(() => _showPass = v),
                activeColor: AppColors.primary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLoginButton(bool isTablet) {
    return Container(
      width: double.infinity,
      height: isTablet ? 56 : 52,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.secondary],
        ),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: _busy ? null : () {
          HapticFeedback.lightImpact();
          _login();
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
        ),
        child: _busy
            ? const SizedBox(
          height: 20, width: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.surface),
          ),
        )
            : Text(
          'Sign In',
          style: TextStyle(
            fontSize: isTablet ? 18 : 16,
            fontWeight: FontWeight.w700,
            color: AppColors.surface,
          ),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  AppColors.mintBgLight.withOpacity(0.5),
                ],
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'OR',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.mintBgLight.withOpacity(0.5),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGoogleButton(bool isTablet) {
    return Container(
      width: double.infinity,
      height: isTablet ? 56 : 52,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: AppColors.mintBgLight,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.deep.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: OutlinedButton.icon(
        onPressed: _busy ? null : () {
          HapticFeedback.lightImpact();
          _google();
        },
        style: OutlinedButton.styleFrom(
          side: BorderSide.none,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
        ),
        icon: Image.asset(
          'image/google.png', // optional logo; falls back below
          width: 24,
          height: 24,
          errorBuilder: (_, __, ___) => const Icon(
            Icons.g_mobiledata_rounded,
            size: 28,
            color: AppColors.primary,
          ),
        ),
        label: Text(
          'Continue with Google',
          style: TextStyle(
            fontSize: isTablet ? 16 : 14,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildRegisterLink() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          "Don't have an account?",
          style: TextStyle(color: AppColors.textSecondary),
        ),
        TextButton(
          onPressed: () => Navigator.pushNamed(context, AppRoutes.registration),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.primary,
          ),
          child: const Text(
            'Sign Up',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
