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
  late final AnimationController _shakeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  late final Animation<double> _shakeAnim = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0, end: -12), weight: 1),
    TweenSequenceItem(tween: Tween(begin: -12, end: 10), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 10, end: -8), weight: 2),
    TweenSequenceItem(tween: Tween(begin: -8, end: 6), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 6, end: 0), weight: 1),
  ]).animate(CurvedAnimation(parent: _shakeCtrl, curve: Curves.elasticOut));

  late final AnimationController _fadeInCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);
    _init();
    _fadeInCtrl.forward();
  }

  @override
  void dispose() {
    _unlockTicker?.cancel();
    _shakeCtrl.dispose();
    _fadeInCtrl.dispose();
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
    if (!bypass && full.length < _pinLen) {
      showToastNotification(
        context: context,
        title: 'Incomplete PIN',
        message: 'Please enter your 4-digit PIN',
        isSuccess: false,
      );
      return;
    }

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

    // Shake animation
    _shakeCtrl.forward().then((_) => _shakeCtrl.reset());
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
    final screenSize = MediaQuery.of(context).size;
    final isSmallScreen = screenSize.width < 360;
    final isTablet = screenSize.width > 600;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Stack(
        children: [
          // Animated background
          const BackgroundWidget(
            showGrid: false,
            intensity: 0.8,
          ),

          // Main content
          SafeArea(
            child: FadeTransition(
              opacity: CurvedAnimation(
                parent: _fadeInCtrl,
                curve: Curves.easeOut,
              ),
              child: _buildContent(isSmallScreen, isTablet),
            ),
          ),

          // Lock overlay
          if (_locked) _buildLockOverlay(),
        ],
      ),
    );
  }

  Widget _buildContent(bool isSmallScreen, bool isTablet) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxContentWidth = isTablet ? 500.0 : double.infinity;

        return Center(
          child: Container(
            width: maxContentWidth,
            padding: EdgeInsets.symmetric(
              horizontal: isSmallScreen ? 16 : 24,
            ),
            child: Column(
              children: [
                SizedBox(height: constraints.maxHeight * 0.05),
                _buildHeader(),
                const Spacer(),
                AnimatedBuilder(
                  animation: _shakeAnim,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(_shakeAnim.value, 0),
                      child: _buildPinSection(isSmallScreen),
                    );
                  },
                ),
                if (_loading) _buildLoadingIndicator(),
                const Spacer(),
                _buildKeypad(constraints, isSmallScreen),
                SizedBox(height: constraints.maxHeight * 0.03),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        // Logo with glow effect
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.surface,
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withOpacity(0.3),
                blurRadius: 20,
                spreadRadius: 5,
              ),
            ],
          ),
          padding: const EdgeInsets.all(12),
          child: Image.asset(
            'image/pickme.png',
            fit: BoxFit.contain,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Welcome back',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: AppColors.textSecondary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _username ?? 'User',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w900,
            color: AppColors.textPrimary,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildPinSection(bool isSmallScreen) {
    final boxSize = isSmallScreen ? 48.0 : 56.0;
    final spacing = isSmallScreen ? 8.0 : 12.0;

    return Column(
      children: [
        Text(
          'Enter PIN',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: AppColors.textSecondary,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(_pinLen, (i) {
            final active = i == _cursor && !_locked;
            final filled = _pin[i].isNotEmpty;

            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutBack,
              margin: EdgeInsets.symmetric(horizontal: spacing),
              width: boxSize,
              height: boxSize,
              decoration: BoxDecoration(
                color: filled
                    ? AppColors.primary.withOpacity(0.1)
                    : AppColors.surface.withOpacity(0.9),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: active
                      ? AppColors.primary
                      : (filled ? AppColors.primary.withOpacity(0.5) : AppColors.mintBgLight),
                  width: active ? 2.5 : 1.5,
                ),
                boxShadow: [
                  if (active)
                    BoxShadow(
                      color: AppColors.primary.withOpacity(0.25),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                ],
              ),
              child: Center(
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 200),
                  scale: filled ? 1.0 : 0.0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withOpacity(0.4),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 32),
        if (_biometricAvailable)
          _buildBiometricButton(),
      ],
    );
  }

  Widget _buildBiometricButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _locked ? null : _biometric,
        borderRadius: BorderRadius.circular(30),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
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
                size: 24,
              ),
              const SizedBox(width: 8),
              Text(
                'Use Biometrics',
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      child: LinearProgressIndicator(
        minHeight: 3,
        backgroundColor: AppColors.mintBgLight.withOpacity(0.3),
        valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
      ),
    );
  }

  Widget _buildKeypad(BoxConstraints constraints, bool isSmallScreen) {
    final buttonSize = _calculateButtonSize(constraints, isSmallScreen);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int row = 0; row < 4; row++) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (int col = 0; col < 3; col++)
                _buildKeypadButton(row, col, buttonSize),
            ],
          ),
          if (row < 3) SizedBox(height: isSmallScreen ? 8 : 12),
        ],
      ],
    );
  }

  Size _calculateButtonSize(BoxConstraints constraints, bool isSmallScreen) {
    final availableWidth = constraints.maxWidth - 32;
    final buttonWidth = (availableWidth / 3.5).clamp(70.0, 100.0);
    final buttonHeight = isSmallScreen ? 52.0 : 60.0;
    return Size(buttonWidth, buttonHeight);
  }

  Widget _buildKeypadButton(int row, int col, Size size) {
    String? label;
    IconData? icon;
    VoidCallback? onTap;
    Color? color;

    if (row < 3) {
      final number = (row * 3 + col + 1).toString();
      label = number;
      onTap = () => _handleKeypadTap(number);
    } else {
      switch (col) {
        case 0:
          icon = Icons.fingerprint_rounded;
          onTap = _biometricAvailable ? _biometric : null;
          color = AppColors.primary;
          break;
        case 1:
          label = '0';
          onTap = () => _handleKeypadTap('0');
          break;
        case 2:
          icon = Icons.backspace_outlined;
          onTap = _handleBackspace;
          color = AppColors.error;
          break;
      }
    }

    final isDisabled = _locked || _loading;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isDisabled ? null : onTap,
          borderRadius: BorderRadius.circular(size.height / 2),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: size.width,
            height: size.height,
            decoration: BoxDecoration(
              color: AppColors.surface.withOpacity(isDisabled ? 0.3 : 0.9),
              borderRadius: BorderRadius.circular(size.height / 2),
              border: Border.all(
                color: color?.withOpacity(0.3) ?? AppColors.mintBgLight,
                width: 1,
              ),
            ),
            child: Center(
              child: label != null
                  ? Text(
                label,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: isDisabled
                      ? AppColors.textSecondary.withOpacity(0.3)
                      : AppColors.textPrimary,
                ),
              )
                  : Icon(
                icon,
                color: isDisabled
                    ? AppColors.textSecondary.withOpacity(0.3)
                    : (color ?? AppColors.textSecondary),
                size: 24,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handleKeypadTap(String digit) {
    if (_locked || _loading || _cursor >= _pinLen) return;

    HapticFeedback.selectionClick();
    setState(() {
      _pin[_cursor] = digit;
      _cursor++;
    });

    if (_cursor == _pinLen) {
      Future.delayed(const Duration(milliseconds: 300), _submitPin);
    }
  }

  void _handleBackspace() {
    if (_locked || _loading || _cursor == 0) return;

    HapticFeedback.selectionClick();
    setState(() {
      _cursor--;
      _pin[_cursor] = '';
    });
  }

  Widget _buildLockOverlay() {
    final minutes = _remaining.inMinutes.remainder(60);
    final seconds = _remaining.inSeconds.remainder(60);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      color: Colors.black.withOpacity(0.7),
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(32),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.error.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.lock_clock_rounded,
                  size: 32,
                  color: AppColors.error,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Account Locked',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Too many failed attempts',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: AppColors.mintBgLight.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.timer_outlined,
                      color: AppColors.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                        fontFeatures: [const FontFeature.tabularFigures()],
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