// lib/api/api_exception.dart
//
// Typed representation of the server error envelope defined in
// docs/SECURITY_CONTRACT.md §4:
//
//   { "error": true, "code": "SESSION_EXPIRED" | ..., "message": "..." }
//
// ApiException extends dart:io's HttpException so legacy call sites that
// catch `HttpException` (or just `catch (e)`) keep working unchanged.
import 'dart:convert';
import 'dart:io';

/// Machine-readable error codes from the contract, plus [unknown] for
/// anything the server did not classify.
enum ApiErrorCode {
  sessionExpired('SESSION_EXPIRED'),
  unauthorized('UNAUTHORIZED'),
  forbidden('FORBIDDEN'),
  rateLimited('RATE_LIMITED'),
  validation('VALIDATION'),
  conflict('CONFLICT'),
  server('SERVER'),
  unknown('UNKNOWN');

  const ApiErrorCode(this.wire);

  /// The string used on the wire.
  final String wire;

  static ApiErrorCode? tryParse(Object? raw) {
    if (raw == null) return null;
    final s = raw.toString().trim().toUpperCase();
    for (final c in ApiErrorCode.values) {
      if (c.wire == s) return c;
    }
    return null;
  }

  /// Best-effort mapping when the server did not send a `code`.
  static ApiErrorCode fromStatus(int status) {
    switch (status) {
      case 401:
        return ApiErrorCode.unauthorized;
      case 403:
        return ApiErrorCode.forbidden;
      case 409:
        return ApiErrorCode.conflict;
      case 422:
      case 400:
        return ApiErrorCode.validation;
      case 429:
        return ApiErrorCode.rateLimited;
      default:
        return status >= 500 ? ApiErrorCode.server : ApiErrorCode.unknown;
    }
  }
}

class ApiException extends HttpException {
  ApiException({
    required this.statusCode,
    required this.code,
    required String message,
    this.serverCodeRaw,
    this.retryAfter,
    Uri? uri,
  }) : super(message, uri: uri);

  /// HTTP status code of the failed response.
  final int statusCode;

  /// Parsed contract code (falls back to a status-derived code).
  final ApiErrorCode code;

  /// The raw `code` string exactly as sent by the server (null if absent).
  final String? serverCodeRaw;

  /// Parsed `Retry-After`, when present.
  final Duration? retryAfter;

  /// True when the session is no longer valid and the user must sign in.
  bool get isAuthError =>
      statusCode == 401 &&
      (code == ApiErrorCode.sessionExpired || code == ApiErrorCode.unauthorized);

  bool get isRateLimited => statusCode == 429 || code == ApiErrorCode.rateLimited;

  /// Builds an exception from a non-2xx response. Never includes the raw body
  /// in the message unless it is a well-formed envelope `message`, so internal
  /// server text is not surfaced to users.
  factory ApiException.fromResponse({
    required int statusCode,
    required String body,
    Map<String, String> headers = const {},
    Uri? uri,
  }) {
    String? rawCode;
    String? message;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final c = decoded['code'];
        if (c != null) rawCode = c.toString();
        final m = decoded['message'] ?? decoded['error_msg'];
        if (m is String && m.trim().isNotEmpty) message = m.trim();
        // Legacy endpoints nest the human text in login_msg.title_msg_body.
        final lm = decoded['login_msg'];
        if (message == null && lm is Map) {
          final b = lm['title_msg_body'];
          if (b is String && b.trim().isNotEmpty) message = b.trim();
        }
      }
    } catch (_) {
      // Not JSON (e.g. an HTML error page from a proxy) – ignore the body.
    }

    final code = ApiErrorCode.tryParse(rawCode) ?? ApiErrorCode.fromStatus(statusCode);
    return ApiException(
      statusCode: statusCode,
      code: code,
      serverCodeRaw: rawCode,
      message: message ?? defaultMessageFor(code),
      retryAfter: parseRetryAfter(headers['retry-after']),
      uri: uri,
    );
  }

  static String defaultMessageFor(ApiErrorCode code) {
    switch (code) {
      case ApiErrorCode.sessionExpired:
        return 'Your session has expired. Please sign in again.';
      case ApiErrorCode.unauthorized:
        return 'Please sign in to continue.';
      case ApiErrorCode.forbidden:
        return 'You are not allowed to perform this action.';
      case ApiErrorCode.rateLimited:
        return 'Too many attempts. Please wait a moment and try again.';
      case ApiErrorCode.validation:
        return 'Some of the information provided is invalid.';
      case ApiErrorCode.conflict:
        return 'This request conflicts with a recent change. Please refresh.';
      case ApiErrorCode.server:
        return 'Something went wrong on our side. Please try again.';
      case ApiErrorCode.unknown:
        return 'Request failed. Please try again.';
    }
  }

  /// Parses `Retry-After` as either delta-seconds or an HTTP-date.
  static Duration? parseRetryAfter(String? value, {DateTime? now}) {
    if (value == null) return null;
    final v = value.trim();
    if (v.isEmpty) return null;
    final secs = int.tryParse(v);
    if (secs != null) return secs < 0 ? Duration.zero : Duration(seconds: secs);
    try {
      final date = HttpDate.parse(v);
      final diff = date.difference((now ?? DateTime.now()).toUtc());
      return diff.isNegative ? Duration.zero : diff;
    } catch (_) {
      return null;
    }
  }

  /// User-facing text (no "HttpException:" prefix, no URI).
  @override
  String toString() => message;
}
