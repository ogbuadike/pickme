// lib/services/booking_controller.dart
//
// Booking controller (rider side) with:
// • create -> polls status -> cancel
// • All requests use Map<String,String> for your ApiClient
// • Safe parsing + resilient error handling
//
// Endpoints here are file names on your PHP side. Adjust if your
// server names differ (the code compiles either way).

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

  // You can change these to ApiConstants.* if you later add them there.
  static const String _epCreate = 'ride_create_booking.php';
  static const String _epStatus = 'ride_booking_status.php';
  static const String _epCancel = 'ride_cancel_booking.php';

  String? _rideId;
  Timer? _pollTimer;
  final _stream = StreamController<BookingUpdate>.broadcast();

  BookingController(this._api, {DriverLocationUpdater? pinger}) : _pinger = pinger;

  String? get rideId => _rideId;
  Stream<BookingUpdate> get updates => _stream.stream;

  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_stream.isClosed) _stream.close();
  }

  /// Create a booking from a selected marketplace offer
  Future<bool> createBooking({
    required RideOffer offer,
    required LatLng pickup,
    required LatLng destination,
    String? pickupText,
    String? destinationText,
    List<LatLng> stops = const [],
    String payMethod = 'cash',
    String? userId,
  }) async {
    try {
      final payload = <String, String>{
        'offer_id': offer.id,
        'provider': offer.provider,
        'category': offer.category,
        'eta_min': offer.etaToPickupMin.toString(),
        'price_ngn': offer.price.toString(),
        'surge': offer.surge ? '1' : '0',
        'pickup': '${pickup.latitude},${pickup.longitude}',
        'pickup_text': pickupText ?? '',
        'destination': '${destination.latitude},${destination.longitude}',
        'destination_text': destinationText ?? '',
        'stops': stops.isEmpty
            ? ''
            : stops.map((e) => '${e.latitude},${e.longitude}').join('|'),
        'pay_method': payMethod,
        'uid': userId ?? '',
        'vehicle': 'car',
      };

      final res = await _api.request(_epCreate, method: 'POST', data: payload);
      final body = _tryJson(res);

      if (res.statusCode == 200 && body['error'] != true) {
        _rideId = (body['ride_id'] ?? body['id'] ?? '').toString();
        if (_rideId == null || _rideId!.isEmpty) throw 'No ride_id in response';

        // Start pinging driver location to server (optional)
        _pinger?.start(() => pickup);

        // Initial status to stream
        _stream.add(BookingUpdate(BookingStatus.searching, body));

        // Start polling
        _startPolling();
        return true;
      }

      _stream.add(BookingUpdate(BookingStatus.failed, body));
      return false;
    } catch (e) {
      _stream.add(BookingUpdate(BookingStatus.failed, {'message': e.toString()}));
      return false;
    }
  }

  /// Cancel an in-flight booking
  Future<bool> cancelBooking({String reason = ''}) async {
    if (_rideId == null || _rideId!.isEmpty) return false;
    try {
      final res = await _api.request(
        _epCancel,
        method: 'POST',
        data: {
          'ride_id': _rideId ?? '',
          'reason': reason,
        },
      );
      final body = _tryJson(res);
      final ok = res.statusCode == 200 && body['error'] != true;

      if (ok) {
        _stream.add(BookingUpdate(BookingStatus.cancelled, body));
      } else {
        _stream.add(BookingUpdate(BookingStatus.failed, body));
      }

      _stopAll();
      return ok;
    } catch (e) {
      _stream.add(BookingUpdate(BookingStatus.failed, {'message': e.toString()}));
      _stopAll();
      return false;
    }
  }

  // ===== Polling =====

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _pollOnce());
    _pollOnce(); // immediate
  }

  Future<void> _pollOnce() async {
    if (_rideId == null || _rideId!.isEmpty) return;
    try {
      final res = await _api.request(
        _epStatus,
        method: 'POST',
        data: {'ride_id': _rideId ?? ''},
      );
      final body = _tryJson(res);

      if (res.statusCode != 200) {
        _stream.add(BookingUpdate(BookingStatus.failed, body));
        return;
      }

      final statusStr = (body['status'] ?? body['ride_status'] ?? 'searching').toString().toLowerCase();
      final status = _mapStatus(statusStr);

      _stream.add(BookingUpdate(status, body));

      if (status == BookingStatus.completed ||
          status == BookingStatus.cancelled ||
          status == BookingStatus.failed) {
        _stopAll();
      }
    } catch (e) {
      _stream.add(BookingUpdate(BookingStatus.failed, {'message': e.toString()}));
      // keep polling; network might be flaky
    }
  }

  void _stopAll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pinger?.stop();
  }

  // ===== Utils =====

  Map<String, dynamic> _tryJson(http.Response r) {
    try {
      final j = jsonDecode(r.body);
      if (j is Map<String, dynamic>) return j;
      if (j is List) return {'list': j};
      return {'raw': r.body};
    } catch (_) {
      return {'raw': r.body};
    }
  }

  BookingStatus _mapStatus(String s) {
    switch (s) {
      case 'assigned':
      case 'driver_assigned':
        return BookingStatus.driverAssigned;
      case 'arriving':
      case 'driver_arriving':
        return BookingStatus.driverArriving;
      case 'ontrip':
      case 'on_trip':
      case 'in_progress':
        return BookingStatus.onTrip;
      case 'done':
      case 'completed':
        return BookingStatus.completed;
      case 'cancelled':
      case 'canceled':
        return BookingStatus.cancelled;
      case 'failed':
      case 'error':
        return BookingStatus.failed;
      default:
        return BookingStatus.searching;
    }
  }
}
