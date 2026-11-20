// lib/services/logistics_service.dart
//
// Single model + service for the two parcel products that share
// user_logistics.php:
//   * Send Me  (ride_type = send_me)  - errand with free-text instructions.
//   * Dispatch (ride_type = dispatch) - parcel with recipient phone, size,
//                                       weight and a mandatory photo.
//
// Both get a 4-digit delivery PIN (delivery_otp) the driver must collect at
// the destination. Tracking after booking goes through BookingController
// (ride_status.php / ride_cancel_booking.php), like every other ride.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../api/url.dart';

enum LogisticsKind { sendMe, dispatch }

extension LogisticsKindX on LogisticsKind {
  /// `ride_type` on the wire.
  String get wire => this == LogisticsKind.dispatch ? 'dispatch' : 'send_me';
  bool get isDispatch => this == LogisticsKind.dispatch;
  String get productName => isDispatch ? 'Dispatch' : 'Send Me';
  Color get brandColor => isDispatch ? const Color(0xFFFFA000) : const Color(0xFF2979FF);
  Color get onBrandColor => isDispatch ? Colors.black : Colors.white;
  IconData get icon => isDispatch ? Icons.local_shipping_rounded : Icons.shopping_cart_checkout_rounded;

  static LogisticsKind? tryParse(Object? raw) {
    switch ((raw ?? '').toString().trim().toLowerCase()) {
      case 'send_me':
        return LogisticsKind.sendMe;
      case 'dispatch':
        return LogisticsKind.dispatch;
      default:
        return null;
    }
  }
}

/// Parcel classes understood by user_logistics.php (`package_size`).
enum PackageSize { envelope, box, heavy }

extension PackageSizeX on PackageSize {
  String get wire => name; // envelope | box | heavy
  String get label => const <String>['Envelope', 'Medium Box', 'Heavy Freight'][index];
  IconData get icon => const <IconData>[
        Icons.mail_outline_rounded,
        Icons.inventory_2_outlined,
        Icons.widgets_outlined,
      ][index];

  /// Allowed weight range (kg) and slider step for this class.
  double get minKg => const <double>[0.1, 1, 10][index];
  double get maxKg => const <double>[2, 30, 500][index];
  double get defaultKg => const <double>[0.5, 5, 50][index];
  double get stepKg => const <double>[0.1, 0.5, 5][index];
  int get divisions => ((maxKg - minKg) / stepKg).round();
}

/// Nigerian mobile numbers: accepts `0803…`, `803…`, `234803…`, `+234 803 …`.
/// Returns E.164 (`+234XXXXXXXXXX`) or null when invalid.
String? normalizeNigerianPhone(String input) {
  String d = input.replaceAll(RegExp(r'[\s\-().]'), '');
  if (d.startsWith('+')) d = d.substring(1);
  if (!RegExp(r'^\d+$').hasMatch(d)) return null;
  if (d.startsWith('234')) d = d.substring(3);
  if (d.startsWith('0')) d = d.substring(1);
  // Mobile prefixes 70x, 80x, 81x, 90x, 91x (10 digits after the 0).
  if (d.length != 10 || !RegExp(r'^[789][01]\d{8}$').hasMatch(d)) return null;
  return '+234$d';
}

class LogisticsException implements Exception {
  final String message;
  final bool retryable;
  const LogisticsException(this.message, {this.retryable = false});
  @override
  String toString() => message;
}

@immutable
class LogisticsBookingRequest {
  final LogisticsKind kind;
  final String userId;
  final LatLng pickup;
  final String pickupText;
  final LatLng destination;
  final String destinationText;
  final double distanceKm;
  final String payMethod; // cash | wallet
  // Send Me
  final String instructions;
  // Dispatch
  final String recipientPhone; // E.164
  final PackageSize packageSize;
  final double weightKg;
  final File? packageImage;

  const LogisticsBookingRequest({
    required this.kind,
    required this.userId,
    required this.pickup,
    required this.pickupText,
    required this.destination,
    required this.destinationText,
    required this.distanceKm,
    this.payMethod = 'cash',
    this.instructions = '',
    this.recipientPhone = '',
    this.packageSize = PackageSize.envelope,
    this.weightKg = 1,
    this.packageImage,
  });

  /// Returns a user-facing problem, or null when the request is valid.
  String? validate() {
    if (userId.trim().isEmpty || userId == 'guest') return 'Please log in again.';
    bool bad(LatLng p) => !p.latitude.isFinite || !p.longitude.isFinite || (p.latitude == 0 && p.longitude == 0);
    if (bad(pickup)) return 'Choose a pickup location.';
    if (bad(destination)) return 'Choose a drop-off location.';
    if (!distanceKm.isFinite || distanceKm <= 0.02) return 'Pickup and drop-off are the same place.';
    if (distanceKm > 300) return 'Deliveries are limited to 300 km.';
    if (payMethod != 'cash' && payMethod != 'wallet') return 'Choose a payment method.';
    if (kind.isDispatch) {
      if (normalizeNigerianPhone(recipientPhone) == null) {
        return 'Enter a valid Nigerian mobile number for the recipient.';
      }
      if (packageImage == null) return 'Please snap a photo of the package.';
      if (!weightKg.isFinite || weightKg < packageSize.minKg || weightKg > packageSize.maxKg) {
        return 'Weight must be between ${packageSize.minKg} and ${packageSize.maxKg} kg for ${packageSize.label}.';
      }
    } else {
      final String t = instructions.trim();
      if (t.length < 5) return 'Tell the rider what to do (at least a few words).';
      if (t.length > 500) return 'Instructions are too long (max 500 characters).';
    }
    return null;
  }
}

@immutable
class LogisticsBooking {
  final String rideId;
  final String deliveryOtp; // may be empty if the response was lost
  final LogisticsKind kind;
  const LogisticsBooking({required this.rideId, required this.deliveryOtp, required this.kind});
}

class LogisticsService {
  final ApiClient api;
  LogisticsService(this.api);

  static const Duration _timeout = Duration(seconds: 20);
  static const Uuid _uuid = Uuid();

  static Map<String, dynamic> _decode(String body) {
    try {
      final dynamic j = jsonDecode(body);
      if (j is Map<String, dynamic>) return j;
      if (j is Map) return j.cast<String, dynamic>();
    } catch (_) {}
    return const <String, dynamic>{};
  }

  static bool _isErr(dynamic v) => v == true || v == 1 || v == '1' || v == 'true';

  static LogisticsException _mapError(Object e) {
    if (e is LogisticsException) return e;
    if (e is ApiException) {
      final bool retry = e.isRateLimited || e.statusCode >= 500;
      return LogisticsException(e.message.isNotEmpty ? e.message : 'Request failed.', retryable: retry);
    }
    if (e is TimeoutException || e is SocketException || e is http.ClientException) {
      return const LogisticsException('Network problem. Check your connection and try again.', retryable: true);
    }
    return const LogisticsException('Something went wrong. Please try again.', retryable: true);
  }

  /// Server-side price quote. Throws [LogisticsException].
  Future<double> estimate({
    required LogisticsKind kind,
    required String userId,
    required double distanceKm,
    PackageSize packageSize = PackageSize.envelope,
    double weightKg = 0,
  }) async {
    try {
      final http.Response res = await api.request(
        ApiConstants.sendMeDispatchEndpoint,
        method: 'POST',
        data: <String, String>{
          'action': 'estimate_delivery',
          'user': userId,
          'ride_type': kind.wire,
          'package_size': packageSize.wire,
          'weight_kg': weightKg.toStringAsFixed(1),
          'distance_km': distanceKm.toStringAsFixed(2),
        },
        idempotent: true, // pure quote
        timeout: _timeout,
      );
      final Map<String, dynamic> body = _decode(res.body);
      final dynamic data = body['data'];
      final double? price = data is Map ? double.tryParse('${data['estimated_price']}') : null;
      if (_isErr(body['error']) || price == null || !price.isFinite || price <= 0) {
        throw LogisticsException((body['message'] ?? 'Could not get a price.').toString(), retryable: true);
      }
      return price;
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// Books the delivery. Never auto-retried (the endpoint does not
  /// de-duplicate yet); a lost response is reconciled via [findRecentBooking].
  Future<LogisticsBooking> book(LogisticsBookingRequest r) async {
    final String? invalid = r.validate();
    if (invalid != null) throw LogisticsException(invalid);

    final String clientRequestId = _uuid.v4();
    final Map<String, String> data = <String, String>{
      'action': 'book_service',
      'client_request_id': clientRequestId,
      'user': r.userId,
      'ride_type': r.kind.wire,
      'pickup_lat': r.pickup.latitude.toStringAsFixed(7),
      'pickup_lng': r.pickup.longitude.toStringAsFixed(7),
      'pickup_text': r.pickupText.trim(),
      'dest_lat': r.destination.latitude.toStringAsFixed(7),
      'dest_lng': r.destination.longitude.toStringAsFixed(7),
      'dest_text': r.destinationText.trim(),
      'distance_km': r.distanceKm.toStringAsFixed(2),
      'pay_method': r.payMethod,
    };
    if (r.kind.isDispatch) {
      data['recipient_phone'] = normalizeNigerianPhone(r.recipientPhone)!;
      data['package_size'] = r.packageSize.wire;
      data['weight_kg'] = r.weightKg.toStringAsFixed(1);
    } else {
      data['instructions'] = r.instructions.trim();
    }

    try {
      final http.Response res = await api.request(
        ApiConstants.sendMeDispatchEndpoint,
        method: 'POST',
        data: data,
        files: r.kind.isDispatch ? <String, File>{'package_image': r.packageImage!} : null,
        retryCount: 0,
        headers: <String, String>{'Idempotency-Key': clientRequestId},
      );
      final Map<String, dynamic> body = _decode(res.body);
      final dynamic d = body['data'];
      final String rideId = d is Map ? (d['ride_id'] ?? '').toString() : '';
      if (_isErr(body['error']) || rideId.isEmpty || rideId == '0') {
        throw LogisticsException((body['message'] ?? 'Booking failed. Please try again.').toString());
      }
      return LogisticsBooking(
        rideId: rideId,
        deliveryOtp: d is Map ? (d['delivery_otp'] ?? '').toString() : '',
        kind: r.kind,
      );
    } catch (e) {
      final LogisticsException ex = _mapError(e);
      if (!ex.retryable) throw ex;
      // The request may have been processed. Look for it before the user
      // retries so they do not pay twice.
      final LogisticsBooking? existing = await findRecentBooking(
        userId: r.userId,
        kind: r.kind,
        pickup: r.pickup,
        destination: r.destination,
      );
      if (existing != null) return existing;
      throw ex;
    }
  }

  static double _metersBetween(LatLng a, LatLng b) {
    const double r = 6371000.0;
    double rad(double x) => x * math.pi / 180;
    final double dLat = rad(b.latitude - a.latitude);
    final double dLng = rad(b.longitude - a.longitude);
    final double h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(a.latitude)) * math.cos(rad(b.latitude)) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
  }

  /// Latest rides of the user (ride_history.php), newest first.
  Future<List<Map<String, dynamic>>> recentRides(String userId, {int limit = 10}) async {
    final http.Response res = await api.request(
      ApiConstants.rideHistoryEndpoint,
      method: 'POST',
      data: <String, String>{'user_id': userId, 'role': 'rider', 'limit': '$limit'},
      idempotent: true,
      timeout: _timeout,
    );
    final Map<String, dynamic> body = _decode(res.body);
    if (_isErr(body['error']) || body['data'] is! List) return const <Map<String, dynamic>>[];
    return (body['data'] as List).whereType<Map>().map((Map m) => m.cast<String, dynamic>()).toList();
  }

  /// Finds a still-searching booking of [kind] matching this route (used to
  /// recover from a lost book response).
  Future<LogisticsBooking?> findRecentBooking({
    required String userId,
    required LogisticsKind kind,
    required LatLng pickup,
    required LatLng destination,
  }) async {
    try {
      final List<Map<String, dynamic>> rides = await recentRides(userId, limit: 5);
      for (final Map<String, dynamic> m in rides) {
        if (LogisticsKindX.tryParse(m['ride_type']) != kind) continue;
        if ((m['status'] ?? '').toString().toLowerCase() != 'searching') continue;
        final LatLng p = LatLng(double.tryParse('${m['pickup_lat']}') ?? 0, double.tryParse('${m['pickup_lng']}') ?? 0);
        final LatLng q = LatLng(double.tryParse('${m['dest_lat']}') ?? 0, double.tryParse('${m['dest_lng']}') ?? 0);
        if (_metersBetween(p, pickup) > 30 || _metersBetween(q, destination) > 30) continue;
        return LogisticsBooking(
          rideId: '${m['id']}',
          deliveryOtp: (m['delivery_otp'] ?? '').toString(),
          kind: kind,
        );
      }
    } catch (_) {}
    return null;
  }

  /// Full history row for one ride (delivery PIN, driver phone, recipient...).
  Future<Map<String, dynamic>?> rideDetails(String userId, String rideId) async {
    try {
      final List<Map<String, dynamic>> rides = await recentRides(userId, limit: 20);
      for (final Map<String, dynamic> m in rides) {
        if ('${m['id']}' == rideId) return m;
      }
    } catch (_) {}
    return null;
  }
}
