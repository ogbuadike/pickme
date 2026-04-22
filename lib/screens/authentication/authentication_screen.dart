// lib/screens/authentication.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../../themes/app_theme.dart';
import '../../utility/notification.dart';
import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../routes/routes.dart';
import '../../widgets/inner_background.dart';
import '../../ui/ui_scale.dart';

// Added imports for correct home routing
import '../../driver/driver_home_page.dart';
import '../home_page.dart';

class AuthenticationScreen extends StatefulWidget {
  const AuthenticationScreen({Key? key}) : super(key: key);

  @override
  State<AuthenticationScreen> createState() => _AuthenticationScreenState();
}

class _AuthenticationScreenState extends State<AuthenticationScreen>
    with TickerProviderStateMixin {
  // PIN state
  static const int _pinLen = 4;
  final List<String> _pin = List.filled(_pinLen, '');
  int _cursor = 0;

  // Services/state
  late ApiClient _api;
  late SharedPreferences _prefs;
  bool _loading = false;
  String? _username;

  // Biometrics
  final _localAuth = LocalAuthentication();
  bool _biometricAvailable = false;

  // Lockout (5 minutes)
  static const _lockout = Duration(minutes: 5);
  bool _locked = false;
  DateTime? _lockStart;
  Timer? _unlockTicker;
  Duration _remaining = Duration.zero;

  // Animations
  late final AnimationController _dotController;
  late final AnimationController _logoController;
  late final AnimationController _fadeController;

  late final Animation<double> _dotScale;
  late final Animation<double> _logoFloat;
  late final Animation<double> _fadeIn;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);

    // Setup animations
    _dotController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _logoController = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    )..repeat(reverse: true);

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    )..forward();

    _dotScale = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _dotController,
      curve: Curves.elasticOut,
    ));

    _logoFloat = Tween<double>(
      begin: -8.0,
      end: 8.0,
    ).animate(CurvedAnimation(
      parent: _logoController,
      curve: Curves.easeInOut,
    ));

    _fadeIn = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    ));

    _init();
  }

  @override
  void dispose() {
    _unlockTicker?.cancel();
    _dotController.dispose();
    _logoController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _username = _prefs.getString('user_name') ?? 'User';

    // Check biometrics
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final supported = await _localAuth.isDeviceSupported();
      final types = await _localAuth.getAvailableBiometrics();

      // Accept weak/iris as well – many devices report face as WEAK.
      final hasBio = types.contains(BiometricType.fingerprint) ||
          types.contains(BiometricType.face) ||
          types.contains(BiometricType.strong) ||
          types.contains(BiometricType.weak) ||
          types.contains(BiometricType.iris);

      _biometricAvailable = canCheck && supported && hasBio;
    } catch (_) {
      _biometricAvailable = false;
    }

    // Check lock status
    final lockStr = _prefs.getString('lock_time');
    if (lockStr != null) {
      _lockStart = DateTime.tryParse(lockStr);
      _evaluateLock();
    }

    if (mounted) setState(() {});
  }

  void _evaluateLock() {
    if (_lockStart == null) return;
    final elapsed = DateTime.now().difference(_lockStart!);
    final remain = _lockout - elapsed;
    if (remain > Duration.zero) {
      _locked = true;
      _remaining = remain;
      _unlockTicker?.cancel();
      _unlockTicker = Timer.periodic(const Duration(seconds: 1), (t) {
        final left = _lockout - DateTime.now().difference(_lockStart!);
        if (left <= Duration.zero) {
          t.cancel();
          _clearLock();
        } else {
          if (mounted) setState(() => _remaining = left);
        }
      });
    } else {
      _clearLock();
    }
  }

  void _clearLock() {
    _locked = false;
    _remaining = Duration.zero;
    _prefs.remove('lock_time');
    _prefs.setInt('failed_attempts', 0);
    if (mounted) setState(() {});
  }

  void _setLock() {
    _locked = true;
    _lockStart = DateTime.now();
    _prefs.setString('lock_time', _lockStart!.toIso8601String());
    _evaluateLock();
  }

  Future<void> _submitPin({bool bypass = false}) async {
    if (_locked) {
      _showLockedMessage();
      return;
    }

    final full = _pin.join();
    if (!bypass && full.length < _pinLen) return;

    final uid = _prefs.getString('user_id') ?? '';
    if (uid.isEmpty && !bypass) {
      showToastNotification(
        context: context,
        title: 'Session Expired',
        message: 'Please sign in again',
        isSuccess: false,
      );
      Navigator.pushReplacementNamed(context, '/login');
      return;
    }

    setState(() => _loading = true);

    try {
      if (bypass) {
        _resetPin();
        if (!mounted) return;

        final isDriver = _prefs.getBool('user_is_driver') ?? false;
        final route = MaterialPageRoute<void>(
          builder: (_) => isDriver ? const DriverHomePage() : const HomePage(),
        );
        Navigator.of(context).pushAndRemoveUntil(route, (_) => false);
        return;
      }

      final res = await _api.request(
        ApiConstants.validatePinEndpoint,
        method: 'POST',
        data: {'uid': uid, 'pin': full},
      );

      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data['error'] == false) {
        _prefs.setInt('failed_attempts', 0);
        _resetPin();
        if (!mounted) return;

        final isDriver = _prefs.getBool('user_is_driver') ?? false;
        final route = MaterialPageRoute<void>(
          builder: (_) => isDriver ? const DriverHomePage() : const HomePage(),
        );
        Navigator.of(context).pushAndRemoveUntil(route, (_) => false);
      } else {
        _onFailedAttempt();
      }
    } catch (e) {
      _onFailedAttempt();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onFailedAttempt() async {
    final attempts = (_prefs.getInt('failed_attempts') ?? 0) + 1;
    await _prefs.setInt('failed_attempts', attempts);
    _resetPin();
    HapticFeedback.heavyImpact();

    if (attempts >= 5) {
      _setLock();
      showToastNotification(
        context: context,
        title: 'Account Locked',
        message: 'Too many attempts. Try again in 5 minutes.',
        isSuccess: false,
      );
    } else {
      showToastNotification(
        context: context,
        title: 'Incorrect PIN',
        message: '${5 - attempts} attempts remaining',
        isSuccess: false,
      );
    }
  }

  void _resetPin() {
    setState(() {
      for (var i = 0; i < _pinLen; i++) _pin[i] = '';
      _cursor = 0;
    });
    _dotController.reverse();
  }

  Future<void> _biometric() async {
    if (_locked) {
      _showLockedMessage();
      return;
    }
    if (!_biometricAvailable) return;

    try {
      final ok = await _localAuth.authenticate(
        localizedReason: 'Verify your identity',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: true,
          sensitiveTransaction: true,
        ),
      );
      if (ok) {
        await _submitPin(bypass: true);
      }
    } on PlatformException catch (e) {
      debugPrint('local_auth error: code=${e.code}, message=${e.message}');
      var message = 'Authentication failed';
      switch (e.code) {
        case 'NotEnrolled':
          message = 'No biometrics enrolled on this device.';
          break;
        case 'NotAvailable':
          message = 'Biometric authentication is not available on this device.';
          break;
        case 'PasscodeNotSet':
          message = 'Set a device screen lock to enable biometrics.';
          break;
        case 'LockedOut':
          message = 'Too many attempts. Try again later.';
          break;
        case 'PermanentlyLockedOut':
          message = 'Biometrics locked. Use device PIN to unlock biometrics.';
          break;
      }
      showToastNotification(
        context: context,
        title: 'Biometric Error',
        message: message,
        isSuccess: false,
      );
    }
  }

  void _showLockedMessage() {
    showToastNotification(
      context: context,
      title: 'Account Locked',
      message: 'Please wait for the timer to complete',
      isSuccess: false,
    );
    HapticFeedback.mediumImpact();
  }

  void _handleInput(String digit) {
    if (_locked || _loading || _cursor >= _pinLen) return;

    HapticFeedback.lightImpact();
    setState(() {
      _pin[_cursor] = digit;
      _cursor++;
    });

    _dotController.forward();

    if (_cursor == _pinLen) {
      Future.delayed(const Duration(milliseconds: 300), _submitPin);
    }
  }

  void _handleBackspace() {
    if (_locked || _loading || _cursor == 0) return;

    HapticFeedback.lightImpact();
    setState(() {
      _cursor--;
      _pin[_cursor] = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : theme.colorScheme.background,
      body: Stack(
        children: [
          // Premium holographic background
          BackgroundWidget(
            style: HoloStyle.flux,
            animate: true,
            intensity: isDark ? 0.3 : 0.7,
          ),

          // Main content with proper responsive layout
          SafeArea(
            child: FadeTransition(
              opacity: _fadeIn,
              child: uiScale.landscape
                  ? _buildLandscapeLayout(uiScale, isDark, cs)
                  : _buildPortraitLayout(uiScale, isDark, cs),
            ),
          ),

          // Loading overlay
          if (_loading) _buildLoadingOverlay(uiScale, isDark, cs),

          // Lock overlay
          if (_locked) _buildLockOverlay(uiScale, isDark, cs),
        ],
      ),
    );
  }

  Widget _buildPortraitLayout(UIScale uiScale, bool isDark, ColorScheme cs) {
    final keypadSize = uiScale.tablet ? 400.0 : uiScale.inset(320.0);

    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: uiScale.tablet ? uiScale.inset(64) : uiScale.inset(24),
            vertical: uiScale.inset(24),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLogo(uiScale.heroLogoSize * 0.8, isDark, cs),
              SizedBox(height: uiScale.gap(24)),
              _buildWelcomeSection(uiScale, isDark, cs),
              SizedBox(height: uiScale.gap(36)),
              _buildPinIndicator(uiScale, isDark, cs),
              SizedBox(height: uiScale.gap(32)),
              if (_biometricAvailable) ...[
                _buildBiometricButton(uiScale, isDark, cs),
                SizedBox(height: uiScale.gap(36)),
              ],
              Container(
                width: keypadSize,
                constraints: BoxConstraints(
                  maxWidth: uiScale.width - uiScale.inset(40),
                ),
                child: _buildNumPad(uiScale, isDark, cs, isLandscape: false),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLandscapeLayout(UIScale uiScale, bool isDark, ColorScheme cs) {
    return Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Container(
          width: math.max(uiScale.width, 600),
          padding: EdgeInsets.symmetric(
            horizontal: uiScale.tablet ? uiScale.inset(64) : uiScale.inset(32),
            vertical: uiScale.inset(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Left side - Logo and info
              Expanded(
                flex: uiScale.tablet ? 3 : 2,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildLogo(uiScale.inset(80), isDark, cs),
                    SizedBox(height: uiScale.gap(16)),
                    _buildWelcomeSection(uiScale, isDark, cs),
                    SizedBox(height: uiScale.gap(24)),
                    _buildPinIndicator(uiScale, isDark, cs),
                    if (_biometricAvailable) ...[
                      SizedBox(height: uiScale.gap(16)),
                      _buildBiometricButton(uiScale, isDark, cs),
                    ],
                  ],
                ),
              ),

              // Divider
              Container(
                width: 1,
                height: uiScale.height * 0.5,
                margin: EdgeInsets.symmetric(horizontal: uiScale.inset(32)),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.3),
                      isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.3),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),

              // Right side - Numpad
              Expanded(
                flex: uiScale.tablet ? 2 : 2,
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: uiScale.inset(320),
                    maxHeight: uiScale.height - uiScale.inset(100),
                  ),
                  child: _buildNumPad(uiScale, isDark, cs, isLandscape: true),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogo(double size, bool isDark, ColorScheme cs) {
    return AnimatedBuilder(
      animation: _logoFloat,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _logoFloat.value),
          child: Container(
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
              ),
              boxShadow: [
                BoxShadow(
                  color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.3),
                  blurRadius: 30,
                  spreadRadius: 5,
                  offset: Offset(0, _logoFloat.value + 10),
                ),
                BoxShadow(
                  color: (isDark ? cs.secondary : AppColors.secondary).withOpacity(0.2),
                  blurRadius: 20,
                  spreadRadius: 2,
                  offset: Offset(0, _logoFloat.value + 5),
                ),
              ],
            ),
            child: Padding(
              padding: EdgeInsets.all(size * 0.2),
              child: Image.asset(
                'image/pickme.png',
                fit: BoxFit.contain,
                color: isDark ? cs.onPrimary : AppColors.surface,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWelcomeSection(UIScale uiScale, bool isDark, ColorScheme cs) {
    return Column(
      children: [
        Text(
          'Welcome Back',
          style: TextStyle(
            fontSize: uiScale.font(16),
            color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        SizedBox(height: uiScale.gap(8)),
        Text(
          _username ?? 'User',
          style: TextStyle(
            fontSize: uiScale.font(28),
            color: isDark ? cs.onSurface : AppColors.textPrimary,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildPinIndicator(UIScale uiScale, bool isDark, ColorScheme cs) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: uiScale.inset(20), vertical: uiScale.inset(16)),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceVariant.withOpacity(0.5) : AppColors.surface.withOpacity(0.8),
        borderRadius: BorderRadius.circular(uiScale.radius(20)),
        border: Border.all(
          color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.3),
          width: 1.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(_pinLen, (index) {
          final filled = _pin[index].isNotEmpty;
          final active = index == _cursor && !_locked;

          return AnimatedBuilder(
            animation: _dotScale,
            builder: (context, child) {
              return Container(
                margin: EdgeInsets.symmetric(horizontal: uiScale.inset(10)),
                width: uiScale.icon(16),
                height: uiScale.icon(16),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled
                      ? (isDark ? cs.primary : AppColors.primary)
                      : active
                      ? (isDark ? cs.primary : AppColors.primary).withOpacity(0.2)
                      : Colors.transparent,
                  border: Border.all(
                    color: active
                        ? (isDark ? cs.primary : AppColors.primary)
                        : filled
                        ? (isDark ? cs.primary : AppColors.primary).withOpacity(0.6)
                        : (isDark ? cs.outline : AppColors.mintBgLight).withOpacity(0.5),
                    width: active ? 2.5 : 1.5,
                  ),
                ),
                child: filled
                    ? Transform.scale(
                  scale: _cursor > index ? 1.0 : _dotScale.value,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDark ? cs.primary : AppColors.primary,
                    ),
                  ),
                )
                    : null,
              );
            },
          );
        }),
      ),
    );
  }

  Widget _buildBiometricButton(UIScale uiScale, bool isDark, ColorScheme cs) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _locked ? null : _biometric,
        borderRadius: BorderRadius.circular(uiScale.radius(30)),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: uiScale.inset(24),
            vertical: uiScale.inset(12),
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                (isDark ? cs.primary : AppColors.primary).withOpacity(0.15),
                (isDark ? cs.secondary : AppColors.secondary).withOpacity(0.15),
              ],
            ),
            borderRadius: BorderRadius.circular(uiScale.radius(30)),
            border: Border.all(
              color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.4),
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.fingerprint_rounded,
                color: isDark ? cs.primary : AppColors.primary,
                size: uiScale.icon(24),
              ),
              SizedBox(width: uiScale.gap(12)),
              Text(
                'Use Biometrics',
                style: TextStyle(
                  color: isDark ? cs.primary : AppColors.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: uiScale.font(14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNumPad(UIScale uiScale, bool isDark, ColorScheme cs, {required bool isLandscape}) {
    final buttonSize = uiScale.icon(isLandscape ? 56.0 : 64.0);
    final spacing = uiScale.gap(12.0);

    Widget cell(Widget child) => Padding(
      padding: EdgeInsets.symmetric(horizontal: spacing / 2),
      child: child,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int row = 0; row < 3; row++)
          Padding(
            padding: EdgeInsets.only(bottom: spacing),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int col = 0; col < 3; col++)
                  cell(_NumpadButton(
                    label: '${row * 3 + col + 1}',
                    size: buttonSize,
                    onTap: () => _handleInput('${row * 3 + col + 1}'),
                    disabled: _locked || _loading,
                    isDark: isDark,
                    cs: cs,
                  )),
              ],
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            cell(
              _biometricAvailable
                  ? _NumpadButton(
                icon: Icons.fingerprint_rounded,
                size: buttonSize,
                onTap: _biometric,
                disabled: _locked || _loading,
                accent: true,
                isDark: isDark,
                cs: cs,
              )
                  : SizedBox(width: buttonSize, height: buttonSize),
            ),
            cell(_NumpadButton(
              label: '0',
              size: buttonSize,
              onTap: () => _handleInput('0'),
              disabled: _locked || _loading,
              isDark: isDark,
              cs: cs,
            )),
            cell(_NumpadButton(
              icon: Icons.backspace_rounded,
              size: buttonSize,
              onTap: _handleBackspace,
              disabled: _locked || _loading || _cursor == 0,
              isDark: isDark,
              cs: cs,
            )),
          ],
        ),
      ],
    );
  }

  Widget _buildLoadingOverlay(UIScale uiScale, bool isDark, ColorScheme cs) {
    return Container(
      color: Colors.black.withOpacity(0.7),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Center(
          child: Container(
            padding: EdgeInsets.all(uiScale.inset(40)),
            decoration: BoxDecoration(
                color: isDark ? cs.surface.withOpacity(0.9) : Colors.white.withOpacity(0.95),
                borderRadius: BorderRadius.circular(uiScale.radius(24)),
                border: Border.all(
                  color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.3),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.5 : 0.1),
                    blurRadius: 30,
                    offset: const Offset(0, 10),
                  )
                ]
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: uiScale.icon(48),
                  height: uiScale.icon(48),
                  child: CircularProgressIndicator(
                      strokeWidth: 3.5,
                      color: isDark ? cs.primary : AppColors.primary
                  ),
                ),
                SizedBox(height: uiScale.gap(24)),
                Text(
                  'Verifying PIN',
                  style: TextStyle(
                    color: isDark ? cs.onSurface : AppColors.textPrimary,
                    fontSize: uiScale.font(18),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: uiScale.gap(8)),
                Text(
                  'Please wait...',
                  style: TextStyle(
                    color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                    fontSize: uiScale.font(14),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLockOverlay(UIScale uiScale, bool isDark, ColorScheme cs) {
    final minutes = _remaining.inMinutes;
    final seconds = _remaining.inSeconds % 60;

    return Container(
      color: Colors.black.withOpacity(0.85),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Center(
          child: Container(
            margin: EdgeInsets.all(uiScale.inset(32)),
            padding: EdgeInsets.all(uiScale.inset(40)),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [cs.surface, cs.surfaceVariant]
                    : [AppColors.surface, AppColors.mintBgLight],
              ),
              borderRadius: BorderRadius.circular(uiScale.radius(32)),
              border: Border.all(
                color: cs.error.withOpacity(0.3),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: cs.error.withOpacity(0.2),
                  blurRadius: 30,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: uiScale.icon(80),
                  height: uiScale.icon(80),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        cs.error.withOpacity(0.1),
                        cs.error.withOpacity(0.2),
                      ],
                    ),
                    border: Border.all(
                      color: cs.error.withOpacity(0.3),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    Icons.lock_clock_rounded,
                    size: uiScale.icon(40),
                    color: cs.error,
                  ),
                ),
                SizedBox(height: uiScale.gap(32)),
                Text(
                  'Account Locked',
                  style: TextStyle(
                    fontSize: uiScale.font(24),
                    fontWeight: FontWeight.w800,
                    color: isDark ? cs.onSurface : AppColors.textPrimary,
                  ),
                ),
                SizedBox(height: uiScale.gap(12)),
                Text(
                  'Too many failed attempts',
                  style: TextStyle(
                    fontSize: uiScale.font(16),
                    color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                  ),
                ),
                SizedBox(height: uiScale.gap(32)),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: uiScale.inset(32),
                    vertical: uiScale.inset(20),
                  ),
                  decoration: BoxDecoration(
                    color: (isDark ? cs.surfaceVariant : AppColors.surface).withOpacity(0.5),
                    borderRadius: BorderRadius.circular(uiScale.radius(20)),
                    border: Border.all(
                      color: (isDark ? cs.outline : AppColors.mintBgLight).withOpacity(0.5),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'Try again in',
                        style: TextStyle(
                          color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                          fontSize: uiScale.font(14),
                        ),
                      ),
                      SizedBox(height: uiScale.gap(8)),
                      Text(
                        '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          fontSize: uiScale.font(40),
                          fontWeight: FontWeight.w900,
                          color: isDark ? cs.primary : AppColors.primary,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Premium number pad button
class _NumpadButton extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final double size;
  final VoidCallback onTap;
  final bool disabled;
  final bool accent;
  final bool isDark;
  final ColorScheme cs;

  const _NumpadButton({
    this.label,
    this.icon,
    required this.size,
    required this.onTap,
    this.disabled = false,
    this.accent = false,
    required this.isDark,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: disabled ? 0.4 : 1.0,
      duration: const Duration(milliseconds: 200),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: disabled ? null : onTap,
          borderRadius: BorderRadius.circular(size / 2),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: accent && !disabled
                  ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [cs.primary.withOpacity(0.2), cs.secondary.withOpacity(0.2)]
                    : [AppColors.primary.withOpacity(0.2), AppColors.secondary.withOpacity(0.2)],
              )
                  : null,
              color: !accent
                  ? (isDark ? cs.surfaceVariant.withOpacity(0.6) : AppColors.surface.withOpacity(0.7))
                  : null,
              border: Border.all(
                color: disabled
                    ? (isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2))
                    : (accent
                    ? (isDark ? cs.primary : AppColors.primary).withOpacity(0.4)
                    : (isDark ? cs.outline : AppColors.mintBgLight).withOpacity(0.4)),
                width: 1.5,
              ),
              boxShadow: !disabled
                  ? [
                BoxShadow(
                  color: (accent ? (isDark ? cs.primary : AppColors.primary) : AppColors.deep).withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
                  : null,
            ),
            child: Center(
              child: label != null
                  ? Text(
                label!,
                style: TextStyle(
                  fontSize: size * 0.4,
                  fontWeight: FontWeight.w800,
                  color: disabled
                      ? (isDark ? cs.onSurfaceVariant : AppColors.textSecondary).withOpacity(0.3)
                      : (isDark ? cs.onSurface : AppColors.textPrimary),
                ),
              )
                  : Icon(
                icon,
                size: size * 0.4,
                color: disabled
                    ? (isDark ? cs.onSurfaceVariant : AppColors.textSecondary).withOpacity(0.3)
                    : (accent
                    ? (isDark ? cs.primary : AppColors.primary)
                    : (isDark ? cs.onSurface : AppColors.textPrimary)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}