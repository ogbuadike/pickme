// lib/screens/authentication.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
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
          biometricOnly: true,        // keep true since you want strictly biometrics
          stickyAuth: true,
          useErrorDialogs: true,      // let OS show helpful messages
          sensitiveTransaction: true, // newer Android guidance
        ),
      );
      if (ok) {
        await _submitPin(bypass: true);
      }
    } on PlatformException catch (e) {
      // LOG THIS to see the actual cause
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

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final isLandscape = size.width > size.height;
    final isTablet = size.shortestSide > 600;
    final isSmallPhone = size.width < 360;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Stack(
        children: [
          // Premium holographic background
          const BackgroundWidget(
            style: HoloStyle.flux,
            animate: true,
            intensity: 0.7,
          ),

          // Main content with proper responsive layout
          SafeArea(
            child: FadeTransition(
              opacity: _fadeIn,
              child: isLandscape
                  ? _buildLandscapeLayout(size, padding, isTablet)
                  : _buildPortraitLayout(size, padding, isTablet, isSmallPhone),
            ),
          ),

          // Loading overlay
          if (_loading) _buildLoadingOverlay(),

          // Lock overlay
          if (_locked) _buildLockOverlay(),
        ],
      ),
    );
  }

  Widget _buildPortraitLayout(Size size, EdgeInsets padding, bool isTablet, bool isSmallPhone) {
    final keypadSize = isTablet ? 400.0 : (isSmallPhone ? 280.0 : 320.0);

    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isTablet ? 64 : (isSmallPhone ? 20 : 32),
            vertical: 24,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLogo(isTablet ? 120 : (isSmallPhone ? 80 : 100)),
              SizedBox(height: isSmallPhone ? 24 : 32),
              _buildWelcomeSection(isTablet, isSmallPhone),
              SizedBox(height: isSmallPhone ? 32 : 48),
              _buildPinIndicator(isSmallPhone),
              SizedBox(height: isSmallPhone ? 24 : 32),
              if (_biometricAvailable) ...[
                _buildBiometricButton(isTablet),
                SizedBox(height: isSmallPhone ? 32 : 48),
              ],
              Container(
                width: keypadSize,
                constraints: BoxConstraints(
                  maxWidth: size.width - 40,
                  maxHeight: isSmallPhone ? 320 : 400,
                ),
                child: _buildNumPad(isTablet, isSmallPhone, false),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLandscapeLayout(Size size, EdgeInsets padding, bool isTablet) {
    return Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Container(
          width: math.max(size.width, 600),
          padding: EdgeInsets.symmetric(
            horizontal: isTablet ? 64 : 32,
            vertical: 16,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Left side - Logo and info
              Expanded(
                flex: isTablet ? 3 : 2,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildLogo(isTablet ? 100 : 80),
                    const SizedBox(height: 16),
                    _buildWelcomeSection(isTablet, false),
                    const SizedBox(height: 24),
                    _buildPinIndicator(false),
                    if (_biometricAvailable) ...[
                      const SizedBox(height: 16),
                      _buildBiometricButton(isTablet),
                    ],
                  ],
                ),
              ),

              // Divider
              Container(
                width: 1,
                height: size.height * 0.5,
                margin: const EdgeInsets.symmetric(horizontal: 32),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      AppColors.mintBgLight.withOpacity(0.3),
                      AppColors.mintBgLight.withOpacity(0.3),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),

              // Right side - Numpad
              Expanded(
                flex: isTablet ? 2 : 2,
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: 320,
                    maxHeight: size.height - 100,
                  ),
                  child: _buildNumPad(isTablet, false, true),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogo(double size) {
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
                colors: [
                  AppColors.surface,
                  AppColors.mintBgLight.withOpacity(0.9),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withOpacity(0.3),
                  blurRadius: 30,
                  spreadRadius: 5,
                  offset: Offset(0, _logoFloat.value + 10),
                ),
                BoxShadow(
                  color: AppColors.secondary.withOpacity(0.2),
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
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWelcomeSection(bool isTablet, bool isSmallPhone) {
    final titleSize = isTablet ? 32.0 : (isSmallPhone ? 24.0 : 28.0);
    final subtitleSize = isTablet ? 18.0 : (isSmallPhone ? 14.0 : 16.0);

    return Column(
      children: [
        Text(
          'Welcome Back',
          style: TextStyle(
            fontSize: subtitleSize,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _username ?? 'User',
          style: TextStyle(
            fontSize: titleSize,
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildPinIndicator(bool isSmallPhone) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.primary.withOpacity(0.3),
          width: 1,
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
                margin: EdgeInsets.symmetric(
                  horizontal: isSmallPhone ? 8 : 12,
                ),
                width: isSmallPhone ? 14 : 16,
                height: isSmallPhone ? 14 : 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled
                      ? AppColors.primary
                      : active
                      ? AppColors.primary.withOpacity(0.2)
                      : Colors.transparent,
                  border: Border.all(
                    color: active
                        ? AppColors.primary
                        : filled
                        ? AppColors.primary.withOpacity(0.6)
                        : AppColors.mintBgLight.withOpacity(0.5),
                    width: active ? 2.5 : 1.5,
                  ),
                ),
                child: filled
                    ? Transform.scale(
                  scale: _cursor > index ? 1.0 : _dotScale.value,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.primary,
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

  Widget _buildBiometricButton(bool isTablet) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _locked ? null : _biometric,
        borderRadius: BorderRadius.circular(30),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: isTablet ? 32 : 24,
            vertical: isTablet ? 14 : 12,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.primary.withOpacity(0.1),
                AppColors.secondary.withOpacity(0.1),
              ],
            ),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: AppColors.primary.withOpacity(0.3),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.fingerprint_rounded,
                color: AppColors.primary,
                size: isTablet ? 28 : 24,
              ),
              const SizedBox(width: 12),
              Text(
                'Use Biometrics',
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: isTablet ? 16 : 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNumPad(bool isTablet, bool isSmallPhone, bool isLandscape) {
    final buttonSize = isTablet
        ? 70.0
        : (isSmallPhone ? 55.0 : (isLandscape ? 50.0 : 60.0));
    final spacing = isTablet
        ? 16.0
        : (isSmallPhone ? 10.0 : (isLandscape ? 8.0 : 12.0));

    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Numbers 1-9
        for (int row = 0; row < 3; row++)
          Padding(
            padding: EdgeInsets.only(bottom: spacing),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int col = 0; col < 3; col++)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: spacing / 2),
                    child: _NumpadButton(
                      label: '${row * 3 + col + 1}',
                      size: buttonSize,
                      onTap: () => _handleInput('${row * 3 + col + 1}'),
                      disabled: _locked || _loading,
                    ),
                  ),
              ],
            ),
          ),
        // Bottom row
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: spacing / 2),
              child: _NumpadButton(
                icon: Icons.fingerprint_rounded,
                size: buttonSize,
                onTap: _biometric,
                disabled: _locked || _loading || !_biometricAvailable,
                accent: true,
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: spacing / 2),
              child: _NumpadButton(
                label: '0',
                size: buttonSize,
                onTap: () => _handleInput('0'),
                disabled: _locked || _loading,
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: spacing / 2),
              child: _NumpadButton(
                icon: Icons.backspace_outlined,
                size: buttonSize,
                onTap: _handleBackspace,
                disabled: _locked || _loading || _cursor == 0,
              ),
            ),
          ],
        ),
      ],
    );
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

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.7),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.surface.withOpacity(0.95),
                  AppColors.mintBgLight.withOpacity(0.95),
                ],
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: AppColors.primary.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Verifying PIN',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Please wait...',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLockOverlay() {
    final minutes = _remaining.inMinutes;
    final seconds = _remaining.inSeconds % 60;

    return Container(
      color: Colors.black.withOpacity(0.8),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(32),
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.surface,
                  AppColors.mintBgLight,
                ],
              ),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: AppColors.error.withOpacity(0.3),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.error.withOpacity(0.2),
                  blurRadius: 30,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        AppColors.error.withOpacity(0.1),
                        AppColors.error.withOpacity(0.2),
                      ],
                    ),
                    border: Border.all(
                      color: AppColors.error.withOpacity(0.3),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    Icons.lock_clock_rounded,
                    size: 40,
                    color: AppColors.error,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'Account Locked',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Too many failed attempts',
                  style: TextStyle(
                    fontSize: 16,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 20,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppColors.mintBgLight.withOpacity(0.5),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'Try again in',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.w900,
                          color: AppColors.primary,
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

  const _NumpadButton({
    this.label,
    this.icon,
    required this.size,
    required this.onTap,
    this.disabled = false,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
                colors: [
                  AppColors.primary.withOpacity(0.2),
                  AppColors.secondary.withOpacity(0.2),
                ],
              )
                  : null,
              color: !accent
                  ? (isDark
                  ? AppColors.surface.withOpacity(0.05)
                  : AppColors.surface.withOpacity(0.7))
                  : null,
              border: Border.all(
                color: disabled
                    ? AppColors.mintBgLight.withOpacity(0.2)
                    : (accent
                    ? AppColors.primary.withOpacity(0.4)
                    : AppColors.mintBgLight.withOpacity(0.4)),
                width: 1.5,
              ),
              boxShadow: !disabled ? [
                BoxShadow(
                  color: (accent ? AppColors.primary : AppColors.deep)
                      .withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ] : null,
            ),
            child: Center(
              child: label != null
                  ? Text(
                label!,
                style: TextStyle(
                  fontSize: size * 0.35,
                  fontWeight: FontWeight.w700,
                  color: disabled
                      ? AppColors.textSecondary.withOpacity(0.3)
                      : AppColors.textPrimary,
                ),
              )
                  : Icon(
                icon,
                size: size * 0.35,
                color: disabled
                    ? AppColors.textSecondary.withOpacity(0.3)
                    : (accent
                    ? AppColors.primary
                    : AppColors.textPrimary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}