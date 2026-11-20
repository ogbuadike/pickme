import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pickme/api/api_client.dart';
import 'package:pickme/api/url.dart';

/// Test harness around [ApiTransport] with a scripted MockClient.
class _Harness {
  _Harness(this.handler, {Session? session}) {
    store = InMemorySessionStore(session);
    transport = ApiTransport(
      httpClient: MockClient((req) async {
        requests.add(req);
        return handler(req, requests.length);
      }),
      sessionStore: store,
      config: const ApiConfig(),
      clientVersion: () async => '9.9.9+42',
      clientPlatform: 'android',
      random: math.Random(1),
      sleep: (d) async => sleeps.add(d),
      clock: () => DateTime.utc(2026, 1, 1),
      onUnauthorized: (e) async => unauthorized.add(e),
    );
  }

  final Future<http.Response> Function(http.Request req, int n) handler;
  late final InMemorySessionStore store;
  late final ApiTransport transport;
  final requests = <http.Request>[];
  final sleeps = <Duration>[];
  final unauthorized = <ApiException>[];
}

http.Response _json(Object body, int status, {Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...headers});

Session _validSession() => Session(token: 'a' * 64, expiresAt: DateTime.utc(2030));

void main() {
  group('ApiException envelope parsing', () {
    test('parses contract envelope into typed code + message', () {
      final e = ApiException.fromResponse(
        statusCode: 403,
        body: jsonEncode({'error': true, 'code': 'FORBIDDEN', 'message': 'Not your ride'}),
      );
      expect(e.code, ApiErrorCode.forbidden);
      expect(e.serverCodeRaw, 'FORBIDDEN');
      expect(e.message, 'Not your ride');
      expect(e.toString(), 'Not your ride');
      expect(e, isA<HttpException>(), reason: 'legacy catch (HttpException) sites keep working');
      expect(e.isAuthError, isFalse);
    });

    test('unknown / missing code falls back to the HTTP status', () {
      expect(ApiException.fromResponse(statusCode: 429, body: '{}').code, ApiErrorCode.rateLimited);
      expect(ApiException.fromResponse(statusCode: 409, body: '{"code":"WHATEVER"}').code, ApiErrorCode.conflict);
      expect(ApiException.fromResponse(statusCode: 401, body: '').isAuthError, isTrue);
    });

    test('non-JSON bodies are never surfaced to the user', () {
      final e = ApiException.fromResponse(
        statusCode: 500,
        body: '<html>Fatal error: mysqli_query() in /var/www/user_info.php</html>',
      );
      expect(e.code, ApiErrorCode.server);
      expect(e.message, isNot(contains('mysqli')));
      expect(e.message, ApiException.defaultMessageFor(ApiErrorCode.server));
    });

    test('legacy login_msg text is used when there is no message', () {
      final e = ApiException.fromResponse(
        statusCode: 429,
        body: jsonEncode({
          'error': true,
          'code': 'RATE_LIMITED',
          'login_msg': {'title_msg_body': 'Slow down'},
        }),
      );
      expect(e.message, 'Slow down');
      expect(e.isRateLimited, isTrue);
    });

    test('Retry-After supports delta-seconds and HTTP-date', () {
      expect(ApiException.parseRetryAfter('7'), const Duration(seconds: 7));
      expect(ApiException.parseRetryAfter(null), isNull);
      expect(ApiException.parseRetryAfter('garbage'), isNull);
      final now = DateTime.utc(2026, 1, 1, 12);
      final date = HttpDate.format(now.add(const Duration(seconds: 30)));
      expect(ApiException.parseRetryAfter(date, now: now), const Duration(seconds: 30));
    });
  });

  group('ApiTransport headers', () {
    test('attaches contract headers and the session token', () async {
      final h = _Harness((req, _) async => _json({'error': false}, 200), session: _validSession());
      await h.transport.send(ApiConstants.userInfoEndpoint, method: 'POST', data: {'user': '1'});

      final req = h.requests.single;
      expect(req.url.toString(), '${ApiConstants.baseUrl}${ApiConstants.userInfoEndpoint}');
      expect(req.headers['Authorization'], ApiConstants.appKey);
      expect(req.headers['X-Session-Token'], 'a' * 64);
      expect(req.headers['X-Client-Platform'], 'android');
      expect(req.headers['X-Client-Version'], '9.9.9+42');
      expect(req.bodyFields, {'user': '1'});
    });

    test('callers cannot override or spoof the session header', () async {
      final h = _Harness((req, _) async => _json({'error': false}, 200), session: _validSession());
      await h.transport.send('x.php', method: 'POST', headers: {'X-Session-Token': 'evil', 'X-Extra': '1'});
      expect(h.requests.single.headers['X-Session-Token'], 'a' * 64);
      expect(h.requests.single.headers['X-Extra'], '1');
    });

    test('no session -> no X-Session-Token header', () async {
      final h = _Harness((req, _) async => _json({'error': false}, 200));
      await h.transport.send(ApiConstants.logInEndpoint, method: 'POST', data: {'email': 'a'});
      expect(h.requests.single.headers.containsKey('X-Session-Token'), isFalse);
    });

    test('GET data is sent as query parameters', () async {
      final h = _Harness((req, _) async => _json({'error': false}, 200));
      await h.transport.send('help_api.php', method: 'GET', data: {'q': 'fare'});
      expect(h.requests.single.url.queryParameters, {'q': 'fare'});
      expect(h.requests.single.body, isEmpty);
    });

    test('rejects unknown HTTP methods', () {
      final h = _Harness((req, _) async => _json({}, 200));
      expect(() => h.transport.send('x.php', method: 'FETCH'), throwsArgumentError);
    });
  });

  group('session handling', () {
    test('401 SESSION_EXPIRED wipes the session and calls the handler once', () async {
      final h = _Harness(
        (req, _) async => _json({'error': true, 'code': 'SESSION_EXPIRED', 'message': 'Expired'}, 401),
        session: _validSession(),
      );

      final results = await Future.wait(List.generate(
        3,
        (_) => h.transport
            .send('ride_status.php', method: 'POST')
            .then<Object?>((_) => null, onError: (Object e) => e),
      ));

      for (final r in results) {
        expect(r, isA<ApiException>().having((e) => e.isAuthError, 'isAuthError', isTrue));
      }
      expect(h.unauthorized, hasLength(1), reason: 'de-duplicated global 401 handler');
      expect(await h.store.read(), isNull);
      expect(h.requests, hasLength(3), reason: '401 is never retried');
    });

    test('401 from a public endpoint (bad password) does not sign out', () async {
      final h = _Harness(
        (req, _) async => _json({'error': true, 'code': 'UNAUTHORIZED', 'message': 'Wrong password'}, 401),
        session: _validSession(),
      );
      await expectLater(
        h.transport.send(ApiConstants.logInEndpoint, method: 'POST'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Wrong password')),
      );
      expect(h.unauthorized, isEmpty);
      expect(await h.store.read(), isNotNull);
    });

    test('403 FORBIDDEN keeps the session', () async {
      final h = _Harness(
        (req, _) async => _json({'error': true, 'code': 'FORBIDDEN', 'message': 'nope'}, 403),
        session: _validSession(),
      );
      await expectLater(h.transport.send('ride_cancel_booking.php', method: 'POST'), throwsA(isA<ApiException>()));
      expect(h.unauthorized, isEmpty);
      expect((await h.store.read())?.token, 'a' * 64);
    });

    test('a token saved by a newer login survives a stale 401', () async {
      late _Harness h;
      h = _Harness((req, n) async {
        // While the old request is in flight the user signs in again.
        await h.store.save('b' * 64, DateTime.utc(2031));
        return _json({'error': true, 'code': 'SESSION_EXPIRED'}, 401);
      }, session: _validSession());

      await expectLater(h.transport.send('user_info.php', method: 'POST'), throwsA(isA<ApiException>()));
      expect((await h.store.read())?.token, 'b' * 64);
      expect(h.unauthorized, isEmpty);
    });

    test('successful authenticated responses slide the local expiry', () async {
      final h = _Harness(
        (req, _) async => _json({'error': false}, 200),
        session: Session(token: 'a' * 64, expiresAt: DateTime.utc(2026, 1, 2)),
      );
      await h.transport.send('user_info.php', method: 'POST');
      await Future<void>.delayed(Duration.zero);
      expect((await h.store.read())?.expiresAt, DateTime.utc(2026, 1, 31));
    });

    test('server-provided X-Session-Expires-At wins', () async {
      final h = _Harness(
        (req, _) async => _json({'error': false}, 200, headers: {'x-session-expires-at': '2026-03-01T00:00:00Z'}),
        session: _validSession(),
      );
      await h.transport.send('user_info.php', method: 'POST');
      await Future<void>.delayed(Duration.zero);
      expect((await h.store.read())?.expiresAt, DateTime.utc(2026, 3, 1));
    });

    test('Session.isValidAt honours expiry', () {
      final s = Session(token: 't', expiresAt: DateTime.utc(2026, 1, 1));
      expect(s.isValidAt(DateTime.utc(2025, 12, 31)), isTrue);
      expect(s.isValidAt(DateTime.utc(2026, 1, 2)), isFalse);
      expect(const Session(token: '').isValidAt(DateTime.utc(2000)), isFalse);
      expect(const Session(token: 't').isValidAt(DateTime.utc(2100)), isTrue);
    });
  });

  group('retry policy', () {
    test('429 honours Retry-After then succeeds (even for POST)', () async {
      final h = _Harness((req, n) async => n == 1
          ? _json({'error': true, 'code': 'RATE_LIMITED'}, 429, headers: {'retry-after': '3'})
          : _json({'error': false}, 200));
      final res = await h.transport.send('validate_pin.php', method: 'POST');
      expect(res.statusCode, 200);
      expect(h.sleeps, [const Duration(seconds: 3)]);
      expect(h.requests, hasLength(2));
    });

    test('429 with an excessive Retry-After surfaces immediately', () async {
      final h = _Harness((req, n) async => _json({'code': 'RATE_LIMITED'}, 429, headers: {'retry-after': '600'}));
      await expectLater(
        h.transport.send('user_login.php', method: 'POST'),
        throwsA(isA<ApiException>().having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 600))),
      );
      expect(h.requests, hasLength(1));
      expect(h.sleeps, isEmpty);
    });

    test('mutating POST is NOT retried on 503', () async {
      final h = _Harness((req, n) async => _json({'code': 'SERVER'}, 503));
      await expectLater(h.transport.send('ride_book.php', method: 'POST'), throwsA(isA<ApiException>()));
      expect(h.requests, hasLength(1));
    });

    test('GET is retried on 503 with bounded backoff', () async {
      final h = _Harness((req, n) async => n < 3 ? _json({'code': 'SERVER'}, 503) : _json({'ok': 1}, 200));
      final res = await h.transport.send('get_countries.php', method: 'GET');
      expect(res.statusCode, 200);
      expect(h.requests, hasLength(3));
      expect(h.sleeps, hasLength(2));
      for (final d in h.sleeps) {
        expect(d, greaterThan(Duration.zero));
        expect(d, lessThanOrEqualTo(const ApiConfig().maxBackoff));
      }
    });

    test('POST with Idempotency-Key is retried on 503', () async {
      final h = _Harness((req, n) async => n == 1 ? _json({}, 503) : _json({'error': false}, 200));
      await h.transport.send('ride_book.php', method: 'POST', headers: {'Idempotency-Key': 'k1'});
      expect(h.requests, hasLength(2));
    });

    test('POST is retried when the request never left the device', () async {
      final h = _Harness((req, n) async {
        if (n == 1) throw const SocketException('Failed host lookup: realpickme.com');
        return _json({'error': false}, 200);
      });
      final res = await h.transport.send('ride_book.php', method: 'POST');
      expect(res.statusCode, 200);
      expect(h.requests, hasLength(2));
    });

    test('POST is NOT retried after a mid-flight network failure', () async {
      final h = _Harness((req, n) async => throw const SocketException('Connection reset by peer'));
      await expectLater(h.transport.send('ride_book.php', method: 'POST'), throwsA(isA<SocketException>()));
      expect(h.requests, hasLength(1));
    });

    test('per-request timeout aborts with TimeoutException and is not retried for POST', () async {
      final h = _Harness((req, n) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _json({'error': false}, 200);
      });
      await expectLater(
        h.transport.send('ride_book.php', method: 'POST', timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
      expect(h.requests, hasLength(1));
    });

    test('retries: 0 disables retries', () async {
      final h = _Harness((req, n) async => _json({}, 503));
      await expectLater(h.transport.send('x.php', method: 'GET', retries: 0), throwsA(isA<ApiException>()));
      expect(h.requests, hasLength(1));
    });

    test('backoff grows exponentially and is capped', () {
      final t = ApiTransport(
        httpClient: MockClient((_) async => http.Response('', 200)),
        sessionStore: InMemorySessionStore(),
        clientVersion: () async => '1',
        random: _MaxRandom(),
      );
      expect(t.backoffFor(0), const Duration(milliseconds: 400));
      expect(t.backoffFor(1), const Duration(milliseconds: 800));
      expect(t.backoffFor(10), const ApiConfig().maxBackoff);
    });
  });

  group('ApiClient facade', () {
    test('legacy request() signature delegates to the transport', () async {
      final h = _Harness((req, _) async => _json({'error': false, 'user': {}}, 200), session: _validSession());
      final api = ApiClient.withTransport(h.transport);
      final res = await api.request(ApiConstants.userInfoEndpoint, method: 'POST', data: {'user': '7'}, retryCount: 1);
      expect(jsonDecode(res.body)['error'], false);
      expect(h.requests.single.bodyFields['user'], '7');
    });

    test('legacy constructor (http.Client(), context) still compiles and is cheap', () {
      final api = ApiClient(http.Client(), null);
      expect(api.transport, same(ApiTransport.shared));
    });
  });
}

class _MaxRandom implements math.Random {
  @override
  double nextDouble() => 1.0;
  @override
  bool nextBool() => true;
  @override
  int nextInt(int max) => max - 1;
}
