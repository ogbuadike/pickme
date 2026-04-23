// lib/screens/state/routing_engine.dart
import 'dart:convert';
import 'dart:math' as math;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../../api/url.dart'; // Make sure this contains ApiConstants.kGoogleApiKey

class RouteResult {
  final List<LatLng> points;
  final int distanceMeters;
  final int durationSeconds;

  const RouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });
}

/// Core Engine for Maps Math, Physics, and Google API integration.
class RoutingEngine {
  static const double _earthRadius = 6371000.0; // Meters

  // --- MATH & PHYSICS ---

  static double deg2rad(double d) => d * (math.pi / 180.0);
  static double rad2deg(double r) => r * (180.0 / math.pi);
  static double normalizeDeg(double d) => (d % 360.0 + 360.0) % 360.0;

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

  /// Computes the optimal driving route using Google Routes V2 API.
  static Future<RouteResult?> computeRoute({
    required LatLng origin,
    required LatLng destination,
    List<LatLng> stops = const [],
  }) async {
    final url = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');
    final body = <String, dynamic>{
      'origin': {'location': {'latLng': {'latitude': origin.latitude, 'longitude': origin.longitude}}},
      'destination': {'location': {'latLng': {'latitude': destination.latitude, 'longitude': destination.longitude}}},
      if (stops.isNotEmpty) 'intermediates': [for (final s in stops) {'location': {'latLng': {'latitude': s.latitude, 'longitude': s.longitude}}}],
      'travelMode': 'DRIVE',
      'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
      'computeAlternativeRoutes': false,
      'optimizeWaypointOrder': stops.isNotEmpty,
      'units': 'METRIC',
      'polylineQuality': 'HIGH_QUALITY',
    };

    final headers = {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': ApiConstants.kGoogleApiKey,
      'X-Goog-FieldMask': 'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline',
    };

    try {
      final res = await http.post(url, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = (json['routes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (routes.isEmpty) return null;

      final route = routes.first;
      final encoded = (route['polyline']?['encodedPolyline'] ?? '') as String;
      if (encoded.isEmpty) return null;

      final pts = decodePolyline(encoded);
      final dist = (route['distanceMeters'] ?? 0) as int;

      // Parse "123s" to 123
      final durationStr = route['duration']?.toString() ?? '0s';
      final durS = durationStr.endsWith('s') ? double.tryParse(durationStr.substring(0, durationStr.length - 1))?.round() ?? 0 : 0;

      return RouteResult(points: pts, distanceMeters: dist, durationSeconds: durS);
    } catch (_) {
      return null; // Will fallback to gracefully handling no-route in the UI
    }
  }

  /// Extremely fast C-style polyline decoder port for Dart
  static List<LatLng> decodePolyline(String enc) {
    final out = <LatLng>[];
    int idx = 0, lat = 0, lng = 0;
    while (idx < enc.length) {
      int b, shift = 0, res = 0;
      do { b = enc.codeUnitAt(idx++) - 63; res |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      lat += (res & 1) != 0 ? ~(res >> 1) : (res >> 1);
      shift = 0; res = 0;
      do { b = enc.codeUnitAt(idx++) - 63; res |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      lng += (res & 1) != 0 ? ~(res >> 1) : (res >> 1);
      out.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return out;
  }
}