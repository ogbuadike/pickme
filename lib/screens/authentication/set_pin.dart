// lib/screens/set_pin.dart
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../themes/app_theme.dart';
import '../../utility/notification.dart';
import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../routes/routes.dart';
import '../../widgets/inner_background.dart';

class SetPinScreen extends StatefulWidget {
  const SetPinScreen({super.key});

  @override
  State<SetPinScreen> createState() => _SetPinScreenState();
}

class _SetPinScreenState extends State<SetPinScreen>
    with TickerProviderStateMixin {
  // PIN length and buffers
  static const int _pinLen = 4;
  final List<String> _pinCreate = List.filled(_pinLen, '');
  final List<String> _pinConfirm = List.filled(_pinLen, '');
  bool _confirmPhase = false;
  int _cursor = 0;

  // Services/state
  late final ApiClient _api;
  bool _loading = false;

  // Animations (match authentication.dart)
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

    // Setup animations to mirror AuthenticationScreen
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

    _dotScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _dotController, curve: Curves.elasticOut),
    );

    _logoFloat = Tween<double>(begin: -8.0, end: 8.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeInOut),
    );

    _fadeIn =
        Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(
          parent: _fadeController,
          curve: Curves.easeOut,
        ));
  }

  @override
  void dispose() {
    _dotController.dispose();
    _logoController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  // Helpers
  List<String> get _active => _confirmPhase ? _pinConfirm : _pinCreate;

  void _resetAll() {
    setState(() {
      for (var i = 0; i < _pinLen; i++) {
        _pinCreate[i] = '';
        _pinConfirm[i] = '';
      }
      _confirmPhase = false;
      _cursor = 0;
    });
    _dotController.reverse();
  }

  // Input handlers (mirror authentication flow)
  void _handleInput(String digit) {
    if (_loading || _cursor >= _pinLen) return;

    HapticFeedback.lightImpact();
    setState(() {
      _active[_cursor] = digit;
      _cursor++;
    });

    _dotController.forward();

    if (_cursor == _pinLen) {
      Future.delayed(const Duration(milliseconds: 250), () async {
        if (!_confirmPhase) {
          // Move to confirm phase
          setState(() {
            _confirmPhase = true;
            _cursor = 0;
          });
          _dotController.reverse();
        } else {
          // Compare and submit
          if (_pinCreate.join() == _pinConfirm.join()) {
            await _submitPin();
          } else {
            _showMismatch();
          }
        }
      });
    }
  }

  void _handleBackspace() {
    if (_loading || _cursor == 0) {
      // If at start of confirm, allow going back to create phase when empty
      if (_confirmPhase &&
          _cursor == 0 &&
          _pinConfirm.where((e) => e.isNotEmpty).isEmpty) {
        setState(() {
          _confirmPhase = false;
          _cursor = _pinCreate.where((e) => e.isNotEmpty).length;
        });
      }
      return;
    }

    HapticFeedback.lightImpact();
    setState(() {
      _cursor--;
      _active[_cursor] = '';
    });
  }

  void _showMismatch() {
    showToastNotification(
      context: context,
      title: 'PINs do not match',
      message: 'Re-enter to confirm',
      isSuccess: false,
    );
    setState(() {
      for (var i = 0; i < _pinLen; i++) {
        _pinConfirm[i] = '';
      }
      _cursor = 0;
    });
    _dotController.reverse();
  }

  // API submit
  Future<void> _submitPin() async {
    setState(() => _loading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final uid = prefs.getString('user_id') ?? '';

      final res = await _api.request(
        ApiConstants.setPinEndpoint,
        method: 'POST',
        data: {'uid': uid, 'pin': _pinCreate.join()},
      );

      final body = jsonDecode(res.body);
      if (res.statusCode == 200 && body['error'] == false) {
        await prefs.setString('user_pin', 'available');

        showToastNotification(
          context: context,
          title: 'Success',
          message: (body['message'] ?? 'PIN set successfully').toString(),
          isSuccess: true,
        );

        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(AppRoutes.authentication);
      } else {
        showToastNotification(
          context: context,
          title: 'Error',
          message:
          (body['message'] ?? 'Failed to set PIN. Please try again.').toString(),
          isSuccess: false,
        );
        _resetAll();
      }
    } catch (e) {
      showToastNotification(
        context: context,
        title: 'Error',
        message: e.toString(),
        isSuccess: false,
      );
      _resetAll();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ───────────────────── UI (mirrors Authentication) ─────────────────────
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
          // Same premium background
          const BackgroundWidget(
            style: HoloStyle.flux,
            animate: true,
            intensity: 0.7,
          ),

          SafeArea(
            child: FadeTransition(
              opacity: _fadeIn,
              child: isLandscape
                  ? _buildLandscapeLayout(size, padding, isTablet)
                  : _buildPortraitLayout(size, padding, isTablet, isSmallPhone),
            ),
          ),

          if (_loading) _buildLoadingOverlay(),
        ],
      ),
    );
  }

  Widget _buildPortraitLayout(
      Size size, EdgeInsets padding, bool isTablet, bool isSmallPhone) {
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
              _buildHeaderText(isTablet, isSmallPhone),
              SizedBox(height: isSmallPhone ? 32 : 48),
              _buildPinIndicator(isSmallPhone),
              SizedBox(height: isSmallPhone ? 24 : 32),
              Container(
                width: keypadSize,
                constraints: BoxConstraints(
                  maxWidth: size.width - 40,
                  maxHeight: isSmallPhone ? 320 : 400,
                ),
                child: _buildNumPad(isTablet, isSmallPhone, false),
              ),
              SizedBox(height: isSmallPhone ? 8 : 12),
              TextButton(
                onPressed: _loading ? null : () => Navigator.pop(context),
                child: const Text('Back to Login'),
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
              // Left: Logo & text
              Expanded(
                flex: isTablet ? 3 : 2,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildLogo(isTablet ? 100 : 80),
                    const SizedBox(height: 16),
                    _buildHeaderText(isTablet, false),
                    const SizedBox(height: 24),
                    _buildPinIndicator(false),
                  ],
                ),
              ),

              // Divider line (same look/feel as sample)
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

              // Right: Numpad
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

  // Floating logo (same as Authentication)
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

  // Title/subtitle to match sample’s hierarchy
  Widget _buildHeaderText(bool isTablet, bool isSmallPhone) {
    final titleSize = isTablet ? 28.0 : (isSmallPhone ? 22.0 : 26.0);
    final subtitleSize = isTablet ? 16.0 : (isSmallPhone ? 13.0 : 14.0);

    return Column(
      children: [
        Text(
          _confirmPhase ? 'Re-enter to confirm' : 'Create a 4-digit PIN',
          style: TextStyle(
            fontSize: titleSize,
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          _confirmPhase
              ? 'Make sure it matches your first entry'
              : 'Use digits you remember',
          style: TextStyle(
            fontSize: subtitleSize,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  // Circular dot indicator (same visual language as Authentication)
  Widget _buildPinIndicator(bool isSmallPhone) {
    final active = _active;
    final filledCount = active.where((e) => e.isNotEmpty).length;

    return Container
      (
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
        children: List.generate(_pinLen, (index) {
          final filled = index < filledCount;
          final activeDot = index == _cursor;

          return AnimatedBuilder(
            animation: _dotScale,
            builder: (context, _) {
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
                      : activeDot
                      ? AppColors.primary.withOpacity(0.2)
                      : Colors.transparent,
                  border: Border.all(
                    color: activeDot
                        ? AppColors.primary
                        : filled
                        ? AppColors.primary.withOpacity(0.6)
                        : AppColors.mintBgLight.withOpacity(0.5),
                    width: activeDot ? 2.5 : 1.5,
                  ),
                ),
                child: filled
                    ? Transform.scale(
                  scale:
                  _cursor > index ? 1.0 : _dotScale.value, // pop-in
                  child: Container(
                    decoration: const BoxDecoration(
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

  // Numpad (same component style as Authentication)
  Widget _buildNumPad(bool isTablet, bool isSmallPhone, bool isLandscape) {
    final buttonSize = isTablet
        ? 70.0
        : (isSmallPhone ? 55.0 : (isLandscape ? 50.0 : 60.0));
    final spacing = isTablet
        ? 16.0
        : (isSmallPhone ? 10.0 : (isLandscape ? 8.0 : 12.0));

    Widget cell(Widget child) => Padding(
      padding: EdgeInsets.symmetric(horizontal: spacing / 2),
      child: child,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
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
                    disabled: _loading,
                  )),
              ],
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            cell(const SizedBox.shrink()), // spacer
            cell(_NumpadButton(
              label: '0',
              size: buttonSize,
              onTap: () => _handleInput('0'),
              disabled: _loading,
            )),
            cell(_NumpadButton(
              icon: Icons.backspace_outlined,
              size: buttonSize,
              onTap: _handleBackspace,
              disabled: _loading || _cursor == 0,
            )),
          ],
        ),
      ],
    );
  }

  // Same loading overlay visuals used in Authentication
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
              children: const [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                SizedBox(height: 24),
                Text(
                  'Setting PIN',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 8),
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
}

// Premium number pad button (copied style from authentication.dart)
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
              boxShadow: !disabled
                  ? [
                BoxShadow(
                  color: (accent ? AppColors.primary : AppColors.deep)
                      .withOpacity(0.1),
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
