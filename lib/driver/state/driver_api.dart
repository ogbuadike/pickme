// lib/driver/state/driver_api.dart
//
// Typed client for backend/endpoint/driver_hub.php. Every driver request goes
// through [DriverHubApi.call], so error-envelope parsing (docs/SECURITY_CONTRACT.md
// section 4), timeouts and 409/429 handling live in exactly one place.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, SocketException;

import 'package:http/http.dart' as http;

import '../../api/api_client.dart';
import 'driver_models.dart';

/// Error codes from the contract envelope plus client-side transport codes.
class DriverApiCode {
  static const conflict = 'CONFLICT';
  static const rateLimited = 'RATE_LIMITED';
  static const unauthorized = 'UNAUTHORIZED';
  static const sessionExpired = 'SESSION_EXPIRED';
  static const forbidden = 'FORBIDDEN';
  static const validation = 'VALIDATION';
  static const server = 'SERVER';

  /// HTTP 200 with `error: true` (legacy business-rule rejection).
  static const rejected = 'REJECTED';
  static const network = 'NETWORK';
  static const timeout = 'TIMEOUT';
}

class DriverApiException implements Exception {
  final String code;
  final String message;
  final int? statusCode;
  final Duration? retryAfter;

  const DriverApiException(this.code, this.message, {this.statusCode, this.retryAfter});

  bool get isConflict => code == DriverApiCode.conflict;
  bool get isRateLimited => code == DriverApiCode.rateLimited;
  bool get isAuth => code == DriverApiCode.unauthorized || code == DriverApiCode.sessionExpired;

  /// The request may not have reached the server or its result is unknown:
  /// safe to retry / reconcile with a fresh dashboard read.
  bool get isTransient =>
      code == DriverApiCode.network || code == DriverApiCode.timeout || code == DriverApiCode.server || isRateLimited;

  @override
  String toString() => message;
}

/// A local precondition failed; nothing was sent to the server.
class DriverActionRejected implements Exception {
  final String message;
  const DriverActionRejected(this.message);
  @override
  String toString() => message;
}

class DriverDashboard {
  final DriverProfile driver;
  final RideJob? activeRide;
  final List<RideJob> queue;

  const DriverDashboard({required this.driver, required this.activeRide, required this.queue});

  factory DriverDashboard.fromData(Map<String, dynamic> data) {
    final rawDriver = data['driver'];
    if (rawDriver is! Map) {
      throw const DriverApiException(DriverApiCode.server, 'Dashboard payload missing driver.');
    }
    final rawActive = data['active_ride'];
    final rawQueue = data['queue'];
    return DriverDashboard(
      driver: DriverProfile.fromJson(rawDriver),
      activeRide: rawActive is Map ? RideJob.fromJson(rawActive) : null,
      queue: rawQueue is List
          ? rawQueue.whereType<Map>().map(RideJob.fromJson).where((r) => r.id > 0).toList(growable: false)
          : const <RideJob>[],
    );
  }
}

/// Coordinates the server needs with GPS-validated requests.
class DriverGpsPayload {
  final double lat;
  final double lng;
  final double heading;
  final double speed;
  final double accuracy;

  const DriverGpsPayload({required this.lat, required this.lng, required this.heading, required this.speed, required this.accuracy});

  Map<String, String> toParams() => {
        'lat': lat.toStringAsFixed(7),
        'lng': lng.toStringAsFixed(7),
        'heading': heading.toStringAsFixed(1),
        'speed': speed.toStringAsFixed(2),
        'accuracy': accuracy.toStringAsFixed(1),
      };
}

class DriverHubApi {
  static const String endpoint = 'driver_hub.php';

  final ApiClient _api;
  final String Function() _userId;

  DriverHubApi(this._api, this._userId);

  /// Sends one driver_hub action and returns the decoded `data` object.
  ///
  /// The server still requires `user` (driver_hub.php `requirePosted('user')`).
  /// Once it derives identity from `X-Session-Token` the param is harmless:
  /// it always equals the session user.
  Future<Map<String, dynamic>> call(
    String action, {
    Map<String, String> params = const {},
    Duration timeout = const Duration(seconds: 12),
    String? idempotencyKey,
  }) async {
    final uid = _userId().trim();
    if (uid.isEmpty) {
      throw const DriverApiException(DriverApiCode.unauthorized, 'Your session has ended. Please sign in again.');
    }
    final data = <String, String>{'action': action, 'user': uid, ...params};

    final http.Response res;
    try {
      res = await _api.request(
        endpoint,
        method: 'POST',
        data: data,
        // Mutations carry an Idempotency-Key so the transport may safely retry
        // them once; reads/heartbeats are re-driven by their own schedulers.
        headers: idempotencyKey == null ? null : {'Idempotency-Key': idempotencyKey},
        idempotent: idempotencyKey != null,
        retryCount: idempotencyKey == null ? 0 : 1,
        timeout: timeout,
      );
    } on ApiException catch (e) {
      throw _fromApiException(e);
    } on TimeoutException {
      throw const DriverApiException(DriverApiCode.timeout, 'The server took too long to respond.');
    } on HttpException catch (e) {
      throw _fromHttpError(e.message);
    } on SocketException {
      throw const DriverApiException(DriverApiCode.network, 'No internet connection.');
    } on DriverApiException {
      rethrow;
    } catch (_) {
      throw const DriverApiException(DriverApiCode.network, 'Network error. Check your connection.');
    }
    return _decode(res.statusCode, res.body);
  }

  Future<DriverDashboard> dashboard() async =>
      DriverDashboard.fromData(await call('dashboard', timeout: const Duration(seconds: 10)));

  Future<Map<String, dynamic>> setOnline(bool online, {DriverGpsPayload? gps}) =>
      call('set_online', params: {'is_online': online ? '1' : '0', ...?gps?.toParams()});

  Future<Map<String, dynamic>> heartbeat(DriverGpsPayload gps, {required String phase}) =>
      call('heartbeat', params: {...gps.toParams(), 'phase': phase}, timeout: const Duration(seconds: 8));

  Future<Map<String, dynamic>> acceptRide(int rideId, {required String requestId}) =>
      call('accept_ride', params: {'ride_id': '$rideId', 'request_id': requestId}, idempotencyKey: requestId);

  Future<Map<String, dynamic>> rideAction(int rideId, DriverRideAction action,
          {DriverGpsPayload? gps, required String requestId}) =>
      call('ride_action', params: {
        'ride_id': '$rideId',
        'ride_action': action.wire,
        'request_id': requestId,
        ...?gps?.toParams(),
      }, idempotencyKey: requestId);

  Future<Map<String, dynamic>> verifyDeliveryOtp(int rideId, String otp) =>
      call('verify_otp', params: {'ride_id': '$rideId', 'otp': otp});

  // ---------------------------------------------------------------------------

  static DriverApiException _fromApiException(ApiException e) {
    var code = e.serverCodeRaw?.trim().toUpperCase();
    if (code == null || code.isEmpty) code = e.code.wire;
    if (code == ApiErrorCode.unknown.wire) code = _codeForStatus(e.statusCode);
    final message = e.message.trim().isNotEmpty ? e.message.trim() : _messageForStatus(e.statusCode);
    if (code == DriverApiCode.server || code == DriverApiCode.validation) {
      if (_legacyConflict(message)) code = DriverApiCode.conflict;
    }
    var retryAfter = e.retryAfter;
    if (code == DriverApiCode.rateLimited) retryAfter ??= const Duration(seconds: 15);
    return DriverApiException(code, message, statusCode: e.statusCode, retryAfter: retryAfter);
  }

  static Map<String, dynamic> _decode(int status, String body) {
    final dynamic json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      throw DriverApiException(DriverApiCode.server, 'Unexpected server response.', statusCode: status);
    }
    if (json is! Map) {
      throw DriverApiException(DriverApiCode.server, 'Unexpected server response.', statusCode: status);
    }
    if (json['error'] == true || json['error'] == 1 || json['error'] == '1') {
      throw _fromEnvelope(status, json);
    }
    final data = json['data'];
    final out = <String, dynamic>{
      if (data is Map) ...data.map((k, v) => MapEntry(k.toString(), v)),
    };
    final message = json['message'];
    if (message != null) out.putIfAbsent('message', () => message.toString());
    return out;
  }

  /// `ApiClient.request` throws `HttpException('Error <status>: <body>')` for
  /// every non-2xx response.
  static DriverApiException _fromHttpError(String raw) {
    final match = RegExp(r'Error (\d{3}):\s*(.*)', dotAll: true).firstMatch(raw);
    final status = match == null ? null : int.tryParse(match.group(1)!);
    final body = match?.group(2) ?? '';
    Map? envelope;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) envelope = decoded;
    } catch (_) {}
    if (envelope != null) return _fromEnvelope(status ?? 0, envelope);
    return DriverApiException(_codeForStatus(status), _messageForStatus(status), statusCode: status);
  }

  static DriverApiException _fromEnvelope(int status, Map envelope) {
    final message = (envelope['message'] ?? envelope['error_msg'] ?? '').toString().trim();
    var code = (envelope['code'] ?? '').toString().trim().toUpperCase();
    if (code.isEmpty) code = status >= 400 ? _codeForStatus(status) : DriverApiCode.rejected;
    if (code == DriverApiCode.rejected && _legacyConflict(message)) code = DriverApiCode.conflict;

    Duration? retryAfter;
    final ra = num.tryParse('${envelope['retry_after'] ?? ''}');
    if (ra != null && ra > 0) retryAfter = Duration(milliseconds: (ra * 1000).round());
    if (code == DriverApiCode.rateLimited) retryAfter ??= const Duration(seconds: 15);

    return DriverApiException(
      code,
      message.isNotEmpty ? message : _messageForStatus(status),
      statusCode: status == 0 ? null : status,
      retryAfter: retryAfter,
    );
  }

  /// Until the backend returns 409 CONFLICT, recognise the legacy messages that
  /// `acceptRide()` throws when another driver won the race.
  static bool _legacyConflict(String message) {
    final m = message.toLowerCase();
    return m.contains('already moved beyond queue') ||
        m.contains('assigned to another driver') ||
        m.contains('no longer exists');
  }

  static String _codeForStatus(int? status) {
    switch (status) {
      case 401:
        return DriverApiCode.unauthorized;
      case 403:
        return DriverApiCode.forbidden;
      case 409:
        return DriverApiCode.conflict;
      case 422:
      case 400:
        return DriverApiCode.validation;
      case 429:
        return DriverApiCode.rateLimited;
      default:
        return DriverApiCode.server;
    }
  }

  static String _messageForStatus(int? status) {
    switch (status) {
      case 401:
        return 'Your session has ended. Please sign in again.';
      case 403:
        return 'You are not allowed to do that.';
      case 409:
        return 'This ride was just taken by another driver.';
      case 429:
        return 'Too many requests. Retrying shortly.';
      default:
        return 'Server error. Please try again.';
    }
  }
}
