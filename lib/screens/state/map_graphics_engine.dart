// lib/screens/state/map_graphics_engine.dart
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';


/// **ULTRAPREMIUM MAP GRAPHICS ENGINE**
class MapGraphicsEngine {
  // ──────────────────────────────────────────────────────────────────────────────
  // CACHE — O(1) retrieval, maximum memory footprint controlled
  // ──────────────────────────────────────────────────────────────────────────────
  static const int _maxCacheEntries = 60;
  static final LinkedHashMap<int, BitmapDescriptor> _cache = LinkedHashMap<int, BitmapDescriptor>();

  static void clearCache() => _cache.clear();

  /// Dark map style JSON shared by the rider map and trip navigation.
  static const String kDarkMapStyle = '''[{"elementType":"geometry","stylers":[{"color":"#212121"}]},{"elementType":"labels.icon","stylers":[{"visibility":"off"}]},{"elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},{"elementType":"labels.text.stroke","stylers":[{"color":"#212121"}]},{"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#757575"}]},{"featureType":"administrative.country","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]},{"featureType":"administrative.land_parcel","stylers":[{"visibility":"off"}]},{"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#bdbdbd"}]},{"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},{"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#181818"}]},{"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},{"featureType":"poi.park","elementType":"labels.text.stroke","stylers":[{"color":"#1b1b1b"}]},{"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#2c2c2c"}]},{"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#8a8a8a"}]},{"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#373737"}]},{"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3c3c3c"}]},{"featureType":"road.highway.controlled_access","elementType":"geometry","stylers":[{"color":"#4e4e4e"}]},{"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},{"featureType":"transit","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},{"featureType":"water","elementType":"geometry","stylers":[{"color":"#000000"}]},{"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#3d3d3d"}]}]''';


  // ──────────────────────────────────────────────────────────────────────────────
  // PUBLIC FACTORY METHODS
  // ──────────────────────────────────────────────────────────────────────────────

  /// **User location radar marker**
  static Future<BitmapDescriptor> createUserLocationRadarMarker({
    required bool isDark,
    required ColorScheme cs,
  }) async {
    final cacheKey = Object.hash('user_locator_v2', isDark, cs.primary.toARGB32());
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

  // ──────────────────────────────────────────────────────────────────────────────
  // USER LOCATION ("blue dot") — Google/Uber style
  // ──────────────────────────────────────────────────────────────────────────────

  /// Logical diameter of the blue dot (incl. white ring).
  static const double kUserDotLogicalSize = 22.0;

  /// Logical canvas size of the heading variant (dot + beam). The dot sits in
  /// the exact centre so the marker must be anchored at (0.5, 0.5).
  static const double kUserBeamLogicalSize = 96.0;

  /// Accurate location dot: blue core, crisp white ring and soft shadow.
  ///
  /// When [withHeading] is true a translucent beam (cone) pointing "up" is
  /// added; render the marker with `flat: true` and `rotation: heading` so the
  /// beam points along the device heading in map space.
  ///
  /// Rendered once per (devicePixelRatio, heading, colour) and cached; uses
  /// [BitmapDescriptor.bytes] with `imagePixelRatio` so it is pixel-sharp and
  /// has the same logical size on every device.
  static Future<BitmapDescriptor> createUserLocationDot({
    required double devicePixelRatio,
    bool withHeading = false,
    Color color = const Color(0xFF1A73E8),
  }) async {
    final dpr = devicePixelRatio.clamp(1.0, 4.0).toDouble();
    final cacheKey = Object.hash('user_dot_v4', (dpr * 100).round(), withHeading, color.toARGB32());
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    final logical = withHeading ? kUserBeamLogicalSize : kUserDotLogicalSize + 12.0;
    final px = (logical * dpr).ceil();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.scale(px / logical);

    final center = Offset(logical / 2, logical / 2);
    const dotR = kUserDotLogicalSize / 2; // 11
    const coreR = dotR - 3.0; // white ring 3dp

    if (withHeading) {
      // Beam: 70° sector fading out with distance from the dot.
      const beamR = kUserBeamLogicalSize / 2 - 2;
      const half = 35.0 * math.pi / 180.0;
      const up = -math.pi / 2;
      final beam = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(Rect.fromCircle(center: center, radius: beamR), up - half, half * 2, false)
        ..close();
      c.drawPath(
        beam,
        Paint()
          ..isAntiAlias = true
          ..shader = ui.Gradient.radial(
            center,
            beamR,
            [color.withValues(alpha: 0.42), color.withValues(alpha: 0.16), color.withValues(alpha: 0.0)],
            const [0.0, 0.55, 1.0],
          ),
      );
    }

    // Soft drop shadow.
    c.drawCircle(
      center.translate(0, 1.2),
      dotR + 0.6,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.28)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 2.4),
    );
    // White ring.
    c.drawCircle(center, dotR, Paint()..color = Colors.white..isAntiAlias = true);
    // Core with a subtle top-left highlight for depth.
    c.drawCircle(
      center,
      coreR,
      Paint()
        ..isAntiAlias = true
        ..shader = ui.Gradient.radial(
          center.translate(-coreR * 0.35, -coreR * 0.35),
          coreR * 1.6,
          [Color.lerp(color, Colors.white, 0.22)!, color],
        ),
    );
    // Hairline outline keeps the ring visible on very light map tiles.
    c.drawCircle(
      center,
      dotR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = Colors.black.withValues(alpha: 0.10),
    );

    final img = await rec.endRecording().toImage(px, px);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    final bmp = BitmapDescriptor.bytes(bytes!.buffer.asUint8List(), imagePixelRatio: px / logical);
    _cacheEntry(cacheKey, bmp);
    return bmp;
  }

  /// Top-view car marker from an asset (e.g. `assets/images/open_top_view_car.png`),
  /// decoded once at the exact physical size for [devicePixelRatio] and cached.
  /// The asset is expected to face north (up); render with `flat: true`,
  /// `anchor: Offset(0.5, 0.5)` and `rotation: bearing`.
  static Future<BitmapDescriptor> createCarMarker({
    required double devicePixelRatio,
    String assetPath = 'assets/images/open_top_view_car.png',
    double logicalWidth = 24.0,
  }) async {
    final dpr = devicePixelRatio.clamp(1.0, 4.0).toDouble();
    final cacheKey = Object.hash('car_v2', assetPath, (dpr * 100).round(), logicalWidth);
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    final targetPx = (logicalWidth * dpr).round();
    final bd = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(bd.buffer.asUint8List(), targetWidth: targetPx);
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    final bmp = BitmapDescriptor.bytes(png!.buffer.asUint8List(), imagePixelRatio: dpr);
    _cacheEntry(cacheKey, bmp);
    return bmp;
  }

  /// Refined "You" pill marker (kept for screens that render a labelled pin).
  /// Tip of the pointer is at the bottom-centre: anchor with `Offset(0.5, 1.0)`.
  ///
  /// [avatarImage] is accepted for source compatibility and ignored: network
  /// avatars are no longer fetched/decoded for the map marker.
  static Future<BitmapDescriptor> createPremiumAvatarPin({
    required ui.Image? avatarImage,
    required bool isDark,
    required ColorScheme cs,
  }) async {
    final cacheKey = Object.hash('you_pill_v1', isDark, cs.primary.toARGB32());
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    const double w = 132, pillH = 56, tip = 16, h = pillH + tip + 8;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final bg = isDark ? const Color(0xFF1F2937) : Colors.white;
    final fg = isDark ? Colors.white : const Color(0xFF111827);
    const accent = Color(0xFF1A73E8);

    final pill = RRect.fromRectAndRadius(const Rect.fromLTWH(6, 4, w - 12, pillH - 8), const Radius.circular(24));
    final pointer = Path()
      ..moveTo(w / 2 - 11, pillH - 5)
      ..lineTo(w / 2, pillH - 4 + tip)
      ..lineTo(w / 2 + 11, pillH - 5)
      ..close();
    final shape = Path()..addRRect(pill)..addPath(pointer, Offset.zero);

    c.drawPath(shape.shift(const Offset(0, 3)), Paint()
      ..color = Colors.black.withValues(alpha: 0.28)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 5));
    c.drawPath(shape, Paint()..color = bg);
    c.drawRRect(pill, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.08));

    // Mini blue dot + label.
    final dotC = Offset(pill.left + 26, pill.center.dy);
    c.drawCircle(dotC, 11, Paint()..color = Colors.white);
    c.drawCircle(dotC, 8, Paint()..color = accent);
    final tp = TextPainter(
      text: TextSpan(text: 'You', style: TextStyle(color: fg, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(dotC.dx + 18, pill.center.dy - tp.height / 2));

    final bmp = await _finalizeCanvas(rec, w.toInt(), h.toInt());
    _cacheEntry(cacheKey, bmp);
    return bmp;
  }

  /// **ETA pill badge**
  static Future<BitmapDescriptor> createArrivePillBadge({
    required String text,
    required bool isDark,
    required ColorScheme cs,
  }) async {
    final cacheKey = Object.hash('pill_v2', text, isDark, cs.primary.toARGB32());
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;

    const double maxHeight = 100.0;
    final tp = _createTextPainter(text.toUpperCase(), 18, FontWeight.w900, Colors.white);
    final w = (tp.width + 64).clamp(200.0, 420.0);
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final pillColor = isDark ? cs.primary : const Color(0xFF1A73E8);
    final darkPillColor = isDark ? cs.primary.withValues(alpha: 0.6) : const Color(0xFF0D47A1);
    final accent = isDark ? cs.secondary : const Color(0xFF00E5FF);

    final pillRect = Rect.fromLTWH(0, 0, w, 52);
    final pill = RRect.fromRectAndRadius(pillRect, const Radius.circular(26));

    c.drawRRect(pill.shift(const Offset(0, 6)), Paint()
      ..color = pillColor.withValues(alpha: isDark ? 0.5 : 0.35)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 24));
    c.drawRRect(pill.shift(const Offset(0, 14)), Paint()
      ..color = Colors.black.withValues(alpha: isDark ? 0.8 : 0.4)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 16));

    c.drawRRect(pill, Paint()
      ..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(0, 52), [pillColor, darkPillColor]));
    c.drawRRect(pill, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = Colors.white.withValues(alpha: 0.5));

    _drawTechBrackets(c, pillRect, accent);

    final glossPath = Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(4, 2, w - 8, 24), const Radius.circular(20)));
    c.drawPath(glossPath, Paint()
      ..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(0, 24),
          [Colors.white.withValues(alpha: 0.5), Colors.transparent]));

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
    final cacheKey = Object.hash('minutes_v2', minutes, isDark, cs.secondary.toARGB32());
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;

    const double w = 200.0, h = 250.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final center = const Offset(w / 2, 80);
    const badgeR = 56.0;
    final badgeColor = isDark ? cs.secondary : const Color(0xFF00A651);
    final darkBadgeColor = isDark ? cs.secondary.withValues(alpha: 0.6) : const Color(0xFF007E3D);

    _drawOuterProgressRing(c, center, badgeR + 6, badgeColor, darkBadgeColor);

    _drawGlow(c, center + const Offset(0, 8), badgeR + 2, badgeColor.withValues(alpha: isDark ? 0.5 : 0.3), 24);
    _drawGlow(c, center + const Offset(0, 16), badgeR, Colors.black.withValues(alpha: isDark ? 0.8 : 0.35), 16);

    c.drawCircle(center, badgeR, Paint()
      ..shader = ui.Gradient.linear(center - const Offset(0, badgeR), center + const Offset(0, badgeR),
          [badgeColor, darkBadgeColor]));
    c.drawCircle(center, badgeR - 1.5, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = Colors.white.withValues(alpha: 0.5));

    final glossPath = Path()..addOval(
        Rect.fromCircle(center: center - const Offset(0, badgeR * 0.4), radius: badgeR * 0.7));
    c.drawPath(glossPath, Paint()
      ..shader = ui.Gradient.linear(center - const Offset(0, badgeR), center,
          [Colors.white.withValues(alpha: 0.45), Colors.transparent]));

    final numTp = _createTextPainter('$minutes', 44, FontWeight.w900, Colors.white, letterSpacing: -1.2);
    final minTp = _createTextPainter('MIN', 16, FontWeight.w900, Colors.white, letterSpacing: 1.4);
    numTp.paint(c, Offset(center.dx - numTp.width / 2, center.dy - 40));
    minTp.paint(c, Offset(center.dx - minTp.width / 2, center.dy + 10));

    _drawMetallicStem(c, center.dy + badgeR, center.dx, w / 2, 215, badgeColor, darkBadgeColor);

    const dotCenter = Offset(w / 2, 215);
    _drawGlow(c, dotCenter + const Offset(0, 6), 16, Colors.black.withValues(alpha: 0.7), 10);
    c.drawCircle(dotCenter, 16, Paint()..color = Colors.white);
    c.drawCircle(dotCenter, 16, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..color = badgeColor);
    c.drawCircle(dotCenter, 7.0, Paint()..color = darkBadgeColor);
    c.drawCircle(dotCenter, 3.0, Paint()..color = Colors.white.withValues(alpha: 0.8));

    final bmp = await _finalizeCanvas(rec, w.toInt(), h.toInt());
    _cacheEntry(cacheKey, bmp);
    return bmp;
  }

  /// **Ring dot marker**
  static Future<BitmapDescriptor> createRingDotMarker(Color color) async {
    final cacheKey = Object.hash('ring_v2', color.toARGB32());
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;

    const size = 100.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final center = const Offset(size / 2, size / 2);
    final darkColor = HSLColor.fromColor(color).withLightness(0.35).toColor();
    final deepDark = darkColor.withValues(alpha: 0.8);

    _drawGlow(c, center, 34, color.withValues(alpha: 0.3), 14);
    _drawGlow(c, center + const Offset(0, 4), 26, Colors.black.withValues(alpha: 0.4), 12);

    c.drawCircle(center, 26, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..shader = ui.Gradient.linear(
          center - const Offset(26, 26), center + const Offset(26, 26),
          [color, darkColor]));
    c.drawCircle(center, 23, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..color = Colors.grey.shade200.withValues(alpha: 0.35));

    _drawGlow(c, center + const Offset(0, 3), 20, Colors.black.withValues(alpha: 0.5), 8);
    c.drawCircle(center, 20, Paint()..color = Colors.white);

    c.drawCircle(center, 12, Paint()
      ..shader = ui.Gradient.radial(
          center, 4, [Colors.white, color, deepDark], [0.0, 0.5, 1.0]));
    c.drawCircle(center, 8, Paint()..color = Colors.white.withValues(alpha: 0.15));

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

    final bmp = BitmapDescriptor.bytes(pngBytes!.buffer.asUint8List(), bitmapScaling: MapBitmapScaling.none);
    _cacheEntry(cacheKey, bmp);
    return bmp;
  }

  // ──────────────────────────────────────────────────────────────────────────────
  // PRIVATE DRAWING HELPERS
  // ──────────────────────────────────────────────────────────────────────────────

  static void _drawRadarBackground(Canvas c, Offset center, double size, Color color) {
    final bgPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.2)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 12);
    c.drawCircle(center, size / 2.8, bgPaint);

    for (double r = 20; r < size / 2.8; r += 18) {
      c.drawCircle(center, r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = color.withValues(alpha: 0.25));
    }
    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.15)
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
      ..color = color.withValues(alpha: 0.45);
    c.drawCircle(center, 78, ringPaint);
    c.drawCircle(center, 52, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = color.withValues(alpha: 0.7)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4));
  }

  static void _drawRadarSweep(Canvas c, Offset center, Color color) {
    final sweepPaint = Paint()
      ..shader = ui.Gradient.sweep(
          center,
          [color.withValues(alpha: 0.0), color.withValues(alpha: 0.2), color.withValues(alpha: 0.5), color.withValues(alpha: 0.0)],
          [0.0, 0.35, 0.95, 1.0]);
    c.drawCircle(center, 78, sweepPaint);
  }

  static void _drawCrossHair(Canvas c, Offset center, Color color) {
    final crossPaint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..strokeWidth = 1.8
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 2);
    const length = 18.0;
    c.drawLine(center + const Offset(-length, 0), center + const Offset(length, 0), crossPaint);
    c.drawLine(center + const Offset(0, -length), center + const Offset(0, length), crossPaint);
  }

  static void _drawCoreBeacon(Canvas c, Offset center, Color primary, Color accent, bool isDark) {
    _drawGlow(c, center, 30, primary.withValues(alpha: 0.5), 18);
    c.drawCircle(center, 18, Paint()
      ..shader = ui.Gradient.radial(
          center, 3, [Colors.white, primary, primary.withValues(alpha: 0.8)], [0.0, 0.5, 1.0]));
    _drawGlow(c, center + const Offset(0, 2), 12, Colors.black45, 6);
    c.drawCircle(center, 12, Paint()..color = Colors.white);
    c.drawCircle(center, 6, Paint()..color = accent);
    c.drawCircle(center - const Offset(0, 32), 4.5, Paint()..color = primary);
  }

  static void _drawTechBrackets(Canvas c, Rect pillRect, Color accent) {
    final bracketPaint = Paint()
      ..color = accent.withValues(alpha: 0.9)
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
      ..color = color.withValues(alpha: 0.35));
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
          ..color = Colors.white.withValues(alpha: 0.35)
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round);
  }

  static void _drawGlow(Canvas c, Offset center, double radius, Color color, double blur) {
    c.drawCircle(center, radius, Paint()
      ..color = color
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, blur));
  }

  static void _drawThoughtDot(Canvas c, Offset center, double radius, Color color, Color darkColor, bool isDark) {
    _drawGlow(c, center, radius + 6, color.withValues(alpha: isDark ? 0.5 : 0.25), 8);
    _drawGlow(c, center + const Offset(0, 4), radius, Colors.black.withValues(alpha: isDark ? 0.7 : 0.35), 5);
    c.drawCircle(center, radius, Paint()
      ..shader = ui.Gradient.linear(
          center - Offset(0, radius),
          center + Offset(0, radius),
          [color, darkColor]));
    c.drawCircle(center, radius - 0.8, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.white.withValues(alpha: 0.6));
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
    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List(), bitmapScaling: MapBitmapScaling.none);
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