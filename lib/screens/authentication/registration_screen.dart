import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../routes/routes.dart';
import '../../themes/app_theme.dart';
import '../../utility/deviceInfoService.dart';
import '../../utility/notification.dart';
import '../../widgets/inner_background.dart';
import '../../ui/ui_scale.dart';

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
  final _deviceInfo = DeviceInfoService();
  final _auth = FirebaseAuth.instance;

  late final ApiClient _api;
  late final AnimationController _logoController;
  late final Animation<double> _logoRotation;

  bool _busy = false;
  bool _showPass = false;
  bool _showConfirm = false;

  double _strength = 0;
  String _strengthLabel = 'Too weak';

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
    _pass.removeListener(_computeStrength);
    _pass.dispose();
    _confirm.dispose();
    _logoController.dispose();
    super.dispose();
  }

  bool _validEmail(String s) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s.trim());
  }

  void _computeStrength() {
    final s = _pass.text;
    double score = 0;

    if (s.length >= 8) score += .25;
    if (RegExp(r'[A-Z]').hasMatch(s)) score += .20;
    if (RegExp(r'[a-z]').hasMatch(s)) score += .20;
    if (RegExp(r'\d').hasMatch(s)) score += .20;
    if (RegExp(r'[!@#\$%\^&\*\-_\+=\.\,\?\(\)]').hasMatch(s)) {
      score += .15;
    }

    score = score.clamp(0, 1);

    var label = 'Too weak';
    if (score >= .80) {
      label = 'Strong';
    } else if (score >= .55) {
      label = 'Good';
    } else if (score >= .35) {
      label = 'Fair';
    }

    if (!mounted) return;
    setState(() {
      _strength = score;
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
        if (!mounted) return;
        showToastNotification(
          context: context,
          title: 'Success',
          message: body['login_msg']?['title_msg_body'] ?? 'Account created',
          isSuccess: true,
        );
        Navigator.of(context).pushReplacementNamed(AppRoutes.login);
      } else {
        if (!mounted) return;
        showBannerNotification(
          context: context,
          title: body['login_msg']?['title_msg'] ?? 'Registration failed',
          message:
          body['login_msg']?['title_msg_body'] ?? 'Please try again.',
          isSuccess: false,
        );
      }
    } catch (e) {
      if (!mounted) return;
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
        if (mounted) setState(() => _busy = false);
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
    } catch (_) {
      if (!mounted) return;
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
    final ui = UIScale.of(context);

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
            child: ui.useSplitAuth
                ? _buildSplitLayout(ui)
                : _buildCompactLayout(ui),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactLayout(UIScale ui) {
    return Center(
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: ui.screenPadding.copyWith(
          bottom: ui.screenPadding.bottom + ui.viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: ui.authCardMaxWidth),
          child: _buildRegistrationCard(ui, isLandscape: false),
        ),
      ),
    );
  }

  Widget _buildSplitLayout(UIScale ui) {
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
                        child: _buildBrandingSection(ui),
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
                      child: _buildRegistrationCard(ui, isLandscape: true),
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

  Widget _buildBrandingSection(UIScale ui) {
    final featureIconSize = ui.icon(18);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildAnimatedLogo(ui.heroLogoSize),
        SizedBox(height: ui.gap(18)),
        Text(
          'Pick Me',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: ui.font(ui.tablet ? 42 : 34),
            fontWeight: FontWeight.w900,
            color: AppColors.textPrimary,
            letterSpacing: -1,
          ),
        ),
        SizedBox(height: ui.gap(8)),
        Text(
          'Create your account to ride & dispatch',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: ui.font(15),
            color: AppColors.textSecondary,
            letterSpacing: 0.3,
          ),
        ),
        SizedBox(height: ui.gap(20)),
        Container(
          padding: EdgeInsets.all(ui.inset(ui.compact ? 14 : 18)),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.primary.withOpacity(0.08),
                AppColors.secondary.withOpacity(0.08),
              ],
            ),
            borderRadius: BorderRadius.circular(ui.radius(16)),
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
                    colorFilter: const ColorFilter.mode(
                      AppColors.primary,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
                'Street Rides',
                ui,
              ),
              SizedBox(height: ui.gap(10)),
              _buildFeatureItemWidget(
                SizedBox(
                  width: featureIconSize,
                  height: featureIconSize,
                  child: SvgPicture.asset(
                    'assets/icons/campus_ride_monochrome.svg',
                    fit: BoxFit.contain,
                    colorFilter: const ColorFilter.mode(
                      AppColors.primary,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
                'Campus Rides',
                ui,
              ),
              SizedBox(height: ui.gap(10)),
              _buildFeatureItemWidget(
                SizedBox(
                  width: featureIconSize,
                  height: featureIconSize,
                  child: SvgPicture.asset(
                    'assets/icons/dispatch.svg',
                    fit: BoxFit.contain,
                    colorFilter: const ColorFilter.mode(
                      AppColors.primary,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
                'Package Dispatch',
                ui,
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
              colors: [
                AppColors.surface,
                AppColors.mintBgLight.withOpacity(0.9),
              ],
              transform: GradientRotation(_logoRotation.value),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withOpacity(0.28),
                blurRadius: 24,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: AppColors.secondary.withOpacity(0.18),
                blurRadius: 18,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(size * 0.24),
            child: Image.asset('image/pickme.png', fit: BoxFit.contain),
          ),
        );
      },
    );
  }

  Widget _buildRegistrationCard(
      UIScale ui, {
        required bool isLandscape,
      }) {
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
              colors: [
                AppColors.surface.withOpacity(0.92),
                AppColors.mintBgLight.withOpacity(0.28),
              ],
            ),
            borderRadius: BorderRadius.circular(ui.cardRadius),
            border: Border.all(
              color: AppColors.mintBgLight.withOpacity(0.45),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.deep.withOpacity(ui.reduceFx ? 0.05 : 0.10),
                blurRadius: ui.reduceFx ? 12 : 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isLandscape) ...[
                    _buildCompactLogo(ui),
                    SizedBox(height: ui.gap(16)),
                  ],
                  Text(
                    'Create your account',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: ui.font(ui.compact ? 22 : 28),
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  SizedBox(height: ui.gap(6)),
                  Text(
                    'Ride, dispatch, and move smarter with Pick Me',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: ui.font(13),
                      color: AppColors.textSecondary,
                    ),
                  ),
                  SizedBox(height: ui.gap(18)),
                  _fieldWrapper(ui, _buildNameField(ui)),
                  SizedBox(height: ui.gap(12)),
                  _fieldWrapper(ui, _buildEmailField(ui)),
                  SizedBox(height: ui.gap(12)),
                  _fieldWrapper(ui, _buildPasswordField(ui)),
                  SizedBox(height: ui.gap(10)),
                  _buildStrengthMeter(ui),
                  SizedBox(height: ui.gap(12)),
                  _fieldWrapper(ui, _buildConfirmField(ui)),
                  SizedBox(height: ui.gap(16)),
                  _primaryGradientButton(ui),
                  SizedBox(height: ui.gap(14)),
                  _divider(ui),
                  SizedBox(height: ui.gap(14)),
                  _googleButton(ui),
                  SizedBox(height: ui.gap(12)),
                  _loginLink(ui),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactLogo(UIScale ui) {
    final size = ui.compactLogoSize;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.secondary],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.22),
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
          color: AppColors.surface,
        ),
      ),
    );
  }

  Widget _fieldWrapper(UIScale ui, Widget child) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ui.radius(16)),
        boxShadow: [
          BoxShadow(
            color: AppColors.deep.withOpacity(0.05),
            blurRadius: ui.reduceFx ? 6 : 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildNameField(UIScale ui) {
    return TextFormField(
      controller: _name,
      textInputAction: TextInputAction.next,
      style: TextStyle(fontSize: ui.font(14)),
      decoration: _inputDecoration(
        ui,
        label: 'Legal full name',
        icon: Icons.person_rounded,
      ),
      validator: (v) {
        final s = (v ?? '').trim();
        if (s.isEmpty) return 'Full name can’t be empty';
        if (s.length < 3) return 'Enter a valid name';
        return null;
      },
    );
  }

  Widget _buildEmailField(UIScale ui) {
    return TextFormField(
      controller: _email,
      textInputAction: TextInputAction.next,
      keyboardType: TextInputType.emailAddress,
      autofillHints: const [AutofillHints.email, AutofillHints.username],
      style: TextStyle(fontSize: ui.font(14)),
      decoration: _inputDecoration(
        ui,
        label: 'Email Address',
        icon: Icons.email_rounded,
      ),
      validator: (v) => _validEmail(v ?? '') ? null : 'Enter a valid email',
    );
  }

  Widget _buildPasswordField(UIScale ui) {
    return TextFormField(
      controller: _pass,
      obscureText: !_showPass,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.newPassword],
      style: TextStyle(fontSize: ui.font(14)),
      decoration: _inputDecoration(
        ui,
        label: 'Password',
        icon: Icons.lock_rounded,
        trailing: IconButton(
          onPressed: () => setState(() => _showPass = !_showPass),
          icon: Icon(
            _showPass
                ? Icons.visibility_rounded
                : Icons.visibility_off_rounded,
            color: AppColors.textSecondary,
          ),
        ),
      ),
      validator: (v) {
        final s = v ?? '';
        if (s.isEmpty) return 'Password can’t be empty';
        if (s.length < 8) return 'Use at least 8 characters';
        if (!RegExp(r'[A-Za-z]').hasMatch(s) || !RegExp(r'\d').hasMatch(s)) {
          return 'Use letters and numbers';
        }
        return null;
      },
    );
  }

  Widget _buildConfirmField(UIScale ui) {
    return TextFormField(
      controller: _confirm,
      obscureText: !_showConfirm,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.newPassword],
      onFieldSubmitted: (_) => _busy ? null : _register(),
      style: TextStyle(fontSize: ui.font(14)),
      decoration: _inputDecoration(
        ui,
        label: 'Confirm password',
        icon: Icons.lock_person_rounded,
        trailing: IconButton(
          onPressed: () => setState(() => _showConfirm = !_showConfirm),
          icon: Icon(
            _showConfirm
                ? Icons.visibility_rounded
                : Icons.visibility_off_rounded,
            color: AppColors.textSecondary,
          ),
        ),
      ),
      validator: (v) => (v ?? '').trim() == _pass.text.trim()
          ? null
          : 'Passwords do not match',
    );
  }

  InputDecoration _inputDecoration(
      UIScale ui, {
        required String label,
        required IconData icon,
        Widget? trailing,
      }) {
    return InputDecoration(
      isDense: ui.compact,
      labelText: label,
      contentPadding: EdgeInsets.symmetric(
        horizontal: ui.inset(14),
        vertical: ui.inputVerticalPadding,
      ),
      prefixIcon: Padding(
        padding: EdgeInsets.all(ui.inset(8)),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.10),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: ui.icon(18), color: AppColors.primary),
        ),
      ),
      suffixIcon: trailing,
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ui.radius(16)),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ui.radius(16)),
        borderSide: BorderSide(
          color: AppColors.mintBgLight.withOpacity(0.30),
          width: 1,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ui.radius(16)),
        borderSide: const BorderSide(color: AppColors.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ui.radius(16)),
        borderSide: const BorderSide(color: AppColors.error, width: 1),
      ),
    );
  }

  Widget _buildFeatureItemWidget(
      Widget icon,
      String label,
      UIScale ui,
      ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: EdgeInsets.all(ui.inset(8)),
          decoration: BoxDecoration(
            color: AppColors.surface.withOpacity(0.85),
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
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: ui.font(14),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStrengthMeter(UIScale ui) {
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ui.radius(8)),
            child: LinearProgressIndicator(
              minHeight: 6,
              value: _strength == 0 ? null : _strength,
              color: _meterColor(context),
              backgroundColor: AppColors.mintBgLight,
            ),
          ),
        ),
        SizedBox(width: ui.gap(8)),
        Text(
          _strengthLabel,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w700,
            fontSize: ui.font(12.5),
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

  Widget _primaryGradientButton(UIScale ui) {
    return Container(
      width: double.infinity,
      height: ui.buttonHeight,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.secondary],
        ),
        borderRadius: BorderRadius.circular(ui.radius(30)),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(ui.reduceFx ? 0.18 : 0.30),
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
          _register();
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ui.radius(30)),
          ),
        ),
        child: _busy
            ? const SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.surface),
          ),
        )
            : Text(
          'Create account',
          style: TextStyle(
            fontSize: ui.font(15.5),
            fontWeight: FontWeight.w700,
            color: AppColors.surface,
          ),
        ),
      ),
    );
  }

  Widget _divider(UIScale ui) {
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
        Padding(
          padding: EdgeInsets.symmetric(horizontal: ui.inset(14)),
          child: Text(
            'OR',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
              fontSize: ui.font(12),
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

  Widget _googleButton(UIScale ui) {
    return Container(
      width: double.infinity,
      height: ui.buttonHeight,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(ui.radius(30)),
        border: Border.all(color: AppColors.mintBgLight, width: 1),
        boxShadow: [
          BoxShadow(
            color: AppColors.deep.withOpacity(0.05),
            blurRadius: ui.reduceFx ? 6 : 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: OutlinedButton.icon(
        onPressed: _busy
            ? null
            : () {
          HapticFeedback.lightImpact();
          _googleSignup();
        },
        style: OutlinedButton.styleFrom(
          side: BorderSide.none,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ui.radius(30)),
          ),
        ),
        icon: Image.asset(
          'image/google.png',
          width: ui.icon(22),
          height: ui.icon(22),
          errorBuilder: (_, __, ___) => Icon(
            Icons.g_mobiledata_rounded,
            size: ui.icon(26),
            color: AppColors.primary,
          ),
        ),
        label: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'Sign up with Google',
            style: TextStyle(
              fontSize: ui.font(13.5),
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _loginLink(UIScale ui) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      children: [
        Text(
          'Already have an account?',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: ui.font(13),
          ),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pushReplacementNamed(context, AppRoutes.login),
          style: TextButton.styleFrom(foregroundColor: AppColors.primary),
          child: Text(
            'Log in',
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
