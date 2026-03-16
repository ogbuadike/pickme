import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../api/api_client.dart';
import '../api/url.dart';
import '../services/ride_market_service.dart';
import 'driver_location_updater.dart';

enum BookingErrorKind {
  driverBusy,
  validation,
  notFound,
  serverError,
  networkError,
  parseError,
  noRideId,
  unknown,
}

class BookingError {
  final BookingErrorKind kind;
  final String message;
  final int? httpStatus;
  final Map<String, dynamic> rawBody;

  const BookingError({
    required this.kind,
    required this.message,
    this.httpStatus,
    this.rawBody = const <String, dynamic>{},
  });

  @override
  String toString() {
    return 'BookingError(kind=${kind.name}, status=$httpStatus, msg=$message)';
  }
}

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
  final BookingError? error;

  const BookingUpdate(this.status, this.data, {this.error});

  String get displayMessage {
    if (error != null && error!.message.trim().isNotEmpty) {
      return error!.message.trim();
    }
    for (final String key in const <String>[
      'displayMessage',
      'message',
      'error_message',
      'reason',
      'detail',
      'details',
    ]) {
      final dynamic value = data[key];
      if (value == null) continue;
      final String s = value.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return 'An unknown booking error occurred.';
  }
}

class _ApiException implements Exception {
  final BookingErrorKind kind;
  final String message;
  final int? httpStatus;
  final Map<String, dynamic> body;

  const _ApiException({
    required this.kind,
    required this.message,
    this.httpStatus,
    this.body = const <String, dynamic>{},
  });

  BookingError toBookingError() {
    return BookingError(
      kind: kind,
      message: message,
      httpStatus: httpStatus,
      rawBody: body,
    );
  }

  @override
  String toString() => message;
}

class BookingController {
  final ApiClient _api;
  final DriverLocationUpdater? _pinger;

  static const Duration _pollEvery = Duration(seconds: 2);

  final StreamController<BookingUpdate> _stream =
  StreamController<BookingUpdate>.broadcast();

  String? _rideId;
  String? _riderId;
  String? _driverId;
  LatLng? _pickup;
  LatLng? _destination;
  List<LatLng> _stops = const <LatLng>[];
  String _pickupText = '';
  String _destinationText = '';

  Timer? _pollTimer;
  bool _disposed = false;

  BookingError? lastError;
  Map<String, dynamic> _currentSnapshot = <String, dynamic>{};

  BookingController(this._api, {DriverLocationUpdater? pinger})
      : _pinger = pinger;

  String? get rideId => _rideId;
  String? get riderId => _riderId;
  String? get driverId => _driverId;
  Map<String, dynamic> get currentSnapshot =>
      Map<String, dynamic>.from(_currentSnapshot);
  Stream<BookingUpdate> get updates => _stream.stream;
  Stream<BookingUpdate> get stream => _stream.stream;
  Stream<BookingUpdate> get events => _stream.stream;

  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _pinger?.stop();
    if (!_stream.isClosed) {
      _stream.close();
    }
  }

  void _dbg(String tag, [Object? data]) {
    final String stamp = DateTime.now().toIso8601String();
    if (data == null) {
      debugPrint('[Booking][$tag] $stamp');
      return;
    }
    Object safe = data;
    try {
      safe = jsonEncode(data);
    } catch (_) {
      safe = data.toString();
    }
    debugPrint('[Booking][$tag] $stamp $safe');
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

  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim());
  }

  bool _looksLikeHtml(String body) {
    final String x = body.trimLeft().toLowerCase();
    return x.startsWith('<!doctype html') ||
        x.startsWith('<html') ||
        x.contains('<head') ||
        x.contains('<body');
  }

  Map<String, dynamic> _tryJsonBody(String body) {
    try {
      final dynamic j = jsonDecode(body);
      if (j is Map<String, dynamic>) return j;
      if (j is Map) return j.cast<String, dynamic>();
      if (j is List) return <String, dynamic>{'list': j};
      return <String, dynamic>{'raw': body};
    } catch (_) {
      return <String, dynamic>{'raw': body};
    }
  }

  Map<String, dynamic> _tryJson(http.Response r) => _tryJsonBody(r.body);

  String _extractServerMessage(Map<String, dynamic> body, int status) {
    for (final String key in const <String>[
      'message',
      'error_message',
      'reason',
      'detail',
      'details',
      'msg',
      'description',
      'error',
    ]) {
      final dynamic v = body[key];
      if (v == null || v is bool || v is int) continue;
      final String s = v.toString().trim();
      if (s.isNotEmpty && s.toLowerCase() != 'true' && s.toLowerCase() != 'false') {
        return s;
      }
    }

    final dynamic errors = body['errors'];
    if (errors is Map && errors.isNotEmpty) {
      final List<String> parts = <String>[];
      errors.forEach((dynamic k, dynamic v) {
        if (v is List && v.isNotEmpty) {
          parts.add('$k: ${v.first}');
        } else {
          parts.add('$k: $v');
        }
      });
      if (parts.isNotEmpty) return parts.join(' | ');
    }

    return _statusMessage(status);
  }

  String _statusMessage(int status) {
    switch (status) {
      case 400:
        return 'Bad request — check the booking data sent.';
      case 401:
        return 'Unauthorised — please log in again.';
      case 403:
        return 'Access denied.';
      case 404:
        return 'Booking endpoint not found (404). Check ApiConstants.';
      case 409:
        return 'Driver is currently busy or already has an active ride. Please choose another driver.';
      case 410:
        return 'This offer has expired. Please refresh and try again.';
      case 422:
        return 'The server could not process the booking data. Check all required fields.';
      case 429:
        return 'Too many requests — slow down and try again.';
      case 500:
        return 'Internal server error (500). Contact support if it persists.';
      case 502:
        return 'Bad gateway (502). The server is temporarily unavailable.';
      case 503:
        return 'Service unavailable (503). Try again shortly.';
      default:
        return 'Server returned HTTP $status.';
    }
  }

  BookingErrorKind _kindFromStatus(int status) {
    switch (status) {
      case 404:
        return BookingErrorKind.notFound;
      case 409:
        return BookingErrorKind.driverBusy;
      case 422:
        return BookingErrorKind.validation;
      case 500:
      case 502:
      case 503:
        return BookingErrorKind.serverError;
      default:
        return BookingErrorKind.unknown;
    }
  }

  void _ensureHttpOk(http.Response res, String endpoint) {
    if (_looksLikeHtml(res.body)) {
      throw _ApiException(
        kind: BookingErrorKind.parseError,
        message:
        'Server returned an HTML page from $endpoint instead of JSON. The endpoint path may be wrong.',
        httpStatus: res.statusCode,
      );
    }

    if (res.statusCode >= 200 && res.statusCode < 300) return;

    final Map<String, dynamic> body = _tryJson(res);
    final String serverMsg = _extractServerMessage(body, res.statusCode);

    throw _ApiException(
      kind: _kindFromStatus(res.statusCode),
      message: serverMsg,
      httpStatus: res.statusCode,
      body: body,
    );
  }

  _ApiException? _apiExceptionFromThrown(Object error) {
    final String raw = error.toString();
    final RegExpMatch? m = RegExp(r'Error\s+(\d{3})\s*:').firstMatch(raw);
    if (m == null) return null;

    final int? status = int.tryParse(m.group(1) ?? '');
    if (status == null) return null;

    final int jsonStart = raw.indexOf('{');
    Map<String, dynamic> body = const <String, dynamic>{};
    String message = _statusMessage(status);

    if (jsonStart >= 0) {
      final String candidate = raw.substring(jsonStart).trim();
      body = _tryJsonBody(candidate);
      message = _extractServerMessage(body, status);
    }

    return _ApiException(
      kind: _kindFromStatus(status),
      message: message,
      httpStatus: status,
      body: body,
    );
  }

  Future<http.Response> _performRequest({
    required String endpoint,
    required String method,
    required Map<String, String> payload,
  }) async {
    _dbg('HTTP_REQ', <String, dynamic>{
      'endpoint': endpoint,
      'payload': payload,
    });

    try {
      final http.Response res = await _api.request(
        endpoint,
        method: method,
        data: payload,
      );

      _dbg('HTTP_RES', <String, dynamic>{
        'endpoint': endpoint,
        'statusCode': res.statusCode,
        'bodySnippet': res.body.length > 1200 ? res.body.substring(0, 1200) : res.body,
      });

      return res;
    } catch (e) {
      final _ApiException? ex = _apiExceptionFromThrown(e);
      if (ex != null) {
        _dbg('HTTP_THROWN', <String, dynamic>{
          'endpoint': endpoint,
          'message': ex.message,
          'status': ex.httpStatus,
          'kind': ex.kind.name,
          'body': ex.body,
        });
        throw ex;
      }

      _dbg('HTTP_THROWN', <String, dynamic>{
        'endpoint': endpoint,
        'message': e.toString(),
        'status': null,
        'kind': BookingErrorKind.networkError.name,
      });
      rethrow;
    }
  }

  Map<String, String> _coordsPayload(LatLng point, String prefix) {
    return <String, String>{
      prefix: '${point.latitude},${point.longitude}',
      '${prefix}_lat': point.latitude.toString(),
      '${prefix}_lng': point.longitude.toString(),
    };
  }

  Map<String, String> _rideContextPayload({bool includeCoordinates = true}) {
    final String rideId = _s(_rideId);
    final String riderId = _s(_riderId);
    final String driverId = _s(_driverId);

    final Map<String, String> payload = <String, String>{
      'ride_id': rideId,
      'trip_id': rideId,
      'id': rideId,
      'rider_id': riderId,
      'user_id': riderId,
      'uid': riderId,
      'driver_id': driverId,
    };

    if (includeCoordinates && _pickup != null) {
      payload.addAll(_coordsPayload(_pickup!, 'pickup'));
      payload['pickup_text'] = _pickupText;
    }

    if (includeCoordinates && _destination != null) {
      payload.addAll(_coordsPayload(_destination!, 'destination'));
      payload['destination_text'] = _destinationText;
    }

    if (includeCoordinates && _stops.isNotEmpty) {
      payload['stops'] = _stops
          .map((LatLng e) => '${e.latitude},${e.longitude}')
          .join('|');
    }

    return payload;
  }

  Map<String, dynamic> _normalizePayload(Map<String, dynamic> body) {
    final Map<String, dynamic> out = <String, dynamic>{
      ..._currentSnapshot,
      ...body,
    };

    final Map<String, dynamic> ride = body['ride'] is Map
        ? (body['ride'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final Map<String, dynamic> driver = body['driver'] is Map
        ? (body['driver'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};

    final String rideId = _s(
      body['ride_id'] ?? body['trip_id'] ?? body['id'] ?? ride['id'] ?? _rideId,
    );
    if (rideId.isNotEmpty) {
      out['ride_id'] = rideId;
      out['trip_id'] = rideId;
      out['id'] = rideId;
    }

    final String riderId = _s(
      body['rider_id'] ?? body['user_id'] ?? body['uid'] ?? ride['rider_id'] ?? _riderId,
    );
    if (riderId.isNotEmpty) {
      out['rider_id'] = riderId;
      out['user_id'] = riderId;
      out['uid'] = riderId;
    }

    final String driverId = _s(body['driver_id'] ?? ride['driver_id'] ?? _driverId);
    if (driverId.isNotEmpty) {
      out['driver_id'] = driverId;
    }

    final String status = _s(
      body['status'] ?? body['phase'] ?? body['ride_status'] ?? ride['status'],
      _currentSnapshot['status']?.toString() ?? 'searching',
    );
    out['status'] = status;
    out['phase'] = status;
    out['ride_status'] = status;

    final double? driverLat = _toDouble(
      body['driver_lat'] ?? body['driverLat'] ?? body['lat'] ?? driver['lat'] ?? driver['latitude'],
    );
    final double? driverLng = _toDouble(
      body['driver_lng'] ?? body['driverLng'] ?? body['lng'] ?? driver['lng'] ?? driver['longitude'],
    );
    final double driverHeading = _toDouble(
      body['driver_heading'] ??
          body['driverHeading'] ??
          body['heading'] ??
          driver['heading'] ??
          driver['bearing'],
    ) ??
        0.0;

    if (driverLat != null) {
      out['driver_lat'] = driverLat;
      out['driverLat'] = driverLat;
      out['lat'] = driverLat;
    }
    if (driverLng != null) {
      out['driver_lng'] = driverLng;
      out['driverLng'] = driverLng;
      out['lng'] = driverLng;
    }

    out['driver_heading'] = driverHeading;
    out['driverHeading'] = driverHeading;
    out['heading'] = driverHeading;
    out['bearing'] = driverHeading;

    if (_pickup != null) {
      out['pickup'] = out['pickup'] ?? <String, dynamic>{
        'lat': _pickup!.latitude,
        'lng': _pickup!.longitude,
        'text': _pickupText,
      };
      out['pickup_lat'] = _pickup!.latitude;
      out['pickup_lng'] = _pickup!.longitude;
      out['pickup_text'] = _pickupText;
      out['rider_lat'] = out['rider_lat'] ?? _pickup!.latitude;
      out['rider_lng'] = out['rider_lng'] ?? _pickup!.longitude;
      out['user_lat'] = out['user_lat'] ?? _pickup!.latitude;
      out['user_lng'] = out['user_lng'] ?? _pickup!.longitude;
    }

    if (_destination != null) {
      out['destination'] = out['destination'] ?? <String, dynamic>{
        'lat': _destination!.latitude,
        'lng': _destination!.longitude,
        'text': _destinationText,
      };
      out['destination_lat'] = _destination!.latitude;
      out['destination_lng'] = _destination!.longitude;
      out['destination_text'] = _destinationText;
    }

    if (ride.isNotEmpty) {
      if (!ride.containsKey('pickup') && _pickup != null) {
        ride['pickup'] = <String, dynamic>{
          'lat': _pickup!.latitude,
          'lng': _pickup!.longitude,
          'text': _pickupText,
        };
      }
      if (!ride.containsKey('destination') && _destination != null) {
        ride['destination'] = <String, dynamic>{
          'lat': _destination!.latitude,
          'lng': _destination!.longitude,
          'text': _destinationText,
        };
      }
      out['ride'] = ride;
    }

    if (driver.isNotEmpty) out['driver'] = driver;

    return out;
  }

  BookingStatus _mapStatus(String s) {
    switch (s.trim().toLowerCase()) {
      case 'driver_assigned':
      case 'assigned':
        return BookingStatus.driverAssigned;
      case 'enroute_pickup':
      case 'driver_arriving':
      case 'arriving':
      case 'arrived_pickup':
        return BookingStatus.driverArriving;
      case 'in_ride':
      case 'on_trip':
      case 'in_progress':
      case 'ontrip':
        return BookingStatus.onTrip;
      case 'completed':
      case 'done':
      case 'finished':
        return BookingStatus.completed;
      case 'canceled':
      case 'cancelled':
        return BookingStatus.cancelled;
      case 'failed':
      case 'error':
        return BookingStatus.failed;
      default:
        return BookingStatus.searching;
    }
  }

  void _emit(BookingStatus status, Map<String, dynamic> body, {BookingError? error}) {
    if (_disposed || _stream.isClosed) return;
    final Map<String, dynamic> normalized = _normalizePayload(body);
    if (error != null) {
      normalized['booking_status'] = BookingStatus.failed.toString();
      normalized['displayMessage'] = error.message;
      normalized['error_kind'] = error.kind.name;
      normalized['http_status'] = error.httpStatus;
    }
    _currentSnapshot = normalized;
    _stream.add(BookingUpdate(status, normalized, error: error));
  }

  void _emitError(_ApiException ex) {
    final BookingError err = ex.toBookingError();
    lastError = err;
    _emit(
      BookingStatus.failed,
      <String, dynamic>{
        'message': err.message,
        'http_status': err.httpStatus,
        'error_kind': err.kind.name,
        ...ex.body,
      },
      error: err,
    );
  }

  void _emitNetworkError(Object e) {
    final BookingError err = BookingError(
      kind: BookingErrorKind.networkError,
      message: 'Network error — check your connection. (${e.toString()})',
    );
    lastError = err;
    _emit(
      BookingStatus.failed,
      <String, dynamic>{
        'message': err.message,
        'error_kind': err.kind.name,
      },
      error: err,
    );
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
    _pickup = pickup;
    _destination = destination;
    _stops = List<LatLng>.from(stops);
    _pickupText = _s(pickupText);
    _destinationText = _s(destinationText);
    _riderId = _s(userId);
    _driverId = _s(driverId);
    _currentSnapshot = <String, dynamic>{
      'rider_id': _riderId,
      'user_id': _riderId,
      'uid': _riderId,
      'driver_id': _driverId,
      'pickup_lat': pickup.latitude,
      'pickup_lng': pickup.longitude,
      'pickup_text': _pickupText,
      'destination_lat': destination.latitude,
      'destination_lng': destination.longitude,
      'destination_text': _destinationText,
      'status': 'searching',
      'phase': 'searching',
      'ride_status': 'searching',
    };

    try {
      final String safeVehicleType = _s(offer.vehicleType, 'car');
      final String safeProvider = _s(offer.provider, 'PickMe');
      final String safeCategory = _s(offer.category, 'Standard');
      final String safeCurrency = _s(offer.currency, 'NGN');
      final double estimatedTotal = _d(offer.estimatedTotal, _d(offer.price, 0.0));

      final Map<String, String> payload = <String, String>{
        'rider_id': _riderId ?? '',
        'uid': _riderId ?? '',
        'user_id': _riderId ?? '',
        'driver_id': _driverId ?? '',
        'offer_id': _s(offer.id),
        'provider': safeProvider,
        'category': safeCategory,
        'vehicle_type': safeVehicleType,
        'vehicle': safeVehicleType,
        'currency': safeCurrency,
        'pay_method': _s(payMethod, 'cash'),
        'eta_min': _i(offer.etaToPickupMin, 0).toString(),
        'surge': _b(offer.surge, false) ? '1' : '0',
        'price': estimatedTotal.toStringAsFixed(2),
        'price_total': estimatedTotal.toStringAsFixed(2),
        'price_ngn': estimatedTotal.toStringAsFixed(2),
        ..._coordsPayload(pickup, 'pickup'),
        'pickup_text': _pickupText,
        ..._coordsPayload(destination, 'destination'),
        'destination_text': _destinationText,
        'stops': stops.isEmpty
            ? ''
            : stops.map((LatLng e) => '${e.latitude},${e.longitude}').join('|'),
      };

      final http.Response res = await _performRequest(
        endpoint: ApiConstants.rideBookEndpoint,
        method: 'POST',
        payload: payload,
      );

      _ensureHttpOk(res, ApiConstants.rideBookEndpoint);

      final Map<String, dynamic> body = _tryJson(res);
      if (body['error'] == true || body['error'] == 1 || body['error'] == '1') {
        final String serverMsg = _extractServerMessage(body, res.statusCode);
        final BookingError err = BookingError(
          kind: BookingErrorKind.unknown,
          message: serverMsg.isNotEmpty
              ? serverMsg
              : 'Booking failed (server returned error flag).',
          httpStatus: res.statusCode,
          rawBody: body,
        );
        lastError = err;
        _emit(BookingStatus.failed, body, error: err);
        return false;
      }

      final Map<String, dynamic> normalized = _normalizePayload(body);
      final String id = _s(normalized['ride_id']);
      if (id.isEmpty) {
        final BookingError err = BookingError(
          kind: BookingErrorKind.noRideId,
          message: 'Booking accepted but server did not return a ride_id. Contact support.',
          httpStatus: res.statusCode,
          rawBody: body,
        );
        lastError = err;
        _emit(BookingStatus.failed, body, error: err);
        return false;
      }

      _rideId = id;
      lastError = null;
      _pinger?.start(() => pickup);
      _emit(_mapStatus(_s(normalized['status'], 'searching')), normalized);
      _startPolling();
      return true;
    } on _ApiException catch (ex) {
      _emitError(ex);
      return false;
    } catch (e) {
      _emitNetworkError(e);
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
  }) =>
      bookRide(
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
  }) =>
      bookRide(
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

  Future<bool> startTrip() async {
    final String id = _s(_rideId);
    if (id.isEmpty) return false;

    try {
      final http.Response res = await _performRequest(
        endpoint: ApiConstants.rideStartEndpoint,
        method: 'POST',
        payload: _rideContextPayload(),
      );

      _ensureHttpOk(res, ApiConstants.rideStartEndpoint);

      final Map<String, dynamic> body = _tryJson(res);
      final Map<String, dynamic> normalized = _normalizePayload(body);
      final bool ok =
          res.statusCode >= 200 && res.statusCode < 300 && body['error'] != true && body['error'] != 1;

      if (ok) {
        lastError = null;
        _emit(BookingStatus.onTrip, normalized);
      } else {
        final BookingError err = BookingError(
          kind: BookingErrorKind.unknown,
          message: _extractServerMessage(body, res.statusCode),
          httpStatus: res.statusCode,
          rawBody: body,
        );
        lastError = err;
        _emit(BookingStatus.failed, body, error: err);
      }
      return ok;
    } on _ApiException catch (ex) {
      _emitError(ex);
      return false;
    } catch (e) {
      _emitNetworkError(e);
      return false;
    }
  }

  Future<bool> startRide() => startTrip();
  Future<bool> commenceTrip() => startTrip();
  Future<bool> beginTrip() => startTrip();

  Future<bool> cancelBooking({String reason = ''}) async {
    final String id = _s(_rideId);
    if (id.isEmpty) return false;

    try {
      final Map<String, String> payload = _rideContextPayload();
      payload['reason'] = _s(reason);

      final http.Response res = await _performRequest(
        endpoint: ApiConstants.rideCancelEndpoint,
        method: 'POST',
        payload: payload,
      );

      _ensureHttpOk(res, ApiConstants.rideCancelEndpoint);

      final Map<String, dynamic> body = _tryJson(res);
      final Map<String, dynamic> normalized = _normalizePayload(body);
      final bool ok =
          res.statusCode >= 200 && res.statusCode < 300 && body['error'] != true && body['error'] != 1;

      if (ok) {
        lastError = null;
        _emit(BookingStatus.cancelled, normalized);
      } else {
        final BookingError err = BookingError(
          kind: BookingErrorKind.unknown,
          message: _extractServerMessage(body, res.statusCode),
          httpStatus: res.statusCode,
          rawBody: body,
        );
        lastError = err;
        _emit(BookingStatus.failed, body, error: err);
      }

      _stopAll();
      return ok;
    } on _ApiException catch (ex) {
      _emitError(ex);
      _stopAll();
      return false;
    } catch (e) {
      _emitNetworkError(e);
      _stopAll();
      return false;
    }
  }

  Future<bool> cancelRide({String reason = ''}) => cancelBooking(reason: reason);
  Future<bool> cancelTrip({String reason = ''}) => cancelBooking(reason: reason);
  Future<bool> abortTrip({String reason = ''}) => cancelBooking(reason: reason);

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollEvery, (_) => _pollOnce());
    _pollOnce();
  }

  Future<void> _pollOnce() async {
    final String id = _s(_rideId);
    if (id.isEmpty || _disposed) return;

    try {
      final http.Response res = await _performRequest(
        endpoint: ApiConstants.rideStatusEndpoint,
        method: 'POST',
        payload: _rideContextPayload(),
      );

      _ensureHttpOk(res, ApiConstants.rideStatusEndpoint);

      final Map<String, dynamic> body = _tryJson(res);
      final Map<String, dynamic> normalized = _normalizePayload(body);

      if (body['error'] == true || body['error'] == 1) {
        final BookingError err = BookingError(
          kind: BookingErrorKind.unknown,
          message: _extractServerMessage(body, res.statusCode),
          httpStatus: res.statusCode,
          rawBody: body,
        );
        lastError = err;
        _emit(BookingStatus.failed, body, error: err);
        return;
      }

      lastError = null;
      final BookingStatus status = _mapStatus(_s(normalized['status'], 'searching'));
      _emit(status, normalized);

      if (status == BookingStatus.completed ||
          status == BookingStatus.cancelled ||
          status == BookingStatus.failed) {
        _stopAll();
      }
    } on _ApiException catch (ex) {
      _emitError(ex);
    } catch (e) {
      _emitNetworkError(e);
    }
  }

  void _stopAll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pinger?.stop();
  }
}
