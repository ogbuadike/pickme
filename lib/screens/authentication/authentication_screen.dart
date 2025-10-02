// lib/screens/authentication.dart
import 'dart:async';
import 'dart:convert';
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

class AuthenticationScreen extends StatefulWidget {
  const AuthenticationScreen({Key? key}) : super(key: key);

  @override
  State<AuthenticationScreen> createState() => _AuthenticationScreenState();
}

class _AuthenticationScreenState extends State<AuthenticationScreen>
    with SingleTickerProviderStateMixin {
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

  // Simple pulse animation for dots
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(
      begin: 0.5,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));

    _init();
  }

  @override
  void dispose() {
    _unlockTicker?.cancel();
    _pulseController.dispose();
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
      _biometricAvailable = canCheck &&
          supported &&
          (types.contains(BiometricType.fingerprint) ||
              types.contains(BiometricType.face) ||
              types.contains(BiometricType.strong));
    } catch (e) {
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
        Navigator.of(context).pushReplacementNamed(AppRoutes.home);
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
        Navigator.of(context).pushReplacementNamed(AppRoutes.home);
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
  }

  Future<void> _biometric() async {
    if (_locked) {
      _showLockedMessage();
      return;
    }
    if (!_biometricAvailable) return;

    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Verify your identity',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      if (authenticated) {
        await _submitPin(bypass: true);
      }
    } on PlatformException catch (e) {
      String message = 'Authentication failed';
      if (e.code == 'NotEnrolled') {
        message = 'No biometrics enrolled';
      } else if (e.code == 'LockedOut') {
        message = 'Too many failed attempts';
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
    final isSmallScreen = size.width < 360;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Stack(
        children: [
          // Simple gradient background
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.primary.withOpacity(0.1),
                  AppColors.offWhite,
                ],
              ),
            ),
          ),

          // Main content
          SafeArea(
            child: SingleChildScrollView(
              child: Container(
                height: size.height - MediaQuery.of(context).padding.top,
                padding: EdgeInsets.symmetric(horizontal: isSmallScreen ? 20 : 32),
                child: Column(
                  children: [
                    const Spacer(flex: 2),
                    _buildLogo(),
                    const SizedBox(height: 48),
                    _buildWelcomeText(),
                    const SizedBox(height: 48),
                    _buildPinDots(),
                    const SizedBox(height: 32),
                    if (_biometricAvailable) _buildBiometricHint(),
                    const Spacer(flex: 3),
                    _buildNumPad(isSmallScreen),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ),

          // Loading overlay
          if (_loading)
            Container(
              color: Colors.black26,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Verifying...',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Lock overlay
          if (_locked) _buildLockOverlay(),
        ],
      ),
    );
  }

  Widget _buildLogo() {
    return Container(
      width: 100,
      height: 100,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.2),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Image.asset(
        'image/pickme.png',
        fit: BoxFit.contain,
      ),
    );
  }

  Widget _buildWelcomeText() {
    return Column(
      children: [
        Text(
          'Welcome back',
          style: TextStyle(
            fontSize: 16,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _username ?? 'User',
          style: TextStyle(
            fontSize: 28,
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _buildPinDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_pinLen, (index) {
        final filled = _pin[index].isNotEmpty;
        final active = index == _cursor;

        return AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled
                    ? AppColors.primary
                    : active
                    ? AppColors.primary.withOpacity(_pulseAnimation.value * 0.3)
                    : AppColors.mintBgLight,
                border: Border.all(
                  color: active
                      ? AppColors.primary.withOpacity(_pulseAnimation.value)
                      : AppColors.mintBgLight,
                  width: active ? 2 : 1,
                ),
              ),
            );
          },
        );
      }),
    );
  }

  Widget _buildBiometricHint() {
    return TextButton.icon(
      onPressed: _locked ? null : _biometric,
      icon: Icon(
        Icons.fingerprint,
        color: AppColors.primary.withOpacity(0.7),
      ),
      label: Text(
        'Use biometrics',
        style: TextStyle(
          color: AppColors.primary.withOpacity(0.7),
        ),
      ),
    );
  }

  Widget _buildNumPad(bool isSmallScreen) {
    final buttonSize = isSmallScreen ? 60.0 : 72.0;
    final spacing = isSmallScreen ? 16.0 : 20.0;

    return Column(
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
                    child: _NumButton(
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
              child: _NumButton(
                icon: Icons.fingerprint,
                size: buttonSize,
                onTap: _biometric,
                disabled: _locked || _loading || !_biometricAvailable,
                isPrimary: true,
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: spacing / 2),
              child: _NumButton(
                label: '0',
                size: buttonSize,
                onTap: () => _handleInput('0'),
                disabled: _locked || _loading,
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: spacing / 2),
              child: _NumButton(
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

    if (_cursor == _pinLen) {
      Future.delayed(const Duration(milliseconds: 200), _submitPin);
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

  Widget _buildLockOverlay() {
    final minutes = _remaining.inMinutes;
    final seconds = _remaining.inSeconds % 60;

    return Container(
      color: Colors.black54,
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(32),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_clock,
                size: 48,
                color: AppColors.error,
              ),
              const SizedBox(height: 24),
              Text(
                'Too many attempts',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Try again in',
                style: TextStyle(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Custom number button widget
class _NumButton extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final double size;
  final VoidCallback onTap;
  final bool disabled;
  final bool isPrimary;

  const _NumButton({
    this.label,
    this.icon,
    required this.size,
    required this.onTap,
    this.disabled = false,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final backgroundColor = isPrimary
        ? AppColors.primary.withOpacity(disabled ? 0.3 : 1.0)
        : AppColors.surface;

    final contentColor = isPrimary
        ? AppColors.surface
        : disabled
        ? AppColors.textSecondary.withOpacity(0.3)
        : AppColors.textPrimary;

    return Material(
      color: backgroundColor,
      shape: CircleBorder(
        side: BorderSide(
          color: disabled
              ? AppColors.mintBgLight.withOpacity(0.5)
              : AppColors.mintBgLight,
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: disabled ? null : onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          child: label != null
              ? Text(
            label!,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: contentColor,
            ),
          )
              : Icon(
            icon,
            size: 24,
            color: contentColor,
          ),
        ),
      ),
    );
  }
}