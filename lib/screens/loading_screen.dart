// lib/ui/splash_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/firebase_service.dart';
import '../services/push_notification_service.dart';
import '../services/fcm_service.dart';
import '../themes/app_theme.dart'; // AppTheme, AppColors
import '../routes/routes.dart';
import '../utility/notification.dart';
import '../firebase_options.dart'; // <-- use generated options

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

/// Minimal, premium, dark splash (theme-driven).
/// • Center logo (prefers images/pickme.png; falls back gracefully)
/// • Indeterminate bottom progress bar (gradient sweep + glow)
/// • Small caption under the bar
class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _minSplash = Duration(milliseconds: 1200);
  late DateTime _start;

  // Progress bar animation (indeterminate sweep)
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
      // NOTE: WidgetsFlutterBinding.ensureInitialized() belongs in main().
      // Only initialize Firebase here if it wasn't already.
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }

      // Core app services that must succeed to proceed
      await FirebaseService.instance.initialize();

      // Best-effort: push + FCM should NOT block navigation if they fail
      await Future.wait<void>([
        PushNotificationService().initialize().catchError((e, st) {
          debugPrint('PushNotificationService init warning: $e');
        }),
        FCMService(context).initializeFCM().catchError((e, st) {
          debugPrint('FCMService init warning: $e');
        }),
      ], eagerError: false);

      // Respect minimum splash duration
      final elapsed = DateTime.now().difference(_start);
      if (elapsed < _minSplash) {
        await Future<void>.delayed(_minSplash - elapsed);
      }

      if (!mounted) return;
      await _navigateNext();
    } catch (e, st) {
      // Only truly fatal things (e.g., Firebase core init) should land here
      debugPrint('Splash init error: $e\n$st');
      if (!mounted) return;
      showRetryNotification(
        context,
        'Initialization failed. Please try again.',
        onRetry: _bootstrap,
      );
    }
  }

  Future<void> _navigateNext() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id');
    final userPin = prefs.getString('user_pin');

    if (!mounted) return;
    if (userId == null || userId.isEmpty) {
      Navigator.of(context).pushReplacementNamed(AppRoutes.onboarding);
    } else if (userPin == null || userPin.isEmpty) {
      Navigator.of(context).pushReplacementNamed(AppRoutes.set_user_pin);
    } else {
      Navigator.of(context).pushReplacementNamed(AppRoutes.authentication);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Force this screen to use your dark theme palette/typography.
    final dark = AppTheme.dark();

    return Theme(
      data: dark,
      child: Builder(
        builder: (context) {
          final cs = Theme.of(context).colorScheme;
          final size = MediaQuery.of(context).size;
          final shortest = size.shortestSide;

          // Small-but-readable logo sizing (fully responsive):
          // phone ~120–160px, tablets ~160–200px.
          final logoSide = shortest
              .clamp(320.0, 900.0) // normalize
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
                    // Center logo (asset with robust fallback)
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

                    // Bottom: premium indeterminate bar + small caption
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 22),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Custom mint/emerald sweep bar with glow
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

/// Picks the brand image; tries `images/pickme.png`, then `image/pickme.png`,
/// then a vector icon fallback. Keeps memory footprint small.
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

    // First attempt
    return Image.asset(
      'images/pickme.png',
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) {
        // Second attempt (alternate folder naming)
        return Image.asset(
          'image/pickme.png',
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => fallbackBox(Icons.directions_car_filled_rounded),
        );
      },
      cacheWidth: (size * 2).round(), // crisp but still small
      cacheHeight: (size * 2).round(),
      filterQuality: FilterQuality.medium,
    );
  }
}

/// Premium indeterminate progress bar with gradient sweep + glow.
/// t animates 0..1 (controller repeats).
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

    // Track
    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.fill;
    canvas.drawRRect(r, trackPaint);

    // Base fill (subtle)
    final basePaint = Paint()
      ..shader = LinearGradient(
        colors: [base.withOpacity(.28), base.withOpacity(.40)],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(Offset.zero & size);
    canvas.drawRRect(r, basePaint);

    // Moving highlight (sweep)
    final sweepWidth = size.width * 0.28; // highlight width
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

    // Soft outer glow
    final glow = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
      ..color = accent.withOpacity(.25);
    canvas.drawRRect(r, glow);
  }

  @override
  bool shouldRepaint(covariant _IndeterminateBarPainter old) =>
      old.t != t || old.track != track || old.base != base || old.accent != accent;
}

// ─────────────────────────────────────────────────────────────────────────
// Small mapping helper (avoid importing extra libs)
// ─────────────────────────────────────────────────────────────────────────
extension _MapRange on num {
  double map(double inMin, double inMax, double outMin, double outMax) {
    final v = (this - inMin) / (inMax - inMin);
    return (outMin + (outMax - outMin) * v).clamp(outMin, outMax).toDouble();
  }
}
