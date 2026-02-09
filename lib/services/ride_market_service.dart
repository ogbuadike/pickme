// lib/services/ride_market_service.dart
// RideMarketService — ApiClient-style requests (same pattern as login/set_pin)
// - Resilient JSON parsing for dynamic backend output
// - Polls offers + nearby drivers (cursor supported)
// - NO print(); logs are assert-guarded (zero overhead in release)
// - No overlapping ticks (prevents hangs on slow devices)
// - Snapshot dedupe (won't spam UI with identical data)
// - Optional dynamic origin/destination providers (use user's live lat/lng)

import 'dart:async';
import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../api/api_client.dart';
import '../api/url.dart';

class RideOffer {
  final String id;
  final String provider;
  final String category;
  final int etaToPickupMin;
  final int price;
  final bool surge;
  final String? driverName;
  final double? rating;
  final String? carPlate;
  final int? seats;

  const RideOffer({
    required this.id,
    required this.provider,
    required this.category,
    required this.etaToPickupMin,
    required this.price,
    required this.surge,
    this.driverName,
    this.rating,
    this.carPlate,
    this.seats,
  });

  static int _asInt(dynamic v, [int fallback = 0]) {
    if (v == null) return fallback;
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse(v.toString()) ?? fallback;
  }

  static double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static bool _asBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    return s == '1' || s == 'true' || s == 'yes';
  }

  factory RideOffer.fromJson(Map<String, dynamic> m) {
    return RideOffer(
      id: (m['id'] ?? m['offer_id'] ?? '').toString(),
      provider: (m['provider'] ?? m['company'] ?? 'Provider').toString(),
      category: (m['category'] ?? m['vehicle_class'] ?? 'Standard').toString(),
      etaToPickupMin: _asInt(m['eta_min'] ?? m['eta_to_pickup_min'] ?? m['eta']),
      price: _asInt(m['price'] ?? m['price_ngn'] ?? m['amount']),
      surge: _asBool(m['surge']),
      driverName: (m['driver_name'] ?? m['name'])?.toString(),
      rating: _asDouble(m['rating']),
      carPlate: (m['car_plate'] ?? m['plate'])?.toString(),
      seats: _asInt(m['seats'], 0) == 0 ? null : _asInt(m['seats']),
    );
  }
}

class DriverCar {
  final String id;
  final LatLng ll;
  final double heading;

  final String? name;
  final String? category;
  final double? rating;
  final String? carPlate;
  final double? distanceKm;
  final int? etaMin;

  const DriverCar({
    required this.id,
    required this.ll,
    required this.heading,
    this.name,
    this.category,
    this.rating,
    this.carPlate,
    this.distanceKm,
    this.etaMin,
  });

  static double _asDouble0(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  static double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static int? _asIntNullable(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse(v.toString());
  }

  factory DriverCar.fromJson(Map<String, dynamic> m) {
    final lat = _asDouble0(m['lat'] ?? m['latitude']);
    final lng = _asDouble0(m['lng'] ?? m['longitude']);
    final hdg = _asDouble0(m['heading'] ?? m['bearing']);

    return DriverCar(
      id: (m['id'] ?? m['driver_id'] ?? '').toString(),
      ll: LatLng(lat, lng),
      heading: hdg,
      name: (m['name'])?.toString(),
      category: (m['category'])?.toString(),
      rating: _asDouble(m['rating']),
      carPlate: (m['car_plate'])?.toString(),
      distanceKm: _asDouble(m['distance_km']),
      etaMin: _asIntNullable(m['eta_min']),
    );
  }
}

class RideMarketSnapshot {
  final List<RideOffer> offers;
  final List<DriverCar> drivers;
  const RideMarketSnapshot({required this.offers, required this.drivers});
}

class RideMarketService {
  final ApiClient api;
  final double searchRadiusKm;
  final bool debug;

  Timer? _timer;
  StreamController<RideMarketSnapshot>? _controller;
  String? _cursor;

  bool _inFlight = false;

  // Dedupe: don't spam UI with identical snapshots
  String _lastFingerprint = '';
  DateTime _lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);

  RideMarketService({
    required this.api,
    this.searchRadiusKm = 50,
    this.debug = true,
  });

  void _dbg(String msg, [Object? data]) {
    assert(() {
      if (!debug) return true;
      final d = data == null ? '' : ' → $data';
      // debugPrint is throttled; safer than print
      // ignore: avoid_print
      //debugPrint('[RideMarketService] $msg$d');
      return true;
    }());
  }

  bool _isErrorTrue(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    return s == '1' || s == 'true' || s == 'yes';
  }

  Map<String, dynamic> _decodeMap(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map<String, dynamic>) return j;
      if (j is Map) return j.cast<String, dynamic>();
    } catch (_) {}
    return <String, dynamic>{};
  }

  List<dynamic> _readList(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is List) return v;
    }
    return const [];
  }

  String _fingerprint(List<RideOffer> offers, List<DriverCar> drivers) {
    // Cheap stable fingerprint: counts + rounded positions (prevents UI spam)
    final sb = StringBuffer()
      ..write('o')
      ..write(offers.length)
      ..write('|d')
      ..write(drivers.length)
      ..write('|');
    for (final d in drivers) {
      final lat = d.ll.latitude.toStringAsFixed(5);
      final lng = d.ll.longitude.toStringAsFixed(5);
      final hdg = d.heading.toStringAsFixed(0);
      sb
        ..write(d.id)
        ..write(':')
        ..write(lat)
        ..write(',')
        ..write(lng)
        ..write('@')
        ..write(hdg)
        ..write(';');
      if (sb.length > 1500) break; // cap work on huge lists
    }
    return sb.toString();
  }

  /// Starts a polling stream (single active stream per service instance).
  ///
  /// For "use user's live lat/lng", pass:
  ///   originProvider: () => currentUserLatLng
  /// (and optionally destinationProvider if you want offers tied to current destination)
  Stream<RideMarketSnapshot> stream({
    required LatLng origin,
    required LatLng destination,
    Duration pollInterval = const Duration(seconds: 2),
    bool simulateOnFailure = false,

    // NEW: dynamic providers (optional)
    LatLng Function()? originProvider,
    LatLng Function()? destinationProvider,

    // NEW: if you want drivers only (no offers call)
    bool driversOnly = false,
    bool offersOnly = false,

    Duration requestTimeout = const Duration(seconds: 8),
  }) {
    // stop any previous stream cleanly
    _timer?.cancel();
    _timer = null;
    _controller?.close();
    _controller = StreamController<RideMarketSnapshot>.broadcast();
    _cursor = null;
    _inFlight = false;
    _lastFingerprint = '';
    _lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);

    final controller = _controller!;
    _dbg('stream start');

    LatLng getO() => originProvider?.call() ?? origin;
    LatLng getD() => destinationProvider?.call() ?? destination;

    Future<void> tick() async {
      if (controller.isClosed) return;
      if (_inFlight) return; // no overlap
      _inFlight = true;

      List<RideOffer> offers = const [];
      List<DriverCar> drivers = const [];

      try {
        final o = getO();
        final d = getD();

        // ---------- OFFERS ----------
        if (!driversOnly) {
          try {
            final offRes = await api
                .request(
              ApiConstants.rideOffersEndpoint,
              method: 'POST',
              data: {
                'origin': '${o.latitude},${o.longitude}',
                'destination': '${d.latitude},${d.longitude}',
                'radius_km': searchRadiusKm.toStringAsFixed(1),
                'vehicle': 'car',
              },
            )
                .timeout(requestTimeout);

            final offJ = _decodeMap(offRes.body);
            if (!_isErrorTrue(offJ['error'])) {
              final rawOffers = _readList(offJ, ['offers', 'data', 'results']);
              offers = rawOffers
                  .whereType<Map>()
                  .map((e) => RideOffer.fromJson(e.cast<String, dynamic>()))
                  .toList(growable: false);
            } else {
              _dbg('offers error=true', offJ['message'] ?? '');
            }
          } catch (e) {
            _dbg('offers fetch failed', e);
          }
        }

        // ---------- DRIVERS ----------
        if (!offersOnly) {
          try {
            final drvRes = await api
                .request(
              ApiConstants.driversNearbyEndpoint,
              method: 'POST',
              data: {
                'lat': o.latitude.toString(),
                'lng': o.longitude.toString(),
                'radius_km': searchRadiusKm.toStringAsFixed(1),
                'vehicle': 'car',
                'cursor': _cursor ?? '',
              },
            )
                .timeout(requestTimeout);

            final drvJ = _decodeMap(drvRes.body);
            if (!_isErrorTrue(drvJ['error'])) {
              final rawDrivers = _readList(drvJ, ['drivers', 'delta', 'driversNearby', 'data', 'results']);
              drivers = rawDrivers
                  .whereType<Map>()
                  .map((e) => DriverCar.fromJson(e.cast<String, dynamic>()))
                  .where((x) => x.id.isNotEmpty && x.ll.latitude != 0.0 && x.ll.longitude != 0.0)
                  .toList(growable: false);

              _cursor = drvJ['cursor']?.toString() ?? _cursor;
            } else {
              _dbg('drivers error=true', drvJ['message'] ?? '');
            }
          } catch (e) {
            _dbg('drivers fetch failed', e);
          }
        }

        // ---------- SIMULATE (optional) ----------
        if (simulateOnFailure && offers.isEmpty && drivers.isEmpty) {
          final o = getO();
          offers = List.generate(3, (i) {
            return RideOffer(
              id: 'sim-offer-$i',
              provider: 'SimProvider ${i + 1}',
              category: 'Standard',
              etaToPickupMin: 2 + i,
              price: 700 + (i * 120),
              surge: i == 1,
              driverName: 'SimDriver ${i + 1}',
              rating: 4.7 - (i * 0.1),
              carPlate: 'SIM-${100 + i}',
            );
          });

          drivers = List.generate(8, (i) {
            final lat = o.latitude + (i + 1) * 0.0009;
            final lng = o.longitude + (i + 1) * 0.0007;
            return DriverCar(
              id: 'sim-${i + 1}',
              ll: LatLng(lat, lng),
              heading: (i * 35).toDouble(),
              name: 'Sim ${i + 1}',
              category: 'Economy',
              rating: 4.8,
              carPlate: 'SIM-${i + 1}',
            );
          });
        }

        // ---------- EMIT (dedupe) ----------
        if (!controller.isClosed) {
          final fp = _fingerprint(offers, drivers);
          final now = DateTime.now();

          // allow emit if changed OR if 6s elapsed (keeps UI alive without spamming)
          final allow = (fp != _lastFingerprint) || now.difference(_lastEmitAt) > const Duration(seconds: 6);

          if (allow) {
            _lastFingerprint = fp;
            _lastEmitAt = now;
            controller.add(RideMarketSnapshot(offers: offers, drivers: drivers));
          }
        }
      } catch (e) {
        _dbg('tick failed', e);
      } finally {
        _inFlight = false;
      }
    }

    // immediate + periodic polling
    tick();
    _timer = Timer.periodic(pollInterval, (_) => tick());

    controller.onCancel = () {
      _dbg('stream cancelled');
      _timer?.cancel();
      _timer = null;
    };

    return controller.stream;
  }

  void dispose() {
    _dbg('dispose');
    _timer?.cancel();
    _timer = null;
    _controller?.close();
    _controller = null;
  }
}
