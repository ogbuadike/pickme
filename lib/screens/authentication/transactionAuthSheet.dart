import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../utility/notification.dart';
import '../../themes/app_theme.dart';
import '../../ui/ui_scale.dart';

class TransactionPinBottomSheet extends StatefulWidget {
  static const int _maxAttempts = 5;
  static const int _lockDurationMinutes = 5;
  static const int _pinLength = 4;

  final Function(bool) onAuthenticationComplete;
  final ApiClient apiClient;

  const TransactionPinBottomSheet({
    Key? key,
    required this.onAuthenticationComplete,
    required this.apiClient,
  }) : super(key: key);

  static Future<bool> show(BuildContext context, ApiClient apiClient) async {
    return await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TransactionPinBottomSheet(
        onAuthenticationComplete: (success) => Navigator.pop(context, success),
        apiClient: apiClient,
      ),
    ) ?? false;
  }

  @override
  State<TransactionPinBottomSheet> createState() => _TransactionPinBottomSheetState();
}

class _TransactionPinBottomSheetState extends State<TransactionPinBottomSheet>
    with SingleTickerProviderStateMixin {

  // Custom PIN state (replacing native keyboard)
  final List<String> _pin = List.filled(TransactionPinBottomSheet._pinLength, '');
  int _cursor = 0;

  final LocalAuthentication _localAuth = LocalAuthentication();
  late SharedPreferences _prefs;
  DateTime? _lockTime;

  bool _isBiometricAvailable = false;
  bool _isLoading = false;
  bool _isLocked = false;
  int _failedAttempts = 0;

  // Animations
  late final AnimationController _dotController;
  late final Animation<double> _dotScale;

  @override
  void initState() {
    super.initState();

    _dotController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _dotScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _dotController, curve: Curves.elasticOut),
    );

    _initializePrefs();
    _checkBiometricAvailability();
  }

  @override
  void dispose() {
    _dotController.dispose();
    super.dispose();
  }

  Future<void> _initializePrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _loadStoredData();
  }

  void _loadStoredData() {
    setState(() {
      _failedAttempts = _prefs.getInt('failed_attempts') ?? 0;
      final lockTimeStr = _prefs.getString('lock_time');
      if (lockTimeStr != null) {
        _lockTime = DateTime.parse(lockTimeStr);
        _checkLockStatus();
      }
    });
  }

  Future<void> _checkBiometricAvailability() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final supported = await _localAuth.isDeviceSupported();
      final types = await _localAuth.getAvailableBiometrics();

      final hasBio = types.contains(BiometricType.fingerprint) ||
          types.contains(BiometricType.face) ||
          types.contains(BiometricType.strong) ||
          types.contains(BiometricType.weak) ||
          types.contains(BiometricType.iris);

      setState(() {
        _isBiometricAvailable = canCheck && supported && hasBio;
      });
    } catch (_) {
      setState(() => _isBiometricAvailable = false);
    }
  }

  void _checkLockStatus() {
    if (_lockTime == null) return;

    final lockDuration = DateTime.now().difference(_lockTime!);
    if (lockDuration.inMinutes < TransactionPinBottomSheet._lockDurationMinutes) {
      setState(() => _isLocked = true);
      Future.delayed(
        Duration(minutes: TransactionPinBottomSheet._lockDurationMinutes - lockDuration.inMinutes),
        _resetLockState,
      );
    } else {
      _resetLockState();
    }
  }

  void _resetLockState() {
    _prefs.remove('lock_time');
    _prefs.setInt('failed_attempts', 0);
    setState(() {
      _isLocked = false;
      _failedAttempts = 0;
    });
  }

  void _handleInput(String digit) {
    if (_isLocked || _isLoading || _cursor >= TransactionPinBottomSheet._pinLength) return;

    HapticFeedback.lightImpact();
    setState(() {
      _pin[_cursor] = digit;
      _cursor++;
    });

    _dotController.forward();

    if (_cursor == TransactionPinBottomSheet._pinLength) {
      Future.delayed(const Duration(milliseconds: 300), () => _handleAuthentication());
    }
  }

  void _handleBackspace() {
    if (_isLocked || _isLoading || _cursor == 0) return;

    HapticFeedback.lightImpact();
    setState(() {
      _cursor--;
      _pin[_cursor] = '';
    });
  }

  void _resetPin() {
    setState(() {
      for (var i = 0; i < TransactionPinBottomSheet._pinLength; i++) {
        _pin[i] = '';
      }
      _cursor = 0;
    });
    _dotController.reverse();
  }

  Future<void> _handleAuthentication() async {
    if (_isLocked) {
      showToastNotification(
        context: context,
        title: 'Account Locked',
        message: 'Too many failed attempts. Please try again later.',
        isSuccess: false,
      );
      return;
    }

    final pin = _pin.join();
    if (pin.length != TransactionPinBottomSheet._pinLength) return;

    await _verifyPin(pin);
  }

  Future<void> _verifyPin(String pin) async {
    setState(() => _isLoading = true);

    try {
      final userId = _prefs.getString('user_id');
      final data = {
        'uid': userId ?? '',
        'pin': pin,
      };

      final response = await widget.apiClient.request(
        ApiConstants.validatePinEndpoint,
        method: 'POST',
        data: data,
      );

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 200) {
        if (responseData['error'] == false) {
          _handleSuccessfulAuthentication();
        } else {
          _handleFailedAttempt(responseData['message'] ?? 'Incorrect PIN.');
        }
      } else {
        _handleFailedAttempt('Server Error. Please try again.');
      }
    } catch (error) {
      _handleFailedAttempt('Connection error. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _handleSuccessfulAuthentication() {
    _resetPin();
    _failedAttempts = 0;
    _prefs.setInt('failed_attempts', 0);
    HapticFeedback.mediumImpact();
    widget.onAuthenticationComplete(true);
  }

  void _handleFailedAttempt(String message) {
    _failedAttempts++;
    _prefs.setInt('failed_attempts', _failedAttempts);
    _resetPin();
    HapticFeedback.heavyImpact();

    if (_failedAttempts >= TransactionPinBottomSheet._maxAttempts) {
      _handleTooManyAttempts();
    } else {
      showToastNotification(
        context: context,
        title: 'Authentication Failed',
        message: '$message (${TransactionPinBottomSheet._maxAttempts - _failedAttempts} attempts left)',
        isSuccess: false,
      );
    }
  }

  void _handleTooManyAttempts() {
    setState(() => _isLocked = true);
    _lockTime = DateTime.now();
    _prefs.setString('lock_time', _lockTime!.toIso8601String());
    showToastNotification(
      context: context,
      title: 'Account Locked',
      message: 'Too many failed attempts. Please try again in 5 minutes.',
      isSuccess: false,
    );
  }

  Future<void> _authenticateWithBiometrics() async {
    if (_isLocked) {
      showToastNotification(
        context: context,
        title: 'Account Locked',
        message: 'Too many failed attempts. Please try again later.',
        isSuccess: false,
      );
      return;
    }
    if (!_isBiometricAvailable) return;

    try {
      final ok = await _localAuth.authenticate(
        localizedReason: 'Verify your identity to authorize transaction',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: true,
          sensitiveTransaction: true,
        ),
      );
      if (ok) {
        HapticFeedback.mediumImpact();
        widget.onAuthenticationComplete(true);
      }
    } on PlatformException catch (e) {
      String message = 'Authentication failed';
      switch (e.code) {
        case 'NotEnrolled':
          message = 'No biometrics enrolled on this device.';
          break;
        case 'NotAvailable':
          message = 'Biometric authentication is not available.';
          break;
        case 'PasscodeNotSet':
          message = 'Set a screen lock to enable biometrics.';
          break;
        case 'LockedOut':
        case 'PermanentlyLockedOut':
          message = 'Biometrics locked. Use device PIN to unlock.';
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

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    return BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: Container(
        decoration: BoxDecoration(
            color: isDark ? cs.surface.withOpacity(0.95) : Colors.white.withOpacity(0.95),
            borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(28))),
            border: Border(top: BorderSide(color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight, width: 1.5)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.6 : 0.1),
                blurRadius: 30,
                offset: const Offset(0, -10),
              )
            ]
        ),
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + uiScale.inset(16),
        ),
        child: SafeArea(
          top: false,
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(uiScale, isDark, cs),
                  SizedBox(height: uiScale.gap(24)),
                  _buildPinIndicator(uiScale, isDark, cs),
                  SizedBox(height: uiScale.gap(32)),
                  _buildNumPad(uiScale, isDark, cs),
                  SizedBox(height: uiScale.gap(12)),
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: TextButton.styleFrom(
                      foregroundColor: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                    ),
                    child: Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700, fontSize: uiScale.font(14))),
                  ),
                ],
              ),

              if (_isLoading) _buildLoadingOverlay(uiScale, isDark, cs),
              if (_isLocked) _buildLockOverlay(uiScale, isDark, cs),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(UIScale uiScale, bool isDark, ColorScheme cs) {
    return Column(
      children: [
        SizedBox(height: uiScale.gap(12)),
        Container(
          width: uiScale.inset(48),
          height: uiScale.inset(5),
          decoration: BoxDecoration(
            color: isDark ? cs.onSurfaceVariant.withOpacity(0.4) : Colors.grey.withOpacity(0.3),
            borderRadius: BorderRadius.circular(uiScale.radius(10)),
          ),
        ),
        SizedBox(height: uiScale.gap(24)),
        Text(
          'Transaction PIN',
          style: TextStyle(
            fontSize: uiScale.font(22),
            fontWeight: FontWeight.w900,
            color: isDark ? cs.onSurface : AppColors.textPrimary,
            letterSpacing: -0.5,
          ),
        ),
        SizedBox(height: uiScale.gap(8)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: uiScale.inset(32)),
          child: Text(
            'Enter your 4-digit PIN to authorize this transaction',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
              fontSize: uiScale.font(13),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPinIndicator(UIScale uiScale, bool isDark, ColorScheme cs) {
    final filledCount = _pin.where((e) => e.isNotEmpty).length;

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
        children: List.generate(TransactionPinBottomSheet._pinLength, (index) {
          final filled = index < filledCount;
          final active = index == _cursor && !_isLocked;

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

  Widget _buildNumPad(UIScale uiScale, bool isDark, ColorScheme cs) {
    final buttonSize = uiScale.icon(uiScale.compact ? 56.0 : 64.0);
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
                  cell(_buildNumpadButton(
                    label: '${row * 3 + col + 1}',
                    size: buttonSize,
                    onTap: () => _handleInput('${row * 3 + col + 1}'),
                    disabled: _isLocked || _isLoading,
                    isDark: isDark,
                    cs: cs,
                    uiScale: uiScale,
                  )),
              ],
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            cell(
              _isBiometricAvailable
                  ? _buildNumpadButton(
                icon: Icons.fingerprint_rounded,
                size: buttonSize,
                onTap: _authenticateWithBiometrics,
                disabled: _isLocked || _isLoading,
                accent: true,
                isDark: isDark,
                cs: cs,
                uiScale: uiScale,
              )
                  : SizedBox(width: buttonSize, height: buttonSize),
            ),
            cell(_buildNumpadButton(
              label: '0',
              size: buttonSize,
              onTap: () => _handleInput('0'),
              disabled: _isLocked || _isLoading,
              isDark: isDark,
              cs: cs,
              uiScale: uiScale,
            )),
            cell(_buildNumpadButton(
              icon: Icons.backspace_rounded,
              size: buttonSize,
              onTap: _handleBackspace,
              disabled: _isLocked || _isLoading || _cursor == 0,
              isDark: isDark,
              cs: cs,
              uiScale: uiScale,
            )),
          ],
        ),
      ],
    );
  }

  Widget _buildNumpadButton({
    String? label,
    IconData? icon,
    required double size,
    required VoidCallback onTap,
    bool disabled = false,
    bool accent = false,
    required bool isDark,
    required ColorScheme cs,
    required UIScale uiScale,
  }) {
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
                label,
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

  Widget _buildLoadingOverlay(UIScale uiScale, bool isDark, ColorScheme cs) {
    return Positioned.fill(
      child: Container(
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLockOverlay(UIScale uiScale, bool isDark, ColorScheme cs) {
    if (_lockTime == null) return const SizedBox.shrink();

    final elapsed = DateTime.now().difference(_lockTime!);
    final remain = Duration(minutes: TransactionPinBottomSheet._lockDurationMinutes) - elapsed;
    final minutes = remain.inMinutes.clamp(0, 99);
    final seconds = (remain.inSeconds % 60).clamp(0, 59);

    return Positioned.fill(
      child: Container(
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
                border: Border.all(color: cs.error.withOpacity(0.3), width: 2),
                boxShadow: [
                  BoxShadow(color: cs.error.withOpacity(0.2), blurRadius: 30, spreadRadius: 5),
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
                        colors: [cs.error.withOpacity(0.1), cs.error.withOpacity(0.2)],
                      ),
                      border: Border.all(color: cs.error.withOpacity(0.3), width: 2),
                    ),
                    child: Icon(Icons.lock_clock_rounded, size: uiScale.icon(40), color: cs.error),
                  ),
                  SizedBox(height: uiScale.gap(32)),
                  Text(
                    'Transaction Locked',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: uiScale.font(22), fontWeight: FontWeight.w800, color: isDark ? cs.onSurface : AppColors.textPrimary),
                  ),
                  SizedBox(height: uiScale.gap(12)),
                  Text(
                    'Too many failed attempts',
                    style: TextStyle(fontSize: uiScale.font(15), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
                  ),
                  SizedBox(height: uiScale.gap(32)),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: uiScale.inset(32), vertical: uiScale.inset(20)),
                    decoration: BoxDecoration(
                      color: (isDark ? cs.surfaceVariant : AppColors.surface).withOpacity(0.5),
                      borderRadius: BorderRadius.circular(uiScale.radius(20)),
                      border: Border.all(color: (isDark ? cs.outline : AppColors.mintBgLight).withOpacity(0.5), width: 1),
                    ),
                    child: Column(
                      children: [
                        Text('Try again in', style: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontSize: uiScale.font(14))),
                        SizedBox(height: uiScale.gap(8)),
                        Text(
                          '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
                          style: TextStyle(fontSize: uiScale.font(36), fontWeight: FontWeight.w900, color: isDark ? cs.primary : AppColors.primary, letterSpacing: 2),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: uiScale.gap(24)),
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text('Cancel Transaction', style: TextStyle(color: cs.error, fontWeight: FontWeight.w700, fontSize: uiScale.font(14))),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}