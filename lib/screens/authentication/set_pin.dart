// lib/screens/set_pin.dart
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
import '../../ui/ui_scale.dart';

// Added imports for correct home routing after PIN creation
import '../../driver/driver_home_page.dart';
import '../home_page.dart';

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

        // Check if they are a driver so we drop them in the correct screen
        final isDriver = prefs.getBool('user_is_driver') ?? false;

        showToastNotification(
          context: context,
          title: 'Success',
          message: (body['message'] ?? 'PIN set successfully').toString(),
          isSuccess: true,
        );

        if (!mounted) return;

        // Push straight to the correct dashboard based on role
        final route = MaterialPageRoute<void>(
          builder: (_) => isDriver ? const DriverHomePage() : const HomePage(),
        );
        Navigator.of(context).pushAndRemoveUntil(route, (_) => false);

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
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : theme.colorScheme.background,
      body: Stack(
        children: [
          // Same premium background
          BackgroundWidget(
            style: HoloStyle.flux,
            animate: true,
            intensity: isDark ? 0.3 : 0.7,
          ),

          SafeArea(
            child: FadeTransition(
              opacity: _fadeIn,
              child: uiScale.landscape
                  ? _buildLandscapeLayout(uiScale, isDark, cs)
                  : _buildPortraitLayout(uiScale, isDark, cs),
            ),
          ),

          if (_loading) _buildLoadingOverlay(uiScale, isDark, cs),
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
              _buildHeaderText(uiScale, isDark, cs),
              SizedBox(height: uiScale.gap(36)),
              _buildPinIndicator(uiScale, isDark, cs),
              SizedBox(height: uiScale.gap(32)),
              Container(
                width: keypadSize,
                constraints: BoxConstraints(
                  maxWidth: uiScale.width - uiScale.inset(40),
                ),
                child: _buildNumPad(uiScale, isDark, cs, isLandscape: false),
              ),
              SizedBox(height: uiScale.gap(12)),
              TextButton(
                onPressed: _loading ? null : () => Navigator.pop(context),
                style: TextButton.styleFrom(
                  foregroundColor: isDark ? cs.primary : AppColors.primary,
                ),
                child: Text('Back to Login', style: TextStyle(fontSize: uiScale.font(14), fontWeight: FontWeight.w700)),
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
              // Left: Logo & text
              Expanded(
                flex: uiScale.tablet ? 3 : 2,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildLogo(uiScale.inset(80), isDark, cs),
                    SizedBox(height: uiScale.gap(16)),
                    _buildHeaderText(uiScale, isDark, cs),
                    SizedBox(height: uiScale.gap(24)),
                    _buildPinIndicator(uiScale, isDark, cs),
                  ],
                ),
              ),

              // Divider line
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

              // Right: Numpad
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

  // Floating logo
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

  // Title/subtitle
  Widget _buildHeaderText(UIScale uiScale, bool isDark, ColorScheme cs) {
    return Column(
      children: [
        Text(
          _confirmPhase ? 'Re-enter to confirm' : 'Create a 4-digit PIN',
          style: TextStyle(
            fontSize: uiScale.font(24),
            color: isDark ? cs.onSurface : AppColors.textPrimary,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
          ),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: uiScale.gap(6)),
        Text(
          _confirmPhase
              ? 'Make sure it matches your first entry'
              : 'Use digits you remember',
          style: TextStyle(
            fontSize: uiScale.font(14),
            color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  // Circular dot indicator
  Widget _buildPinIndicator(UIScale uiScale, bool isDark, ColorScheme cs) {
    final active = _active;
    final filledCount = active.where((e) => e.isNotEmpty).length;

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
        children: List.generate(_pinLen, (index) {
          final filled = index < filledCount;
          final activeDot = index == _cursor;

          return AnimatedBuilder(
            animation: _dotScale,
            builder: (context, _) {
              return Container(
                margin: EdgeInsets.symmetric(horizontal: uiScale.inset(10)),
                width: uiScale.icon(16),
                height: uiScale.icon(16),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled
                      ? (isDark ? cs.primary : AppColors.primary)
                      : activeDot
                      ? (isDark ? cs.primary : AppColors.primary).withOpacity(0.2)
                      : Colors.transparent,
                  border: Border.all(
                    color: activeDot
                        ? (isDark ? cs.primary : AppColors.primary)
                        : filled
                        ? (isDark ? cs.primary : AppColors.primary).withOpacity(0.6)
                        : (isDark ? cs.outline : AppColors.mintBgLight).withOpacity(0.5),
                    width: activeDot ? 2.5 : 1.5,
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

  // Numpad
  Widget _buildNumPad(UIScale uiScale, bool isDark, ColorScheme cs, {required bool isLandscape}) {
    final buttonSize = uiScale.icon(isLandscape ? 56.0 : 64.0);
    final spacing = uiScale.gap(12.0);

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
                  cell(_buildNumpadButton(
                    label: '${row * 3 + col + 1}',
                    size: buttonSize,
                    onTap: () => _handleInput('${row * 3 + col + 1}'),
                    disabled: _loading,
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
            cell(SizedBox(width: buttonSize, height: buttonSize)), // spacer
            cell(_buildNumpadButton(
              label: '0',
              size: buttonSize,
              onTap: () => _handleInput('0'),
              disabled: _loading,
              isDark: isDark,
              cs: cs,
              uiScale: uiScale,
            )),
            cell(_buildNumpadButton(
              icon: Icons.backspace_rounded,
              size: buttonSize,
              onTap: _handleBackspace,
              disabled: _loading || _cursor == 0,
              isDark: isDark,
              cs: cs,
              uiScale: uiScale,
            )),
          ],
        ),
      ],
    );
  }

  // Loading overlay
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
                  child: CircularProgressIndicator(strokeWidth: 3.5, color: isDark ? cs.primary : AppColors.primary),
                ),
                SizedBox(height: uiScale.gap(24)),
                Text(
                  'Setting PIN',
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

  // Premium number pad button logic embedded here to access theme natively
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
}