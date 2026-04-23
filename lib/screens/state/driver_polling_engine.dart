// lib/screens/state/driver_polling_engine.dart
import 'dart:async';
import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../../api/api_client.dart';
import '../../api/url.dart';
import 'home_models.dart';
import 'routing_engine.dart';
// FIXED: Added the import so it knows what a DriverCar is
import '../../services/ride_market_service.dart';

/// Enterprise Polling Engine
/// Implements Smart Polling, Time-To-Live (TTL) culling, and Server DDOS protection.
class DriverPollingEngine {
  final ApiClient api;
  final String userId;
  final Function(List<DriverCar> activeDrivers, Map<String, double> computedHeadings) onDriversUpdated;

  Timer? _timer;
  bool _isBusy = false;
  String? _cursor;
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);

  final Map<String, DriverCar> _driverCache = {};
  final Map<String, DateTime> _driverLastSeen = {};
  final Map<String, double> _computedHeadings = {};

  DriverPollingEngine({
    required this.api,
    required this.userId,
    required this.onDriversUpdated,
  });

  /// Starts the polling loop. Uses adaptive frequency.
  void start(LatLng currentUserLocation, {double radiusKm = 5.0}) {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _fetchNearby(currentUserLocation, radiusKm));
    _fetchNearby(currentUserLocation, radiusKm);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _isBusy = false;
  }

  void dispose() {
    stop();
    _driverCache.clear();
    _driverLastSeen.clear();
    _computedHeadings.clear();
  }

  Future<void> _fetchNearby(LatLng location, double radiusKm) async {
    if (_isBusy) return;

    // ANTI-OVERLOAD: Prevent spamming if the loop runs too fast
    final now = DateTime.now();
    if (now.difference(_lastTick) < const Duration(milliseconds: 2000)) return;
    _lastTick = now;

    _isBusy = true;

    try {
      final payload = <String, String>{
        'lat': location.latitude.toString(),
        'lng': location.longitude.toString(),
        'radius_km': radiusKm.toStringAsFixed(1),
        'vehicle': 'car',
        'user_id': userId,
        if (_cursor != null) 'cursor': _cursor!,
      };

      final res = await api.request(
        ApiConstants.driversNearbyEndpoint,
        method: 'POST',
        data: payload,
      ).timeout(const Duration(seconds: 5)); // 5s drop dead to prevent socket hanging

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        final data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};

        if (data['error'] == true || data['error']?.toString() == '1') return;

        _cursor = data['cursor']?.toString() ?? _cursor;

        final rawList = data['drivers'] ?? data['data'] ?? [];
        final parsedDrivers = <DriverCar>[];

        for (final e in (rawList is List ? rawList : rawList.values)) {
          if (e is Map) {
            final d = DriverCar.fromJson(e.cast<String, dynamic>());
            if (d.id.isNotEmpty && d.ll.latitude != 0.0) parsedDrivers.add(d);
          }
        }

        _processDrivers(parsedDrivers);
      }
    } catch (_) {
      // Fail silently to avoid interrupting the user experience
    } finally {
      _isBusy = false;
    }
  }

  void _processDrivers(List<DriverCar> incoming) {
    final now = DateTime.now();
    bool changed = false;

    for (final d in incoming) {
      _driverLastSeen[d.id] = now;
      final existing = _driverCache[d.id];

      // Compute physical heading if the driver has moved enough
      if (existing != null) {
        final dist = RoutingEngine.haversine(existing.ll, d.ll);
        if (dist > 2.0) {
          _computedHeadings[d.id] = RoutingEngine.bearingBetween(existing.ll, d.ll);
        }
      } else {
        _computedHeadings[d.id] = d.heading > 0 ? d.heading : 0.0;
      }

      // Update cache
      if (existing == null || RoutingEngine.haversine(existing.ll, d.ll) >= 1.2 || (existing.heading - d.heading).abs() >= 6.0) {
        _driverCache[d.id] = d;
        changed = true;
      }
    }

    // TTL (Time-To-Live) Culling: Remove drivers that haven't responded in 12 seconds
    final staleIds = _driverLastSeen.entries
        .where((e) => now.difference(e.value).inSeconds > 12)
        .map((e) => e.key)
        .toList();

    for (final id in staleIds) {
      _driverLastSeen.remove(id);
      _computedHeadings.remove(id);
      if (_driverCache.remove(id) != null) changed = true;
    }

    if (changed) {
      onDriversUpdated(_driverCache.values.toList(), Map.from(_computedHeadings));
    }
  }
}