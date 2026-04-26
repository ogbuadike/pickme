// lib/screens/state/driver_polling_engine.dart
import 'dart:async';
import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../../api/api_client.dart';
import '../../api/url.dart';
import 'home_models.dart';
import 'routing_engine.dart';
import '../../services/ride_market_service.dart';

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

  void start(LatLng currentUserLocation, {double radiusKm = 5.0, String rideType = 'street_ride'}) {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _fetchNearby(currentUserLocation, radiusKm, rideType));
    _fetchNearby(currentUserLocation, radiusKm, rideType);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    _driverCache.clear();
    _driverLastSeen.clear();
    _computedHeadings.clear();
  }

  Future<void> _fetchNearby(LatLng location, double radiusKm, String rideType) async {
    if (_isBusy) return;

    final now = DateTime.now();
    if (now.difference(_lastTick).inMilliseconds < 1500) return;
    _lastTick = now;
    _isBusy = true;

    try {
      final payload = <String, String>{
        'lat': location.latitude.toString(),
        'lng': location.longitude.toString(),
        'radius_km': radiusKm.toStringAsFixed(1),
        'vehicle': 'car',
        'user_id': userId,
        'ride_type': rideType,
        if (_cursor != null) 'cursor': _cursor!,
      };

      final res = await api.request(ApiConstants.driversNearbyEndpoint, method: 'POST', data: payload).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;

        if (j['cursor'] != null) {
          _cursor = j['cursor'].toString();
        }

        final rawDrivers = j['drivers'];
        final List<DriverCar> parsedDrivers = [];

        if (rawDrivers is List) {
          for (final d in rawDrivers) {
            if (d is Map) {
              try {
                parsedDrivers.add(DriverCar.fromJson(d.cast<String, dynamic>()));
              } catch (_) {}
            }
          }
        }

        _processDrivers(parsedDrivers);
      }
    } catch (_) {
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

      if (existing != null) {
        final dist = RoutingEngine.haversine(existing.ll, d.ll);
        if (dist > 2.0) {
          _computedHeadings[d.id] = RoutingEngine.bearingBetween(existing.ll, d.ll);
        }
      } else {
        _computedHeadings[d.id] = d.heading > 0 ? d.heading : 0.0;
      }

      if (existing == null || RoutingEngine.haversine(existing.ll, d.ll) >= 1.2 || (existing.heading - d.heading).abs() >= 6.0) {
        _driverCache[d.id] = d;
        changed = true;
      }
    }

    final staleIds = _driverLastSeen.entries
        .where((e) => now.difference(e.value).inSeconds > 12)
        .map((e) => e.key)
        .toList();

    for (final id in staleIds) {
      _driverCache.remove(id);
      _driverLastSeen.remove(id);
      _computedHeadings.remove(id);
      changed = true;
    }

    if (changed) {
      onDriversUpdated(_driverCache.values.toList(), Map.from(_computedHeadings));
    }
  }
}