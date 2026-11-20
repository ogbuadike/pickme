// lib/api/api_client.dart
//
// Production HTTP client for the Pick Me API.
//
//  * One shared, keep-alive http.Client for the whole app (connection reuse).
//  * Per-request timeouts that actually abort the underlying request.
//  * Retries with exponential backoff + full jitter, ONLY when it is safe:
//      - idempotent methods (GET/HEAD/PUT/DELETE/OPTIONS), or a POST that
//        carries an `Idempotency-Key` header / `idempotent: true`;
//      - any method when the failure happened before the request could reach
//        the server (DNS failure, connection refused, network unreachable);
//      - any method on HTTP 429, honouring `Retry-After` (the server rejected
//        the request without processing it).
//  * Contract headers (docs/SECURITY_CONTRACT.md §1): Authorization (app key),
//    X-Session-Token, X-Client-Platform, X-Client-Version.
//  * De-duplicated global 401 handling (session wiped once, one navigation).
//  * Error envelope parsed into [ApiException].
//  * No logging of headers, tokens or bodies; diagnostics only in debug builds.
//
// Public surface is backwards compatible: `ApiClient(http.Client(), context)`
// and `request(endpoint, method:, data:, headers:, files:, retryCount:)` keep
// working for every existing caller.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'api_exception.dart';
import 'session_store.dart';
import 'url.dart';

export 'api_exception.dart';
export 'session_store.dart';

/// Called (at most once per burst) when an authenticated request is rejected
/// with 401 SESSION_EXPIRED / UNAUTHORIZED. The session token has already been
/// removed from the [SessionStore] when this runs.
typedef UnauthorizedHandler = FutureOr<void> Function(ApiException error);

/// Tunables for [ApiTransport].
@immutable
class ApiConfig {
  const ApiConfig({
    this.baseUrl = ApiConstants.baseUrl,
    this.appKey = ApiConstants.appKey,
    this.requestTimeout = const Duration(seconds: 20),
    this.uploadTimeout = const Duration(seconds: 90),
    this.maxRetries = 2,
    this.baseBackoff = const Duration(milliseconds: 400),
    this.maxBackoff = const Duration(seconds: 8),
    this.maxRetryAfter = const Duration(seconds: 30),
    this.sessionLifetime = const Duration(days: 30),
  });

  final String baseUrl;
  final String appKey;
  final Duration requestTimeout;
  final Duration uploadTimeout;

  /// Default number of retries (attempts = retries + 1) for retryable failures.
  final int maxRetries;
  final Duration baseBackoff;
  final Duration maxBackoff;

  /// A `Retry-After` longer than this is not waited for; the error surfaces.
  final Duration maxRetryAfter;

  /// Server-side sliding session window (contract §2).
  final Duration sessionLifetime;
}

/// The engine behind [ApiClient]. Use [ApiTransport.shared] in the app; tests
/// construct their own with a `MockClient` and an [InMemorySessionStore].
class ApiTransport {
  ApiTransport({
    http.Client? httpClient,
    SessionStore? sessionStore,
    this.config = const ApiConfig(),
    Future<String> Function()? clientVersion,
    String? clientPlatform,
    math.Random? random,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
    this.onUnauthorized,
  })  : _http = httpClient ?? http.Client(),
        sessionStore = sessionStore ?? SecureSessionStore(),
        _clientVersionLoader = clientVersion ?? _loadPackageVersion,
        clientPlatform = clientPlatform ?? _platformName(),
        _random = random ?? math.Random(),
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _clock = clock ?? (() => DateTime.now().toUtc());

  static ApiTransport? _shared;

  /// Process-wide instance (lazily created).
  static ApiTransport get shared => _shared ??= ApiTransport();

  /// Replace the shared transport (tests / custom bootstrap).
  @visibleForTesting
  static set shared(ApiTransport transport) => _shared = transport;

  final http.Client _http;
  final SessionStore sessionStore;
  final ApiConfig config;
  final String clientPlatform;
  final Future<String> Function() _clientVersionLoader;
  final math.Random _random;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _clock;

  /// Global 401 hook (wired in main.dart to wipe + navigate to login).
  UnauthorizedHandler? onUnauthorized;

  Future<String>? _clientVersion;
  Future<void>? _unauthorizedInFlight;
  DateTime? _lastSessionTouch;

  /// Endpoints that do not require a session (contract §5). A 401 from these
  /// is a normal failure (e.g. wrong password), never a forced sign-out.
  static const Set<String> publicEndpoints = {
    ApiConstants.logInEndpoint,
    ApiConstants.registerEndpoint,
    ApiConstants.sendTokenEndpoint,
    ApiConstants.restPwdEndpoint,
    ApiConstants.countryEndpoint,
    ApiConstants.helpEndpoint,
    'privacy.php',
    'webhook.php',
  };

  static const Set<String> _idempotentMethods = {'GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS'};

  static String _platformName() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return defaultTargetPlatform.name.toLowerCase();
    }
  }

  static Future<String> _loadPackageVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.buildNumber.isEmpty ? info.version : '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<String> get clientVersion => _clientVersion ??= _clientVersionLoader();

  /// Sends a request and returns the 2xx response.
  ///
  /// Throws [ApiException] for non-2xx responses, or the original
  /// [SocketException] / [TimeoutException] / [http.ClientException] for
  /// transport failures after retries are exhausted.
  Future<http.Response> send(
    String endpoint, {
    required String method,
    Map<String, String>? data,
    Map<String, String>? headers,
    Map<String, File>? files,
    int? retries,
    Duration? timeout,
    bool idempotent = false,
  }) async {
    final verb = method.trim().toUpperCase();
    if (!const {'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'}.contains(verb)) {
      throw ArgumentError.value(method, 'method', 'Invalid HTTP method');
    }

    final uri = _resolve(endpoint, verb == 'GET' || verb == 'HEAD' ? data : null);
    final hasFiles = files != null && files.isNotEmpty;
    final canRetryAnyFailure = idempotent ||
        _idempotentMethods.contains(verb) ||
        (headers?.keys.any((k) => k.toLowerCase() == 'idempotency-key') ?? false);
    final maxRetries = math.max(0, retries ?? config.maxRetries);
    final perAttemptTimeout = timeout ?? (hasFiles ? config.uploadTimeout : config.requestTimeout);
    final isPublic = publicEndpoints.contains(_endpointName(endpoint));

    var attempt = 0;
    while (true) {
      final session = await sessionStore.read();
      final token = (session != null && session.token.isNotEmpty) ? session.token : null;
      final requestHeaders = await _buildHeaders(headers, token);
      final sw = Stopwatch()..start();

      http.Response response;
      try {
        response = await _sendOnce(verb, uri, requestHeaders, data, files, perAttemptTimeout);
      } catch (e) {
        final retryable = canRetryAnyFailure ? _isTransportError(e) : _isPreSendFailure(e);
        _debugLog('$verb ${uri.path} failed after ${sw.elapsedMilliseconds}ms: ${e.runtimeType}'
            '${retryable && attempt < maxRetries ? ' (retrying)' : ''}');
        if (retryable && attempt < maxRetries) {
          await _sleep(backoffFor(attempt));
          attempt++;
          continue;
        }
        rethrow;
      }

      _debugLog('$verb ${uri.path} -> ${response.statusCode} (${sw.elapsedMilliseconds}ms)');

      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        if (token != null && !isPublic) unawaited(_slideSession(session!, response));
        return response;
      }

      final error = ApiException.fromResponse(
        statusCode: status,
        body: response.body,
        headers: response.headers,
        uri: uri,
      );

      if (status == 401 && token != null && !isPublic && _isSessionFailure(error)) {
        await _handleUnauthorized(error, token);
        throw error;
      }

      if (attempt < maxRetries) {
        Duration? wait;
        if (status == 429) {
          final ra = error.retryAfter;
          if (ra == null) {
            wait = backoffFor(attempt);
          } else if (ra <= config.maxRetryAfter) {
            wait = ra;
          }
        } else if (canRetryAnyFailure && (status == 502 || status == 503 || status == 504)) {
          final ra = error.retryAfter;
          wait = (ra != null && ra <= config.maxRetryAfter) ? ra : backoffFor(attempt);
        }
        if (wait != null) {
          _debugLog('$verb ${uri.path} retry in ${wait.inMilliseconds}ms');
          await _sleep(wait);
          attempt++;
          continue;
        }
      }
      throw error;
    }
  }

  /// Full-jitter exponential backoff: random in [0, min(max, base * 2^attempt)].
  @visibleForTesting
  Duration backoffFor(int attempt) {
    final capMs = math.min(
      config.maxBackoff.inMilliseconds,
      config.baseBackoff.inMilliseconds * math.pow(2, attempt).toInt(),
    );
    if (capMs <= 0) return Duration.zero;
    // Never 0 so consecutive retries are not a tight loop.
    final ms = math.max(1, (_random.nextDouble() * capMs).round());
    return Duration(milliseconds: ms);
  }

  Uri _resolve(String endpoint, Map<String, String>? query) {
    final base = endpoint.startsWith('http://') || endpoint.startsWith('https://')
        ? Uri.parse(endpoint)
        : Uri.parse('${config.baseUrl}${endpoint.startsWith('/') ? endpoint.substring(1) : endpoint}');
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: {...base.queryParameters, ...query});
  }

  static String _endpointName(String endpoint) {
    final path = endpoint.split('?').first;
    final i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }

  Future<Map<String, String>> _buildHeaders(Map<String, String>? extra, String? token) async {
    final h = <String, String>{
      'Authorization': config.appKey,
      'Accept': 'application/json',
      'X-Client-Platform': clientPlatform,
      'X-Client-Version': await clientVersion,
    };
    if (token != null) h['X-Session-Token'] = token;
    if (extra != null) {
      // Caller headers may add to, but never remove, the contract headers.
      extra.forEach((k, v) {
        final lk = k.toLowerCase();
        if (lk == 'x-session-token' || lk == 'authorization') return;
        h[k] = v;
      });
    }
    return h;
  }

  Future<http.Response> _sendOnce(
    String verb,
    Uri uri,
    Map<String, String> headers,
    Map<String, String>? data,
    Map<String, File>? files,
    Duration timeout,
  ) async {
    final abort = Completer<void>();
    final http.BaseRequest req;

    if (files != null && files.isNotEmpty) {
      final mr = http.AbortableMultipartRequest(verb, uri, abortTrigger: abort.future);
      mr.headers.addAll(headers..remove('Content-Type'));
      if (data != null) mr.fields.addAll(data);
      for (final entry in files.entries) {
        mr.files.add(await http.MultipartFile.fromPath(entry.key, entry.value.path));
      }
      req = mr;
    } else {
      final r = http.AbortableRequest(verb, uri, abortTrigger: abort.future);
      r.headers.addAll(headers);
      final hasBody = verb != 'GET' && verb != 'HEAD';
      if (hasBody && data != null) r.bodyFields = data;
      req = r;
    }

    // The whole exchange (connect + headers + body) shares one deadline. On
    // expiry the abort trigger tears down the socket (IOClient) and the
    // `.timeout` guarantees the caller is released even for clients that do
    // not support aborting.
    final sw = Stopwatch()..start();
    Never onTimeout() {
      if (!abort.isCompleted) abort.complete();
      throw TimeoutException('Request timed out', timeout);
    }

    try {
      final streamed = await _http.send(req).timeout(timeout, onTimeout: onTimeout);
      final remaining = timeout - sw.elapsed;
      return await http.Response.fromStream(streamed)
          .timeout(remaining.isNegative ? Duration.zero : remaining, onTimeout: onTimeout);
    } on http.RequestAbortedException {
      throw TimeoutException('Request timed out', timeout);
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  static bool _isSessionFailure(ApiException e) {
    // Older backends send a bare 401 without a code; treat that as a session
    // failure too when a token was attached.
    return e.serverCodeRaw == null || e.isAuthError;
  }

  static bool _isTransportError(Object e) =>
      e is SocketException || e is TimeoutException || e is http.ClientException || e is HandshakeException;

  /// True when the request certainly did not reach the server.
  static bool _isPreSendFailure(Object e) {
    String msg;
    if (e is SocketException) {
      msg = '${e.message} ${e.osError?.message ?? ''}';
    } else if (e is http.ClientException) {
      msg = e.message;
    } else {
      return false;
    }
    msg = msg.toLowerCase();
    return msg.contains('failed host lookup') ||
        msg.contains('connection refused') ||
        msg.contains('network is unreachable') ||
        msg.contains('no address associated') ||
        msg.contains('no route to host');
  }

  Future<void> _slideSession(Session session, http.Response response) async {
    final now = _clock();
    final headerExpiry = SecureSessionStore.parseExpiry(response.headers['x-session-expires-at']);
    if (headerExpiry != null) {
      await sessionStore.touch(headerExpiry);
      _lastSessionTouch = now;
      return;
    }
    // Throttle secure-storage writes to once per hour.
    final last = _lastSessionTouch;
    if (last != null && now.difference(last) < const Duration(hours: 1)) return;
    _lastSessionTouch = now;
    await sessionStore.touch(now.add(config.sessionLifetime));
  }

  Future<void> _handleUnauthorized(ApiException error, String rejectedToken) {
    // Only the token that was actually rejected is wiped: a fresh login that
    // raced with an old request must survive.
    final inflight = _unauthorizedInFlight;
    if (inflight != null) return inflight;
    final current = sessionStore.cached;
    if (current == null || current.token != rejectedToken) return Future.value();

    final f = () async {
      await sessionStore.clear();
      final handler = onUnauthorized;
      if (handler != null) {
        try {
          await handler(error);
        } catch (e) {
          _debugLog('onUnauthorized handler failed: ${e.runtimeType}');
        }
      }
    }();
    _unauthorizedInFlight = f.whenComplete(() => _unauthorizedInFlight = null);
    return _unauthorizedInFlight!;
  }

  void _debugLog(String message) {
    if (kDebugMode) debugPrint('[ApiClient] $message');
  }

  /// Closes the underlying connection pool. Only for tests / app teardown.
  void close() => _http.close();
}

/// Image cache tunables (kept for API compatibility).
class ImageCacheConfig {
  final Duration cacheDuration;
  final int maxCacheItems;
  final int maxCacheSizeBytes;

  const ImageCacheConfig({
    this.cacheDuration = const Duration(days: 7),
    this.maxCacheItems = 1000,
    this.maxCacheSizeBytes = 100 * 1024 * 1024, // 100MB
  });
}

/// Lightweight facade used throughout the app. Cheap to construct: all heavy
/// state (connection pool, session cache, image cache) is shared.
class ApiClient {
  /// [client] and [context] are accepted for backwards compatibility only.
  /// The shared keep-alive client is always used, and the API layer never
  /// touches UI through a BuildContext (errors are thrown to the caller; global
  /// 401 handling goes through the app's navigatorKey).
  ApiClient([http.Client? client, BuildContext? context, this.config = const ImageCacheConfig()])
      : _transport = ApiTransport.shared {
    // The throw-away client the legacy call sites create is never used.
    client?.close();
  }

  /// Explicit transport, for tests.
  ApiClient.withTransport(this._transport, {this.config = const ImageCacheConfig()});

  final ApiTransport _transport;
  final ImageCacheConfig config;

  ApiTransport get transport => _transport;

  /// Sends a request to `ApiConstants.baseUrl + endpoint`.
  ///
  /// [retryCount] caps the number of retries (null = default policy). Retries
  /// only happen when safe; see the file header. Pass [idempotent] (or an
  /// `Idempotency-Key` header) to allow retrying a POST after a timeout.
  Future<http.Response> request(
    String endpoint, {
    required String method,
    Map<String, String>? data,
    Map<String, String>? headers,
    Map<String, File>? files,
    int? retryCount,
    Duration? timeout,
    bool idempotent = false,
  }) {
    return _transport.send(
      endpoint,
      method: method,
      data: data,
      headers: headers,
      files: files,
      retries: retryCount,
      timeout: timeout,
      idempotent: idempotent,
    );
  }

  // ───────────────────────── Image cache ─────────────────────────
  static const String _imageCacheKey = 'pickmeImageCache';
  static Future<CacheManager>? _cacheManagerFuture;
  static final Map<String, Future<File>> _inflightImages = {};
  static DateTime? _lastCacheSweep;

  /// Created once, on first use – no late-init race.
  Future<CacheManager> get _cacheManager => _cacheManagerFuture ??= Future.value(
        CacheManager(
          Config(
            _imageCacheKey,
            stalePeriod: config.cacheDuration,
            maxNrOfCacheObjects: config.maxCacheItems,
          ),
        ),
      );

  Future<File> fetchImage(String imageUrl, {bool forceFetch = false}) {
    final existing = _inflightImages[imageUrl];
    if (existing != null && !forceFetch) return existing;

    final f = () async {
      final cm = await _cacheManager;
      unawaited(_maybeSweepCache());
      if (!forceFetch) {
        final cached = await cm.getFileFromCache(imageUrl);
        if (cached != null && await cached.file.exists()) return cached.file;
      }
      final info = await cm.downloadFile(imageUrl, key: imageUrl, force: true);
      return info.file;
    }();
    _inflightImages[imageUrl] = f;
    return f.whenComplete(() => _inflightImages.remove(imageUrl));
  }

  Future<void> prefetchImages(List<String> imageUrls) async {
    const batchSize = 3;
    for (var i = 0; i < imageUrls.length; i += batchSize) {
      final batch = imageUrls.skip(i).take(batchSize);
      await Future.wait(batch.map((u) => fetchImage(u).then<void>((_) {}, onError: (_) {})));
    }
  }

  Future<void> clearCache() async => (await _cacheManager).emptyCache();

  /// Size of the image cache directory only (not the whole temp dir).
  Future<int> getCachedImagesSize() async {
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/$_imageCacheKey');
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Replaces the old never-cancelled Timer.periodic: checks size lazily, at
  /// most every 6 hours, while the cache is actually being used.
  Future<void> _maybeSweepCache() async {
    final now = DateTime.now();
    final last = _lastCacheSweep;
    if (last != null && now.difference(last) < const Duration(hours: 6)) return;
    _lastCacheSweep = now;
    try {
      if (await getCachedImagesSize() > config.maxCacheSizeBytes) {
        await (await _cacheManager).emptyCache();
      }
    } catch (_) {}
  }
}
