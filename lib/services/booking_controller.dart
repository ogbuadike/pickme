// lib/services/booking_controller.dart
//
// Headless booking engine shared by Street Ride, Campus Ride, Send Me and
// Dispatch. It owns one ride at a time:
//
//   book (idempotent, client_request_id) -> poll ride_status.php -> terminal
//
// Guarantees:
//  * at most one book / cancel / start request in flight (double taps are
//    coalesced onto the same Future);
//  * mutations are never blindly retried by the transport (retryCount: 0); a
//    lost book response is reconciled against the server before retrying with
//    the SAME client_request_id;
//  * polling is a single-shot timer chain (never overlaps), backs off with
//    jitter on errors / 429, pauses while the app is in the background and
//    stops on dispose or on a terminal status;
//  * results that arrive after a cancel / dispose are dropped (generation
//    counter), so a late "searching" poll can never resurrect a cancelled ride;
//  * a ride that stays in `searching` longer than [searchTimeout] is cancelled
//    server-side and reported as cancelled with reason `no_driver_found`.
//
// Public API is source compatible with the previous version (home_page,
// booking_flow_manager, trip_navigation_page depend on it).

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../services/ride_market_service.dart';
import 'driver_location_updater.dart';

/// Canonical ride status strings used by the PHP backend (`ride_rides.status`).
abstract final class RideStatusCode {
  static const String searching = 'searching';
  static const String accepted = 'accepted';
  static const String enroutePickup = 'enroute_pickup';
  static const String arrivedPickup = 'arrived_pickup';
  static const String inProgress = 'in_progress';
  static const String arrivedDestination = 'arrived_destination';
  static const String completed = 'completed';
  static const String canceled = 'canceled';

  /// Returned by ride_status.php when the rider has no active ride.
  static const String idle = 'idle';

  static const Set<String> active = <String>{
    searching,
    accepted,
    enroutePickup,
    arrivedPickup,
    inProgress,
    arrivedDestination,
  };

  /// Maps legacy aliases and spelling variants onto the canonical set.
  /// (`cancelled` is written by ride_history.php's cleanup, `canceled` by
  /// ride_cancel_booking.php / driver_hub.php.)
  static String normalize(Object? raw) {
    final String s = (raw ?? '').toString().trim().toLowerCase();
    switch (s) {
      case '':
        return searching;
      case 'driver_assigned':
      case 'assigned':
        return accepted;
      case 'driver_arriving':
      case 'arriving':
        return enroutePickup;
      case 'in_ride':
      case 'on_trip':
      case 'ontrip':
        return inProgress;
      case 'cancelled':
        return canceled;
      case 'done':
      case 'finished':
        return completed;
      default:
        return s;
    }
  }

  static bool isActive(Object? raw) => active.contains(normalize(raw));
  static bool isTerminal(Object? raw) {
    final String s = normalize(raw);
    return s == completed || s == canceled;
  }
}

enum BookingErrorKind {
  driverBusy,
  validation,
  notFound,
  serverError,
  networkError,
  parseError,
  noRideId,
  unknown,
  // Added (no exhaustive switches over this enum exist in the app):
  conflict,
  rateLimited,
  sessionExpired,
  forbidden,
  timeout,
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
  String toString() => 'BookingError(kind=${kind.name}, status=$httpStatus, msg=$message)';
}

/// Coarse phase of a booking. NOTE: trip_navigation_page.dart switches
/// exhaustively over this enum - do not add values. Finer detail (e.g.
/// `arrived_pickup` vs `enroute_pickup`) is exposed via [BookingUpdate.rawStatus].
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

  /// Canonical server status string (see [RideStatusCode]).
  String get rawStatus => RideStatusCode.normalize(data['status']);

  bool get isTerminal =>
      status == BookingStatus.completed || status == BookingStatus.cancelled;

  /// Most relevant human-readable message.
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
  final Duration? retryAfter;

  const _ApiException({
    required this.kind,
    required this.message,
    this.httpStatus,
    this.body = const <String, dynamic>{},
    this.retryAfter,
  });

  BookingError toBookingError() =>
      BookingError(kind: kind, message: message, httpStatus: httpStatus, rawBody: body);

  bool get isTransient =>
      kind == BookingErrorKind.networkError ||
      kind == BookingErrorKind.serverError ||
      kind == BookingErrorKind.rateLimited ||
      kind == BookingErrorKind.timeout;

  @override
  String toString() => message;
}

class BookingController {
  final ApiClient _api;
  final DriverLocationUpdater? _pinger;

  /// How long a ride may stay in `searching` before it is cancelled
  /// automatically (server keeps searching rides for 30 min otherwise).
  final Duration searchTimeout;

  static const Duration _pollSearching = Duration(seconds: 3);
  static const Duration _pollActive = Duration(seconds: 2);
  static const Duration _maxBackoff = Duration(seconds: 30);
  static const Duration _requestTimeout = Duration(seconds: 15);
  static const int _failuresBeforeReport = 4;

  static const Uuid _uuid = Uuid();
  final math.Random _rng = math.Random();

  final StreamController<BookingUpdate> _stream = StreamController<BookingUpdate>.broadcast();

  String? _rideId;
  String? _riderId;
  String? _driverId;
  String _rideType = 'street_ride';
  LatLng? _pickup;
  LatLng? _destination;
  List<LatLng> _stops = const <LatLng>[];
  String _pickupText = '';
  String _destinationText = '';

  Timer? _pollTimer;
  bool _pollInFlight = false;
  bool _polling = false;
  bool _backgrounded = false;
  int _generation = 0;
  int _consecutiveFailures = 0;
  bool _failureReported = false;
  DateTime? _searchStartedAt;
  String _lastFingerprint = '';
  AppLifecycleListener? _lifecycle;

  Future<bool>? _bookingFuture;
  Future<bool>? _cancelFuture;
  Future<bool>? _startFuture;
  bool _cancelRequestedDuringBooking = false;
  bool _disposed = false;

  BookingError? lastError;
  Map<String, dynamic> _currentSnapshot = <String, dynamic>{};

  BookingController(
    this._api, {
    DriverLocationUpdater? pinger,
    this.searchTimeout = const Duration(minutes: 5),
  }) : _pinger = pinger;

  String? get rideId => _rideId;
  String? get riderId => _riderId;
  String? get driverId => _driverId;
  String get rideType => _rideType;
  LatLng? get pickup => _pickup;
  LatLng? get destination => _destination;
  List<LatLng> get stops => List<LatLng>.unmodifiable(_stops);
  Map<String, dynamic> get currentSnapshot => Map<String, dynamic>.from(_currentSnapshot);

  /// True while a ride is booked and not yet terminal.
  bool get hasActiveRide =>
      (_rideId ?? '').isNotEmpty && !RideStatusCode.isTerminal(_currentSnapshot['status']);

  bool get isBooking => _bookingFuture != null;

  // Exposed under several names for backward compatibility.
  Stream<BookingUpdate> get updates => _stream.stream;
  Stream<BookingUpdate> get stream => _stream.stream;
  Stream<BookingUpdate> get events => _stream.stream;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopAll();
    if (!_stream.isClosed) _stream.close();
  }

  void _dbg(String tag, [Object? data]) {
    if (!kDebugMode) return; // payloads contain PII - never log in release
    debugPrint('[Booking][$tag] ${data ?? ''}');
  }

  // ───────────────────────────── parsing helpers ─────────────────────────────

  static String _s(Object? v, [String fallback = '']) {
    if (v == null) return fallback;
    final String x = v.toString().trim();
    return x.isEmpty ? fallback : x;
  }

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.isFinite ? v.toDouble() : null;
    final double? d = double.tryParse(v.toString().trim());
    return (d != null && d.isFinite) ? d : null;
  }

  static bool _isErrorFlag(dynamic v) {
    if (v == null || v == false) return false;
    if (v == true) return true;
    final String s = v.toString().trim().toLowerCase();
    return s == '1' || s == 'true' || s == 'yes';
  }

  static bool _validLatLng(LatLng? p) =>
      p != null &&
      p.latitude.isFinite &&
      p.longitude.isFinite &&
      p.latitude.abs() <= 90 &&
      p.longitude.abs() <= 180 &&
      !(p.latitude == 0 && p.longitude == 0);

  static bool _looksLikeHtml(String body) {
    final String x = body.trimLeft().toLowerCase();
    return x.startsWith('<!doctype html') || x.startsWith('<html') || x.contains('<body');
  }

  static Map<String, dynamic> _tryJsonBody(String body) {
    try {
      final dynamic j = jsonDecode(body);
      if (j is Map<String, dynamic>) return j;
      if (j is Map) return j.cast<String, dynamic>();
      if (j is List) return <String, dynamic>{'list': j};
    } catch (_) {}
    return <String, dynamic>{'raw': body};
  }

  static String _extractServerMessage(Map<String, dynamic> body, int status) {
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
      if (v == null || v is bool || v is num) continue;
      final String s = v.toString().trim();
      if (s.isNotEmpty && s.toLowerCase() != 'true' && s.toLowerCase() != 'false') return s;
    }
    final dynamic errors = body['errors'];
    if (errors is Map && errors.isNotEmpty) {
      final List<String> parts = <String>[];
      errors.forEach((dynamic k, dynamic v) {
        parts.add(v is List && v.isNotEmpty ? '$k: ${v.first}' : '$k: $v');
      });
      if (parts.isNotEmpty) return parts.join(' | ');
    }
    return _statusMessage(status);
  }

  static String _statusMessage(int status) {
    switch (status) {
      case 400:
        return 'The request was rejected. Please check the trip details.';
      case 401:
        return 'Your session has expired. Please log in again.';
      case 403:
        return 'You are not allowed to perform this action.';
      case 404:
        return 'This ride could not be found.';
      case 409:
        return 'This ride changed on the server. Please try again.';
      case 410:
        return 'This offer has expired. Please refresh and try again.';
      case 422:
        return 'Some booking details are missing or invalid.';
      case 429:
        return 'Too many requests. Please wait a moment and try again.';
      case 502:
      case 503:
      case 504:
        return 'The service is temporarily unavailable. Please try again shortly.';
      default:
        return status >= 500 ? 'Server error. Please try again.' : 'Request failed (HTTP $status).';
    }
  }

  static BookingErrorKind _kindFromStatus(int status) {
    if (status == 401) return BookingErrorKind.sessionExpired;
    if (status == 403) return BookingErrorKind.forbidden;
    if (status == 404) return BookingErrorKind.notFound;
    if (status == 409) return BookingErrorKind.conflict;
    if (status == 410 || status == 400 || status == 422) return BookingErrorKind.validation;
    if (status == 429) return BookingErrorKind.rateLimited;
    if (status >= 500) return BookingErrorKind.serverError;
    return BookingErrorKind.unknown;
  }

  static BookingErrorKind? _kindFromCode(Object? code) {
    switch (_s(code).toUpperCase()) {
      case 'SESSION_EXPIRED':
      case 'UNAUTHORIZED':
        return BookingErrorKind.sessionExpired;
      case 'FORBIDDEN':
        return BookingErrorKind.forbidden;
      case 'RATE_LIMITED':
        return BookingErrorKind.rateLimited;
      case 'VALIDATION':
        return BookingErrorKind.validation;
      case 'CONFLICT':
        return BookingErrorKind.conflict;
      case 'SERVER':
        return BookingErrorKind.serverError;
      default:
        return null;
    }
  }

  static BookingErrorKind _kindFromApiCode(ApiErrorCode code, int status) {
    switch (code) {
      case ApiErrorCode.sessionExpired:
      case ApiErrorCode.unauthorized:
        return BookingErrorKind.sessionExpired;
      case ApiErrorCode.forbidden:
        return BookingErrorKind.forbidden;
      case ApiErrorCode.rateLimited:
        return BookingErrorKind.rateLimited;
      case ApiErrorCode.validation:
        return BookingErrorKind.validation;
      case ApiErrorCode.conflict:
        return BookingErrorKind.conflict;
      case ApiErrorCode.server:
        return BookingErrorKind.serverError;
      case ApiErrorCode.unknown:
        return _kindFromStatus(status);
    }
  }

  /// Maps whatever the transport threw onto [_ApiException]. ApiClient throws
  /// [ApiException] for non-2xx responses (contract error envelope).
  static _ApiException _exceptionFromThrown(Object error) {
    if (error is _ApiException) return error;
    if (error is ApiException) {
      final int status = error.statusCode;
      final BookingErrorKind kind =
          status == 404 ? BookingErrorKind.notFound : _kindFromApiCode(error.code, status);
      final String msg = error.message.trim().isNotEmpty ? error.message.trim() : _statusMessage(status);
      return _ApiException(
        kind: kind,
        message: msg,
        httpStatus: status,
        retryAfter: error.retryAfter,
      );
    }
    if (error is TimeoutException) {
      return const _ApiException(
        kind: BookingErrorKind.timeout,
        message: 'The server is taking too long to respond. Check your connection.',
      );
    }
    // Legacy transports threw HttpException('Error <code>: <body>').
    final String raw = error.toString();
    final RegExpMatch? m = RegExp(r'Error\s+(\d{3})\s*:').firstMatch(raw);
    final int? status = m == null ? null : int.tryParse(m.group(1) ?? '');
    if (status != null) {
      Map<String, dynamic> body = const <String, dynamic>{};
      String message = _statusMessage(status);
      final int jsonStart = raw.indexOf('{');
      if (jsonStart >= 0) {
        body = _tryJsonBody(raw.substring(jsonStart).trim());
        message = _extractServerMessage(body, status);
      }
      return _ApiException(
        kind: _kindFromCode(body['code']) ?? _kindFromStatus(status),
        message: message,
        httpStatus: status,
        body: body,
      );
    }
    return const _ApiException(
      kind: BookingErrorKind.networkError,
      message: 'Network error. Check your connection and try again.',
    );
  }

  /// Single POST helper: no transport-level retry, hard timeout, error
  /// envelope (`error:true`, `code`) mapped to [_ApiException].
  Future<Map<String, dynamic>> _post(String endpoint, Map<String, String> payload) async {
    _dbg('REQ', endpoint);
    final String? idem = payload['client_request_id'];
    http.Response res;
    try {
      res = await _api
          .request(
            endpoint,
            method: 'POST',
            data: payload,
            // Never let the transport replay a mutation: the PHP endpoints do
            // not de-duplicate yet. We reconcile/retry ourselves.
            retryCount: 0,
            timeout: _requestTimeout,
            headers: idem == null ? null : <String, String>{'Idempotency-Key': idem},
          )
          .timeout(_requestTimeout + const Duration(seconds: 2));
    } catch (e) {
      throw _exceptionFromThrown(e);
    }
    if (_looksLikeHtml(res.body)) {
      throw _ApiException(
        kind: BookingErrorKind.parseError,
        message: 'Unexpected server response. Please try again.',
        httpStatus: res.statusCode,
      );
    }
    final Map<String, dynamic> body = _tryJsonBody(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _ApiException(
        kind: _kindFromCode(body['code']) ?? _kindFromStatus(res.statusCode),
        message: _extractServerMessage(body, res.statusCode),
        httpStatus: res.statusCode,
        body: body,
      );
    }
    if (body.containsKey('raw')) {
      throw _ApiException(
        kind: BookingErrorKind.parseError,
        message: 'Unexpected server response. Please try again.',
        httpStatus: res.statusCode,
      );
    }
    if (_isErrorFlag(body['error'])) {
      throw _ApiException(
        kind: _kindFromCode(body['code']) ?? BookingErrorKind.unknown,
        message: _extractServerMessage(body, res.statusCode),
        httpStatus: res.statusCode,
        body: body,
      );
    }
    _dbg('RES', '$endpoint ${res.statusCode}');
    return body;
  }

  // ───────────────────────────── payload builders ────────────────────────────

  static String _coord(double v) => v.toStringAsFixed(7);

  static double _routeKm(LatLng a, List<LatLng> stops, LatLng b) {
    double total = 0;
    LatLng prev = a;
    for (final LatLng p in <LatLng>[...stops, b]) {
      total += _haversineKm(prev, p);
      prev = p;
    }
    return total;
  }

  static double _haversineKm(LatLng a, LatLng b) {
    const double r = 6371.0;
    double rad(double d) => d * math.pi / 180.0;
    final double dLat = rad(b.latitude - a.latitude);
    final double dLng = rad(b.longitude - a.longitude);
    final double h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(a.latitude)) * math.cos(rad(b.latitude)) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
  }

  Map<String, String> _rideContextPayload() {
    final Map<String, String> payload = <String, String>{'ride_id': _s(_rideId)};
    // The server derives identity from the session (SECURITY_CONTRACT §3);
    // rider_id is still sent because the current PHP reads it.
    final String rider = _s(_riderId);
    if (rider.isNotEmpty) payload['rider_id'] = rider;
    return payload;
  }

  // ───────────────────────────── normalisation ───────────────────────────────

  Map<String, dynamic> _normalizePayload(Map<String, dynamic> body) {
    final Map<String, dynamic> out = <String, dynamic>{..._currentSnapshot, ...body};

    final Map<String, dynamic> ride =
        body['ride'] is Map ? (body['ride'] as Map).cast<String, dynamic>() : <String, dynamic>{};
    final Map<String, dynamic> driver =
        body['driver'] is Map ? (body['driver'] as Map).cast<String, dynamic>() : <String, dynamic>{};
    final Map<String, dynamic> data =
        body['data'] is Map ? (body['data'] as Map).cast<String, dynamic>() : <String, dynamic>{};

    final String rideId = _s(body['ride_id'] ?? body['trip_id'] ?? ride['id'] ?? data['ride_id'] ?? _rideId);
    if (rideId.isNotEmpty) {
      out['ride_id'] = rideId;
      out['trip_id'] = rideId;
      out['id'] = rideId;
    }

    final String riderId = _s(ride['rider_id'] ?? _riderId);
    if (riderId.isNotEmpty) {
      out['rider_id'] = riderId;
      out['user_id'] = riderId;
      out['uid'] = riderId;
    }

    final String driverId = _s(ride['driver_id'] ?? driver['id'] ?? body['driver_id'] ?? _driverId);
    if (driverId.isNotEmpty && driverId != '0') out['driver_id'] = driverId;

    final String status = RideStatusCode.normalize(
      _s(body['status'] ?? ride['status'] ?? data['status'] ?? body['ride_status'],
          _currentSnapshot['status']?.toString() ?? RideStatusCode.searching),
    );
    out['status'] = status;
    out['phase'] = status;
    out['ride_status'] = status;

    // Driver position: ignore (0,0) placeholders the server sends when no
    // driver is assigned / no fix exists, so the map never jumps to 0,0.
    final double? dLat = _toDouble(body['driver_lat'] ?? driver['lat'] ?? driver['latitude']);
    final double? dLng = _toDouble(body['driver_lng'] ?? driver['lng'] ?? driver['longitude']);
    if (dLat != null && dLng != null && _validLatLng(LatLng(dLat, dLng))) {
      out['driver_lat'] = dLat;
      out['driverLat'] = dLat;
      out['lat'] = dLat;
      out['driver_lng'] = dLng;
      out['driverLng'] = dLng;
      out['lng'] = dLng;
    } else {
      for (final String k in const <String>['driver_lat', 'driverLat', 'lat', 'driver_lng', 'driverLng', 'lng']) {
        if (_currentSnapshot.containsKey(k)) {
          out[k] = _currentSnapshot[k];
        } else {
          out.remove(k);
        }
      }
    }
    final double heading =
        _toDouble(body['driver_heading'] ?? driver['heading'] ?? driver['bearing']) ??
            (_toDouble(_currentSnapshot['driver_heading']) ?? 0.0);
    out['driver_heading'] = heading;
    out['driverHeading'] = heading;
    out['heading'] = heading;
    out['bearing'] = heading;

    if (_pickup != null) {
      out['pickup'] = <String, dynamic>{'lat': _pickup!.latitude, 'lng': _pickup!.longitude, 'text': _pickupText};
      out['pickup_lat'] = _pickup!.latitude;
      out['pickup_lng'] = _pickup!.longitude;
      out['pickup_text'] = _pickupText;
      out['rider_lat'] ??= _pickup!.latitude;
      out['rider_lng'] ??= _pickup!.longitude;
      out['user_lat'] ??= _pickup!.latitude;
      out['user_lng'] ??= _pickup!.longitude;
    }
    if (_destination != null) {
      out['destination'] = <String, dynamic>{
        'lat': _destination!.latitude,
        'lng': _destination!.longitude,
        'text': _destinationText,
      };
      out['destination_lat'] = _destination!.latitude;
      out['destination_lng'] = _destination!.longitude;
      out['destination_text'] = _destinationText;
    }
    if (ride.isNotEmpty) out['ride'] = ride;
    if (driver.isNotEmpty) out['driver'] = driver;
    out['ride_type'] = _s(ride['ride_type'] ?? body['ride_type'], _rideType);
    return out;
  }

  static BookingStatus _mapStatus(String raw) {
    switch (RideStatusCode.normalize(raw)) {
      case RideStatusCode.accepted:
        return BookingStatus.driverAssigned;
      case RideStatusCode.enroutePickup:
      case RideStatusCode.arrivedPickup:
        return BookingStatus.driverArriving;
      case RideStatusCode.inProgress:
      case RideStatusCode.arrivedDestination:
        return BookingStatus.onTrip;
      case RideStatusCode.completed:
        return BookingStatus.completed;
      case RideStatusCode.canceled:
      case RideStatusCode.idle:
        return BookingStatus.cancelled;
      case 'failed':
      case 'error':
        return BookingStatus.failed;
      default:
        return BookingStatus.searching;
    }
  }

  String _fingerprint(Map<String, dynamic> m) => <Object?>[
        m['status'],
        m['driver_id'],
        (_toDouble(m['driver_lat']) ?? 0).toStringAsFixed(6),
        (_toDouble(m['driver_lng']) ?? 0).toStringAsFixed(6),
        (_toDouble(m['driver_heading']) ?? 0).round(),
        m['ride'] is Map ? (m['ride'] as Map)['updated_at'] : null,
      ].join('|');

  void _emit(BookingStatus status, Map<String, dynamic> body, {BookingError? error, bool force = true}) {
    if (_disposed || _stream.isClosed) return;
    final Map<String, dynamic> normalized = _normalizePayload(body);
    if (error != null) {
      normalized['booking_status'] = BookingStatus.failed.toString();
      normalized['displayMessage'] = error.message;
      normalized['error_kind'] = error.kind.name;
      normalized['http_status'] = error.httpStatus;
      // Errors never overwrite the last known ride snapshot.
      _stream.add(BookingUpdate(status, normalized, error: error));
      return;
    }
    normalized.remove('error_kind');
    normalized.remove('http_status');
    normalized.remove('booking_status');
    final String fp = _fingerprint(normalized);
    _currentSnapshot = normalized;
    if (!force && fp == _lastFingerprint) return; // nothing changed -> no UI churn
    _lastFingerprint = fp;
    _stream.add(BookingUpdate(status, normalized));
  }

  void _emitFailure(_ApiException ex) {
    final BookingError err = ex.toBookingError();
    lastError = err;
    _emit(
      BookingStatus.failed,
      <String, dynamic>{'message': err.message},
      error: err,
    );
  }

  // ───────────────────────────── booking ─────────────────────────────────────

  /// Books [offer] with the given driver. Concurrent calls (double taps) share
  /// one request. Returns true once the server returned a ride id.
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
    String rideType = 'street_ride',
    String? instructions,
    double? tripKm,
  }) {
    final Future<bool>? inFlight = _bookingFuture;
    if (inFlight != null) return inFlight;
    final Future<bool> f = _createBookingImpl(
      offer: offer,
      pickup: pickup,
      destination: destination,
      pickupText: pickupText,
      destinationText: destinationText,
      stops: stops,
      payMethod: payMethod,
      userId: userId,
      driverId: driverId,
      rideType: rideType,
      instructions: instructions,
      tripKm: tripKm,
    ).whenComplete(() => _bookingFuture = null);
    _bookingFuture = f;
    return f;
  }

  Future<bool> _createBookingImpl({
    required RideOffer offer,
    required LatLng pickup,
    required LatLng destination,
    String? pickupText,
    String? destinationText,
    required List<LatLng> stops,
    required String payMethod,
    String? userId,
    String? driverId,
    required String rideType,
    String? instructions,
    double? tripKm,
  }) async {
    if (_disposed) return false;
    if (hasActiveRide) {
      lastError = const BookingError(
        kind: BookingErrorKind.validation,
        message: 'You already have an active ride.',
      );
      return false;
    }

    final String rider = _s(userId);
    final String driver = _s(driverId);
    final String pay = _s(payMethod, 'cash').toLowerCase();
    final List<LatLng> cleanStops = stops.where(_validLatLng).toList(growable: false);

    String? invalid;
    if (rider.isEmpty || rider == 'guest') {
      invalid = 'Please log in again to book a ride.';
    } else if (driver.isEmpty || int.tryParse(driver) == null || int.parse(driver) <= 0) {
      invalid = 'Please select an available driver.';
    } else if (!_validLatLng(pickup)) {
      invalid = 'Pickup location is missing.';
    } else if (!_validLatLng(destination)) {
      invalid = 'Destination is missing.';
    } else if (_haversineKm(pickup, destination) < 0.02 && cleanStops.isEmpty) {
      invalid = 'Pickup and destination are the same place.';
    } else if (pay != 'cash' && pay != 'wallet') {
      invalid = 'Unsupported payment method.';
    }
    if (invalid != null) {
      final BookingError err = BookingError(kind: BookingErrorKind.validation, message: invalid);
      lastError = err;
      _emit(BookingStatus.failed, <String, dynamic>{'message': invalid}, error: err);
      return false;
    }

    // Fresh ride context.
    _stopAll();
    _rideId = null;
    _pickup = pickup;
    _destination = destination;
    _stops = cleanStops;
    _pickupText = _s(pickupText);
    _destinationText = _s(destinationText);
    _riderId = rider;
    _driverId = driver;
    _rideType = _s(rideType, 'street_ride');
    _cancelRequestedDuringBooking = false;
    _lastFingerprint = '';
    _currentSnapshot = <String, dynamic>{
      'rider_id': rider,
      'user_id': rider,
      'uid': rider,
      'driver_id': driver,
      'status': RideStatusCode.searching,
      'phase': RideStatusCode.searching,
      'ride_status': RideStatusCode.searching,
    };

    final double km = (tripKm != null && tripKm.isFinite && tripKm > 0)
        ? tripKm
        : _routeKm(pickup, cleanStops, destination);
    final double total = (offer.estimatedTotal != null && offer.estimatedTotal! > 0)
        ? offer.estimatedTotal!
        : offer.price.toDouble();

    final String clientRequestId = _uuid.v4();
    final Map<String, String> payload = <String, String>{
      'client_request_id': clientRequestId,
      'rider_id': rider,
      'driver_id': driver,
      'offer_id': _s(offer.id),
      'provider': _s(offer.provider, 'PickMe'),
      'category': _s(offer.category, 'Standard'),
      'vehicle_type': _s(offer.vehicleType, 'car'),
      'currency': _s(offer.currency, 'NGN').toUpperCase(),
      'pay_method': pay,
      'ride_type': _rideType,
      'instructions': _s(instructions),
      'eta_min': math.max(0, offer.etaToPickupMin).toString(),
      'surge': offer.surge ? '1' : '0',
      if (offer.seats != null && offer.seats! > 0) 'seats': offer.seats.toString(),
      'price': total.toStringAsFixed(2),
      'estimated_total': total.toStringAsFixed(2),
      if (offer.baseFare != null && offer.baseFare! > 0) 'base_fare': offer.baseFare!.toStringAsFixed(2),
      if (offer.pricePerKm != null && offer.pricePerKm! > 0) 'price_per_km': offer.pricePerKm!.toStringAsFixed(2),
      'trip_km': km.toStringAsFixed(3),
      'pickup_lat': _coord(pickup.latitude),
      'pickup_lng': _coord(pickup.longitude),
      'pickup_text': _pickupText,
      'destination_lat': _coord(destination.latitude),
      'destination_lng': _coord(destination.longitude),
      'destination_text': _destinationText,
      'stops': cleanStops.map((LatLng e) => '${_coord(e.latitude)},${_coord(e.longitude)}').join('|'),
    };

    Map<String, dynamic>? body;
    _ApiException? failure;
    for (int attempt = 0; attempt < 2 && body == null; attempt++) {
      try {
        body = await _post(ApiConstants.rideBookEndpoint, payload);
        failure = null;
      } on _ApiException catch (ex) {
        failure = ex;
        if (!ex.isTransient || _disposed) break;
        // The request may have reached the server even though we got no
        // answer. Reconcile before retrying so we never create two rides.
        final Map<String, dynamic>? existing = await _findAdoptableRide(rider, driver);
        if (existing != null) {
          body = existing;
          failure = null;
          break;
        }
        if (ex.kind == BookingErrorKind.rateLimited) break;
        await Future<void>.delayed(Duration(milliseconds: 600 + _rng.nextInt(600)));
      }
    }

    if (_disposed) return false;
    if (body == null) {
      final _ApiException ex = failure ??
          const _ApiException(kind: BookingErrorKind.unknown, message: 'Booking failed. Please try again.');
      // ride_book.php answers 409 when the chosen driver is busy/offline.
      final _ApiException mapped = ex.kind == BookingErrorKind.conflict
          ? _ApiException(
              kind: BookingErrorKind.driverBusy,
              message: ex.message,
              httpStatus: ex.httpStatus,
              body: ex.body,
            )
          : ex;
      _emitFailure(mapped);
      return false;
    }

    final Map<String, dynamic> normalized = _normalizePayload(body);
    final String id = _s(normalized['ride_id']);
    if (id.isEmpty || id == '0') {
      _emitFailure(const _ApiException(
        kind: BookingErrorKind.noRideId,
        message: 'The booking could not be confirmed. Please check your ride history before trying again.',
      ));
      return false;
    }

    _rideId = id;
    lastError = null;
    _searchStartedAt = DateTime.now();
    _pinger?.start(() => pickup);
    _emit(_mapStatus(_s(normalized['status'], RideStatusCode.searching)), body);
    _startPolling();

    if (_cancelRequestedDuringBooking) {
      _cancelRequestedDuringBooking = false;
      unawaited(cancelBooking(reason: 'rider_cancelled'));
    }
    return true;
  }

  /// After a lost book response: returns the server's active `searching` ride
  /// for this rider + driver (created by our request), if any.
  Future<Map<String, dynamic>?> _findAdoptableRide(String rider, String driver) async {
    try {
      final Map<String, dynamic> body =
          await _post(ApiConstants.rideStatusEndpoint, <String, String>{'rider_id': rider});
      final Map<String, dynamic>? ride =
          body['ride'] is Map ? (body['ride'] as Map).cast<String, dynamic>() : null;
      if (ride == null) return null;
      final String status = RideStatusCode.normalize(ride['status'] ?? body['status']);
      if (status != RideStatusCode.searching) return null;
      if (_s(ride['driver_id']) != driver) return null;
      return body;
    } catch (_) {
      return null;
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
    String rideType = 'street_ride',
    String? instructions,
    double? tripKm,
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
      rideType: rideType,
      instructions: instructions,
      tripKm: tripKm,
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
    String rideType = 'street_ride',
    String? instructions,
    double? tripKm,
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
        rideType: rideType,
        instructions: instructions,
        tripKm: tripKm,
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
    String rideType = 'street_ride',
    String? instructions,
    double? tripKm,
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
        rideType: rideType,
        instructions: instructions,
        tripKm: tripKm,
      );

  // ───────────────────────────── resume / attach ─────────────────────────────

  /// Looks up the rider's current active ride on the server (used to resume
  /// after an app restart). Returns the raw ride_status payload or null.
  static Future<Map<String, dynamic>?> fetchActiveRide(ApiClient api, String riderId) async {
    final String rider = _s(riderId);
    if (rider.isEmpty || rider == 'guest') return null;
    try {
      final http.Response res = await api.request(
        ApiConstants.rideStatusEndpoint,
        method: 'POST',
        data: <String, String>{'rider_id': rider},
        retryCount: 1,
        idempotent: true, // read-only
        timeout: _requestTimeout,
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final Map<String, dynamic> body = _tryJsonBody(res.body);
      if (_isErrorFlag(body['error'])) return null;
      final dynamic ride = body['ride'];
      if (ride is! Map) return null;
      final String status = RideStatusCode.normalize(ride['status'] ?? body['status']);
      if (!RideStatusCode.active.contains(status)) return null;
      return body;
    } catch (_) {
      return null;
    }
  }

  /// Starts tracking an existing ride (e.g. one found by [fetchActiveRide] or
  /// booked through user_logistics.php). Emits the current state immediately
  /// when [initialPayload] is given, then polls.
  void attachToRide({
    required String rideId,
    String? riderId,
    String? driverId,
    String rideType = 'street_ride',
    LatLng? pickup,
    LatLng? destination,
    String? pickupText,
    String? destinationText,
    Map<String, dynamic>? initialPayload,
  }) {
    if (_disposed) return;
    final String id = _s(rideId);
    if (id.isEmpty) return;
    _stopAll();
    _rideId = id;
    _riderId = _s(riderId);
    _driverId = _s(driverId);
    _rideType = _s(rideType, 'street_ride');
    _stops = const <LatLng>[];
    _lastFingerprint = '';
    _searchStartedAt = DateTime.now();

    final Map<String, dynamic>? ride = initialPayload?['ride'] is Map
        ? (initialPayload!['ride'] as Map).cast<String, dynamic>()
        : null;
    LatLng? fromRide(String key) {
      final dynamic m = ride?[key];
      if (m is! Map) return null;
      final double? la = _toDouble(m['lat']);
      final double? lo = _toDouble(m['lng']);
      if (la == null || lo == null) return null;
      final LatLng p = LatLng(la, lo);
      return _validLatLng(p) ? p : null;
    }

    String textFromRide(String key) {
      final dynamic m = ride?[key];
      return m is Map ? _s(m['text']) : '';
    }

    _pickup = pickup ?? fromRide('pickup');
    _destination = destination ?? fromRide('destination');
    _pickupText = _s(pickupText, textFromRide('pickup'));
    _destinationText = _s(destinationText, textFromRide('destination'));
    if (ride != null) _rideType = _s(ride['ride_type'], _rideType);

    _currentSnapshot = <String, dynamic>{'status': RideStatusCode.searching, 'ride_id': id};
    if (initialPayload != null) {
      final Map<String, dynamic> n = _normalizePayload(initialPayload);
      _emit(_mapStatus(_s(n['status'])), initialPayload);
    }
    if (!RideStatusCode.isTerminal(_currentSnapshot['status'])) {
      _startPolling();
    }
  }

  /// Forces an immediate status refresh (e.g. pull-to-refresh).
  Future<void> refreshNow() async {
    if (!_polling) return;
    _pollTimer?.cancel();
    await _pollOnce();
  }

  // ───────────────────────────── trip actions ────────────────────────────────

  Future<bool> startTrip() {
    final Future<bool>? inFlight = _startFuture;
    if (inFlight != null) return inFlight;
    final Future<bool> f = _startTripImpl().whenComplete(() => _startFuture = null);
    _startFuture = f;
    return f;
  }

  Future<bool> _startTripImpl() async {
    final String id = _s(_rideId);
    if (id.isEmpty || _disposed) return false;
    final int gen = _generation;
    try {
      // NOTE: lat/lng are deliberately NOT sent: ride_start_trip.php treats
      // them as the DRIVER position (see report).
      final Map<String, String> payload = _rideContextPayload()
        ..['client_request_id'] = _uuid.v4();
      final Map<String, dynamic> body = await _post(ApiConstants.rideStartEndpoint, payload);
      if (gen != _generation || _disposed) return false;
      lastError = null;
      _emit(BookingStatus.onTrip, <String, dynamic>{...body, 'status': RideStatusCode.inProgress});
      _scheduleNextPoll(Duration.zero);
      return true;
    } on _ApiException catch (ex) {
      if (gen != _generation || _disposed) return false;
      _emitFailure(ex);
      _scheduleNextPoll(Duration.zero); // re-sync with the server's truth
      return false;
    }
  }

  Future<bool> startRide() => startTrip();
  Future<bool> commenceTrip() => startTrip();
  Future<bool> beginTrip() => startTrip();

  /// Cancels the current ride. Safe to call repeatedly, while a booking is in
  /// flight (the ride is cancelled as soon as it exists) and after a terminal
  /// state (returns true without a request).
  Future<bool> cancelBooking({String reason = ''}) {
    final Future<bool>? inFlight = _cancelFuture;
    if (inFlight != null) return inFlight;
    final Future<bool> f = _cancelImpl(reason).whenComplete(() => _cancelFuture = null);
    _cancelFuture = f;
    return f;
  }

  Future<bool> _cancelImpl(String reason) async {
    if (_disposed) return false;
    final String id = _s(_rideId);
    if (id.isEmpty) {
      if (_bookingFuture != null) {
        _cancelRequestedDuringBooking = true;
        return true;
      }
      return false;
    }
    final String current = RideStatusCode.normalize(_currentSnapshot['status']);
    if (current == RideStatusCode.canceled) return true;
    if (current == RideStatusCode.completed) {
      lastError = const BookingError(kind: BookingErrorKind.conflict, message: 'This ride is already completed.');
      return false;
    }

    // Freeze polling so a late poll cannot overwrite the cancellation.
    _pausePolling();
    final int gen = ++_generation;
    try {
      final Map<String, String> payload = _rideContextPayload()
        ..['reason'] = _s(reason, 'rider_cancelled')
        ..['client_request_id'] = _uuid.v4();
      final Map<String, dynamic> body = await _post(ApiConstants.rideCancelEndpoint, payload);
      if (gen != _generation || _disposed) return true;
      lastError = null;
      final Map<String, dynamic> merged = <String, dynamic>{...body};
      if (!RideStatusCode.isTerminal(body['status'] ?? (body['ride'] is Map ? body['ride']['status'] : null))) {
        merged['status'] = RideStatusCode.canceled;
      }
      final String serverStatus = RideStatusCode.normalize(merged['status']);
      _emit(_mapStatus(serverStatus), merged);
      _stopAll();
      return serverStatus == RideStatusCode.canceled;
    } on _ApiException catch (ex) {
      if (_disposed) return false;
      _emitFailure(ex);
      // The ride is still alive on the server (409 = it moved on, e.g.
      // completed; network = unknown). Resume tracking to show the truth.
      if (ex.kind != BookingErrorKind.sessionExpired && ex.kind != BookingErrorKind.forbidden) {
        _resumePolling();
      } else {
        _stopAll();
      }
      return false;
    }
  }

  Future<bool> cancelRide({String reason = ''}) => cancelBooking(reason: reason);
  Future<bool> cancelTrip({String reason = ''}) => cancelBooking(reason: reason);
  Future<bool> abortTrip({String reason = ''}) => cancelBooking(reason: reason);

  // ───────────────────────────── polling ─────────────────────────────────────

  void _startPolling() {
    _polling = true;
    _consecutiveFailures = 0;
    _failureReported = false;
    _ensureLifecycleListener();
    _scheduleNextPoll(const Duration(milliseconds: 400));
  }

  void _pausePolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _polling = false;
  }

  void _resumePolling() {
    if (_disposed || (_rideId ?? '').isEmpty) return;
    _polling = true;
    _generation++;
    _ensureLifecycleListener();
    _scheduleNextPoll(Duration.zero);
  }

  void _ensureLifecycleListener() {
    if (_lifecycle != null) return;
    try {
      _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    } catch (_) {
      // No WidgetsBinding (unit tests) - poll regardless of lifecycle.
    }
  }

  void _onLifecycle(AppLifecycleState state) {
    final bool bg = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (bg == _backgrounded) return;
    _backgrounded = bg;
    if (bg) {
      _pollTimer?.cancel();
      _pollTimer = null;
    } else if (_polling) {
      _scheduleNextPoll(Duration.zero);
    }
  }

  Duration _baseInterval() =>
      RideStatusCode.normalize(_currentSnapshot['status']) == RideStatusCode.searching
          ? _pollSearching
          : _pollActive;

  Duration _nextDelay({bool rateLimited = false, Duration? retryAfter}) {
    final Duration base = _baseInterval();
    if (_consecutiveFailures == 0 && !rateLimited) return base;
    final int exp = math.min(_consecutiveFailures, 4);
    int ms = base.inMilliseconds * (1 << exp);
    if (rateLimited) ms = math.max(ms, retryAfter?.inMilliseconds ?? 15000);
    ms = math.min(ms, _maxBackoff.inMilliseconds);
    final int jitter = (ms * 0.3 * _rng.nextDouble()).round();
    return Duration(milliseconds: ms + jitter);
  }

  void _scheduleNextPoll([Duration? delay]) {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_polling || _disposed || _backgrounded) return;
    _pollTimer = Timer(delay ?? _nextDelay(), () {
      _pollTimer = null;
      _pollOnce();
    });
  }

  Future<void> _pollOnce() async {
    final String id = _s(_rideId);
    if (id.isEmpty || _disposed || !_polling || _pollInFlight) return;
    _pollInFlight = true;
    final int gen = _generation;
    bool rateLimited = false;
    Duration? retryAfter;
    try {
      final Map<String, dynamic> body = await _post(ApiConstants.rideStatusEndpoint, _rideContextPayload());
      if (gen != _generation || _disposed || !_polling) return;
      _consecutiveFailures = 0;
      _failureReported = false;
      lastError = null;

      final bool missing = body['ride'] == null && RideStatusCode.normalize(body['status']) == RideStatusCode.idle;
      if (missing) {
        _emit(BookingStatus.cancelled, <String, dynamic>{
          ...body,
          'status': RideStatusCode.canceled,
          'displayMessage': 'This ride is no longer available.',
        });
        _stopAll();
        return;
      }

      final Map<String, dynamic> normalized = _normalizePayload(body);
      final String status = _s(normalized['status'], RideStatusCode.searching);
      final BookingStatus mapped = _mapStatus(status);
      _emit(mapped, body, force: false);

      if (mapped == BookingStatus.completed || mapped == BookingStatus.cancelled) {
        _stopAll();
        return;
      }
      if (status == RideStatusCode.searching) {
        final DateTime? started = _searchStartedAt;
        if (started != null && DateTime.now().difference(started) > searchTimeout) {
          unawaited(_expireSearch());
          return;
        }
      } else {
        _searchStartedAt = null;
      }
    } on _ApiException catch (ex) {
      if (gen != _generation || _disposed) return;
      if (ex.kind == BookingErrorKind.sessionExpired || ex.kind == BookingErrorKind.forbidden) {
        _emitFailure(ex);
        _stopAll();
        return;
      }
      if (ex.kind == BookingErrorKind.notFound) {
        _emit(BookingStatus.cancelled, <String, dynamic>{
          'status': RideStatusCode.canceled,
          'displayMessage': 'This ride is no longer available.',
        });
        _stopAll();
        return;
      }
      rateLimited = ex.kind == BookingErrorKind.rateLimited;
      retryAfter = ex.retryAfter;
      _consecutiveFailures++;
      lastError = ex.toBookingError();
      // Report a connectivity problem once per outage, not on every tick.
      if (_consecutiveFailures >= _failuresBeforeReport && !_failureReported) {
        _failureReported = true;
        _emitFailure(ex);
      }
    } finally {
      _pollInFlight = false;
      if (gen == _generation && _polling && !_disposed) {
        _scheduleNextPoll(_nextDelay(rateLimited: rateLimited, retryAfter: retryAfter));
      }
    }
  }

  Future<void> _expireSearch() async {
    _pausePolling();
    final int gen = ++_generation;
    try {
      final Map<String, String> payload = _rideContextPayload()
        ..['reason'] = 'no_driver_found'
        ..['client_request_id'] = _uuid.v4();
      await _post(ApiConstants.rideCancelEndpoint, payload);
      if (gen != _generation || _disposed) return;
      lastError = const BookingError(
        kind: BookingErrorKind.timeout,
        message: 'No driver accepted your request. Please try another driver.',
      );
      _emit(BookingStatus.cancelled, <String, dynamic>{
        'status': RideStatusCode.canceled,
        'cancel_reason': 'no_driver_found',
        'displayMessage': 'No driver accepted your request. Please try another driver.',
      });
      _stopAll();
    } on _ApiException {
      // 409 = a driver accepted at the last second; anything else = retry
      // tracking. Either way the next poll shows the truth.
      if (gen != _generation || _disposed) return;
      _searchStartedAt = DateTime.now();
      _resumePolling();
    }
  }

  void _stopAll() {
    _generation++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _polling = false;
    _pinger?.stop();
    _lifecycle?.dispose();
    _lifecycle = null;
    _backgrounded = false;
  }
}
