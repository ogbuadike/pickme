// lib/screens/set_pin.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

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
  late AnimationController _shake;
  late Animation<double> _shakeAnim;

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
  }

  @override
  void dispose() {
    _shake.dispose();
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
        // Compare both
        if (_pin.join() == _confirm.join()) {
          _submit();
        } else {
          _mismatch();
        }
      } else {
        // Move to confirm phase
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
        // Go back to create phase if user clears all in confirm
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
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      body: Stack(
        children: [
          const BackgroundWidget(showGrid: true, intensity: 1.0),

          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 24),
                _topBar(tt, cs),
                const Spacer(),
                AnimatedBuilder(
                  animation: _shake,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(_shakeAnim.value, 0),
                      child: child,
                    );
                  },
                  child: _pinPanel(tt, cs),
                ),
                const SizedBox(height: 16),
                if (_busy) CircularProgressIndicator(color: cs.primary),
                const Spacer(),
                _keypad(cs, tt),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar(TextTheme tt, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          IconButton(
            onPressed: _busy
                ? null
                : () => Navigator.pushReplacementNamed(context, AppRoutes.login),
            icon: Icon(Icons.arrow_back_rounded, color: cs.onBackground),
            tooltip: 'Back to Login',
          ),
          const Spacer(),
          Text('Set your PIN',
              style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const Spacer(),
          TextButton(
            onPressed: (!_confirmPhase || _busy) ? null : _resetAll,
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  Widget _pinPanel(TextTheme tt, ColorScheme cs) {
    final heading = _confirmPhase ? 'Re-enter to confirm' : 'Create a 4-digit PIN';
    final sub =
    _confirmPhase ? 'Make sure it matches your first entry' : 'Use digits you remember';

    return Column(
      children: [
        // Brand capsule (consistent with Login/Authentication)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(color: cs.primary.withOpacity(.35), blurRadius: 22, spreadRadius: 1),
              BoxShadow(color: cs.primary.withOpacity(.18), blurRadius: 8, offset: const Offset(0, 3)),
            ],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.directions_car_rounded, size: 22, color: Colors.white),
            const SizedBox(width: 8),
            Text('Pick Me',
                style: tt.labelLarge?.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w800)),
          ]),
        ),

        const SizedBox(height: 12),
        Text(heading, style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(sub, style: tt.bodyMedium?.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 18),
        _pinBoxes(cs),
      ],
    );
  }

  Widget _pinBoxes(ColorScheme cs) {
    final active = _confirmPhase ? _confirm : _pin;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_pinLen, (i) {
        final isActive = i == _cursor;
        final filled = active[i].isNotEmpty;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.symmetric(horizontal: 8),
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive ? cs.primary : cs.surfaceVariant,
              width: isActive ? 2 : 1,
            ),
            boxShadow: [
              if (isActive)
                BoxShadow(
                  color: cs.primary.withOpacity(.22),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
            ],
          ),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: filled ? 12 : 0,
              height: filled ? 12 : 0,
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _keypad(ColorScheme cs, TextTheme tt) {
    Widget numBtn(String n, {VoidCallback? onTap}) {
      return SizedBox(
        width: 86,
        height: 64,
        child: ElevatedButton(
          onPressed: _busy ? null : onTap,
          style: ButtonStyle(
            elevation: const MaterialStatePropertyAll(0),
            shape: const MaterialStatePropertyAll(StadiumBorder()),
            backgroundColor: MaterialStateProperty.resolveWith((states) {
              if (states.contains(MaterialState.disabled)) return cs.surfaceVariant;
              return cs.surface;
            }),
            foregroundColor: MaterialStatePropertyAll(cs.onSurface),
            side: MaterialStatePropertyAll(BorderSide(color: cs.surfaceVariant)),
          ),
          child: Text(n, style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        ),
      );
    }

    Widget backspace() => IconButton(
      onPressed: (_busy || _cursor == 0) ? null : _backspace,
      icon: Icon(Icons.backspace_rounded, size: 28, color: cs.error),
      tooltip: 'Delete',
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            numBtn('1', onTap: () => _tap('1')),
            numBtn('2', onTap: () => _tap('2')),
            numBtn('3', onTap: () => _tap('3')),
          ]),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            numBtn('4', onTap: () => _tap('4')),
            numBtn('5', onTap: () => _tap('5')),
            numBtn('6', onTap: () => _tap('6')),
          ]),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            numBtn('7', onTap: () => _tap('7')),
            numBtn('8', onTap: () => _tap('8')),
            numBtn('9', onTap: () => _tap('9')),
          ]),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            // Spacer button to balance layout
            const SizedBox(width: 86, height: 64),
            numBtn('0', onTap: () => _tap('0')),
            backspace(),
          ]),
        ],
      ),
    );
  }
}
