// lib/services/ride_market_service.dart
// RideMarketService — ApiClient-style requests (same pattern as login/set_pin)
// ✅ Updated to support NEW driver-based pricing + images + rank badge data.
// ✅ Sends trip_km to drivers endpoint (and offers endpoint optionally) so PHP returns estimated_total.
// ✅ Adds stable driver ordering in-service (prevents “shuffle” across ticks for ALL consumers).
// ✅ Fingerprint now includes trip_km + pricing (so UI updates when destination/trip changes).
// - Resilient JSON parsing for dynamic backend output
// - Polls offers + nearby drivers (cursor supported)
// - NO print(); logs are assert-guarded (zero overhead in release)
// - No overlapping ticks (prevents hangs on slow devices)
// - Snapshot dedupe (won't spam UI with identical data)

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../api/api_client.dart';
import '../api/url.dart';

class RideOffer {
  final String id;
  final String provider;
  final String category;
  final int etaToPickupMin;

  /// Legacy/compat: may represent a “display price” from offers API.
  final int price;

  final bool surge;
  final String? driverName;
  final double? rating;
  final String? carPlate;
  final int? seats;

  // ✅ New/optional (for newer backends)
  final String currency;
  final double? pricePerKm;
  final double? baseFare;
  final double? estimatedTotal;
  final String? vehicleType;

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
    this.currency = 'NGN',
    this.pricePerKm,
    this.baseFare,
    this.estimatedTotal,
    this.vehicleType,
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
    final currency = (m['currency'] ?? m['cur'] ?? 'NGN').toString();
    final pricePerKm = _asDouble(m['price_per_km'] ?? m['per_km'] ?? m['ppk']);
    final baseFare = _asDouble(m['base_fare'] ?? m['base']);
    final estTotal = _asDouble(m['estimated_total'] ?? m['price_total'] ?? m['total']);

    // Prefer explicit total if provided; else fallback to legacy price fields.
    final price = _asInt(m['price_total'] ?? m['estimated_total'] ?? m['price'] ?? m['price_ngn'] ?? m['amount']);

    final seatsRaw = _asInt(m['seats'], 0);
    final seats = seatsRaw == 0 ? null : seatsRaw;

    return RideOffer(
      id: (m['id'] ?? m['offer_id'] ?? '').toString(),
      provider: (m['provider'] ?? m['company'] ?? 'Provider').toString(),
      category: (m['category'] ?? m['vehicle_class'] ?? 'Standard').toString(),
      etaToPickupMin: _asInt(m['eta_min'] ?? m['eta_to_pickup_min'] ?? m['eta']),
      price: price,
      surge: _asBool(m['surge']),
      driverName: (m['driver_name'] ?? m['name'])?.toString(),
      rating: _asDouble(m['rating']),
      carPlate: (m['car_plate'] ?? m['plate'])?.toString(),
      seats: seats,
      currency: currency,
      pricePerKm: pricePerKm,
      baseFare: baseFare,
      estimatedTotal: estTotal,
      vehicleType: (m['vehicle_type'] ?? m['vehicle'] ?? m['type'])?.toString(),
    );
    // NOTE: Keep this compatible with older backends.
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

  // ✅ New: vehicle + profile + trip stats
  final String? vehicleType; // car | bike
  final int? seats;
  final List<String> vehicleImages;
  final String? vehicleDescription;
  final String? carImageUrl;
  final String? avatarUrl;

  final String? phone;
  final String? nin;
  final String? rank;

  final int? completedTrips;
  final int? cancelledTrips;
  final int? incompleteTrips;
  final int? reviewsCount;
  final int? totalTrips;

  // ✅ New: driver-based pricing
  final String currency;
  final double? pricePerKm;
  final double? baseFare;
  final double? estimatedTotal;
  final double? tripKm;

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
    this.vehicleType,
    this.seats,
    this.vehicleImages = const [],
    this.vehicleDescription,
    this.carImageUrl,
    this.avatarUrl,
    this.phone,
    this.nin,
    this.rank,
    this.completedTrips,
    this.cancelledTrips,
    this.incompleteTrips,
    this.reviewsCount,
    this.totalTrips,
    this.currency = 'NGN',
    this.pricePerKm,
    this.baseFare,
    this.estimatedTotal,
    this.tripKm,
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

  static int _asInt(dynamic v, [int fallback = 0]) {
    if (v == null) return fallback;
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse(v.toString()) ?? fallback;
  }

  static List<String> _asStringList(dynamic v) {
    if (v == null) return const [];
    if (v is List) {
      return v.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList(growable: false);
    }
    final s = v.toString().trim();
    if (s.isEmpty) return const [];

    // JSON array string?
    if (s.startsWith('[')) {
      try {
        final j = jsonDecode(s);
        if (j is List) {
          return j.map((e) => e.toString()).where((x) => x.trim().isNotEmpty).toList(growable: false);
        }
      } catch (_) {}
    }

    // CSV fallback
    final parts = s.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList(growable: false);
    return parts;
  }

  factory DriverCar.fromJson(Map<String, dynamic> m) {
    final lat = _asDouble0(m['lat'] ?? m['latitude']);
    final lng = _asDouble0(m['lng'] ?? m['longitude']);
    final hdg = _asDouble0(m['heading'] ?? m['bearing']);

    final vt = (m['vehicle_type'] ?? m['vehicle'] ?? m['type'])?.toString();
    final imgs = _asStringList(m['vehicle_images']);
    final carImg = (m['car_image_url'] ?? m['carImageUrl'] ?? m['car_img'])?.toString();
    final avatar = (m['avatar_url'] ?? m['avatarUrl'] ?? m['avatar'])?.toString();

    final currency = (m['currency'] ?? 'NGN').toString();

    return DriverCar(
      id: (m['id'] ?? m['driver_id'] ?? '').toString(),
      ll: LatLng(lat, lng),
      heading: hdg,
      name: m['name']?.toString(),
      category: m['category']?.toString(),
      rating: _asDouble(m['rating']),
      carPlate: (m['car_plate'] ?? m['plate'])?.toString(),
      distanceKm: _asDouble(m['distance_km']),
      etaMin: _asIntNullable(m['eta_min']),

      vehicleType: vt,
      seats: _asIntNullable(m['seats']),
      vehicleImages: imgs,
      vehicleDescription: (m['vehicle_description'] ?? m['vehicleDescription'])?.toString(),
      carImageUrl: carImg,
      avatarUrl: avatar,

      phone: m['phone']?.toString(),
      nin: m['nin']?.toString(),
      rank: m['rank']?.toString(),

      completedTrips: _asIntNullable(m['completed_trips']),
      cancelledTrips: _asIntNullable(m['cancelled_trips']),
      incompleteTrips: _asIntNullable(m['incomplete_trips']),
      reviewsCount: _asIntNullable(m['reviews_count']),
      totalTrips: _asIntNullable(m['total_trips']),

      currency: currency,
      pricePerKm: _asDouble(m['price_per_km']),
      baseFare: _asDouble(m['base_fare']),
      estimatedTotal: _asDouble(m['estimated_total'] ?? m['price_total']),
      tripKm: _asDouble(m['trip_km']),
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

  // ✅ Stable ordering (prevents “shuffle” across ticks)
  final Map<String, int> _stableDriverOrder = <String, int>{};
  int _stableSeq = 0;

  RideMarketService({
    required this.api,
    this.searchRadiusKm = 50,
    this.debug = true,
  });

  void _dbg(String msg, [Object? data]) {
    assert(() {
      if (!debug) return true;
      final d = data == null ? '' : ' → $data';
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

  double _haversineKm(LatLng a, LatLng b) {
    const r = 6371.0;
    double toRad(double deg) => deg * (math.pi / 180.0);

    final dLat = toRad(b.latitude - a.latitude);
    final dLng = toRad(b.longitude - a.longitude);

    final la1 = toRad(a.latitude);
    final la2 = toRad(b.latitude);

    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(la1) * math.cos(la2) * math.sin(dLng / 2) * math.sin(dLng / 2);

    final c = 2 * math.asin(math.min(1.0, math.sqrt(h)));
    return r * c;
  }

  String _fingerprint(double tripKm, List<RideOffer> offers, List<DriverCar> drivers) {
    // Stable fingerprint: includes tripKm + pricing bits (so fare updates propagate)
    final sb = StringBuffer()
      ..write('km')
      ..write(tripKm.toStringAsFixed(2))
      ..write('|o')
      ..write(offers.length)
      ..write('|d')
      ..write(drivers.length)
      ..write('|');

    for (final d in drivers) {
      final lat = d.ll.latitude.toStringAsFixed(5);
      final lng = d.ll.longitude.toStringAsFixed(5);
      final hdg = d.heading.toStringAsFixed(0);
      final ppk = (d.pricePerKm ?? 0).toStringAsFixed(0);
      sb
        ..write(d.id)
        ..write(':')
        ..write(lat)
        ..write(',')
        ..write(lng)
        ..write('@')
        ..write(hdg)
        ..write('#')
        ..write(ppk)
        ..write(';');
      if (sb.length > 1800) break; // cap work on huge lists
    }
    return sb.toString();
  }

  /// Starts a polling stream (single active stream per service instance).
  ///
  /// New: pass tripKm (or tripKmProvider) so backend returns estimated_total.
  Stream<RideMarketSnapshot> stream({
    required LatLng origin,
    required LatLng destination,
    Duration pollInterval = const Duration(seconds: 2),
    bool simulateOnFailure = false,

    // optional dynamic providers
    LatLng Function()? originProvider,
    LatLng Function()? destinationProvider,

    // ✅ NEW: trip distance in KM (used for driver price_total/estimated_total)
    double? tripKm,
    double Function()? tripKmProvider,

    // optional switches
    bool driversOnly = false,
    bool offersOnly = false,

    Duration requestTimeout = const Duration(seconds: 8),

    // optional: choose vehicle filter you send to backend
    String vehicle = 'car',
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

    // keep stable ordering across restarts? (reset for a new stream)
    _stableDriverOrder.clear();
    _stableSeq = 0;

    final controller = _controller!;
    _dbg('stream start');

    LatLng getO() => originProvider?.call() ?? origin;
    LatLng getD() => destinationProvider?.call() ?? destination;

    double getTripKm(LatLng o, LatLng d) {
      final v = tripKmProvider?.call() ?? tripKm ?? _haversineKm(o, d);
      if (v.isNaN || v.isInfinite) return 0.0;
      // keep sane bounds
      return v.clamp(0.0, 500.0);
    }

    Future<void> tick() async {
      if (controller.isClosed) return;
      if (_inFlight) return; // no overlap
      _inFlight = true;

      List<RideOffer> offers = const [];
      List<DriverCar> drivers = const [];

      try {
        final o = getO();
        final d = getD();
        final tripKmVal = getTripKm(o, d);

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
                'vehicle': vehicle,
                // ✅ send trip_km for backends that use it
                'trip_km': tripKmVal.toStringAsFixed(3),
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
                'vehicle': vehicle,
                'cursor': _cursor ?? '',
                // ✅ critical for new PHP pricing
                'trip_km': tripKmVal.toStringAsFixed(3),
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

              // ✅ stable ordering to stop shuffling across ticks
              for (final d in drivers) {
                _stableDriverOrder.putIfAbsent(d.id, () => _stableSeq++);
              }
              drivers.sort((a, b) => (_stableDriverOrder[a.id] ?? 0).compareTo(_stableDriverOrder[b.id] ?? 0));

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
          final d = getD();
          final tripKmVal = getTripKm(o, d);

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
              currency: 'NGN',
              pricePerKm: 220 + (i * 20),
              baseFare: 200,
              estimatedTotal: (200 + (220 + (i * 20)) * tripKmVal),
              vehicleType: 'car',
            );
          });

          drivers = List.generate(8, (i) {
            final lat = o.latitude + (i + 1) * 0.0009;
            final lng = o.longitude + (i + 1) * 0.0007;
            final id = 'sim-${i + 1}';

            final ppk = 220.0 + (i * 10);
            final base = 200.0;
            final total = tripKmVal > 0 ? (base + ppk * tripKmVal) : 0.0;

            return DriverCar(
              id: id,
              ll: LatLng(lat, lng),
              heading: (i * 35).toDouble(),
              name: 'Sim ${i + 1}',
              category: 'Economy',
              rating: 4.8,
              carPlate: 'SIM-${i + 1}',
              distanceKm: (i + 1) * 0.4,
              etaMin: 2 + i,

              vehicleType: 'car',
              seats: 4,
              vehicleImages: const [],
              vehicleDescription: 'Sim car, AC, clean interior',
              carImageUrl: null,
              avatarUrl: null,
              rank: (i % 4 == 0) ? 'Gold' : 'Verified',

              currency: 'NGN',
              pricePerKm: ppk,
              baseFare: base,
              tripKm: tripKmVal,
              estimatedTotal: total,
            );
          });

          for (final d0 in drivers) {
            _stableDriverOrder.putIfAbsent(d0.id, () => _stableSeq++);
          }
          drivers.sort((a, b) => (_stableDriverOrder[a.id] ?? 0).compareTo(_stableDriverOrder[b.id] ?? 0));
        }

        // ---------- EMIT (dedupe) ----------
        if (!controller.isClosed) {
          final o = getO();
          final d = getD();
          final tripKmVal = getTripKm(o, d);

          final fp = _fingerprint(tripKmVal, offers, drivers);
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
