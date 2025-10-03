// lib/screens/set_pin.dart
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

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
    with SingleTickerProviderStateMixin {
  static const int _pinLen = 4;

  // Phase 1: create, Phase 2: confirm
  bool _confirmPhase = false;

  // Buffers
  final List<String> _pin = List.filled(_pinLen, '');
  final List<String> _confirm = List.filled(_pinLen, '');
  int _cursor = 0;

  // Services/state
  late ApiClient _api;
  bool _busy = false;

  // Shake animation on mismatch
  late final AnimationController _shake;
  late final Animation<double> _shakeAnim;

  // Floating header logo (subtle)
  late final AnimationController _float;
  late final Animation<double> _logoFloat;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);

    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _shakeAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -8), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -8, end: 8), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8, end: -6), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -6, end: 0), weight: 1),
    ]).animate(CurvedAnimation(parent: _shake, curve: Curves.easeOut));

    _float = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    )..repeat(reverse: true);

    _logoFloat = Tween<double>(begin: -6.0, end: 6.0).animate(
      CurvedAnimation(parent: _float, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _shake.dispose();
    _float.dispose();
    super.dispose();
  }

  // ── Flow helpers ───────────────────────────────────────────────────────
  List<String> get _active => _confirmPhase ? _confirm : _pin;

  void _tap(String d) {
    if (_busy) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (_cursor < _pinLen) {
        _active[_cursor] = d;
        _cursor++;
      }
    });

    if (_cursor == _pinLen) {
      if (_confirmPhase) {
        if (_pin.join() == _confirm.join()) {
          _submit();
        } else {
          _mismatch();
        }
      } else {
        setState(() {
          _confirmPhase = true;
          _cursor = 0;
        });
      }
    }
  }

  void _backspace() {
    if (_busy) return;
    if (_cursor == 0) {
      if (_confirmPhase) {
        setState(() {
          _confirm.fillRange(0, _pinLen, '');
          _confirmPhase = false;
          _cursor = _pin.where((e) => e.isNotEmpty).length;
        });
      }
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _cursor--;
      _active[_cursor] = '';
    });
  }

  void _resetAll() {
    setState(() {
      _pin.fillRange(0, _pinLen, '');
      _confirm.fillRange(0, _pinLen, '');
      _confirmPhase = false;
      _cursor = 0;
    });
  }

  Future<void> _mismatch() async {
    _confirm.fillRange(0, _pinLen, '');
    _cursor = 0;
    _shake.forward(from: 0);
    showToastNotification(
      context: context,
      title: 'PINs do not match',
      message: 'Re-enter to confirm',
      isSuccess: false,
    );
    setState(() {});
  }

  // ── API submit ─────────────────────────────────────────────────────────
  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final uid = prefs.getString('user_id') ?? '';

      final res = await _api.request(
        ApiConstants.setPinEndpoint,
        method: 'POST',
        data: {'uid': uid, 'pin': _pin.join()},
      );
      final body = jsonDecode(res.body);

      if (res.statusCode == 200 && body['error'] == false) {
        await prefs.setString('user_pin', 'available');
        if (!mounted) return;

        showToastNotification(
          context: context,
          title: 'Success',
          message: (body['message'] ?? 'PIN set successfully').toString(),
          isSuccess: true,
        );
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
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────
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
          // Holographic background to match the rest of the app
          const BackgroundWidget(
            style: HoloStyle.vapor,
            animate: true,
            intensity: 0.8,
          ),

          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isTablet ? 64 : (isSmallPhone ? 20 : 32),
                  vertical: 24,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isTablet ? 520 : 440,
                  ),
                  child: _FrostedCard(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _HeaderLogo(float: _logoFloat),
                        const SizedBox(height: 16),
                        Text(
                          _confirmPhase ? 'Re-enter to confirm' : 'Create a 4-digit PIN',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: isTablet ? 28 : (isSmallPhone ? 22 : 26),
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Use digits you’ll remember',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 22),

                        // PIN boxes (shake on mismatch)
                        AnimatedBuilder(
                          animation: _shake,
                          builder: (context, child) {
                            return Transform.translate(
                              offset: Offset(_shakeAnim.value, 0),
                              child: child,
                            );
                          },
                          child: _PinDots(
                            length: _pinLen,
                            filledCount:
                            (_confirmPhase ? _confirm : _pin).where((e) => e.isNotEmpty).length,
                            cursor: _cursor,
                          ),
                        ),

                        const SizedBox(height: 24),

                        if (_busy)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8.0),
                            child: SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            ),
                          ),

                        // Numpad
                        _PinPad(
                          onTap: _tap,
                          onBackspace: _backspace,
                          disabled: _busy,
                          isTablet: isTablet,
                          isSmallPhone: isSmallPhone,
                        ),

                        const SizedBox(height: 12),

                        // Footer row: Back & Reset
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => Navigator.pushReplacementNamed(
                                  context, AppRoutes.login),
                              icon: const Icon(Icons.arrow_back_rounded),
                              label: const Text('Back'),
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.primary,
                              ),
                            ),
                            TextButton(
                              onPressed: (!_confirmPhase || _busy) ? null : _resetAll,
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.error,
                              ),
                              child: const Text('Reset'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Frosted container (same vibe as Login/Registration)
class _FrostedCard extends StatelessWidget {
  const _FrostedCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.surface.withOpacity(0.92),
                AppColors.mintBgLight.withOpacity(0.35),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.mintBgLight.withOpacity(0.5), width: 1),
            boxShadow: [
              BoxShadow(
                color: AppColors.deep.withOpacity(0.10),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Floating Pick Me round logo
class _HeaderLogo extends StatelessWidget {
  const _HeaderLogo({required this.float});
  final Animation<double> float;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.shortestSide > 600 ? 96.0 : 84.0;

    return AnimatedBuilder(
      animation: float,
      builder: (_, __) {
        return Transform.translate(
          offset: Offset(0, float.value),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [AppColors.primary, AppColors.secondary],
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withOpacity(0.30),
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
          ),
        );
      },
    );
  }
}

/// PIN indicator: four rounded boxes with filled dots
class _PinDots extends StatelessWidget {
  const _PinDots({
    required this.length,
    required this.filledCount,
    required this.cursor,
  });

  final int length;
  final int filledCount;
  final int cursor;

  @override
  Widget build(BuildContext context) {
    final isSmallPhone = MediaQuery.of(context).size.width < 360;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (i) {
        final filled = i < filledCount;
        final active = i == cursor;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: EdgeInsets.symmetric(horizontal: isSmallPhone ? 6 : 8),
          width: isSmallPhone ? 48 : 56,
          height: isSmallPhone ? 48 : 56,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active ? AppColors.primary : AppColors.mintBgLight,
              width: active ? 2 : 1,
            ),
            boxShadow: [
              if (active)
                BoxShadow(
                  color: AppColors.primary.withOpacity(.20),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
            ],
          ),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: filled ? (isSmallPhone ? 10 : 12) : 0,
              height: filled ? (isSmallPhone ? 10 : 12) : 0,
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// Numeric keypad (matches Authentication numpad look)
class _PinPad extends StatelessWidget {
  const _PinPad({
    required this.onTap,
    required this.onBackspace,
    required this.disabled,
    required this.isTablet,
    required this.isSmallPhone,
  });

  final void Function(String) onTap;
  final VoidCallback onBackspace;
  final bool disabled;
  final bool isTablet;
  final bool isSmallPhone;

  @override
  Widget build(BuildContext context) {
    final size = isTablet ? 70.0 : (isSmallPhone ? 55.0 : 60.0);
    final spacing = isTablet ? 16.0 : (isSmallPhone ? 10.0 : 12.0);

    Widget row(List<Widget> children) => Padding(
      padding: EdgeInsets.only(bottom: spacing),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: children
            .map((w) => Padding(
          padding: EdgeInsets.symmetric(horizontal: spacing / 2),
          child: w,
        ))
            .toList(),
      ),
    );

    return Column(
      children: [
        for (int r = 0; r < 3; r++)
          row([
            for (int c = 0; c < 3; c++)
              _NumpadButton(
                label: '${r * 3 + c + 1}',
                size: size,
                onTap: () => onTap('${r * 3 + c + 1}'),
                disabled: disabled,
              ),
          ]),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // spacer to balance
            SizedBox(width: size, height: size),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: spacing / 2),
              child: _NumpadButton(
                label: '0',
                size: size,
                onTap: () => onTap('0'),
                disabled: disabled,
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: spacing / 2),
              child: _NumpadButton(
                icon: Icons.backspace_outlined,
                size: size,
                onTap: onBackspace,
                disabled: disabled,
                accent: true,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _NumpadButton extends StatelessWidget {
  const _NumpadButton({
    this.label,
    this.icon,
    required this.size,
    required this.onTap,
    this.disabled = false,
    this.accent = false,
  });

  final String? label;
  final IconData? icon;
  final double size;
  final VoidCallback onTap;
  final bool disabled;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: disabled ? 0.4 : 1.0,
      duration: const Duration(milliseconds: 180),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: disabled ? null : () {
            HapticFeedback.lightImpact();
            onTap();
          },
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
                  AppColors.primary.withOpacity(0.18),
                  AppColors.secondary.withOpacity(0.18),
                ],
              )
                  : null,
              color: !accent
                  ? AppColors.surface.withOpacity(0.8)
                  : null,
              border: Border.all(
                color: disabled
                    ? AppColors.mintBgLight.withOpacity(0.2)
                    : (accent
                    ? AppColors.primary.withOpacity(0.4)
                    : AppColors.mintBgLight.withOpacity(0.45)),
                width: 1.5,
              ),
              boxShadow: !disabled
                  ? [
                BoxShadow(
                  color: (accent ? AppColors.primary : AppColors.deep)
                      .withOpacity(0.10),
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
