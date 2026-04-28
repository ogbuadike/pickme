// lib/screens/state/map_graphics_engine.dart
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../themes/app_theme.dart';

/// **ULTRAPREMIUM MAP GRAPHICS ENGINE**
class MapGraphicsEngine {
  // ──────────────────────────────────────────────────────────────────────────────
  // CACHE — O(1) retrieval, maximum memory footprint controlled
  // ──────────────────────────────────────────────────────────────────────────────
  static const int _maxCacheEntries = 60;
  static final LinkedHashMap<int, BitmapDescriptor> _cache = LinkedHashMap<int, BitmapDescriptor>();

  static void clearCache() => _cache.clear();

  // ──────────────────────────────────────────────────────────────────────────────
  // PUBLIC FACTORY METHODS
  // ──────────────────────────────────────────────────────────────────────────────

  /// **User location radar marker**
  static Future<BitmapDescriptor> createUserLocationRadarMarker({
    required bool isDark,
    required ColorScheme cs,
  }) async {
    final cacheKey = Object.hash('user_locator_v2', isDark, cs.primary.value);
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;

    const double canvasSize = 200.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final center = const Offset(canvasSize / 2, canvasSize / 2);
    final primary = isDark ? cs.primary : const Color(0xFF1A73E8);
    final accent = isDark ? cs.secondary : const Color(0xFF00A651);

    _drawRadarBackground(c, center, canvasSize, primary);
    _drawSonarRings(c, center, primary);
    _drawRadarSweep(c, center, primary);
    _drawCrossHair(c, center, primary);
    _drawCoreBeacon(c, center, primary, accent, isDark);

    final bmp = await _finalizeCanvas(rec, canvasSize.toInt(), canvasSize.toInt());
    _cacheEntry(cacheKey, bmp);
    return bmp;
  }

  /// **Premium "ME" Pin** - Perfect circle, instant loading text instead of image
  static Future<BitmapDescriptor> createPremiumAvatarPin({
    required ui.Image? avatarImage, // Kept so your existing calls don't break
    required bool isDark,
    required ColorScheme cs,
  }) async {
    // Cache key ignores the image for instant O(1) lookup
    final cacheKey = Object.hash('avatar_me_v3', isDark, cs.primary.value);
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;

    const double canvasSize = 220.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final center = const Offset(canvasSize / 2, canvasSize / 2 - 14);
    const avatarRadius = 44.0;
    final ringColor = isDark ? cs.primary : AppColors.primary;
    final accent = isDark ? cs.secondary : const Color(0xFF00E5FF);

    // 1. Perfect Circular Glow & Shadow
    _drawGlow(c, center, avatarRadius + 12, ringColor.withOpacity(isDark ? 0.35 : 0.20), 24);
    _drawGlow(c, center + const Offset(0, 16), avatarRadius + 4, Colors.black.withOpacity(0.6), 16);

    // 2. Outer Metallic Bezel (Perfect Circle)
    c.drawCircle(center, avatarRadius + 6, Paint()
      ..shader = ui.Gradient.linear(
          center - const Offset(avatarRadius, avatarRadius),
          center + const Offset(avatarRadius, avatarRadius),
          [Colors.white.withOpacity(0.95), ringColor, Colors.black87],
          const [0.0, 0.4, 1.0]));

    // Inner dark background for the text
    c.drawCircle(center, avatarRadius, Paint()..color = isDark ? const Color(0xFF121212) : const Color(0xFF1E293B));

    // 3. The "ME" Text
    final tp = _createTextPainter("ME", 32, FontWeight.w900, Colors.white, letterSpacing: 2.0);
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));

    // 4. Holographic Glass Bezel & Arcs
    _drawHolographicBezel(c, center, avatarRadius, ringColor);
    _drawEnergyArcs(c, center, avatarRadius, accent);

    // 5. Sleek Pointer pointing down to the road
    _drawPointer(c, center, avatarRadius, ringColor, isDark);

    // 6. Online Status Dot
    _drawOnlineIndicator(c, center + const Offset(avatarRadius * 0.75, avatarRadius * 0.7), accent);

    final bmp = await _finalizeCanvas(rec, canvasSize.toInt(), canvasSize.toInt());
    _cacheEntry(cacheKey, bmp);
    return bmp;
  }

  /// **ETA pill badge**
  static Future<BitmapDescriptor> createArrivePillBadge({
    required String text,
    required bool isDark,
    required ColorScheme cs,
  }) async {
    final cacheKey = Object.hash('pill_v2', text, isDark, cs.primary.value);
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;

    const double maxHeight = 100.0;
    final tp = _createTextPainter(text.toUpperCase(), 18, FontWeight.w900, Colors.white);
    final w = (tp.width + 64).clamp(200.0, 420.0);
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final pillColor = isDark ? cs.primary : const Color(0xFF1A73E8);
    final darkPillColor = isDark ? cs.primary.withOpacity(0.6) : const Color(0xFF0D47A1);
    final accent = isDark ? cs.secondary : const Color(0xFF00E5FF);

    final pillRect = Rect.fromLTWH(0, 0, w, 52);
    final pill = RRect.fromRectAndRadius(pillRect, const Radius.circular(26));

    c.drawRRect(pill.shift(const Offset(0, 6)), Paint()
      ..color = pillColor.withOpacity(isDark ? 0.5 : 0.35)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 24));
    c.drawRRect(pill.shift(const Offset(0, 14)), Paint()
      ..color = Colors.black.withOpacity(isDark ? 0.8 : 0.4)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 16));

    c.drawRRect(pill, Paint()
      ..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(0, 52), [pillColor, darkPillColor]));
    c.drawRRect(pill, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = Colors.white.withOpacity(0.5));

    _drawTechBrackets(c, pillRect, accent);

    final glossPath = Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(4, 2, w - 8, 24), const Radius.circular(20)));
    c.drawPath(glossPath, Paint()
      ..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(0, 24),
          [Colors.white.withOpacity(0.5), Colors.transparent]));

    _drawThoughtDot(c, Offset(w / 2 + 18, 62), 7.5, pillColor, darkPillColor, isDark);
    _drawThoughtDot(c, Offset(w / 2 + 8, 78), 4.5, pillColor, darkPillColor, isDark);
    _drawThoughtDot(c, Offset(w / 2, 90), 2.5, pillColor, darkPillColor, isDark);

    tp.paint(c, Offset((w - tp.width) / 2, (52 - tp.height) / 2));

    final bmp = await _finalizeCanvas(rec, w.toInt(), maxHeight.toInt());
    _cacheEntry(cacheKey, bmp);
    return bmp;
  }

  /// **Minutes circle badge**
  static Future<BitmapDescriptor> createMinutesCircleBadge({
    required int minutes,
    required bool isDark,
    required ColorScheme cs,
  }) async {
    final cacheKey = Object.hash('minutes_v2', minutes, isDark, cs.secondary.value);
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;

    const double w = 200.0, h = 250.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final center = const Offset(w / 2, 80);
    const badgeR = 56.0;
    final badgeColor = isDark ? cs.secondary : const Color(0xFF00A651);
    final darkBadgeColor = isDark ? cs.secondary.withOpacity(0.6) : const Color(0xFF007E3D);

    _drawOuterProgressRing(c, center, badgeR + 6, badgeColor, darkBadgeColor);

    _drawGlow(c, center + const Offset(0, 8), badgeR + 2, badgeColor.withOpacity(isDark ? 0.5 : 0.3), 24);
    _drawGlow(c, center + const Offset(0, 16), badgeR, Colors.black.withOpacity(isDark ? 0.8 : 0.35), 16);

    c.drawCircle(center, badgeR, Paint()
      ..shader = ui.Gradient.linear(center - const Offset(0, badgeR), center + const Offset(0, badgeR),
          [badgeColor, darkBadgeColor]));
    c.drawCircle(center, badgeR - 1.5, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = Colors.white.withOpacity(0.5));

    final glossPath = Path()..addOval(
        Rect.fromCircle(center: center - const Offset(0, badgeR * 0.4), radius: badgeR * 0.7));
    c.drawPath(glossPath, Paint()
      ..shader = ui.Gradient.linear(center - const Offset(0, badgeR), center,
          [Colors.white.withOpacity(0.45), Colors.transparent]));

    final numTp = _createTextPainter('$minutes', 44, FontWeight.w900, Colors.white, letterSpacing: -1.2);
    final minTp = _createTextPainter('MIN', 16, FontWeight.w900, Colors.white, letterSpacing: 1.4);
    numTp.paint(c, Offset(center.dx - numTp.width / 2, center.dy - 40));
    minTp.paint(c, Offset(center.dx - minTp.width / 2, center.dy + 10));

    _drawMetallicStem(c, center.dy + badgeR, center.dx, w / 2, 215, badgeColor, darkBadgeColor);

    const dotCenter = Offset(w / 2, 215);
    _drawGlow(c, dotCenter + const Offset(0, 6), 16, Colors.black.withOpacity(0.7), 10);
    c.drawCircle(dotCenter, 16, Paint()..color = Colors.white);
    c.drawCircle(dotCenter, 16, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..color = badgeColor);
    c.drawCircle(dotCenter, 7.0, Paint()..color = darkBadgeColor);
    c.drawCircle(dotCenter, 3.0, Paint()..color = Colors.white.withOpacity(0.8));

    final bmp = await _finalizeCanvas(rec, w.toInt(), h.toInt());
    _cacheEntry(cacheKey, bmp);
    return bmp;
  }

  /// **Ring dot marker**
  static Future<BitmapDescriptor> createRingDotMarker(Color color) async {
    final cacheKey = Object.hash('ring_v2', color.value);
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;

    const size = 100.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final center = const Offset(size / 2, size / 2);
    final darkColor = HSLColor.fromColor(color).withLightness(0.35).toColor();
    final deepDark = darkColor.withOpacity(0.8);

    _drawGlow(c, center, 34, color.withOpacity(0.3), 14);
    _drawGlow(c, center + const Offset(0, 4), 26, Colors.black.withOpacity(0.4), 12);

    c.drawCircle(center, 26, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..shader = ui.Gradient.linear(
          center - const Offset(26, 26), center + const Offset(26, 26),
          [color, darkColor]));
    c.drawCircle(center, 23, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..color = Colors.grey.shade200.withOpacity(0.35));

    _drawGlow(c, center + const Offset(0, 3), 20, Colors.black.withOpacity(0.5), 8);
    c.drawCircle(center, 20, Paint()..color = Colors.white);

    c.drawCircle(center, 12, Paint()
      ..shader = ui.Gradient.radial(
          center, 4, [Colors.white, color, deepDark], [0.0, 0.5, 1.0]));
    c.drawCircle(center, 8, Paint()..color = Colors.white.withOpacity(0.15));

    final bmp = await _finalizeCanvas(rec, size.toInt(), size.toInt());
    _cacheEntry(cacheKey, bmp);
    return bmp;
  }

  static Future<BitmapDescriptor> assetToMarker(String assetPath, {int targetWidth = 130}) async {
    final cacheKey = Object.hash('asset_v2', assetPath, targetWidth);
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;

    final bd = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(
        bd.buffer.asUint8List(), targetWidth: targetWidth);
    final frame = await codec.getNextFrame();
    final pngBytes = await frame.image.toByteData(format: ui.ImageByteFormat.png);

    final bmp = BitmapDescriptor.fromBytes(pngBytes!.buffer.asUint8List());
    _cacheEntry(cacheKey, bmp);
    return bmp;
  }

  // ──────────────────────────────────────────────────────────────────────────────
  // PRIVATE DRAWING HELPERS
  // ──────────────────────────────────────────────────────────────────────────────

  static void _drawRadarBackground(Canvas c, Offset center, double size, Color color) {
    final bgPaint = Paint()
      ..color = Colors.black.withOpacity(0.2)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 12);
    c.drawCircle(center, size / 2.8, bgPaint);

    for (double r = 20; r < size / 2.8; r += 18) {
      c.drawCircle(center, r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = color.withOpacity(0.25));
    }
    final linePaint = Paint()
      ..color = color.withOpacity(0.15)
      ..strokeWidth = 0.8;
    for (int i = 0; i < 12; i++) {
      final angle = (i * 30) * math.pi / 180;
      final dx = math.cos(angle) * size / 2.8;
      final dy = math.sin(angle) * size / 2.8;
      c.drawLine(center, Offset(center.dx + dx, center.dy + dy), linePaint);
    }
  }

  static void _drawSonarRings(Canvas c, Offset center, Color color) {
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color.withOpacity(0.45);
    c.drawCircle(center, 78, ringPaint);
    c.drawCircle(center, 52, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = color.withOpacity(0.7)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4));
  }

  static void _drawRadarSweep(Canvas c, Offset center, Color color) {
    final sweepPaint = Paint()
      ..shader = ui.Gradient.sweep(
          center,
          [color.withOpacity(0.0), color.withOpacity(0.2), color.withOpacity(0.5), color.withOpacity(0.0)],
          [0.0, 0.35, 0.95, 1.0]);
    c.drawCircle(center, 78, sweepPaint);
  }

  static void _drawCrossHair(Canvas c, Offset center, Color color) {
    final crossPaint = Paint()
      ..color = color.withOpacity(0.6)
      ..strokeWidth = 1.8
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 2);
    const length = 18.0;
    c.drawLine(center + const Offset(-length, 0), center + const Offset(length, 0), crossPaint);
    c.drawLine(center + const Offset(0, -length), center + const Offset(0, length), crossPaint);
  }

  static void _drawCoreBeacon(Canvas c, Offset center, Color primary, Color accent, bool isDark) {
    _drawGlow(c, center, 30, primary.withOpacity(0.5), 18);
    c.drawCircle(center, 18, Paint()
      ..shader = ui.Gradient.radial(
          center, 3, [Colors.white, primary, primary.withOpacity(0.8)], [0.0, 0.5, 1.0]));
    _drawGlow(c, center + const Offset(0, 2), 12, Colors.black45, 6);
    c.drawCircle(center, 12, Paint()..color = Colors.white);
    c.drawCircle(center, 6, Paint()..color = accent);
    c.drawCircle(center - const Offset(0, 32), 4.5, Paint()..color = primary);
  }

  static void _drawHolographicBezel(Canvas c, Offset center, double radius, Color color) {
    c.drawCircle(center, radius + 8, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..shader = ui.Gradient.sweep(center,
          [Colors.white.withOpacity(0.0), color.withOpacity(0.7), Colors.white.withOpacity(0.0)],
          const [0.0, 0.6, 1.0]));
    c.drawCircle(center, radius + 2, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = Colors.white.withOpacity(0.9));
    c.drawCircle(center, radius + 2, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..color = color.withOpacity(0.5)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3));
  }

  static void _drawEnergyArcs(Canvas c, Offset center, double radius, Color accent) {
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = accent.withOpacity(0.5)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3);
    for (int i = 0; i < 3; i++) {
      final startAngle = i * 2.0;
      const sweep = 1.2;
      final rect = Rect.fromCircle(center: center, radius: radius + 16);
      c.drawArc(rect, startAngle, sweep, false, arcPaint);
    }
  }

  static void _drawPointer(Canvas c, Offset center, double radius, Color ringColor, bool isDark) {
    final pointerPath = Path()
      ..moveTo(center.dx - 20, center.dy + radius - 6)
      ..lineTo(center.dx, center.dy + radius + 46)
      ..lineTo(center.dx + 20, center.dy + radius - 6)
      ..close();
    _drawGlowPath(c, pointerPath.shift(const Offset(0, 8)),
        Colors.black.withOpacity(isDark ? 0.8 : 0.4), 12);
    c.drawPath(pointerPath, Paint()
      ..shader = ui.Gradient.linear(
          Offset(center.dx, center.dy + radius - 6),
          Offset(center.dx, center.dy + radius + 46),
          [ringColor, HSLColor.fromColor(ringColor).withLightness(0.15).toColor()]));
    c.drawLine(
        Offset(center.dx, center.dy + radius - 4),
        Offset(center.dx, center.dy + radius + 44),
        Paint()
          ..color = Colors.white.withOpacity(0.4)
          ..strokeWidth = 2.5);
  }

  static void _drawOnlineIndicator(Canvas c, Offset dotCenter, Color accent) {
    _drawGlow(c, dotCenter, 14, Colors.black.withOpacity(0.6), 8);
    c.drawCircle(dotCenter, 11, Paint()..color = Colors.black);
    c.drawCircle(dotCenter, 8, Paint()..color = accent);
    _drawGlow(c, dotCenter, 8, accent.withOpacity(0.8), 6);
  }

  static void _drawTechBrackets(Canvas c, Rect pillRect, Color accent) {
    final bracketPaint = Paint()
      ..color = accent.withOpacity(0.9)
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;
    const brLen = 12.0;
    c.drawLine(Offset(pillRect.left + 4, pillRect.top + 8),
        Offset(pillRect.left + 4, pillRect.top + 8 + brLen), bracketPaint);
    c.drawLine(Offset(pillRect.left + 4, pillRect.top + 8),
        Offset(pillRect.left + 4 + brLen, pillRect.top + 8), bracketPaint);
    c.drawLine(Offset(pillRect.right - 4, pillRect.bottom - 8),
        Offset(pillRect.right - 4, pillRect.bottom - 8 - brLen), bracketPaint);
    c.drawLine(Offset(pillRect.right - 4, pillRect.bottom - 8),
        Offset(pillRect.right - 4 - brLen, pillRect.bottom - 8), bracketPaint);
  }

  static void _drawOuterProgressRing(Canvas c, Offset center, double radius, Color color, Color dark) {
    final rect = Rect.fromCircle(center: center, radius: radius);
    final sweepPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8.0
      ..shader = ui.Gradient.sweep(
          center,
          [color, dark, color, Colors.transparent],
          const [0.0, 0.25, 0.4, 1.0]);
    c.drawArc(rect, 4.7, 4.0, false, sweepPaint);
    c.drawCircle(center, radius + 4, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = color.withOpacity(0.35));
  }

  static void _drawMetallicStem(Canvas c, double topY, double centerX, double stemX, double yEnd, Color color, Color dark) {
    final stemPaint = Paint()
      ..strokeWidth = 8.0
      ..strokeCap = StrokeCap.round;
    c.drawLine(Offset(stemX, topY), Offset(stemX, yEnd),
        stemPaint..color = Colors.black54..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 8));
    c.drawLine(Offset(stemX, topY), Offset(stemX, yEnd),
        stemPaint
          ..maskFilter = null
          ..shader = ui.Gradient.linear(
              Offset(stemX, topY), Offset(stemX, yEnd), [dark, color]));
    c.drawLine(Offset(stemX - 1.5, topY + 4), Offset(stemX - 1.5, yEnd - 4),
        Paint()
          ..color = Colors.white.withOpacity(0.35)
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round);
  }

  static void _drawGlow(Canvas c, Offset center, double radius, Color color, double blur) {
    c.drawCircle(center, radius, Paint()
      ..color = color
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, blur));
  }

  static void _drawGlowPath(Canvas c, Path path, Color color, double blur) {
    c.drawPath(path, Paint()
      ..color = color
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, blur));
  }

  static void _drawThoughtDot(Canvas c, Offset center, double radius, Color color, Color darkColor, bool isDark) {
    _drawGlow(c, center, radius + 6, color.withOpacity(isDark ? 0.5 : 0.25), 8);
    _drawGlow(c, center + const Offset(0, 4), radius, Colors.black.withOpacity(isDark ? 0.7 : 0.35), 5);
    c.drawCircle(center, radius, Paint()
      ..shader = ui.Gradient.linear(
          center - Offset(0, radius),
          center + Offset(0, radius),
          [color, darkColor]));
    c.drawCircle(center, radius - 0.8, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.white.withOpacity(0.6));
  }

  static TextPainter _createTextPainter(String text, double size, FontWeight weight, Color color, {double letterSpacing = 0.0}) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: weight,
          height: 1.0,
          letterSpacing: letterSpacing,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 3))],
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
  }

  static Future<BitmapDescriptor> _finalizeCanvas(ui.PictureRecorder rec, int w, int h) async {
    final img = await rec.endRecording().toImage(w, h);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  // ──────────────────────────────────────────────────────────────────────────────
  // CACHE MANAGEMENT
  // ──────────────────────────────────────────────────────────────────────────────
  static void _cacheEntry(int key, BitmapDescriptor descriptor) {
    _cache[key] = descriptor;
    if (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }
}