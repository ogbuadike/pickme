// lib/services/ride_market_service.dart
// RideMarketService — debug friendly + resilient parsing + simulated fallback

import 'dart:async';
import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
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

  factory RideOffer.fromJson(Map<String, dynamic> m) {
    int _asInt(dynamic v) => int.tryParse(v?.toString() ?? '') ?? 0;
    double? _asDouble(dynamic v) => double.tryParse(v?.toString() ?? '');
    return RideOffer(
      id: (m['id'] ?? m['offer_id'] ?? '').toString(),
      provider: (m['provider'] ?? 'Provider').toString(),
      category: (m['category'] ?? 'Standard').toString(),
      etaToPickupMin: _asInt(m['eta_min'] ?? m['eta_to_pickup_min']),
      price: _asInt(m['price'] ?? m['price_ngn']),
      surge: (m['surge']?.toString() == '1') || (m['surge'] == true) || (m['surge']?.toString().toLowerCase() == 'true'),
      driverName: (m['driver_name'] ?? m['name'])?.toString(),
      rating: _asDouble(m['rating']),
      carPlate: (m['car_plate'] ?? m['plate'])?.toString(),
      seats: int.tryParse((m['seats'] ?? '').toString()),
    );
  }
}

class DriverCar {
  final String id;
  final LatLng ll;
  final double heading;
  DriverCar({required this.id, required this.ll, required this.heading});

  factory DriverCar.fromJson(Map<String, dynamic> m) {
    final lat = double.tryParse(m['lat']?.toString() ?? '') ?? 0.0;
    final lng = double.tryParse(m['lng']?.toString() ?? '') ?? 0.0;
    final hdg = double.tryParse(m['heading']?.toString() ?? '') ?? 0.0;
    return DriverCar(
      id: (m['id'] ?? m['driver_id'] ?? '').toString(),
      ll: LatLng(lat, lng),
      heading: hdg,
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
  String? _cursor;

  RideMarketService({required this.api, this.searchRadiusKm = 40, this.debug = true});

  void _log(String s) {
    if (debug) print('[RideMarketService] $s');
  }

  Stream<RideMarketSnapshot> stream({
    required LatLng origin,
    required LatLng destination,
    Duration pollInterval = const Duration(seconds: 3),
    bool simulateOnFailure = true, // fallback to simulated drivers/offers for UI testing
  }) async* {
    final controller = StreamController<RideMarketSnapshot>();
    _log('starting stream — origin=${origin.latitude},${origin.longitude} dest=${destination.latitude},${destination.longitude}');

    Future<void> _tick() async {
      try {
        _log('tick: fetching offers');
        final offRes = await api.request(
          ApiConstants.rideOffersEndpoint,
          method: 'POST',
          data: {
            'origin': '${origin.latitude},${origin.longitude}',
            'destination': '${destination.latitude},${destination.longitude}',
            'radius_km': searchRadiusKm.toStringAsFixed(1),
            'vehicle': 'car',
          },
        ).timeout(const Duration(seconds: 8));

        _log('offers response status: ${offRes.statusCode}');
        final offBody = offRes.body;
        _log('offers body: ${offBody.length > 1000 ? offBody.substring(0, 1000) + "..." : offBody}');
        List<RideOffer> offList = [];
        try {
          final offJ = jsonDecode(offBody) as Map<String, dynamic>;
          final offersRaw = (offJ['offers'] as List? ?? const []);
          offList = offersRaw.map((e) => RideOffer.fromJson(e as Map<String, dynamic>)).toList();
          _cursor = offJ['cursor']?.toString() ?? _cursor;
        } catch (e) {
          _log('offers parsing failed: $e');
        }

        // Drivers poll (either initial full list or delta with cursor)
        final endpoint = (_cursor == null || _cursor!.isEmpty) ? ApiConstants.driversNearbyEndpoint : ApiConstants.driversPollEndpoint;
        _log('drivers endpoint: $endpoint (cursor=${_cursor ?? "null"})');
        final drvReqData = (_cursor == null || _cursor!.isEmpty)
            ? {
          'lat': origin.latitude.toString(),
          'lng': origin.longitude.toString(),
          'radius_km': searchRadiusKm.toStringAsFixed(1),
          'vehicle': 'car',
        }
            : {
          'cursor': _cursor ?? '',
          'vehicle': 'car',
        };

        final drvRes = await api.request(endpoint, method: 'POST', data: drvReqData).timeout(const Duration(seconds: 8));
        _log('drivers response status: ${drvRes.statusCode}');
        final drvBody = drvRes.body;
        _log('drivers body len=${drvBody.length}');
        List<DriverCar> drivers = [];

        try {
          final drvJ = jsonDecode(drvBody) as Map<String, dynamic>;
          final list = (drvJ['drivers'] ?? drvJ['delta'] ?? drvJ['driversNearby'] ?? const []) as List<dynamic>;
          drivers = list.map((e) {
            try {
              return DriverCar.fromJson(e as Map<String, dynamic>);
            } catch (ex) {
              _log('driver parse error: $ex — raw: $e');
              return DriverCar(id: 'bad', ll: LatLng(0, 0), heading: 0.0);
            }
          }).toList();
          _cursor = drvJ['cursor']?.toString() ?? _cursor;
          _log('parsed ${drivers.length} drivers, cursor=$_cursor');
        } catch (e) {
          _log('drivers parsing failed: $e');
        }

        // if both empty and simulateOnFailure => return simulation
        if (simulateOnFailure && offList.isEmpty && drivers.isEmpty) {
          _log('no offers/drivers — returning simulated data for UI debugging');
          final simOffers = List.generate(3, (i) {
            return RideOffer(
                id: 'sim-offer-$i',
                provider: 'SimProvider ${i + 1}',
                category: 'Standard',
                etaToPickupMin: 3 + i * 2,
                price: 800 + i * 150,
                surge: i % 2 == 0,
                driverName: 'SimDriver ${i + 1}',
                rating: 4.0 + i * 0.1,
                carPlate: 'SIM-00${i + 1}');
          });
          final simDrivers = List.generate(5, (i) {
            final lat = origin.latitude + (i + 1) * 0.0012;
            final lng = origin.longitude + (i + 1) * 0.0011;
            return DriverCar(id: 'sim-${i + 1}', ll: LatLng(lat, lng), heading: (i + 1) * 20.0);
          });
          final snap = RideMarketSnapshot(offers: simOffers, drivers: simDrivers);
          if (!controller.isClosed) controller.add(snap);
          return;
        }

        final snap = RideMarketSnapshot(offers: offList, drivers: drivers);
        if (!controller.isClosed) controller.add(snap);
      } catch (err) {
        _log('tick failed: $err');
        // swallow error (UI shows connection banner). Optionally fallback to simulation:
        if (simulateOnFailure) {
          _log('tick failed -> simulate fallback');
          final simOffers = List.generate(2, (i) => RideOffer(
            id: 'sim-offer-$i',
            provider: 'OfflineSim ${i+1}',
            category: 'Standard',
            etaToPickupMin: 2 + i,
            price: 700 + i * 100,
            surge: false,
          ));
          final simDrivers = List.generate(3, (i) {
            final lat = origin.latitude + (i + 1) * 0.001;
            final lng = origin.longitude - (i + 1) * 0.001;
            return DriverCar(id: 'sim-$i', ll: LatLng(lat, lng), heading: 0.0);
          });
          if (!controller.isClosed) controller.add(RideMarketSnapshot(offers: simOffers, drivers: simDrivers));
        }
      }
    }

    // immediate tick then periodic
    await _tick();
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => _tick());

    controller.onCancel = () {
      _log('stream cancelled by UI');
      _timer?.cancel();
      _timer = null;
    };

    yield* controller.stream;
  }

  void dispose() {
    _log('dispose called');
    _timer?.cancel();
    _timer = null;
  }
}
