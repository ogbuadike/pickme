// lib/services/booking_controller.dart
//
// Rider booking controller
// Uses your real ApiConstants endpoints:
// - ride_book.php
// - ride_status.php
// - ride_cancel_booking.php
//
// Features:
// • create booking
// • poll booking status
// • cancel booking
// • compatibility aliases for home_page.dart
// • strict Map<String,String> payloads for ApiClient
// • safe nullable handling for RideOffer

import 'dart:async';
import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../api/api_client.dart';
import '../api/url.dart';
import '../services/ride_market_service.dart';
import 'driver_location_updater.dart';

enum BookingStatus {
  searching,
  driverAssigned,
  driverArriving,
  onTrip,
  completed,
  cancelled,
  failed,
}

class BookingUpdate {
  final BookingStatus status;
  final Map<String, dynamic> data;

  const BookingUpdate(this.status, this.data);
}

class BookingController {
  final ApiClient _api;
  final DriverLocationUpdater? _pinger;

  static const String _epCreate = ApiConstants.rideBookEndpoint;
  static const String _epStatus = ApiConstants.rideStatusEndpoint;
  static const String _epCancel = ApiConstants.rideCancelEndpoint;

  String? _rideId;
  Timer? _pollTimer;

  final StreamController<BookingUpdate> _stream =
  StreamController<BookingUpdate>.broadcast();

  BookingController(this._api, {DriverLocationUpdater? pinger}) : _pinger = pinger;

  String? get rideId => _rideId;
  Stream<BookingUpdate> get updates => _stream.stream;
  Stream<BookingUpdate> get stream => _stream.stream;
  Stream<BookingUpdate> get events => _stream.stream;

  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pinger?.stop();
    if (!_stream.isClosed) {
      _stream.close();
    }
  }

  String _s(Object? v, [String fallback = '']) {
    if (v == null) return fallback;
    final String x = v.toString().trim();
    return x.isEmpty ? fallback : x;
  }

  int _i(Object? v, [int fallback = 0]) {
    if (v == null) return fallback;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString().trim()) ?? fallback;
  }

  double _d(Object? v, [double fallback = 0.0]) {
    if (v == null) return fallback;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim()) ?? fallback;
  }

  bool _b(Object? v, [bool fallback = false]) {
    if (v == null) return fallback;
    if (v is bool) return v;
    final String s = v.toString().trim().toLowerCase();
    if (s == '1' || s == 'true' || s == 'yes') return true;
    if (s == '0' || s == 'false' || s == 'no') return false;
    return fallback;
  }

  Map<String, String> _buildCreatePayload({
    required String riderId,
    required String driverId,
    required RideOffer offer,
    required LatLng pickup,
    required LatLng destination,
    String? pickupText,
    String? destinationText,
    List<LatLng> stops = const <LatLng>[],
    String payMethod = 'cash',
  }) {
    final String vehicleType = _s(offer.vehicleType, 'car');
    final String provider = _s(offer.provider, 'PickMe');
    final String category = _s(offer.category, 'Standard');
    final String driverName = _s(offer.driverName);
    final String carPlate = _s(offer.carPlate);
    final String currency = _s(offer.currency, 'NGN');

    final int seats = _i(
      offer.seats,
      vehicleType.toLowerCase().contains('bike') ? 1 : 4,
    );

    final int etaMin = _i(offer.etaToPickupMin, 0);
    final int price = _i(offer.price, 0);

    final double estimatedTotal = _d(
      offer.estimatedTotal,
      price.toDouble(),
    );

    final double baseFare = _d(offer.baseFare, 0.0);
    final double pricePerKm = _d(offer.pricePerKm, 0.0);
    final bool surge = _b(offer.surge, false);

    final List<Map<String, double>> stopsJson = stops
        .map((LatLng e) => <String, double>{
      'lat': e.latitude,
      'lng': e.longitude,
    })
        .toList(growable: false);

    final Map<String, dynamic> pickupObj = <String, dynamic>{
      'lat': pickup.latitude,
      'lng': pickup.longitude,
      'text': _s(pickupText),
    };

    final Map<String, dynamic> destinationObj = <String, dynamic>{
      'lat': destination.latitude,
      'lng': destination.longitude,
      'text': _s(destinationText),
    };

    return <String, String>{
      // primary ids
      'rider_id': riderId,
      'user_id': riderId,
      'uid': riderId,
      'driver_id': driverId,

      // offer / trip info
      'offer_id': _s(offer.id),
      'ride_offer_id': _s(offer.id),
      'provider': provider,
      'category': category,
      'vehicle': vehicleType,
      'vehicle_type': vehicleType,
      'driver_name': driverName,
      'car_plate': carPlate,
      'currency': currency,
      'seats': seats.toString(),
      'eta_min': etaMin.toString(),
      'surge': surge ? '1' : '0',
      'pay_method': _s(payMethod, 'cash'),

      // price variants for backend compatibility
      'price': price.toString(),
      'price_ngn': price.toString(),
      'price_total': price.toString(),
      'estimated_total': estimatedTotal.toStringAsFixed(2),
      'base_fare': baseFare.toStringAsFixed(2),
      'price_per_km': pricePerKm.toStringAsFixed(2),

      // flattened pickup
      'pickup': '${pickup.latitude},${pickup.longitude}',
      'pickup_lat': pickup.latitude.toString(),
      'pickup_lng': pickup.longitude.toString(),
      'pickup_text': _s(pickupText),

      // flattened destination
      'destination': '${destination.latitude},${destination.longitude}',
      'destination_lat': destination.latitude.toString(),
      'destination_lng': destination.longitude.toString(),
      'destination_text': _s(destinationText),

      // json variants for backend compatibility
      'pickup_json': jsonEncode(pickupObj),
      'destination_json': jsonEncode(destinationObj),
      'stops': stops.isEmpty
          ? ''
          : stops.map((LatLng e) => '${e.latitude},${e.longitude}').join('|'),
      'stops_json': jsonEncode(stopsJson),
    };
  }

  Future<bool> createBooking({
    required RideOffer offer,
    required LatLng pickup,
    required LatLng destination,
    String? pickupText,
    String? destinationText,
    List<LatLng> stops = const <LatLng>[],
    String payMethod = 'cash',
    String? userId,
    String? driverId,
  }) async {
    try {
      final String riderId = _s(userId);
      final String selectedDriverId = _s(driverId);

      if (riderId.isEmpty) {
        throw 'Missing rider_id';
      }
      if (selectedDriverId.isEmpty) {
        throw 'Missing driver_id';
      }

      final Map<String, String> payload = _buildCreatePayload(
        riderId: riderId,
        driverId: selectedDriverId,
        offer: offer,
        pickup: pickup,
        destination: destination,
        pickupText: pickupText,
        destinationText: destinationText,
        stops: stops,
        payMethod: payMethod,
      );

      final http.Response res =
      await _api.request(_epCreate, method: 'POST', data: payload);

      final Map<String, dynamic> body = _tryJson(res);

      final bool ok = res.statusCode == 200 &&
          body['error'] != true &&
          body['success']?.toString().toLowerCase() != 'false';

      if (!ok) {
        _stream.add(BookingUpdate(BookingStatus.failed, body));
        return false;
      }

      final String newRideId = _s(
        body['ride_id'] ?? body['rideId'] ?? body['id'],
      );

      if (newRideId.isEmpty) {
        throw 'No ride_id returned by server';
      }

      _rideId = newRideId;

      _pinger?.start(() => pickup);

      _stream.add(
        BookingUpdate(
          BookingStatus.searching,
          <String, dynamic>{
            ...body,
            'ride_id': _rideId,
          },
        ),
      );

      _startPolling();
      return true;
    } catch (e) {
      _stream.add(
        BookingUpdate(
          BookingStatus.failed,
          <String, dynamic>{'message': e.toString()},
        ),
      );
      return false;
    }
  }

  Future<String?> bookRide({
    required String riderId,
    required String driverId,
    required RideOffer offer,
    required LatLng pickup,
    required LatLng destination,
    String? pickupText,
    String? destinationText,
    List<LatLng> stops = const <LatLng>[],
    String payMethod = 'cash',
  }) async {
    final bool ok = await createBooking(
      offer: offer,
      pickup: pickup,
      destination: destination,
      pickupText: pickupText,
      destinationText: destinationText,
      stops: stops,
      payMethod: payMethod,
      userId: riderId,
      driverId: driverId,
    );
    return ok ? _rideId : null;
  }

  Future<String?> startBooking({
    required String riderId,
    required String driverId,
    required RideOffer offer,
    required LatLng pickup,
    required LatLng destination,
    String? pickupText,
    String? destinationText,
    List<LatLng> stops = const <LatLng>[],
    String payMethod = 'cash',
  }) async {
    return bookRide(
      riderId: riderId,
      driverId: driverId,
      offer: offer,
      pickup: pickup,
      destination: destination,
      pickupText: pickupText,
      destinationText: destinationText,
      stops: stops,
      payMethod: payMethod,
    );
  }

  Future<String?> createRide({
    required String riderId,
    required String driverId,
    required RideOffer offer,
    required LatLng pickup,
    required LatLng destination,
    String? pickupText,
    String? destinationText,
    List<LatLng> stops = const <LatLng>[],
    String payMethod = 'cash',
  }) async {
    return bookRide(
      riderId: riderId,
      driverId: driverId,
      offer: offer,
      pickup: pickup,
      destination: destination,
      pickupText: pickupText,
      destinationText: destinationText,
      stops: stops,
      payMethod: payMethod,
    );
  }

  Future<bool> cancelBooking({String reason = ''}) async {
    final String id = _s(_rideId);
    if (id.isEmpty) return false;

    try {
      final http.Response res = await _api.request(
        _epCancel,
        method: 'POST',
        data: <String, String>{
          'ride_id': id,
          'reason': _s(reason),
        },
      );

      final Map<String, dynamic> body = _tryJson(res);
      final bool ok = res.statusCode == 200 && body['error'] != true;

      if (ok) {
        _stream.add(BookingUpdate(BookingStatus.cancelled, body));
      } else {
        _stream.add(BookingUpdate(BookingStatus.failed, body));
      }

      _stopAll();
      return ok;
    } catch (e) {
      _stream.add(
        BookingUpdate(
          BookingStatus.failed,
          <String, dynamic>{'message': e.toString()},
        ),
      );
      _stopAll();
      return false;
    }
  }

  Future<bool> cancelRide({String reason = ''}) => cancelBooking(reason: reason);
  Future<bool> cancelTrip({String reason = ''}) => cancelBooking(reason: reason);
  Future<bool> abortTrip({String reason = ''}) => cancelBooking(reason: reason);

  Future<bool> startTrip() => _emitOnTripLocalOnly();
  Future<bool> startRide() => _emitOnTripLocalOnly();
  Future<bool> commenceTrip() => _emitOnTripLocalOnly();
  Future<bool> beginTrip() => _emitOnTripLocalOnly();

  Future<bool> _emitOnTripLocalOnly() async {
    final String id = _s(_rideId);
    if (id.isEmpty) return false;

    _stream.add(
      BookingUpdate(
        BookingStatus.onTrip,
        <String, dynamic>{
          'ride_id': id,
          'status': 'on_trip',
          'local_only': true,
        },
      ),
    );
    return true;
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _pollOnce());
    _pollOnce();
  }

  Future<void> _pollOnce() async {
    final String id = _s(_rideId);
    if (id.isEmpty) return;

    try {
      final http.Response res = await _api.request(
        _epStatus,
        method: 'POST',
        data: <String, String>{'ride_id': id},
      );

      final Map<String, dynamic> body = _tryJson(res);

      if (res.statusCode != 200) {
        _stream.add(BookingUpdate(BookingStatus.failed, body));
        return;
      }

      final String statusStr = _s(
        body['status'] ?? body['ride_status'],
        'searching',
      ).toLowerCase();

      final BookingStatus status = _mapStatus(statusStr);
      _stream.add(BookingUpdate(status, body));

      if (status == BookingStatus.completed ||
          status == BookingStatus.cancelled ||
          status == BookingStatus.failed) {
        _stopAll();
      }
    } catch (e) {
      _stream.add(
        BookingUpdate(
          BookingStatus.failed,
          <String, dynamic>{'message': e.toString()},
        ),
      );
    }
  }

  void _stopAll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pinger?.stop();
  }

  Map<String, dynamic> _tryJson(http.Response r) {
    try {
      final dynamic j = jsonDecode(r.body);
      if (j is Map<String, dynamic>) return j;
      if (j is Map) return j.cast<String, dynamic>();
      if (j is List) return <String, dynamic>{'list': j};
      return <String, dynamic>{'raw': r.body};
    } catch (_) {
      return <String, dynamic>{'raw': r.body};
    }
  }

  BookingStatus _mapStatus(String s) {
    switch (s) {
      case 'assigned':
      case 'driver_assigned':
        return BookingStatus.driverAssigned;

      case 'arriving':
      case 'driver_arriving':
      case 'arrived_pickup':
      case 'reach_pickup':
        return BookingStatus.driverArriving;

      case 'ontrip':
      case 'on_trip':
      case 'in_progress':
      case 'started':
        return BookingStatus.onTrip;

      case 'done':
      case 'completed':
      case 'finished':
        return BookingStatus.completed;

      case 'cancelled':
      case 'canceled':
      case 'declined':
        return BookingStatus.cancelled;

      case 'failed':
      case 'error':
        return BookingStatus.failed;

      default:
        return BookingStatus.searching;
    }
  }
}