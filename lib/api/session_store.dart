// lib/api/session_store.dart
//
// Storage for the per-user session token (docs/SECURITY_CONTRACT.md §2).
// The token lives ONLY in flutter_secure_storage (Keychain / EncryptedSharedPreferences)
// and is cached in memory so every request does not hit the platform channel.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Immutable snapshot of the current session.
@immutable
class Session {
  const Session({required this.token, this.expiresAt});

  final String token;

  /// UTC expiry as last known by the client. The server uses a sliding window,
  /// so this is a lower bound that is pushed forward on authenticated traffic.
  final DateTime? expiresAt;

  bool get isEmpty => token.isEmpty;

  bool isValidAt(DateTime now) =>
      token.isNotEmpty && (expiresAt == null || expiresAt!.isAfter(now));

  bool get isValid => isValidAt(DateTime.now().toUtc());
}

abstract class SessionStore {
  /// Returns the current session (from memory after the first read).
  Future<Session?> read();

  /// Synchronous access to the cached session; null until [read] completed once.
  Session? get cached;

  Future<void> save(String token, DateTime? expiresAt);

  /// Updates only the expiry (sliding window), keeping the token.
  Future<void> touch(DateTime expiresAt);

  Future<void> clear();
}

/// Default store backed by flutter_secure_storage.
class SecureSessionStore implements SessionStore {
  SecureSessionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? defaultSecureStorage;

  static const String tokenKey = 'session_token';
  static const String expiresKey = 'session_expires_at';

  /// Shared secure-storage configuration for the whole app.
  static const FlutterSecureStorage defaultSecureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  final FlutterSecureStorage _storage;

  Session? _cache;
  bool _loaded = false;
  Future<Session?>? _inflight;

  @override
  Session? get cached => _cache;

  @override
  Future<Session?> read() {
    if (_loaded) return Future.value(_cache);
    return _inflight ??= _load().whenComplete(() => _inflight = null);
  }

  Future<Session?> _load() async {
    try {
      final token = await _storage.read(key: tokenKey);
      final exp = await _storage.read(key: expiresKey);
      _cache = (token == null || token.isEmpty)
          ? null
          : Session(token: token, expiresAt: parseExpiry(exp));
    } catch (_) {
      // Keystore corruption (e.g. after a backup restore on Android) – treat
      // as signed out rather than crashing.
      _cache = null;
    }
    _loaded = true;
    return _cache;
  }

  @override
  Future<void> save(String token, DateTime? expiresAt) async {
    _cache = Session(token: token, expiresAt: expiresAt?.toUtc());
    _loaded = true;
    await _storage.write(key: tokenKey, value: token);
    if (expiresAt != null) {
      await _storage.write(key: expiresKey, value: expiresAt.toUtc().toIso8601String());
    } else {
      await _storage.delete(key: expiresKey);
    }
  }

  @override
  Future<void> touch(DateTime expiresAt) async {
    final current = _cache;
    if (current == null) return;
    _cache = Session(token: current.token, expiresAt: expiresAt.toUtc());
    try {
      await _storage.write(key: expiresKey, value: expiresAt.toUtc().toIso8601String());
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    _cache = null;
    _loaded = true;
    try {
      await _storage.delete(key: tokenKey);
      await _storage.delete(key: expiresKey);
    } catch (_) {}
  }

  static DateTime? parseExpiry(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    return DateTime.tryParse(raw.trim())?.toUtc();
  }
}

/// Non-persistent store, used by tests and as a fallback.
class InMemorySessionStore implements SessionStore {
  InMemorySessionStore([this._session]);

  Session? _session;

  @override
  Session? get cached => _session;

  @override
  Future<Session?> read() async => _session;

  @override
  Future<void> save(String token, DateTime? expiresAt) async {
    _session = Session(token: token, expiresAt: expiresAt?.toUtc());
  }

  @override
  Future<void> touch(DateTime expiresAt) async {
    final s = _session;
    if (s != null) _session = Session(token: s.token, expiresAt: expiresAt.toUtc());
  }

  @override
  Future<void> clear() async => _session = null;
}
