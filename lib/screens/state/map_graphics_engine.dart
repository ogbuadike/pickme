// lib/screens/state/map_graphics_engine.dart
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../themes/app_theme.dart';

/// Generates ultra-premium, OLED-optimized map markers and graphical assets.
/// Simulates extreme 3D depth, glowing auras, and elevated glass edge-highlights.
class MapGraphicsEngine {

  /// Creates a "Gaming-Tier" Avatar Map Marker
  /// Highly elevated with a long sci-fi pointer to float above traffic.
  static Future<BitmapDescriptor> createPremiumAvatarPin({
    required ui.Image? avatarImage,
    required bool isDark,
    required ColorScheme cs,
  }) async {
    const double size = 180.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);

    final center = const Offset(size / 2, size / 2 - 24);
    const avatarRadius = 44.0;
    final ringColor = isDark ? cs.primary : AppColors.primary;

    // 1. High-Tech Glowing Aura (Massive spread)
    c.drawCircle(
      center,
      avatarRadius + 12,
      Paint()
        ..color = ringColor.withOpacity(isDark ? 0.35 : 0.20)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 24),
    );

    // 2. Deep, Elevated Drop Shadow
    c.drawCircle(
      center + const Offset(0, 16),
      avatarRadius + 4,
      Paint()
        ..color = Colors.black.withOpacity(0.6)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 16),
    );

    // 3. Gaming/Sci-Fi Chevron Pointer
    final pointerPath = Path()
      ..moveTo(center.dx - 18, center.dy + avatarRadius - 8)
      ..lineTo(center.dx, center.dy + avatarRadius + 42) // Sharp tip
      ..lineTo(center.dx + 18, center.dy + avatarRadius - 8)
      ..close();

    // Pointer shadow
    c.drawPath(
      pointerPath.shift(const Offset(0, 6)),
      Paint()
        ..color = Colors.black.withOpacity(0.4)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 8),
    );

    // Pointer body
    c.drawPath(
        pointerPath,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(center.dx, center.dy + avatarRadius - 8),
            Offset(center.dx, center.dy + avatarRadius + 42),
            [ringColor, HSLColor.fromColor(ringColor).withLightness(0.2).toColor()],
          )
    );

    // 4. Outer Metallic/Neon Bezel
    c.drawCircle(
        center,
        avatarRadius + 6,
        Paint()
          ..shader = ui.Gradient.linear(
            center - const Offset(avatarRadius, avatarRadius),
            center + const Offset(avatarRadius, avatarRadius),
            [Colors.white.withOpacity(0.95), ringColor, Colors.black87],
            const [0.0, 0.4, 1.0],
          )
    );

    // Inner dark ring to separate image from bezel
    c.drawCircle(center, avatarRadius + 1, Paint()..color = Colors.black);

    // 5. Draw Avatar Image perfectly masked
    c.save();
    c.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: avatarRadius)));

    if (avatarImage != null) {
      final src = Rect.fromLTWH(0, 0, avatarImage.width.toDouble(), avatarImage.height.toDouble());
      final dst = Rect.fromCircle(center: center, radius: avatarRadius);
      c.drawImageRect(avatarImage, src, dst, Paint()..isAntiAlias = true..filterQuality = FilterQuality.high);
    } else {
      c.drawPaint(Paint()..color = isDark ? cs.surfaceVariant : AppColors.mintBgLight);
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.person.codePoint),
          style: TextStyle(
            fontSize: avatarRadius * 1.4,
            fontFamily: Icons.person.fontFamily,
            color: ringColor,
            shadows: const [Shadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 2))],
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
    }
    c.restore();

    // 6. Glass/Glossy Overlay (The "Curved Screen" reflection)
    final glossPath = Path()
      ..addOval(Rect.fromCircle(center: center - const Offset(0, avatarRadius * 0.35), radius: avatarRadius * 0.75));
    c.drawPath(
        glossPath,
        Paint()
          ..shader = ui.Gradient.linear(
            center - const Offset(0, avatarRadius),
            center,
            [Colors.white.withOpacity(0.5), Colors.white.withOpacity(0.0)],
          )
    );

    // 7. Online Status Dot (Neon Green HUD element)
    final dotCenter = center + Offset(avatarRadius * 0.75, avatarRadius * 0.70);

    c.drawCircle(dotCenter, 13, Paint()..color = Colors.black);
    c.drawCircle(dotCenter, 9, Paint()..color = const Color(0xFF00E676));
    c.drawCircle(
        dotCenter, 9,
        Paint()
          ..color = const Color(0xFF00E676).withOpacity(0.8)
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 6)
    );

    final img = await rec.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  /// Creates the "Dream/Thought Bubble" ETA pill for the origin point.
  /// Looks like the user avatar is thinking about their arrival time.
  static Future<BitmapDescriptor> createArrivePillBadge({
    required String text,
    required bool isDark,
    required ColorScheme cs,
  }) async {
    const double h = 96; // Increased height to fit the trailing thought bubbles
    final tp = TextPainter(
      text: TextSpan(
        text: text.toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
          shadows: [Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 2))],
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final w = (tp.width + 56).clamp(200.0, 400.0);
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);

    final pillColor = isDark ? cs.primary : const Color(0xFF1A73E8);
    final darkPillColor = isDark ? cs.primary.withOpacity(0.6) : const Color(0xFF0D47A1);

    // Main Bubble Body (Fixed height of 52)
    final pillRect = Rect.fromLTWH(0, 0, w, 52);
    final pill = RRect.fromRectAndRadius(pillRect, const Radius.circular(26));

    // 1. Massive Ambient Neon Glow
    c.drawRRect(
      pill.shift(const Offset(0, 6)),
      Paint()
        ..color = pillColor.withOpacity(isDark ? 0.45 : 0.30)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 20),
    );

    // 2. Heavy Elevated Drop Shadow
    c.drawRRect(
      pill.shift(const Offset(0, 10)),
      Paint()
        ..color = Colors.black.withOpacity(isDark ? 0.7 : 0.3)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 12),
    );

    // 3. Main Body Gradient
    final bodyPaint = Paint()
      ..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(0, 52), [pillColor, darkPillColor]);
    c.drawRRect(pill, bodyPaint);

    // 4. Inner Edge Highlight (3D Bevel)
    c.drawRRect(
      pill,
      Paint()..style = PaintingStyle.stroke..strokeWidth = 2.0..color = Colors.white.withOpacity(0.35),
    );

    // 5. Glass Reflection on the main bubble
    final glossPath = Path()
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(4, 2, w - 8, 24), const Radius.circular(20)));
    c.drawPath(
        glossPath,
        Paint()
          ..shader = ui.Gradient.linear(
            const Offset(0, 0), const Offset(0, 24),
            [Colors.white.withOpacity(0.4), Colors.white.withOpacity(0.0)],
          )
    );

    // 6. The "Thinking" Trailing Bubbles
    // These cascade down and curve toward the center anchor point (w/2, h)
    _drawThoughtDot(c, Offset(w / 2 + 18, 62), 7.5, pillColor, darkPillColor, isDark); // Big dot right
    _drawThoughtDot(c, Offset(w / 2 + 8, 78), 4.5, pillColor, darkPillColor, isDark);  // Medium dot curved in
    _drawThoughtDot(c, Offset(w / 2, 90), 2.5, pillColor, darkPillColor, isDark);      // Tiny dot dead center (Anchor)

    // 7. Draw Text perfectly centered in the main pill
    tp.paint(c, Offset((w - tp.width) / 2, (52 - tp.height) / 2));

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  /// Helper to draw the individual 3D glass thought bubbles
  static void _drawThoughtDot(Canvas c, Offset center, double radius, Color color, Color darkColor, bool isDark) {
    // Neon Glow
    c.drawCircle(center, radius + 4, Paint()..color = color.withOpacity(isDark ? 0.4 : 0.2)..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 6));
    // Drop Shadow
    c.drawCircle(center + const Offset(0, 4), radius, Paint()..color = Colors.black.withOpacity(isDark ? 0.6 : 0.3)..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 4));
    // Gradient Body
    c.drawCircle(center, radius, Paint()..shader = ui.Gradient.linear(center - Offset(0, radius), center + Offset(0, radius), [color, darkColor]));
    // Glossy Highlight
    c.drawCircle(center, radius - 0.5, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.0..color = Colors.white.withOpacity(0.4));
  }

  /// Creates the premium glowing circular "Minutes" badge for the destination point.
  static Future<BitmapDescriptor> createMinutesCircleBadge({
    required int minutes,
    required bool isDark,
    required ColorScheme cs,
  }) async {
    const w = 160.0, h = 220.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);

    final center = const Offset(w / 2, 68);
    const badgeR = 52.0;

    final badgeColor = isDark ? cs.secondary : const Color(0xFF00A651);
    final darkBadgeColor = isDark ? cs.secondary.withOpacity(0.6) : const Color(0xFF007E3D);

    // 1. Massive Ambient Neon Glow
    c.drawCircle(
      center + const Offset(0, 6), badgeR,
      Paint()
        ..color = badgeColor.withOpacity(isDark ? 0.45 : 0.3)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 24),
    );

    // 2. Heavy Drop Shadow
    c.drawCircle(
      center + const Offset(0, 14), badgeR,
      Paint()
        ..color = Colors.black.withOpacity(isDark ? 0.7 : 0.3)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 14),
    );

    // 3. Main Gradient Body
    final circlePaint = Paint()
      ..shader = ui.Gradient.linear(
        center - const Offset(0, badgeR),
        center + const Offset(0, badgeR),
        [badgeColor, darkBadgeColor],
      );
    c.drawCircle(center, badgeR, circlePaint);

    // 4. Edge Highlight Ring
    c.drawCircle(
        center, badgeR - 1.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = Colors.white.withOpacity(0.4)
    );

    // 5. Glass Reflection (Curved surface effect)
    final glossPath = Path()
      ..addOval(Rect.fromCircle(center: center - const Offset(0, badgeR * 0.4), radius: badgeR * 0.7));
    c.drawPath(
        glossPath,
        Paint()
          ..shader = ui.Gradient.linear(
            center - const Offset(0, badgeR),
            center,
            [Colors.white.withOpacity(0.4), Colors.white.withOpacity(0.0)],
          )
    );

    // 6. Typography with shadows
    final numTp = TextPainter(
      text: TextSpan(
          text: '$minutes',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 42,
            fontWeight: FontWeight.w900,
            height: 1.0,
            letterSpacing: -1.0,
            shadows: [Shadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 3))],
          )
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final minTp = TextPainter(
      text: const TextSpan(
          text: 'MIN',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w900,
            height: 1.0,
            letterSpacing: 1.0,
            shadows: [Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 2))],
          )
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    numTp.paint(c, Offset(center.dx - numTp.width / 2, center.dy - 36));
    minTp.paint(c, Offset(center.dx - minTp.width / 2, center.dy + 10));

    // 7. Extra-long Sleek Stem line
    final stemPaint = Paint()
      ..shader = ui.Gradient.linear(
          const Offset(w / 2, 120), const Offset(w / 2, 180),
          [darkBadgeColor, badgeColor]
      )
      ..strokeWidth = 6.5
      ..strokeCap = StrokeCap.round;

    c.drawLine(
        const Offset(w / 2, 120), const Offset(w / 2, 182),
        Paint()..color = Colors.black45..strokeWidth = 6.5..strokeCap = StrokeCap.round..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 6)
    );
    c.drawLine(const Offset(w / 2, 120), const Offset(w / 2, 180), stemPaint);

    // 8. Map Anchor Dot
    const dotCenter = Offset(w / 2, 194);
    c.drawCircle(dotCenter + const Offset(0, 4), 14, Paint()..color = Colors.black54..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 6));
    c.drawCircle(dotCenter, 14, Paint()..color = Colors.white);
    c.drawCircle(dotCenter, 14, Paint()..style = PaintingStyle.stroke..strokeWidth = 4.5..color = badgeColor);
    c.drawCircle(dotCenter, 6.0, Paint()..color = darkBadgeColor);

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  /// Creates standard pickup/dropoff rings with high-end glows
  static Future<BitmapDescriptor> createRingDotMarker(Color color) async {
    const size = 80.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final center = const Offset(size / 2, size / 2);

    final darkColor = HSLColor.fromColor(color).withLightness(0.35).toColor();

    c.drawCircle(
        center, 26,
        Paint()
          ..color = color.withOpacity(0.35)
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 14)
    );

    c.drawCircle(
        center + const Offset(0, 6), 20,
        Paint()
          ..color = Colors.black.withOpacity(0.4)
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 10)
    );

    c.drawCircle(center, 20, Paint()..color = Colors.white);

    c.drawCircle(
        center, 20,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6.0
          ..shader = ui.Gradient.linear(
              center - const Offset(20, 20),
              center + const Offset(20, 20),
              [color, darkColor]
          )
    );

    c.drawCircle(
        center, 17,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.black.withOpacity(0.15)
    );

    c.drawCircle(center, 7.5, Paint()..color = color);

    final img = await rec.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  /// Converts a physical asset image to a map marker
  static Future<BitmapDescriptor> assetToMarker(String assetPath, {int targetWidth = 120}) async {
    final bd = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(bd.buffer.asUint8List(), targetWidth: targetWidth);
    final frame = await codec.getNextFrame();
    final pngBytes = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(pngBytes!.buffer.asUint8List());
  }
}