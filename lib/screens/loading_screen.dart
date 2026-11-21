import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/fcm_service.dart';
import '../themes/app_theme.dart';
import '../routes/routes.dart';
import '../utility/notification.dart';
import '../utility/session_manager.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _minSplash = Duration(milliseconds: 1200);
  late DateTime _start;

  late final AnimationController _barCtrl =
  AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();

  @override
  void initState() {
    super.initState();
    _start = DateTime.now();
    _bootstrap();
  }

  @override
  void dispose() {
    _barCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      // Firebase / push listeners are initialised in main(); here we only
      // decide where to go and (re)register the push token for a signed-in
      // user without blocking the splash.
      final hasSession = await SessionManager.instance.hasValidSession();
      if (hasSession) unawaited(FCMService.instance.syncTokenWithBackend());

      final elapsed = DateTime.now().difference(_start);
      if (elapsed < _minSplash) {
        await Future<void>.delayed(_minSplash - elapsed);
      }

      if (!mounted) return;
      await _navigateNext(hasSession: hasSession);
    } catch (e, st) {
      if (kDebugMode) debugPrint('Splash init error: $e\n$st');
      if (!mounted) return;
      showRetryNotification(
        context,
        'Initialization failed. Please try again.',
        onRetry: _bootstrap,
      );
    }
  }

  Future<void> _navigateNext({required bool hasSession}) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(PrefKeys.userId);
    final userPin = prefs.getString(PrefKeys.pinFlag);
    final isDriver = prefs.getBool(PrefKeys.isDriver) ?? false;
    final hadAccount = userId != null && userId.isNotEmpty;

    if (!hasSession && hadAccount) {
      // Signed in with a pre-session build, or the session expired: the old
      // identity is no longer usable, so drop it and ask for a fresh login.
      await SessionManager.instance.wipeLocalData();
    }
    if (!mounted) return;

    final nav = Navigator.of(context);
    if (!hasSession) {
      nav.pushReplacementNamed(
        hadAccount ? AppRoutes.login : AppRoutes.onboarding,
        arguments: hadAccount ? const {'reason': 'session_expired'} : null,
      );
    } else if (userPin == null || userPin.isEmpty) {
      nav.pushReplacementNamed(AppRoutes.set_user_pin);
    } else if (isDriver) {
      nav.pushReplacementNamed(AppRoutes.authentication);
    } else {
      nav.pushReplacementNamed(AppRoutes.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.dark();

    return Theme(
      data: dark,
      child: Builder(
        builder: (context) {
          final cs = Theme.of(context).colorScheme;
          final size = MediaQuery.of(context).size;
          final shortest = size.shortestSide;

          final logoSide = shortest
              .clamp(320.0, 900.0)
              .map(320.0, 900.0, 120.0, 200.0);

          final overlay = SystemUiOverlayStyle.light.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: cs.background,
            systemNavigationBarIconBrightness: Brightness.light,
          );

          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: overlay,
            child: Scaffold(
              backgroundColor: cs.background,
              body: SafeArea(
                child: Stack(
                  children: [
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: logoSide,
                            maxHeight: logoSide,
                          ),
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: _PickMeLogo(size: logoSide * 0.9),
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 22),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            RepaintBoundary(
                              child: AnimatedBuilder(
                                animation: _barCtrl,
                                builder: (_, __) {
                                  return ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: CustomPaint(
                                      size: const Size(double.infinity, 10),
                                      painter: _IndeterminateBarPainter(
                                        t: _barCtrl.value,
                                        track: AppColors.darken(cs.surfaceVariant, .10),
                                        base: cs.primary,
                                        accent: AppColors.secondary,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Book rides • Send packages • Move smarter',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                color: cs.onBackground.withOpacity(.95),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PickMeLogo extends StatelessWidget {
  const _PickMeLogo({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget fallbackBox(IconData icon) => Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.darken(cs.surface, .04),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: AppColors.darken(cs.surfaceVariant, .06),
          width: 1,
        ),
      ),
      child: Icon(icon, size: size * 0.45, color: cs.onSurface.withOpacity(.85)),
    );

    return Image.asset(
      'image/pickme.png',
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => fallbackBox(Icons.directions_car_filled_rounded),
      cacheWidth: (size * 2).round(),
      cacheHeight: (size * 2).round(),
      filterQuality: FilterQuality.medium,
    );
  }
}

class _IndeterminateBarPainter extends CustomPainter {
  _IndeterminateBarPainter({
    required this.t,
    required this.track,
    required this.base,
    required this.accent,
  });

  final double t;
  final Color track;
  final Color base;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12));

    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.fill;
    canvas.drawRRect(r, trackPaint);

    final basePaint = Paint()
      ..shader = LinearGradient(
        colors: [base.withOpacity(.28), base.withOpacity(.40)],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(Offset.zero & size);
    canvas.drawRRect(r, basePaint);

    final sweepWidth = size.width * 0.28;
    final startX = (size.width + sweepWidth) * t - sweepWidth;
    final rect = Rect.fromLTWH(startX, 0, sweepWidth, size.height);

    final sweepPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          base.withOpacity(.0),
          accent.withOpacity(.85),
          Colors.white.withOpacity(.95),
          accent.withOpacity(.85),
          base.withOpacity(.0),
        ],
        stops: const [0.00, 0.20, 0.50, 0.80, 1.00],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(rect);
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRect(rect, sweepPaint);
    canvas.restore();

    final glow = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
      ..color = accent.withOpacity(.25);
    canvas.drawRRect(r, glow);
  }

  @override
  bool shouldRepaint(covariant _IndeterminateBarPainter old) =>
      old.t != t || old.track != track || old.base != base || old.accent != accent;
}

extension _MapRange on num {
  double map(double inMin, double inMax, double outMin, double outMax) {
    final v = (this - inMin) / (inMax - inMin);
    return (outMin + (outMax - outMin) * v).clamp(outMin, outMax).toDouble();
  }
}