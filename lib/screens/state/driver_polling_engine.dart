// lib/screens/state/driver_polling_engine.dart
//
// Nearby-driver polling with:
//   • single in-flight request (no overlapping polls),
//   • self-scheduling timer (next poll is scheduled after the previous one
//     finished, so slow networks never queue requests),
//   • exponential backoff on failures (3s → 30s), reset on success,
//   • a live, updatable search centre (the previous version captured the
//     first location forever),
//   • stale-driver eviction and movement-derived headings.
import 'dart:async';
import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../services/ride_market_service.dart';
import 'routing_engine.dart';

class DriverPollingEngine {
  final ApiClient api;
  final String userId;
  final Function(List<DriverCar> activeDrivers, Map<String, double> computedHeadings) onDriversUpdated;

  static const Duration _baseInterval = Duration(seconds: 3);
  static const Duration _maxInterval = Duration(seconds: 30);
  static const Duration _staleAfter = Duration(seconds: 12);

  Timer? _timer;
  bool _running = false;
  bool _isBusy = false;
  bool _disposed = false;
  int _failures = 0;
  String? _cursor;

  LatLng? _center;
  double _radiusKm = 5.0;
  String _rideType = 'street_ride';

  final Map<String, DriverCar> _driverCache = {};
  final Map<String, DateTime> _driverLastSeen = {};
  final Map<String, double> _computedHeadings = {};

  DriverPollingEngine({
    required this.api,
    required this.userId,
    required this.onDriversUpdated,
  });

  bool get isRunning => _running;

  /// Starts polling around [currentUserLocation]. When already running this
  /// only updates the search centre / radius / ride type (no extra request).
  void start(LatLng currentUserLocation, {double radiusKm = 5.0, String rideType = 'street_ride'}) {
    if (_disposed) return;
    final rideTypeChanged = rideType != _rideType;
    _center = currentUserLocation;
    _radiusKm = radiusKm;
    _rideType = rideType;
    if (rideTypeChanged) _cursor = null;
    if (_running) return;
    _running = true;
    _failures = 0;
    _pollNow();
  }

  /// Moves the search centre without restarting the loop.
  void updateLocation(LatLng location) => _center = location;

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    stop();
    _driverCache.clear();
    _driverLastSeen.clear();
    _computedHeadings.clear();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_running || _disposed) return;
    var delay = _baseInterval;
    for (int i = 0; i < _failures && delay < _maxInterval; i++) {
      delay *= 2;
    }
    if (delay > _maxInterval) delay = _maxInterval;
    _timer = Timer(delay, _pollNow);
  }

  Future<void> _pollNow() async {
    if (!_running || _disposed || _isBusy) return;
    final location = _center;
    if (location == null) return;
    _isBusy = true;
    try {
      final payload = <String, String>{
        'lat': location.latitude.toString(),
        'lng': location.longitude.toString(),
        'radius_km': _radiusKm.toStringAsFixed(1),
        'vehicle': 'car',
        'user_id': userId,
        'ride_type': _rideType,
        if (_cursor != null) 'cursor': _cursor!,
      };

      final res = await api.request(ApiConstants.driversNearbyEndpoint, method: 'POST', data: payload).timeout(const Duration(seconds: 6));
      if (_disposed) return;

      if (res.statusCode == 200) {
        final j = jsonDecode(res.body);
        if (j is Map) {
          if (j['cursor'] != null) _cursor = j['cursor'].toString();
          final rawDrivers = j['drivers'];
          final parsed = <DriverCar>[];
          if (rawDrivers is List) {
            for (final d in rawDrivers) {
              if (d is Map) {
                try {
                  parsed.add(DriverCar.fromJson(d.cast<String, dynamic>()));
                } catch (_) {}
              }
            }
          }
          _processDrivers(parsed);
        }
        _failures = 0;
      } else {
        _failures++;
      }
    } catch (_) {
      _failures++;
      // Still evict stale drivers so ghosts disappear while offline.
      if (!_disposed) _processDrivers(const []);
    } finally {
      _isBusy = false;
      _schedule();
    }
  }

  void _processDrivers(List<DriverCar> incoming) {
    final now = DateTime.now();
    bool changed = false;

    for (final d in incoming) {
      if (!d.ll.latitude.isFinite || !d.ll.longitude.isFinite) continue;
      _driverLastSeen[d.id] = now;
      final existing = _driverCache[d.id];

      if (existing != null) {
        final dist = RoutingEngine.haversine(existing.ll, d.ll);
        if (dist > 3.0) {
          _computedHeadings[d.id] = RoutingEngine.bearingBetween(existing.ll, d.ll);
        } else if (d.heading > 0 && !_computedHeadings.containsKey(d.id)) {
          _computedHeadings[d.id] = d.heading;
        }
      } else {
        _computedHeadings[d.id] = d.heading > 0 ? d.heading : 0.0;
      }

      if (existing == null || RoutingEngine.haversine(existing.ll, d.ll) >= 1.2 || (existing.heading - d.heading).abs() >= 6.0) {
        _driverCache[d.id] = d;
        changed = true;
      }
    }

    final staleIds = _driverLastSeen.entries.where((e) => now.difference(e.value) > _staleAfter).map((e) => e.key).toList();
    for (final id in staleIds) {
      _driverCache.remove(id);
      _driverLastSeen.remove(id);
      _computedHeadings.remove(id);
      changed = true;
    }

    if (changed && !_disposed) {
      onDriversUpdated(_driverCache.values.toList(), Map<String, double>.from(_computedHeadings));
    }
  }
}
