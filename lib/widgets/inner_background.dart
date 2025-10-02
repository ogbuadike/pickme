// lib/widgets/inner_background.dart
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../themes/app_theme.dart';

/// Unique animated background with floating organic shapes and aurora-like gradients
class BackgroundWidget extends StatefulWidget {
  const BackgroundWidget({
    Key? key,
    this.animate = true,
    this.intensity = 1.0,
    this.variant = BackgroundVariant.aurora,
  }) : super(key: key);

  final bool animate;
  final double intensity;
  final BackgroundVariant variant;

  @override
  State<BackgroundWidget> createState() => _BackgroundWidgetState();
}

enum BackgroundVariant {
  aurora,       // Smooth flowing gradients like northern lights
  crystalline,  // Geometric crystal-like patterns
  organic,      // Floating organic shapes
  mesh,         // Modern gradient mesh
}

class _BackgroundWidgetState extends State<BackgroundWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _flowAnimation;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 20),
      vsync: this,
    );

    _flowAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));

    _pulseAnimation = Tween<double>(
      begin: 0.95,
      end: 1.05,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));

    if (widget.animate) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                AppColors.deep,
                AppColors.darken(AppColors.deep, 0.1),
              ]
                  : [
                AppColors.offWhite,
                AppColors.mintBgLight.withOpacity(0.5),
              ],
            ),
          ),
          child: CustomPaint(
            painter: _getBackgroundPainter(),
            size: Size.infinite,
          ),
        );
      },
    );
  }

  CustomPainter _getBackgroundPainter() {
    switch (widget.variant) {
      case BackgroundVariant.aurora:
        return AuroraBackgroundPainter(
          flowProgress: _flowAnimation.value,
          pulseScale: _pulseAnimation.value,
          intensity: widget.intensity,
          isDark: Theme.of(context).brightness == Brightness.dark,
        );
      case BackgroundVariant.crystalline:
        return CrystallineBackgroundPainter(
          flowProgress: _flowAnimation.value,
          intensity: widget.intensity,
          isDark: Theme.of(context).brightness == Brightness.dark,
        );
      case BackgroundVariant.organic:
        return OrganicBackgroundPainter(
          flowProgress: _flowAnimation.value,
          pulseScale: _pulseAnimation.value,
          intensity: widget.intensity,
          isDark: Theme.of(context).brightness == Brightness.dark,
        );
      case BackgroundVariant.mesh:
        return MeshBackgroundPainter(
          flowProgress: _flowAnimation.value,
          intensity: widget.intensity,
          isDark: Theme.of(context).brightness == Brightness.dark,
        );
    }
  }
}

/// Aurora-like flowing gradients
class AuroraBackgroundPainter extends CustomPainter {
  final double flowProgress;
  final double pulseScale;
  final double intensity;
  final bool isDark;

  AuroraBackgroundPainter({
    required this.flowProgress,
    required this.pulseScale,
    required this.intensity,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Create flowing aurora waves
    for (int i = 0; i < 3; i++) {
      final phase = flowProgress * 2 * math.pi + (i * math.pi / 3);
      final offsetY = size.height * (0.3 + i * 0.15);

      final path = Path();
      path.moveTo(0, offsetY);

      for (double x = 0; x <= size.width; x += 10) {
        final y = offsetY +
            math.sin((x / size.width) * 4 * math.pi + phase) * 40 * pulseScale +
            math.sin((x / size.width) * 2 * math.pi - phase) * 20;

        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }

      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
      path.close();

      final gradient = ui.Gradient.linear(
        Offset(0, offsetY - 50),
        Offset(0, size.height),
        [
          _getAuroraColor(i).withOpacity(0.15 * intensity),
          _getAuroraColor(i).withOpacity(0.03 * intensity),
        ],
        [0.0, 1.0],
      );

      final paint = Paint()
        ..shader = gradient
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20);

      canvas.drawPath(path, paint);
    }

    // Add glowing orbs
    _drawGlowingOrbs(canvas, size);
  }

  Color _getAuroraColor(int index) {
    final colors = isDark
        ? [
      AppColors.primary.withOpacity(0.8),
      AppColors.secondary.withOpacity(0.7),
      const Color(0xFF6BC39B).withOpacity(0.6),
    ]
        : [
      AppColors.primary,
      AppColors.secondary,
      AppColors.mintBg,
    ];
    return colors[index % colors.length];
  }

  void _drawGlowingOrbs(Canvas canvas, Size size) {
    final positions = [
      Offset(size.width * 0.2, size.height * 0.3),
      Offset(size.width * 0.7, size.height * 0.5),
      Offset(size.width * 0.4, size.height * 0.7),
    ];

    for (var i = 0; i < positions.length; i++) {
      final offset = positions[i];
      final movingOffset = Offset(
        offset.dx + math.sin(flowProgress * 2 * math.pi + i) * 30,
        offset.dy + math.cos(flowProgress * 2 * math.pi + i) * 20,
      );

      final paint = Paint()
        ..shader = ui.Gradient.radial(
          movingOffset,
          100 * pulseScale,
          [
            _getAuroraColor(i).withOpacity(0.3 * intensity),
            _getAuroraColor(i).withOpacity(0.0),
          ],
        )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40);

      canvas.drawCircle(movingOffset, 80 * pulseScale, paint);
    }
  }

  @override
  bool shouldRepaint(AuroraBackgroundPainter oldDelegate) =>
      oldDelegate.flowProgress != flowProgress ||
          oldDelegate.pulseScale != pulseScale ||
          oldDelegate.intensity != intensity ||
          oldDelegate.isDark != isDark;
}

/// Geometric crystalline patterns
class CrystallineBackgroundPainter extends CustomPainter {
  final double flowProgress;
  final double intensity;
  final bool isDark;

  CrystallineBackgroundPainter({
    required this.flowProgress,
    required this.intensity,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(42);

    // Draw crystalline shapes
    for (int i = 0; i < 12; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final radius = 50 + random.nextDouble() * 100;
      final rotation = flowProgress * math.pi * 2 + (i * math.pi / 6);

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(rotation);

      final path = _createCrystalPath(radius);

      final paint = Paint()
        ..style = PaintingStyle.fill
        ..shader = ui.Gradient.linear(
          Offset(-radius, -radius),
          Offset(radius, radius),
          [
            _getCrystalColor(i).withOpacity(0.1 * intensity),
            _getCrystalColor(i).withOpacity(0.02 * intensity),
          ],
        );

      canvas.drawPath(path, paint);

      // Draw crystal edges
      final edgePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _getCrystalColor(i).withOpacity(0.2 * intensity);

      canvas.drawPath(path, edgePaint);

      canvas.restore();
    }
  }

  Path _createCrystalPath(double radius) {
    final path = Path();
    const sides = 6;

    for (int i = 0; i <= sides; i++) {
      final angle = (i * 2 * math.pi) / sides;
      final x = radius * math.cos(angle);
      final y = radius * math.sin(angle);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    path.close();
    return path;
  }

  Color _getCrystalColor(int index) {
    return index % 2 == 0
        ? (isDark ? const Color(0xFF6BC39B) : AppColors.primary)
        : (isDark ? const Color(0xFF74C5A4) : AppColors.secondary);
  }

  @override
  bool shouldRepaint(CrystallineBackgroundPainter oldDelegate) =>
      oldDelegate.flowProgress != flowProgress ||
          oldDelegate.intensity != intensity ||
          oldDelegate.isDark != isDark;
}

/// Floating organic shapes
class OrganicBackgroundPainter extends CustomPainter {
  final double flowProgress;
  final double pulseScale;
  final double intensity;
  final bool isDark;

  OrganicBackgroundPainter({
    required this.flowProgress,
    required this.pulseScale,
    required this.intensity,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw multiple organic blobs
    final blobs = [
      _BlobConfig(
        center: Offset(size.width * 0.3, size.height * 0.2),
        radius: 120,
        color: AppColors.primary,
        phase: 0,
      ),
      _BlobConfig(
        center: Offset(size.width * 0.7, size.height * 0.4),
        radius: 100,
        color: AppColors.secondary,
        phase: math.pi / 3,
      ),
      _BlobConfig(
        center: Offset(size.width * 0.5, size.height * 0.7),
        radius: 140,
        color: AppColors.mintBg,
        phase: 2 * math.pi / 3,
      ),
      _BlobConfig(
        center: Offset(size.width * 0.2, size.height * 0.6),
        radius: 80,
        color: isDark ? const Color(0xFF6BC39B) : AppColors.mintBgLight,
        phase: math.pi,
      ),
    ];

    for (final blob in blobs) {
      _drawOrganicBlob(canvas, blob, flowProgress, pulseScale);
    }
  }

  void _drawOrganicBlob(
      Canvas canvas,
      _BlobConfig config,
      double progress,
      double scale,
      ) {
    final path = Path();
    const points = 8;

    for (int i = 0; i <= points; i++) {
      final angle = (i * 2 * math.pi) / points;
      final phase = progress * 2 * math.pi + config.phase;

      // Create organic variation
      final radiusVariation = config.radius * scale +
          math.sin(angle * 2 + phase) * 20 +
          math.cos(angle * 3 - phase) * 15;

      final x = config.center.dx + radiusVariation * math.cos(angle);
      final y = config.center.dy + radiusVariation * math.sin(angle);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        final prevAngle = ((i - 1) * 2 * math.pi) / points;
        final prevRadiusVariation = config.radius * scale +
            math.sin(prevAngle * 2 + phase) * 20 +
            math.cos(prevAngle * 3 - phase) * 15;

        final prevX = config.center.dx + prevRadiusVariation * math.cos(prevAngle);
        final prevY = config.center.dy + prevRadiusVariation * math.sin(prevAngle);

        final cpX1 = prevX + (x - prevX) * 0.3;
        final cpY1 = prevY + (y - prevY) * 0.3;
        final cpX2 = x - (x - prevX) * 0.3;
        final cpY2 = y - (y - prevY) * 0.3;

        path.cubicTo(cpX1, cpY1, cpX2, cpY2, x, y);
      }
    }

    path.close();

    final paint = Paint()
      ..shader = ui.Gradient.radial(
        config.center,
        config.radius * 1.5,
        [
          config.color.withOpacity(0.15 * intensity),
          config.color.withOpacity(0.02 * intensity),
        ],
      )
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(OrganicBackgroundPainter oldDelegate) =>
      oldDelegate.flowProgress != flowProgress ||
          oldDelegate.pulseScale != pulseScale ||
          oldDelegate.intensity != intensity ||
          oldDelegate.isDark != isDark;
}

/// Modern gradient mesh background
class MeshBackgroundPainter extends CustomPainter {
  final double flowProgress;
  final double intensity;
  final bool isDark;

  MeshBackgroundPainter({
    required this.flowProgress,
    required this.intensity,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final meshPoints = <Offset>[];
    const cols = 5;
    const rows = 5;

    // Generate mesh grid points with animated distortion
    for (int i = 0; i < rows; i++) {
      for (int j = 0; j < cols; j++) {
        final baseX = (size.width / (cols - 1)) * j;
        final baseY = (size.height / (rows - 1)) * i;

        final distortionX = math.sin(flowProgress * 2 * math.pi + i * 0.5) * 20;
        final distortionY = math.cos(flowProgress * 2 * math.pi + j * 0.5) * 20;

        meshPoints.add(Offset(
          baseX + distortionX,
          baseY + distortionY,
        ));
      }
    }

    // Draw mesh connections
    final meshPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = (isDark ? AppColors.mintBgLight : AppColors.primary)
          .withOpacity(0.1 * intensity);

    // Draw horizontal lines
    for (int i = 0; i < rows; i++) {
      final path = Path();
      for (int j = 0; j < cols; j++) {
        final point = meshPoints[i * cols + j];
        if (j == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(path, meshPaint);
    }

    // Draw vertical lines
    for (int j = 0; j < cols; j++) {
      final path = Path();
      for (int i = 0; i < rows; i++) {
        final point = meshPoints[i * cols + j];
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(path, meshPaint);
    }

    // Add gradient nodes at intersection points
    for (final point in meshPoints) {
      final gradientPaint = Paint()
        ..shader = ui.Gradient.radial(
          point,
          50,
          [
            _getMeshNodeColor(point, size).withOpacity(0.3 * intensity),
            _getMeshNodeColor(point, size).withOpacity(0.0),
          ],
        );

      canvas.drawCircle(point, 30, gradientPaint);
    }
  }

  Color _getMeshNodeColor(Offset point, Size size) {
    final distanceFromCenter = (point - Offset(size.width / 2, size.height / 2)).distance;
    final maxDistance = size.shortestSide / 2;
    final ratio = (distanceFromCenter / maxDistance).clamp(0.0, 1.0);

    if (ratio < 0.5) {
      return isDark ? const Color(0xFF6BC39B) : AppColors.primary;
    } else {
      return isDark ? const Color(0xFF74C5A4) : AppColors.secondary;
    }
  }

  @override
  bool shouldRepaint(MeshBackgroundPainter oldDelegate) =>
      oldDelegate.flowProgress != flowProgress ||
          oldDelegate.intensity != intensity ||
          oldDelegate.isDark != isDark;
}

class _BlobConfig {
  final Offset center;
  final double radius;
  final Color color;
  final double phase;

  _BlobConfig({
    required this.center,
    required this.radius,
    required this.color,
    required this.phase,
  });
}