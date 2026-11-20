import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pickme/api/api_client.dart';
import 'package:pickme/services/booking_controller.dart';
import 'package:pickme/services/logistics_service.dart';
import 'package:pickme/services/ride_market_service.dart';
import 'package:pickme/widgets/ride_market/money.dart';
import 'package:pickme/widgets/ride_market/ride_nearby_driver.dart';

typedef _Handler = FutureOr<http.Response> Function(http.Request req);

ApiClient _client(_Handler handler, List<http.Request> log) {
  final ApiTransport t = ApiTransport(
    httpClient: MockClient((http.Request req) async {
      log.add(req);
      return handler(req);
    }),
    sessionStore: InMemorySessionStore(Session(token: 'a' * 64, expiresAt: DateTime.utc(2030))),
    clientVersion: () async => '1.0.0+1',
    clientPlatform: 'android',
    random: math.Random(1),
    sleep: (Duration d) async {},
  );
  return ApiClient.withTransport(t);
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: <String, String>{'content-type': 'application/json'});

Map<String, dynamic> _ridePayload(String status, {String id = '77', String driverId = '5'}) => <String, dynamic>{
      'error': false,
      'ride_id': id,
      'status': status,
      'driver_lat': 6.5,
      'driver_lng': 3.3,
      'driver_heading': 90,
      'ride': <String, dynamic>{
        'id': id,
        'rider_id': 'u1',
        'driver_id': driverId,
        'status': status,
        'ride_type': 'street_ride',
        'pickup': <String, dynamic>{'lat': 6.45, 'lng': 3.39, 'text': 'A'},
        'destination': <String, dynamic>{'lat': 6.6, 'lng': 3.35, 'text': 'B'},
      },
      'driver': <String, dynamic>{'id': driverId, 'name': 'Ada', 'lat': 6.5, 'lng': 3.3, 'heading': 90},
    };

const RideOffer _offer = RideOffer(
  id: 'driver-5',
  provider: 'PickMe',
  category: 'Standard',
  etaToPickupMin: 3,
  price: 2500,
  surge: false,
  estimatedTotal: 2500,
  pricePerKm: 150,
  baseFare: 500,
  vehicleType: 'car',
);

String _endpoint(http.Request r) => r.url.pathSegments.last;

void main() {
  const Timeout to = Timeout(Duration(seconds: 60));
  group('RideStatusCode', () {
    test('normalizes backend aliases', () {
      expect(RideStatusCode.normalize('cancelled'), RideStatusCode.canceled);
      expect(RideStatusCode.normalize('driver_assigned'), RideStatusCode.accepted);
      expect(RideStatusCode.normalize('in_ride'), RideStatusCode.inProgress);
      expect(RideStatusCode.isTerminal('cancelled'), isTrue);
      expect(RideStatusCode.isActive('arrived_destination'), isTrue);
      expect(RideStatusCode.isActive('idle'), isFalse);
    });
  });

  group('BookingController', () {
    testWidgets('double tap books once, then tracks until completed', timeout: to, (WidgetTester tester) async {
      final List<http.Request> log = <http.Request>[];
      int statusCalls = 0;
      final ApiClient api = _client((http.Request r) {
        switch (_endpoint(r)) {
          case 'ride_book.php':
            return _json(_ridePayload('searching'));
          case 'ride_status.php':
            statusCalls++;
            return _json(_ridePayload(statusCalls < 2 ? 'accepted' : 'completed'));
          default:
            return _json(<String, dynamic>{'error': true}, 404);
        }
      }, log);
      final BookingController c = BookingController(api);
      final List<BookingStatus> seen = <BookingStatus>[];
      final StreamSubscription<BookingUpdate> sub = c.updates.listen((BookingUpdate u) => seen.add(u.status));

      Future<bool> book() => c.createBooking(
            offer: _offer,
            pickup: const LatLng(6.45, 3.39),
            destination: const LatLng(6.6, 3.35),
            userId: 'u1',
            driverId: '5',
          );
      final List<bool> results = await Future.wait(<Future<bool>>[book(), book()]);
      expect(results, <bool>[true, true]);
      final List<http.Request> books = log.where((http.Request r) => _endpoint(r) == 'ride_book.php').toList();
      expect(books, hasLength(1), reason: 'double tap must not create two rides');
      expect(books.single.bodyFields['client_request_id'], isNotEmpty);
      expect(books.single.headers['Idempotency-Key'], books.single.bodyFields['client_request_id']);
      expect(books.single.bodyFields['pickup_lat'], startsWith('6.45'));
      expect(books.single.bodyFields['estimated_total'], '2500.00');
      await tester.pump(const Duration(seconds: 1)); // first poll -> accepted
      await tester.pump(const Duration(seconds: 3)); // second poll -> completed
      expect(seen, containsAllInOrder(<BookingStatus>[
        BookingStatus.searching,
        BookingStatus.driverAssigned,
        BookingStatus.completed,
      ]));
      final int callsAtEnd = statusCalls;
      await tester.pump(const Duration(seconds: 30));
      expect(statusCalls, callsAtEnd, reason: 'polling stops on a terminal status');
      // Not awaited: a broadcast cancel future never completes inside the
      // fake-async zone of testWidgets.
      unawaited(sub.cancel());
      c.dispose();
    });

    testWidgets('lost book response is reconciled instead of re-booking', (WidgetTester tester) async {
      final List<http.Request> log = <http.Request>[];
      final ApiClient api = _client((http.Request r) {
        if (_endpoint(r) == 'ride_book.php') throw const SocketException('Connection reset by peer');
        if (_endpoint(r) == 'ride_status.php' && !r.bodyFields.containsKey('ride_id')) {
          return _json(_ridePayload('searching', id: '91'));
        }
        return _json(_ridePayload('searching', id: '91'));
      }, log);
      final BookingController c = BookingController(api);
      final bool ok = await c.createBooking(
        offer: _offer,
        pickup: const LatLng(6.45, 3.39),
        destination: const LatLng(6.6, 3.35),
        userId: 'u1',
        driverId: '5',
      );
      expect(ok, isTrue);
      expect(c.rideId, '91');
      expect(log.where((http.Request r) => _endpoint(r) == 'ride_book.php'), hasLength(1));
      c.dispose();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('cancel wins over a late searching poll; 409 on book maps to driverBusy', (WidgetTester tester) async {
      final List<http.Request> log = <http.Request>[];
      final ApiClient api = _client((http.Request r) {
        switch (_endpoint(r)) {
          case 'ride_book.php':
            return _json(_ridePayload('searching'));
          case 'ride_cancel_booking.php':
            return _json(_ridePayload('canceled'));
          default:
            return _json(_ridePayload('searching'));
        }
      }, log);
      final BookingController c = BookingController(api);
      final List<String> raw = <String>[];
      c.updates.listen((BookingUpdate u) => raw.add(u.rawStatus));
      await c.createBooking(
        offer: _offer,
        pickup: const LatLng(6.45, 3.39),
        destination: const LatLng(6.6, 3.35),
        userId: 'u1',
        driverId: '5',
      );
      expect(await c.cancelBooking(reason: 'test'), isTrue);
      await tester.pump(const Duration(seconds: 10));
      expect(raw.last, RideStatusCode.canceled);
      expect(log.where((http.Request r) => _endpoint(r) == 'ride_status.php'), isEmpty);
      c.dispose();

      final ApiClient busyApi = _client(
          (http.Request r) => _json(<String, dynamic>{'error': true, 'message': 'Driver is busy'}, 409), <http.Request>[]);
      final BookingController c2 = BookingController(busyApi);
      final bool ok = await c2.createBooking(
        offer: _offer,
        pickup: const LatLng(6.45, 3.39),
        destination: const LatLng(6.6, 3.35),
        userId: 'u1',
        driverId: '5',
      );
      expect(ok, isFalse);
      expect(c2.lastError?.kind, BookingErrorKind.driverBusy);
      expect(c2.lastError?.message, 'Driver is busy');
      c2.dispose();
    });

    testWidgets('invalid input never hits the network', (WidgetTester tester) async {
      final List<http.Request> log = <http.Request>[];
      final BookingController c = BookingController(_client((_) => _json(<String, dynamic>{}), log));
      final bool ok = await c.createBooking(
        offer: _offer,
        pickup: const LatLng(0, 0),
        destination: const LatLng(6.6, 3.35),
        userId: 'guest',
        driverId: '',
      );
      expect(ok, isFalse);
      expect(c.lastError?.kind, BookingErrorKind.validation);
      expect(log, isEmpty);
      c.dispose();
    });
  });

  group('RideMarketService', () {
    testWidgets('sends PHP array origin/destination and keeps data on a failed tick', timeout: to, (WidgetTester tester) async {
      final List<http.Request> log = <http.Request>[];
      int driverCalls = 0;
      final ApiClient api = _client((http.Request r) {
        if (_endpoint(r) == 'ride_offers.php') return _json(<String, dynamic>{'error': false, 'offers': <dynamic>[]});
        driverCalls++;
        if (driverCalls == 2) return _json(<String, dynamic>{'error': true}, 500);
        return _json(<String, dynamic>{
          'error': false,
          'drivers': <dynamic>[
            <String, dynamic>{'id': '5', 'lat': 6.5, 'lng': 3.3, 'price_per_km': 150, 'base_fare': 500},
          ],
        });
      }, log);
      final RideMarketService svc = RideMarketService(api: api, debug: false);
      final List<RideMarketSnapshot> snaps = <RideMarketSnapshot>[];
      final StreamSubscription<RideMarketSnapshot> sub = svc
          .stream(origin: const LatLng(6.45, 3.39), destination: const LatLng(6.6, 3.35))
          .listen(snaps.add);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 5));
      final http.Request offers = log.firstWhere((http.Request r) => _endpoint(r) == 'ride_offers.php');
      expect(offers.bodyFields['origin[lat]'], '6.45');
      expect(offers.bodyFields['destination[lng]'], '3.35');
      expect(snaps, isNotEmpty);
      expect(snaps.every((RideMarketSnapshot s) => s.drivers.length == 1), isTrue,
          reason: 'a failed tick must not wipe the driver list');
      // Not awaited: a broadcast cancel future never completes inside the
      // fake-async zone of testWidgets.
      unawaited(sub.cancel());
      svc.dispose();
    });
  });

  group('validation + money', () {
    test('Nigerian phone numbers', () {
      expect(normalizeNigerianPhone('0803 123 4567'), '+2348031234567');
      expect(normalizeNigerianPhone('+234 803-123-4567'), '+2348031234567');
      expect(normalizeNigerianPhone('2349061234567'), '+2349061234567');
      expect(normalizeNigerianPhone('12345'), isNull);
      expect(normalizeNigerianPhone('0603 123 4567'), isNull);
    });

    test('fare uses route distance x driver tariff, whole naira', () {
      const RideNearbyDriver d = RideNearbyDriver(
        id: '5',
        name: 'Ada',
        category: 'Standard',
        rating: 4.8,
        carPlate: 'X',
        heading: 0,
        lat: 6.5,
        lng: 3.3,
        distanceKm: 1,
        etaMin: 3,
        pricePerKm: 150,
        baseFare: 500,
        estimatedTotal: 9999,
      );
      expect(d.fareFor(10.33), 2050);
      expect(d.fareFor(0), 9999);
      expect(formatMoney(2050), '₦2,050');
      expect(formatMoney(2050.5), '₦2,050.50');
      expect(formatMoney(double.nan), '—');
    });

    test('logistics request validation', () {
      const LogisticsBookingRequest r = LogisticsBookingRequest(
        kind: LogisticsKind.dispatch,
        userId: 'u1',
        pickup: LatLng(6.45, 3.39),
        pickupText: 'A',
        destination: LatLng(6.6, 3.35),
        destinationText: 'B',
        distanceKm: 12,
        recipientPhone: '0803',
        packageSize: PackageSize.box,
        weightKg: 5,
      );
      expect(r.validate(), contains('Nigerian mobile'));
    });
  });
}
