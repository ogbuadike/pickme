// lib/widgets/inner_background.dart
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../themes/app_theme.dart';

/// HOLOGRAPHIC FLUX BACKGROUND (with backward-compat 'showGrid')
/// - Stunning layered background (flux/prism/vapor) using ONLY AppColors
/// - Back-compat: `showGrid: true` maps to `HoloStyle.prism`
class BackgroundWidget extends StatefulWidget {
  const BackgroundWidget({
    Key? key,
    this.animate = true,
    this.intensity = 1.0,        // 0.5 subtle … 1.0 rich … 1.5 bold
    this.style = HoloStyle.flux, // flux / prism / vapor
    @Deprecated('Use `style: HoloStyle.prism` instead.')
    this.showGrid,               // legacy param; when true => prism
  }) : super(key: key);

  final bool animate;
  final double intensity;
  final HoloStyle style;

  /// Legacy flag kept so existing screens compile:
  /// If true, overrides `style` with `HoloStyle.prism`.
  final bool? showGrid;

  @override
  State<BackgroundWidget> createState() => _BackgroundWidgetState();
}

enum HoloStyle { flux, prism, vapor }

class _BackgroundWidgetState extends State<BackgroundWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 28),
  )..addListener(() => setState(() {}));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant BackgroundWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.animate && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = cs.brightness == Brightness.dark;

    // Back-compat: showGrid=true forces prism style
    final effectiveStyle =
    (widget.showGrid ?? false) ? HoloStyle.prism : widget.style;

    return CustomPaint(
      painter: _HoloPainter(
        t: _ctrl.value,
        style: effectiveStyle,
        intensity: widget.intensity,
        isDark: isDark,
        cs: cs,
      ),
      size: Size.infinite,
    );
  }
}

/// Core painter: different modes that all feel premium.
class _HoloPainter extends CustomPainter {
  final double t;          // 0..1 time
  final HoloStyle style;
  final double intensity;
  final bool isDark;
  final ColorScheme cs;

  _HoloPainter({
    required this.t,
    required this.style,
    required this.intensity,
    required this.isDark,
    required this.cs,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintBaseGradient(canvas, size);

    switch (style) {
      case HoloStyle.flux:
        _paintFluxRibbons(canvas, size);
        _paintPrismaticStrokes(canvas, size);
        _paintBokehGlows(canvas, size);
        break;
      case HoloStyle.prism:
        _paintPrismaticField(canvas, size);
        _paintBokehGlows(canvas, size, fewer: true);
        break;
      case HoloStyle.vapor:
        _paintVaporWaves(canvas, size);
        _paintBokehGlows(canvas, size, tiny: true);
        break;
    }

    _paintVignette(canvas, size);
  }

  // ───────────────────────────────── Base wash
  void _paintBaseGradient(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final c1 = isDark ? AppColors.deep : AppColors.offWhite;
    final c2 = isDark
        ? AppColors.darken(AppColors.deep, .08)
        : AppColors.mintBgLight.withOpacity(.65);

    final base = Paint()
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [c1, c2]);

    canvas.drawRect(rect, base);
  }

  // ───────────────────────────────── HoloStyle.flux — swirling ribbons
  void _paintFluxRibbons(Canvas canvas, Size size) {
    final cx = size.width * .5;
    final cy = size.height * (.40 + .05 * math.sin(t * math.pi * 2));
    final baseR = size.shortestSide * (.28 + .02 * math.cos(t * math.pi * 2));
    const segments = 160;

    final a = AppColors.primary;
    final b = AppColors.secondary;
    final m = AppColors.mintBg;

    for (int i = 0; i < 3; i++) {
      final phase = t * math.pi * 2 + i * (math.pi / 3);
      final swell = 0.22 + 0.05 * math.sin(phase * 1.3 + i);
      final path = Path();

      for (int s = 0; s <= segments; s++) {
        final th = (s / segments) * math.pi * 2;
        final r = baseR *
            (1.0 +
                0.06 * math.sin(2.0 * th + phase) +
                swell * math.sin(th * 1.5 - phase * .7));

        final x = cx + r * math.cos(th + i * .12);
        final y = cy + r * math.sin(th + i * .12);
        (s == 0) ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      path.close();

      final grad = ui.Gradient.radial(
        Offset(cx, cy),
        baseR * 1.2,
        switch (i) {
          0 => [a.withOpacity(.28 * intensity), a.withOpacity(.05 * intensity)],
          1 => [b.withOpacity(.24 * intensity), b.withOpacity(.04 * intensity)],
          _ => [m.withOpacity(.20 * intensity), m.withOpacity(.03 * intensity)],
        },
      );

      final p = Paint()
        ..shader = grad
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24);

      canvas.drawPath(path, p);
    }
  }

  // ───────────────────────────────── Flux helper: prismatic strokes
  void _paintPrismaticStrokes(Canvas canvas, Size size) {
    final rnd = math.Random(7);
    const count = 9;
    for (int i = 0; i < count; i++) {
      final w = size.width * (.12 + rnd.nextDouble() * .10);
      final h = size.height * (.010 + rnd.nextDouble() * .018);
      final x = rnd.nextDouble() * (size.width - w);
      final y = rnd.nextDouble() * (size.height - h);

      canvas.save();
      final rot = (i * .25) + math.sin((t + i * .07) * math.pi * 2) * .12;
      canvas.translate(x + w / 2, y + h / 2);
      canvas.rotate(rot);
      canvas.translate(-(x + w / 2), -(y + h / 2));

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, w, h),
        const Radius.circular(18),
      );

      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = ui.Gradient.linear(
          Offset(x, y),
          Offset(x + w, y + h),
          [
            AppColors.primary.withOpacity(.22 * intensity),
            AppColors.secondary.withOpacity(.18 * intensity),
          ],
        );

      canvas.drawRRect(rrect, stroke);
      canvas.restore();
    }
  }

  // ───────────────────────────────── HoloStyle.prism — crystalline bands
  void _paintPrismaticField(Canvas canvas, Size size) {
    const cols = 6, rows = 8;
    for (int i = 0; i < rows; i++) {
      for (int j = 0; j < cols; j++) {
        final cellW = size.width / cols;
        final cellH = size.height / rows;
        final cx = j * cellW + cellW / 2;
        final cy = i * cellH + cellH / 2;

        final r = math.min(cellW, cellH) *
            (.42 + .08 * math.sin((t + i * .07 + j * .05) * math.pi * 2));
        final rot = (i + j) * .12 + math.cos((t + i * .03) * math.pi * 2) * .15;

        canvas.save();
        canvas.translate(cx, cy);
        canvas.rotate(rot);

        final rr = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: r * 1.6, height: r * .38),
          const Radius.circular(18),
        );

        final p = Paint()
          ..shader = ui.Gradient.linear(
            const Offset(-60, 0),
            const Offset(60, 0),
            [
              AppColors.primary.withOpacity(.12 * intensity),
              AppColors.secondary.withOpacity(.12 * intensity),
            ],
          )
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);

        canvas.drawRRect(rr, p); // <-- fixed method name

        final edge = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9
          ..color = AppColors.mintBgLight.withOpacity(.35 * intensity);

        canvas.drawRRect(rr, edge); // <-- fixed method name
        canvas.restore();
      }
    }
  }

  // ───────────────────────────────── HoloStyle.vapor — wave lines
  void _paintVaporWaves(Canvas canvas, Size size) {
    const lines = 8;
    for (int i = 0; i < lines; i++) {
      final y0 = size.height * (.15 + i * .1);
      final path = Path();
      for (double x = 0; x <= size.width; x += 8) {
        final y = y0 +
            math.sin((x / size.width) * math.pi * 4 + t * math.pi * 2 + i) * 24 +
            math.cos((x / size.width) * math.pi * 2 - t * math.pi * 2 - i) * 12;
        (x == 0) ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = ui.Gradient.linear(
          Offset(0, y0 - 24),
          Offset(0, y0 + 24),
          [
            AppColors.primary.withOpacity(.16 * intensity),
            AppColors.secondary.withOpacity(.06 * intensity),
          ],
        );
      canvas.drawPath(path, stroke);
    }
  }

  // ───────────────────────────────── Shared: bokeh glows
  void _paintBokehGlows(Canvas canvas, Size size, {bool fewer = false, bool tiny = false}) {
    final n = fewer ? 4 : (tiny ? 3 : 6);
    final radiusBase = tiny ? 50.0 : 90.0;

    for (int i = 0; i < n; i++) {
      final ox = size.width * (.15 + .7 * _hash(i, 0.37));
      final oy = size.height * (.20 + .6 * _hash(i, 0.71));

      final px = ox + math.sin(t * math.pi * 2 + i) * 40;
      final py = oy + math.cos(t * math.pi * 2 + i * .6) * 28;

      final r = radiusBase * (1 + .15 * math.sin(t * math.pi * 2 + i * .9));

      final paint = Paint()
        ..shader = ui.Gradient.radial(
          Offset(px, py),
          r,
          [
            AppColors.primary.withOpacity(.22 * intensity),
            AppColors.secondary.withOpacity(.00),
          ],
        )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 36);

      canvas.drawCircle(Offset(px, py), r * .9, paint);
    }
  }

  // ───────────────────────────────── Subtle vignette (edge fade)
  void _paintVignette(Canvas canvas, Size size) {
    final vignette = Paint()
      ..shader = ui.Gradient.radial(
        Offset(size.width * .5, size.height * .55),
        size.longestSide * .75,
        [
          Colors.transparent,
          (isDark ? Colors.black : AppColors.deep).withOpacity(isDark ? .32 : .06),
        ],
      );
    canvas.drawRect(Offset.zero & size, vignette);
  }

  double _hash(int i, double seed) {
    final s = math.sin(i * 127.1 + seed * 311.7) * 43758.5453;
    return s - s.floorToDouble();
  }

  @override
  bool shouldRepaint(covariant _HoloPainter old) =>
      old.t != t ||
          old.style != style ||
          old.intensity != intensity ||
          old.isDark != isDark;
}
