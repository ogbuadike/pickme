// lib/screens/state/routing_engine.dart
//
// Maps math, route geometry (snap-to-route, remaining distance) and the
// Google Routes v2 integration shared by the rider map and trip navigation.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute, debugPrint, kDebugMode;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../../api/url.dart';

/// One turn-by-turn step from the Routes API (`routes.legs.steps`).
class RouteStep {
  /// Human readable instruction, e.g. "Turn left onto Marian Rd".
  final String instruction;

  /// Routes API maneuver code (TURN_LEFT, ROUNDABOUT_RIGHT, ...). May be empty.
  final String maneuver;

  final int distanceMeters;
  final int durationSeconds;
  final LatLng start;
  final LatLng end;

  const RouteStep({
    required this.instruction,
    required this.maneuver,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.start,
    required this.end,
  });
}

class RouteResult {
  final List<LatLng> points;
  final int distanceMeters;
  final int durationSeconds;

  /// Turn-by-turn steps. Only populated when requested with `includeSteps`.
  final List<RouteStep> steps;

  const RouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    this.steps = const <RouteStep>[],
  });
}

/// Result of projecting a position onto a polyline.
class PolylineProjection {
  /// Closest point on the polyline.
  final LatLng point;

  /// Index `i` of the segment `points[i] -> points[i + 1]` that holds [point].
  final int segmentIndex;

  /// Fraction (0..1) along that segment.
  final double t;

  /// Distance in meters from the raw position to the polyline.
  final double distanceToRoute;

  /// Bearing of the matched segment (degrees, 0..360).
  final double segmentBearing;

  /// Distance in meters from the start of the polyline to [point].
  final double distanceAlong;

  const PolylineProjection({
    required this.point,
    required this.segmentIndex,
    required this.t,
    required this.distanceToRoute,
    required this.segmentBearing,
    required this.distanceAlong,
  });
}

/// A polyline with pre-computed cumulative distances so that projections,
/// remaining distance and "point at distance" queries are cheap enough to run
/// on every animation frame.
class RouteGeometry {
  final List<LatLng> points;

  /// cumulative[i] = distance in meters from points[0] to points[i].
  final List<double> cumulative;

  RouteGeometry._(this.points, this.cumulative);

  factory RouteGeometry(List<LatLng> points) {
    final cum = List<double>.filled(points.length, 0.0);
    for (int i = 1; i < points.length; i++) {
      cum[i] = cum[i - 1] + RoutingEngine.haversine(points[i - 1], points[i]);
    }
    return RouteGeometry._(List<LatLng>.unmodifiable(points), cum);
  }

  bool get isEmpty => points.length < 2;
  double get length => cumulative.isEmpty ? 0.0 : cumulative.last;

  /// Projects [p] on the polyline. When [hintSegment] is given, the search is
  /// limited to a window around it first (O(window)), falling back to a full
  /// scan only when the windowed match is far away. This keeps per-fix cost
  /// constant on long routes and prevents snapping onto an earlier/later pass
  /// of the same road.
  PolylineProjection? project(LatLng p, {int? hintSegment, int window = 40}) {
    if (points.length < 2) return null;
    final segCount = points.length - 1;
    PolylineProjection? best;

    PolylineProjection? scan(int from, int to) {
      PolylineProjection? local;
      for (int i = from; i <= to; i++) {
        final a = points[i], b = points[i + 1];
        final t = RoutingEngine.segmentFraction(p, a, b);
        final c = RoutingEngine.lerpLatLng(a, b, t);
        final d = RoutingEngine.haversine(p, c);
        if (local == null || d < local.distanceToRoute) {
          final segLen = cumulative[i + 1] - cumulative[i];
          local = PolylineProjection(
            point: c,
            segmentIndex: i,
            t: t,
            distanceToRoute: d,
            segmentBearing: RoutingEngine.bearingBetween(a, b),
            distanceAlong: cumulative[i] + segLen * t,
          );
        }
      }
      return local;
    }

    if (hintSegment != null && hintSegment >= 0) {
      final from = (hintSegment - 4).clamp(0, segCount - 1);
      final to = (hintSegment + window).clamp(0, segCount - 1);
      best = scan(from, to);
      if (best != null && best.distanceToRoute <= 60) return best;
    }
    final full = scan(0, segCount - 1);
    if (best == null || (full != null && full.distanceToRoute < best.distanceToRoute)) best = full;
    return best;
  }

  /// Point (and the bearing of its segment) located [meters] from the start.
  ({LatLng point, double bearing, int segment}) pointAtDistance(double meters) {
    if (points.length < 2) {
      return (point: points.isEmpty ? const LatLng(0, 0) : points.first, bearing: 0.0, segment: 0);
    }
    final d = meters.clamp(0.0, length);
    // Binary search the segment.
    int lo = 0, hi = cumulative.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (cumulative[mid] <= d) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final segLen = cumulative[hi] - cumulative[lo];
    final t = segLen <= 0 ? 0.0 : (d - cumulative[lo]) / segLen;
    return (
      point: RoutingEngine.lerpLatLng(points[lo], points[hi], t),
      bearing: RoutingEngine.bearingBetween(points[lo], points[hi]),
      segment: lo,
    );
  }

  /// Remaining polyline starting at a projection (projected point first).
  List<LatLng> remainingFrom(PolylineProjection proj) {
    final out = <LatLng>[proj.point];
    for (int i = proj.segmentIndex + 1; i < points.length; i++) {
      out.add(points[i]);
    }
    return out;
  }
}

/// Core Engine for Maps Math, Physics, and Google API integration.
class RoutingEngine {
  static const double _earthRadius = 6371000.0; // Meters

  /// Long-lived client => TCP/TLS keep-alive between route requests.
  static final http.Client _client = http.Client();

  /// Responses larger than this are parsed + decoded on a background isolate.
  static const int _isolateParseThresholdBytes = 24 * 1024;

  // --- MATH & PHYSICS ---

  static double deg2rad(double d) => d * (math.pi / 180.0);
  static double rad2deg(double r) => r * (180.0 / math.pi);
  static double normalizeDeg(double d) => (d % 360.0 + 360.0) % 360.0;

  /// Signed shortest angular difference `to - from` in degrees (-180..180].
  static double shortestAngleDelta(double from, double to) {
    final d = (to - from + 540.0) % 360.0 - 180.0;
    return d == -180.0 ? 180.0 : d;
  }

  /// Interpolates angles along the shortest arc.
  static double lerpAngle(double from, double to, double t) =>
      normalizeDeg(from + shortestAngleDelta(from, to) * t);

  static LatLng lerpLatLng(LatLng a, LatLng b, double t) => LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );

  static double haversine(LatLng a, LatLng b) {
    final dLat = deg2rad(b.latitude - a.latitude);
    final dLon = deg2rad(b.longitude - a.longitude);
    final la1 = deg2rad(a.latitude);
    final la2 = deg2rad(b.latitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(la1) * math.cos(la2) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * _earthRadius * math.asin(math.min(1, math.sqrt(h)));
  }

  static double bearingBetween(LatLng a, LatLng b) {
    final lat1 = deg2rad(a.latitude);
    final lat2 = deg2rad(b.latitude);
    final dLon = deg2rad(b.longitude - a.longitude);
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return normalizeDeg(rad2deg(math.atan2(y, x)));
  }

  static LatLng offsetLatLng(LatLng origin, double meters, double bearingDeg) {
    final br = deg2rad(bearingDeg);
    final lat1 = deg2rad(origin.latitude);
    final lon1 = deg2rad(origin.longitude);
    final d = meters / _earthRadius;
    final lat2 = math.asin(math.sin(lat1) * math.cos(d) + math.cos(lat1) * math.sin(d) * math.cos(br));
    final lon2 = lon1 + math.atan2(math.sin(br) * math.sin(d) * math.cos(lat1), math.cos(d) - math.sin(lat1) * math.sin(lat2));
    return LatLng(rad2deg(lat2), rad2deg(lon2));
  }

  /// Fraction (0..1) of the closest point to [p] on segment a→b, computed on a
  /// local equirectangular plane (accurate for road-length segments).
  static double segmentFraction(LatLng p, LatLng a, LatLng b) {
    final cosLat = math.cos(deg2rad((a.latitude + b.latitude) / 2));
    final dx = (b.longitude - a.longitude) * cosLat;
    final dy = b.latitude - a.latitude;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) return 0.0;
    final px = (p.longitude - a.longitude) * cosLat;
    final py = p.latitude - a.latitude;
    return ((px * dx + py * dy) / len2).clamp(0.0, 1.0);
  }

  static double polylineLength(List<LatLng> pts) {
    double sum = 0;
    for (int i = 1; i < pts.length; i++) {
      sum += haversine(pts[i - 1], pts[i]);
    }
    return sum;
  }

  static LatLngBounds computeSmartBounds(List<LatLng> points) {
    if (points.isEmpty) return LatLngBounds(southwest: const LatLng(0, 0), northeast: const LatLng(0, 0));
    double minLat = points.first.latitude, maxLat = points.first.latitude, minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      minLat = math.min(minLat, p.latitude); maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude); maxLng = math.max(maxLng, p.longitude);
    }
    final altitudeBuffer = math.max(math.max(maxLat - minLat, maxLng - minLng) * 0.10, 0.0018);
    minLat = math.max(minLat - altitudeBuffer, -90.0); maxLat = math.min(maxLat + altitudeBuffer, 90.0);
    minLng = math.max(minLng - altitudeBuffer, -180.0); maxLng = math.min(maxLng + altitudeBuffer, 180.0);
    if ((maxLat - minLat).abs() < 0.0001) { minLat -= 0.0008; maxLat += 0.0008; }
    if ((maxLng - minLng).abs() < 0.0001) { minLng -= 0.0008; maxLng += 0.0008; }
    return LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
  }

  // --- GOOGLE ROUTES API INTEGRATION ---

  static const String _baseFieldMask = 'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline';
  static const String _stepsFieldMask = ',routes.legs.steps.distanceMeters,routes.legs.steps.staticDuration,'
      'routes.legs.steps.startLocation,routes.legs.steps.endLocation,routes.legs.steps.navigationInstruction';

  /// Computes the optimal driving route using Google Routes V2 API.
  ///
  /// Returns null on any failure (network, quota, no route). Large responses
  /// are parsed and their polylines decoded on a background isolate so long
  /// routes never stall the UI thread.
  static Future<RouteResult?> computeRoute({
    required LatLng origin,
    required LatLng destination,
    List<LatLng> stops = const [],
    bool includeSteps = false,
    bool optimizeStopOrder = true,
  }) async {
    final url = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');
    final body = <String, dynamic>{
      'origin': {'location': {'latLng': {'latitude': origin.latitude, 'longitude': origin.longitude}}},
      'destination': {'location': {'latLng': {'latitude': destination.latitude, 'longitude': destination.longitude}}},
      if (stops.isNotEmpty) 'intermediates': [for (final s in stops) {'location': {'latLng': {'latitude': s.latitude, 'longitude': s.longitude}}}],
      'travelMode': 'DRIVE',
      'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
      'computeAlternativeRoutes': false,
      'optimizeWaypointOrder': stops.isNotEmpty && optimizeStopOrder,
      'units': 'METRIC',
      'polylineQuality': 'HIGH_QUALITY',
    };

    final headers = {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': ApiConstants.kGoogleApiKey,
      'X-Goog-FieldMask': includeSteps ? '$_baseFieldMask$_stepsFieldMask' : _baseFieldMask,
    };

    try {
      final res = await _client.post(url, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        if (kDebugMode) debugPrint('[RoutingEngine] HTTP ${res.statusCode}');
        return null;
      }
      final raw = res.body;
      if (raw.length >= _isolateParseThresholdBytes) {
        return await compute(_parseRoutesBody, raw);
      }
      return _parseRoutesBody(raw);
    } catch (e) {
      if (kDebugMode) debugPrint('[RoutingEngine] computeRoute failed: $e');
      return null; // Caller handles "no route" gracefully.
    }
  }

  /// Pure function (isolate-safe): JSON body -> RouteResult.
  static RouteResult? _parseRoutesBody(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map) return null;
    final routes = json['routes'];
    if (routes is! List || routes.isEmpty || routes.first is! Map) return null;
    final route = routes.first as Map;

    final poly = route['polyline'];
    final encoded = poly is Map ? (poly['encodedPolyline']?.toString() ?? '') : '';
    if (encoded.isEmpty) return null;

    final pts = decodePolyline(encoded);
    if (pts.isEmpty) return null;

    final dist = (route['distanceMeters'] as num?)?.toInt() ?? polylineLength(pts).round();
    final durS = parseDurationSeconds(route['duration']);

    final steps = <RouteStep>[];
    final legs = route['legs'];
    if (legs is List) {
      for (final leg in legs) {
        if (leg is! Map) continue;
        final rawSteps = leg['steps'];
        if (rawSteps is! List) continue;
        for (final s in rawSteps) {
          if (s is! Map) continue;
          final start = _latLngOf(s['startLocation']);
          final end = _latLngOf(s['endLocation']);
          if (start == null || end == null) continue;
          final nav = s['navigationInstruction'];
          steps.add(RouteStep(
            instruction: nav is Map ? (nav['instructions']?.toString() ?? '') : '',
            maneuver: nav is Map ? (nav['maneuver']?.toString() ?? '') : '',
            distanceMeters: (s['distanceMeters'] as num?)?.toInt() ?? 0,
            durationSeconds: parseDurationSeconds(s['staticDuration']),
            start: start,
            end: end,
          ));
        }
      }
    }

    return RouteResult(points: pts, distanceMeters: dist, durationSeconds: durS, steps: steps);
  }

  static LatLng? _latLngOf(dynamic loc) {
    if (loc is! Map) return null;
    final ll = loc['latLng'];
    if (ll is! Map) return null;
    final lat = (ll['latitude'] as num?)?.toDouble();
    final lng = (ll['longitude'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  /// Parses Routes API durations ("123s" / "123.4s").
  static int parseDurationSeconds(dynamic v) {
    final s = v?.toString() ?? '';
    if (s.isEmpty) return 0;
    final trimmed = s.endsWith('s') ? s.substring(0, s.length - 1) : s;
    return double.tryParse(trimmed)?.round() ?? 0;
  }

  /// Decodes a Google encoded polyline. Prefer [decodePolylineAsync] for long
  /// strings when called from UI code.
  static List<LatLng> decodePolyline(String enc) {
    final out = <LatLng>[];
    int idx = 0, lat = 0, lng = 0;
    final len = enc.length;
    while (idx < len) {
      int b, shift = 0, res = 0;
      do {
        if (idx >= len) return out; // Malformed input: stop instead of throwing.
        b = enc.codeUnitAt(idx++) - 63; res |= (b & 0x1f) << shift; shift += 5;
      } while (b >= 0x20);
      lat += (res & 1) != 0 ? ~(res >> 1) : (res >> 1);
      shift = 0; res = 0;
      do {
        if (idx >= len) return out;
        b = enc.codeUnitAt(idx++) - 63; res |= (b & 0x1f) << shift; shift += 5;
      } while (b >= 0x20);
      lng += (res & 1) != 0 ? ~(res >> 1) : (res >> 1);
      out.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return out;
  }

  /// Off-UI-thread decode for long polylines.
  static Future<List<LatLng>> decodePolylineAsync(String enc) {
    if (enc.length < 4000) return Future.value(decodePolyline(enc));
    return compute(decodePolyline, enc);
  }
}
