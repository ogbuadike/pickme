// lib/screens/registration.dart
// (This is the same structure you already have; only _buildFeatureItemWidget was fixed.)
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
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
import '../../utility/deviceInfoService.dart';
import '../../widgets/inner_background.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});
  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen>
    with TickerProviderStateMixin {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();

  final _formKey = GlobalKey<FormState>();
  bool _busy = false;
  bool _showPass = false;
  bool _showConfirm = false;

  late ApiClient _api;
  final _deviceInfo = DeviceInfoService();
  final _auth = FirebaseAuth.instance;

  double _strength = 0;
  String _strengthLabel = 'Too weak';

  late final AnimationController _logoController;
  late final Animation<double> _logoRotation;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);
    _pass.addListener(_computeStrength);

    _logoController = AnimationController(
      duration: const Duration(seconds: 20),
      vsync: this,
    )..repeat();

    _logoRotation = Tween<double>(begin: 0, end: 2 * math.pi).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.linear),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _pass.dispose();
    _confirm.dispose();
    _logoController.dispose();
    super.dispose();
  }

  bool _validEmail(String s) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s.trim());

  void _computeStrength() {
    final s = _pass.text;
    double sc = 0;
    if (s.length >= 8) sc += .25;
    if (RegExp(r'[A-Z]').hasMatch(s)) sc += .20;
    if (RegExp(r'[a-z]').hasMatch(s)) sc += .20;
    if (RegExp(r'\d').hasMatch(s)) sc += .20;
    if (RegExp(r'[!@#\$%\^&\*\-_\+=\.\,\?\(\)]').hasMatch(s)) sc += .15;
    sc = sc.clamp(0, 1);
    String label = 'Too weak';
    if (sc >= .80) label = 'Strong';
    else if (sc >= .55) label = 'Good';
    else if (sc >= .35) label = 'Fair';
    setState(() {
      _strength = sc;
      _strengthLabel = label;
    });
  }

  Future<void> _register() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    try {
      final device = await _deviceInfo.getDeviceInfo();
      final payload = {
        'full_name': _name.text.trim(),
        'email': _email.text.trim(),
        'password': _pass.text.trim(),
        'device': jsonEncode(device),
      };

      final res = await _api.request(
        ApiConstants.registerEndpoint,
        method: 'POST',
        data: payload,
      );
      final body = jsonDecode(res.body);

      if (res.statusCode == 200 && body['error'] == false) {
        showToastNotification(
          context: context,
          title: 'Success',
          message: body['login_msg']?['title_msg_body'] ?? 'Account created',
          isSuccess: true,
        );
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(AppRoutes.login);
      } else {
        showBannerNotification(
          context: context,
          title: body['login_msg']?['title_msg'] ?? 'Registration failed',
          message: body['login_msg']?['title_msg_body'] ?? 'Please try again.',
          isSuccess: false,
        );
      }
    } catch (e) {
      showToastNotification(
        context: context,
        title: 'Error',
        message: e.toString(),
        isSuccess: false,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _googleSignup() async {
    setState(() => _busy = true);
    try {
      final g = GoogleSignIn();
      final account = await g.signIn();
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
        title: 'Google Sign-In failed',
        message: 'Please try again',
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

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Stack(
        children: [
          const BackgroundWidget(
            style: HoloStyle.vapor,
            animate: true,
            intensity: 0.8,
          ),
          SafeArea(
            child: Center(
              child: isLandscape
                  ? _buildLandscapeLayout(size, isTablet)
                  : _buildPortraitLayout(size, isTablet),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitLayout(Size size, bool isTablet) {
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: isTablet ? 64 : 32, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isTablet ? 520 : 420),
        child: _buildRegistrationCard(isTablet: isTablet, isLandscape: false),
      ),
    );
  }

  Widget _buildLandscapeLayout(Size size, bool isTablet) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        width: math.max(size.width, 900),
        padding: EdgeInsets.symmetric(horizontal: isTablet ? 64 : 32, vertical: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
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
            Flexible(
              flex: 5,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: SingleChildScrollView(
                  child: _buildRegistrationCard(isTablet: isTablet, isLandscape: true),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrandingSection(bool isTablet) {
    const double featureIconSize = 20;

    return Column(
      mainAxisSize: MainAxisSize.min,
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
        const Text(
          'Create your account to ride & dispatch',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
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
                'Campus Rides',
              ),
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
                'Package Dispatch',
              ),
            ],
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
              colors: [AppColors.surface, AppColors.mintBgLight.withOpacity(0.9)],
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
            child: Image.asset('image/pickme.png', fit: BoxFit.contain),
          ),
        );
      },
    );
  }

  Widget _buildRegistrationCard({required bool isTablet, required bool isLandscape}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: EdgeInsets.all(isTablet ? 40 : 32),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.surface.withOpacity(0.9),
                AppColors.mintBgLight.withOpacity(0.3),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.mintBgLight.withOpacity(0.5), width: 1),
            boxShadow: [
              BoxShadow(
                color: AppColors.deep.withOpacity(0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: LayoutBuilder(
            builder: (_, __) {
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isLandscape) ...[
                        _buildCompactLogo(),
                        const SizedBox(height: 20),
                      ],
                      const Text(
                        'Create your account',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Ride, dispatch, and move smarter with Pick Me',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: 24),

                      _fieldWrapper(
                        child: TextFormField(
                          controller: _name,
                          textInputAction: TextInputAction.next,
                          decoration: _inputDecoration(
                            label: 'Legal full name',
                            icon: Icons.person_rounded,
                          ),
                          validator: (v) {
                            final s = (v ?? '').trim();
                            if (s.isEmpty) return 'Full name can’t be empty';
                            if (s.length < 3) return 'Enter a valid name';
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: 14),

                      _fieldWrapper(
                        child: TextFormField(
                          controller: _email,
                          textInputAction: TextInputAction.next,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email, AutofillHints.username],
                          decoration: _inputDecoration(
                            label: 'Email Address',
                            icon: Icons.email_rounded,
                          ),
                          validator: (v) => _validEmail(v ?? '') ? null : 'Enter a valid email',
                        ),
                      ),
                      const SizedBox(height: 14),

                      _fieldWrapper(
                        child: TextFormField(
                          controller: _pass,
                          obscureText: !_showPass,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.newPassword],
                          decoration: _inputDecoration(
                            label: 'Password',
                            icon: Icons.lock_rounded,
                            trailing: IconButton(
                              onPressed: () => setState(() => _showPass = !_showPass),
                              icon: Icon(
                                _showPass ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                          validator: (v) {
                            final s = (v ?? '');
                            if (s.isEmpty) return 'Password can’t be empty';
                            if (s.length < 8) return 'Use at least 8 characters';
                            if (!RegExp(r'[A-Za-z]').hasMatch(s) || !RegExp(r'\d').hasMatch(s)) {
                              return 'Use letters and numbers';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: 10),

                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                minHeight: 6,
                                value: _strength == 0 ? null : _strength,
                                color: _meterColor(context),
                                backgroundColor: AppColors.mintBgLight,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _strengthLabel,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      _fieldWrapper(
                        child: TextFormField(
                          controller: _confirm,
                          obscureText: !_showConfirm,
                          textInputAction: TextInputAction.done,
                          autofillHints: const [AutofillHints.newPassword],
                          onFieldSubmitted: (_) => _busy ? null : _register(),
                          decoration: _inputDecoration(
                            label: 'Confirm password',
                            icon: Icons.lock_person_rounded,
                            trailing: IconButton(
                              onPressed: () => setState(() => _showConfirm = !_showConfirm),
                              icon: Icon(
                                _showConfirm ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                          validator: (v) => (v ?? '').trim() == _pass.text.trim()
                              ? null
                              : 'Passwords do not match',
                        ),
                      ),

                      const SizedBox(height: 22),

                      _primaryGradientButton(
                        label: 'Create account',
                        onPressed: _busy ? null : () {
                          HapticFeedback.lightImpact();
                          _register();
                        },
                        busy: _busy,
                      ),

                      const SizedBox(height: 18),
                      _divider(),
                      const SizedBox(height: 18),

                      _googleButton(
                        label: 'Sign up with Google',
                        onPressed: _busy ? null : () {
                          HapticFeedback.lightImpact();
                          _googleSignup();
                        },
                      ),

                      const SizedBox(height: 20),
                      _loginLink(),
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
        gradient: const LinearGradient(colors: [AppColors.primary, AppColors.secondary]),
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
        child: Image.asset('image/pickme.png', fit: BoxFit.contain, color: AppColors.surface),
      ),
    );
  }

  Widget _fieldWrapper({required Widget child}) {
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
      child: child,
    );
  }

  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
    Widget? trailing,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 20, color: AppColors.primary),
      ),
      suffixIcon: trailing,
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
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        borderSide: BorderSide(color: AppColors.primary, width: 2),
      ),
      errorBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        borderSide: BorderSide(color: AppColors.error, width: 1),
      ),
    );
  }

  // ✅ Fixed: use the passed label (no const)
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

  Color _meterColor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_strength >= .80) return cs.primary;
    if (_strength >= .55) return AppColors.secondary;
    if (_strength >= .35) return AppColors.outline;
    return cs.error;
  }

  Widget _primaryGradientButton({
    required String label,
    required VoidCallback? onPressed,
    required bool busy,
  }) {
    return Container(
      width: double.infinity,
      height: 52,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [AppColors.primary, AppColors.secondary]),
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
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        ),
        child: busy
            ? const SizedBox(
          height: 20, width: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.surface),
          ),
        )
            : Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.surface,
          ),
        ),
      ),
    );
  }

  Widget _divider() {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, AppColors.mintBgLight.withOpacity(0.5)],
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
                colors: [AppColors.mintBgLight.withOpacity(0.5), Colors.transparent],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _googleButton({required String label, required VoidCallback? onPressed}) {
    return Container(
      width: double.infinity,
      height: 52,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: AppColors.mintBgLight, width: 1),
        boxShadow: [
          BoxShadow(
            color: AppColors.deep.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: OutlinedButton.icon(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          side: BorderSide.none,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        ),
        icon: Image.asset(
          'image/google.png',
          width: 24,
          height: 24,
          errorBuilder: (_, __, ___) => const Icon(
            Icons.g_mobiledata_rounded,
            size: 28,
            color: AppColors.primary,
          ),
        ),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _loginLink() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text("Already have an account?", style: TextStyle(color: AppColors.textSecondary)),
        TextButton(
          onPressed: () => Navigator.pushReplacementNamed(context, AppRoutes.login),
          style: TextButton.styleFrom(foregroundColor: AppColors.primary),
          child: const Text('Log in', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
