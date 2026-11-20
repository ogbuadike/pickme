// lib/services/ride_market_service.dart
//
// RideMarketService — polls ride_offers.php + drivers_nearby.php for the
// Street Ride / Campus Ride "select a driver" market.
//
//  * one active stream per instance; restarting the stream invalidates any
//    tick still in flight (generation counter) so stale results never leak
//    into a new route;
//  * ticks never overlap; failures back off exponentially with jitter
//    (429 honours Retry-After) and a single failed tick never wipes the last
//    good driver list;
//  * polling pauses while the app is in the background;
//  * offers change slowly and are fetched at a lower cadence and cached;
//  * very large responses are decoded off the UI isolate;
//  * stable driver ordering across ticks, snapshot de-duplication.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
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

  /// Driver behind this offer (ride_offers.php returns one offer per driver).
  final String? driverId;

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
    this.driverId,
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
      driverId: (m['driver_id'] ?? m['driverId'])?.toString(),
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
    String pickString(List<String> keys) {
      for (final k in keys) {
        final v = m[k];
        final s = v?.toString().trim() ?? '';
        if (s.isNotEmpty) return s;
      }
      return '';
    }

    int? pickInt(List<String> keys) {
      for (final k in keys) {
        final v = _asIntNullable(m[k]);
        if (v != null) return v;
      }
      return null;
    }

    double? pickDouble(List<String> keys) {
      for (final k in keys) {
        final v = _asDouble(m[k]);
        if (v != null) return v;
      }
      return null;
    }

    final lat = _asDouble0(m['lat'] ?? m['latitude']);
    final lng = _asDouble0(m['lng'] ?? m['longitude']);
    final hdg = _asDouble0(m['heading'] ?? m['bearing']);

    final vt = pickString(['vehicle_type', 'vehicle', 'type']);
    final imgs = _asStringList(m['vehicle_images']);
    final carImg = pickString(['car_image_url', 'carImageUrl', 'car_img']);
    final avatar = pickString(['avatar_url', 'avatarUrl', 'avatar']);

    final currency = pickString(['currency']).isEmpty ? 'NGN' : pickString(['currency']);

    return DriverCar(
      id: pickString(['id', 'driver_id']),
      ll: LatLng(lat, lng),
      heading: hdg,
      name: pickString(['name']).isEmpty ? null : pickString(['name']),
      category: pickString(['category']).isEmpty ? null : pickString(['category']),
      rating: pickDouble(['rating']),
      carPlate: pickString(['car_plate', 'plate']).isEmpty ? null : pickString(['car_plate', 'plate']),
      distanceKm: pickDouble(['distance_km']),
      etaMin: pickInt(['eta_min']),

      vehicleType: vt.isEmpty ? null : vt,
      seats: pickInt(['seats']),
      vehicleImages: imgs,
      vehicleDescription: pickString(['vehicle_description', 'vehicleDescription']).isEmpty
          ? null
          : pickString(['vehicle_description', 'vehicleDescription']),
      carImageUrl: carImg.isEmpty ? null : carImg,
      avatarUrl: avatar.isEmpty ? null : avatar,

      phone: pickString(['phone', 'phone_number', 'tel', 'mobile']).isEmpty
          ? null
          : pickString(['phone', 'phone_number', 'tel', 'mobile']),
      nin: pickString(['nin', 'national_id', 'nationalId']).isEmpty
          ? null
          : pickString(['nin', 'national_id', 'nationalId']),
      rank: pickString(['rank']).isEmpty ? null : pickString(['rank']),

      completedTrips: pickInt(['completed_trips']),
      cancelledTrips: pickInt(['cancelled_trips']),
      incompleteTrips: pickInt(['incomplete_trips']),
      reviewsCount: pickInt(['reviews_count']),
      totalTrips: pickInt(['total_trips']),

      currency: currency,
      pricePerKm: pickDouble(['price_per_km']),
      baseFare: pickDouble(['base_fare']),
      estimatedTotal: pickDouble(['estimated_total', 'price_total']),
      tripKm: pickDouble(['trip_km']),
    );
  }
}

class RideMarketSnapshot {
  final List<RideOffer> offers;
  final List<DriverCar> drivers;
  const RideMarketSnapshot({required this.offers, required this.drivers});
}

// ── Isolate-friendly parsers (top-level so `compute` can run them) ──────────

/// Bodies larger than this are decoded on a background isolate.
const int _kIsolateParseThreshold = 96 * 1024;

Map<String, dynamic> _decodeMapSync(String body) {
  try {
    final dynamic j = jsonDecode(body);
    if (j is Map<String, dynamic>) return j;
    if (j is Map) return j.cast<String, dynamic>();
  } catch (_) {}
  return <String, dynamic>{};
}

bool _isErrorTrue(dynamic v) {
  if (v == null) return false;
  if (v is bool) return v;
  final String s = v.toString().trim().toLowerCase();
  return s == '1' || s == 'true' || s == 'yes';
}

List<dynamic> _readList(Map<String, dynamic> m, List<String> keys) {
  for (final String k in keys) {
    final dynamic v = m[k];
    if (v is List) return v;
  }
  return const <dynamic>[];
}

class _DriversParse {
  final bool ok;
  final List<DriverCar> drivers;
  final String? cursor;
  const _DriversParse(this.ok, this.drivers, this.cursor);
}

_DriversParse _parseDrivers(String body) {
  final Map<String, dynamic> j = _decodeMapSync(body);
  if (j.isEmpty || _isErrorTrue(j['error'])) return const _DriversParse(false, <DriverCar>[], null);
  final List<DriverCar> drivers = _readList(j, const <String>['drivers', 'delta', 'driversNearby', 'data', 'results'])
      .whereType<Map>()
      .map((Map e) => DriverCar.fromJson(e.cast<String, dynamic>()))
      .where((DriverCar x) =>
          x.id.isNotEmpty &&
          x.ll.latitude.isFinite &&
          x.ll.longitude.isFinite &&
          !(x.ll.latitude == 0.0 && x.ll.longitude == 0.0))
      .toList(growable: true);
  return _DriversParse(true, drivers, j['cursor']?.toString());
}

class _OffersParse {
  final bool ok;
  final List<RideOffer> offers;
  const _OffersParse(this.ok, this.offers);
}

_OffersParse _parseOffers(String body) {
  final Map<String, dynamic> j = _decodeMapSync(body);
  if (j.isEmpty || _isErrorTrue(j['error'])) return const _OffersParse(false, <RideOffer>[]);
  final List<RideOffer> offers = _readList(j, const <String>['offers', 'data', 'results'])
      .whereType<Map>()
      .map((Map e) => RideOffer.fromJson(e.cast<String, dynamic>()))
      .toList(growable: false);
  return _OffersParse(true, offers);
}

Future<R> _parseMaybeInBackground<R>(R Function(String) parser, String body) {
  if (body.length < _kIsolateParseThreshold) return Future<R>.value(parser(body));
  return compute<String, R>(parser, body);
}

class RideMarketService {
  final ApiClient api;
  final double searchRadiusKm;
  final bool debug;

  Timer? _timer;
  StreamController<RideMarketSnapshot>? _controller;
  String? _cursor;
  int _generation = 0;
  bool _inFlight = false;
  bool _backgrounded = false;
  AppLifecycleListener? _lifecycle;
  void Function()? _resumeTick;

  int _consecutiveFailures = 0;
  final math.Random _rng = math.Random();

  // Last good data (a failed tick never wipes the UI).
  List<RideOffer> _lastOffers = const <RideOffer>[];
  List<DriverCar> _lastDrivers = const <DriverCar>[];
  DateTime _lastOffersAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Dedupe: don't spam the UI with identical snapshots.
  String _lastFingerprint = '';
  DateTime _lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Stable ordering (prevents "shuffle" across ticks).
  final Map<String, int> _stableDriverOrder = <String, int>{};
  int _stableSeq = 0;

  RideMarketService({
    required this.api,
    this.searchRadiusKm = 50,
    this.debug = true,
  });

  void _dbg(String msg, [Object? data]) {
    if (!debug || !kDebugMode) return;
    debugPrint('[RideMarketService] $msg${data == null ? '' : ' -> $data'}');
  }

  static double _haversineKm(LatLng a, LatLng b) {
    const double r = 6371.0;
    double toRad(double deg) => deg * (math.pi / 180.0);
    final double dLat = toRad(b.latitude - a.latitude);
    final double dLng = toRad(b.longitude - a.longitude);
    final double h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(toRad(a.latitude)) * math.cos(toRad(b.latitude)) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return r * 2 * math.asin(math.min(1.0, math.sqrt(h)));
  }

  String _fingerprint(double tripKm, List<RideOffer> offers, List<DriverCar> drivers) {
    final StringBuffer sb = StringBuffer()
      ..write('km')
      ..write(tripKm.toStringAsFixed(2))
      ..write('|o')
      ..write(offers.length)
      ..write('|d')
      ..write(drivers.length)
      ..write('|');
    for (final RideOffer o in offers) {
      sb
        ..write(o.id)
        ..write(':')
        ..write(o.price)
        ..write(';');
    }
    for (final DriverCar d in drivers) {
      sb
        ..write(d.id)
        ..write(':')
        ..write(d.ll.latitude.toStringAsFixed(5))
        ..write(',')
        ..write(d.ll.longitude.toStringAsFixed(5))
        ..write('@')
        ..write(d.heading.toStringAsFixed(0))
        ..write('#')
        ..write((d.estimatedTotal ?? d.pricePerKm ?? 0).toStringAsFixed(0))
        ..write(';');
      if (sb.length > 4000) break; // cap work on huge lists
    }
    return sb.toString();
  }

  void _ensureLifecycle() {
    if (_lifecycle != null) return;
    try {
      _lifecycle = AppLifecycleListener(onStateChange: (AppLifecycleState state) {
        final bool bg = state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached;
        if (bg == _backgrounded) return;
        _backgrounded = bg;
        if (!bg) _resumeTick?.call();
      });
    } catch (_) {
      // No binding (tests) - ignore lifecycle.
    }
  }

  /// Starts a polling stream (single active stream per service instance).
  /// Cancelling the subscription (or calling [stop]/[dispose]) stops polling.
  Stream<RideMarketSnapshot> stream({
    required LatLng origin,
    required LatLng destination,
    String rideType = 'street_ride',
    Duration pollInterval = const Duration(seconds: 2),
    bool simulateOnFailure = false,
    LatLng Function()? originProvider,
    LatLng Function()? destinationProvider,
    String? userId,
    String Function()? userIdProvider,
    double? tripKm,
    double Function()? tripKmProvider,
    bool driversOnly = false,
    bool offersOnly = false,
    Duration requestTimeout = const Duration(seconds: 8),
    String vehicle = 'car',
    double? radiusKm,

    /// Offers barely change between ticks; refresh them at this cadence.
    Duration offersRefreshEvery = const Duration(seconds: 10),
  }) {
    _stopInternal(closeController: true);
    final int gen = ++_generation;
    final StreamController<RideMarketSnapshot> controller = StreamController<RideMarketSnapshot>.broadcast();
    _controller = controller;
    _cursor = null;
    _inFlight = false;
    _consecutiveFailures = 0;
    _lastFingerprint = '';
    _lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastOffers = const <RideOffer>[];
    _lastDrivers = const <DriverCar>[];
    _lastOffersAt = DateTime.fromMillisecondsSinceEpoch(0);
    _stableDriverOrder.clear();
    _stableSeq = 0;
    _ensureLifecycle();

    final double radius = (radiusKm ?? searchRadiusKm).clamp(0.5, 50.0).toDouble();
    _dbg('stream start', rideType);

    LatLng getO() => originProvider?.call() ?? origin;
    LatLng getD() => destinationProvider?.call() ?? destination;
    String getUid() => (userIdProvider?.call() ?? userId ?? '').trim();
    double getTripKm(LatLng o, LatLng d) {
      double v = tripKmProvider?.call() ?? tripKm ?? 0;
      if (!(v > 0)) v = _haversineKm(o, d); // no route distance yet
      if (v.isNaN || v.isInfinite || v < 0) return 0.0;
      return v.clamp(0.0, 500.0).toDouble();
    }

    bool alive() => gen == _generation && !controller.isClosed;

    void scheduleNext(Duration delay) {
      _timer?.cancel();
      _timer = null;
      if (!alive() || _backgrounded) return;
      _timer = Timer(delay, () {
        _timer = null;
        _resumeTick?.call();
      });
    }

    Duration nextDelay({Duration? retryAfter}) {
      if (_consecutiveFailures == 0) return pollInterval;
      final int exp = math.min(_consecutiveFailures, 4);
      int ms = math.min(pollInterval.inMilliseconds * (1 << exp), 30000);
      if (retryAfter != null) ms = math.max(ms, retryAfter.inMilliseconds);
      return Duration(milliseconds: ms + (ms * 0.3 * _rng.nextDouble()).round());
    }

    Future<void> tick() async {
      if (!alive() || _inFlight || _backgrounded) return;
      _inFlight = true;
      Duration? retryAfter;
      bool anyFailed = false;
      try {
        final LatLng o = getO();
        final LatLng d = getD();
        final String uid = getUid();
        final double tripKmVal = getTripKm(o, d);

        List<RideOffer>? offers;
        List<DriverCar>? drivers;

        final bool offersDue = !driversOnly &&
            (_lastOffers.isEmpty || DateTime.now().difference(_lastOffersAt) >= offersRefreshEvery);

        Future<void> fetchOffers() async {
          try {
            final Map<String, String> data = <String, String>{
              // ride_offers.php reads $in['origin']['lat'] -> PHP array syntax.
              'origin[lat]': o.latitude.toString(),
              'origin[lng]': o.longitude.toString(),
              'destination[lat]': d.latitude.toString(),
              'destination[lng]': d.longitude.toString(),
              'radius_km': radius.toStringAsFixed(1),
              'vehicle': vehicle,
              'trip_km': tripKmVal.toStringAsFixed(3),
              'ride_type': rideType,
              if (uid.isNotEmpty) 'user_id': uid,
            };
            final res = await api.request(
              ApiConstants.rideOffersEndpoint,
              method: 'POST',
              data: data,
              retryCount: 0,
              idempotent: true,
              timeout: requestTimeout,
            );
            final _OffersParse p = await _parseMaybeInBackground(_parseOffers, res.body);
            if (p.ok) {
              offers = p.offers;
            } else {
              _dbg('offers error=true');
            }
          } catch (e) {
            anyFailed = true;
            if (e is ApiException && e.isRateLimited) retryAfter = e.retryAfter;
            _dbg('offers fetch failed', e.runtimeType);
          }
        }

        Future<void> fetchDrivers() async {
          try {
            final Map<String, String> data = <String, String>{
              'lat': o.latitude.toString(),
              'lng': o.longitude.toString(),
              'radius_km': radius.toStringAsFixed(1),
              'vehicle': vehicle,
              'cursor': _cursor ?? '',
              'trip_km': tripKmVal.toStringAsFixed(3),
              'ride_type': rideType,
              if (uid.isNotEmpty) 'user_id': uid,
            };
            final res = await api.request(
              ApiConstants.driversNearbyEndpoint,
              method: 'POST',
              data: data,
              retryCount: 0,
              idempotent: true,
              timeout: requestTimeout,
            );
            final _DriversParse p = await _parseMaybeInBackground(_parseDrivers, res.body);
            if (p.ok) {
              drivers = p.drivers;
              _cursor = p.cursor ?? _cursor;
            } else {
              anyFailed = true;
              _dbg('drivers error=true');
            }
          } catch (e) {
            anyFailed = true;
            if (e is ApiException && e.isRateLimited) retryAfter = e.retryAfter;
            _dbg('drivers fetch failed', e.runtimeType);
          }
        }

        await Future.wait<void>(<Future<void>>[
          if (offersDue) fetchOffers(),
          if (!offersOnly) fetchDrivers(),
        ]);
        if (!alive()) return; // route changed / stopped while in flight

        if (offers != null) {
          _lastOffers = offers!;
          _lastOffersAt = DateTime.now();
        }
        if (drivers != null) {
          final List<DriverCar> list = drivers!;
          for (final DriverCar d0 in list) {
            _stableDriverOrder.putIfAbsent(d0.id, () => _stableSeq++);
          }
          list.sort((DriverCar a, DriverCar b) =>
              (_stableDriverOrder[a.id] ?? 0).compareTo(_stableDriverOrder[b.id] ?? 0));
          _lastDrivers = List<DriverCar>.unmodifiable(list);
        }

        _consecutiveFailures = anyFailed ? _consecutiveFailures + 1 : 0;

        if (simulateOnFailure && _lastOffers.isEmpty && _lastDrivers.isEmpty && anyFailed) {
          _lastDrivers = _simulatedDrivers(o, tripKmVal);
        }

        // A failed tick keeps the previous data; nothing new to emit unless
        // this is the very first tick (so the UI can leave its loading state).
        final bool firstEmit = _lastEmitAt.millisecondsSinceEpoch == 0;
        if (offers == null && drivers == null && !firstEmit) return;

        final String fp = _fingerprint(tripKmVal, _lastOffers, _lastDrivers);
        final DateTime now = DateTime.now();
        if (fp != _lastFingerprint || now.difference(_lastEmitAt) > const Duration(seconds: 6)) {
          _lastFingerprint = fp;
          _lastEmitAt = now;
          controller.add(RideMarketSnapshot(offers: _lastOffers, drivers: _lastDrivers));
        }
      } catch (e) {
        _consecutiveFailures++;
        _dbg('tick failed', e.runtimeType);
      } finally {
        _inFlight = false;
        if (alive()) scheduleNext(nextDelay(retryAfter: retryAfter));
      }
    }

    _resumeTick = () {
      if (alive()) tick();
    };

    tick();

    controller.onCancel = () {
      _dbg('stream cancelled');
      if (identical(_controller, controller)) _stopInternal(closeController: false);
    };

    return controller.stream;
  }

  List<DriverCar> _simulatedDrivers(LatLng o, double tripKmVal) {
    return List<DriverCar>.generate(8, (int i) {
      const double base = 200.0;
      final double ppk = 220.0 + (i * 10);
      return DriverCar(
        id: 'sim-${i + 1}',
        ll: LatLng(o.latitude + (i + 1) * 0.0009, o.longitude + (i + 1) * 0.0007),
        heading: (i * 35).toDouble(),
        name: 'Sim ${i + 1}',
        category: 'Economy',
        rating: 4.8,
        carPlate: 'SIM-${i + 1}',
        distanceKm: (i + 1) * 0.4,
        etaMin: 2 + i,
        vehicleType: 'car',
        seats: 4,
        rank: (i % 4 == 0) ? 'Gold' : 'Verified',
        pricePerKm: ppk,
        baseFare: base,
        tripKm: tripKmVal,
        estimatedTotal: tripKmVal > 0 ? (base + ppk * tripKmVal) : 0.0,
      );
    });
  }

  void _stopInternal({required bool closeController}) {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _resumeTick = null;
    _inFlight = false;
    if (closeController) {
      final StreamController<RideMarketSnapshot>? c = _controller;
      _controller = null;
      if (c != null && !c.isClosed) c.close();
    }
    _lifecycle?.dispose();
    _lifecycle = null;
    _backgrounded = false;
  }

  /// Stops polling and closes the current stream.
  void stop() => _stopInternal(closeController: true);

  void dispose() {
    _dbg('dispose');
    _stopInternal(closeController: true);
  }
}
