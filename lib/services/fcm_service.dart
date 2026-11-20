// lib/services/fcm_service.dart
//
// FCM token lifecycle: fetch (with FIS-error recovery), register with the
// backend once the user is signed in, re-register on token refresh, and
// delete on sign-out so the device stops receiving the previous user's pushes.
import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../utility/device_info_service.dart';
import '../utility/session_manager.dart';

class FCMService {
  FCMService._();

  static final FCMService instance = FCMService._();

  /// Kept for source compatibility with older call sites (`FCMService(context)`);
  /// the context is not used.
  factory FCMService([Object? _]) => instance;

  FirebaseMessaging get _fm => FirebaseMessaging.instance;

  StreamSubscription<String>? _refreshSub;
  String? _lastRegistered;
  Future<void>? _inflight;

  /// Kept for compatibility: same as [syncTokenWithBackend].
  Future<void> initializeFCM() => syncTokenWithBackend();

  /// Fetches the current token and registers it for the signed-in user.
  /// No-op when signed out. Safe to call repeatedly (deduplicated).
  Future<void> syncTokenWithBackend() {
    return _inflight ??= _sync().whenComplete(() => _inflight = null);
  }

  Future<void> _sync() async {
    try {
      _refreshSub ??= _fm.onTokenRefresh.listen(
        (t) => unawaited(_register(t, force: true)),
        onError: (Object _) {},
      );
      if (!await SessionManager.instance.hasValidSession()) return;
      final token = await _getTokenWithRecovery();
      if (token != null) await _register(token);
    } catch (e) {
      // Firebase unavailable (not initialised / no Play Services): push is
      // optional, never surface this as an app error.
      if (kDebugMode) debugPrint('[FCM] sync skipped: ${e.runtimeType}');
    }
  }

  /// Called on sign-out.
  Future<void> unregister() async {
    _lastRegistered = null;
    try {
      // A new token is issued (and registered) at the next sign-in.
      await _fm.deleteToken();
    } catch (_) {}
  }

  Future<String?> _getTokenWithRecovery() async {
    try {
      return await _fm.getToken();
    } catch (e) {
      final msg = e.toString();
      final isFisAuthError =
          msg.contains('FIS_AUTH_ERROR') || msg.contains('Firebase Installations Service is unavailable');
      if (isFisAuthError) {
        try {
          await _fm.deleteToken();
        } catch (_) {}
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(Duration(milliseconds: 400 * (1 << i)));
          try {
            final t = await _fm.getToken();
            if (t != null) return t;
          } catch (_) {}
        }
      }
      if (kDebugMode) debugPrint('[FCM] token unavailable: ${e.runtimeType}');
      return null;
    }
  }

  Future<void> _register(String token, {bool force = false}) async {
    try {
      if (!await SessionManager.instance.hasValidSession()) return;
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString(PrefKeys.userId) ?? '';
      if (userId.isEmpty) return;

      final key = '$userId|$token';
      if (!force && _lastRegistered == key) return;

      final device = await DeviceInfoService().getDeviceInfo();
      await ApiTransport.shared.send(
        ApiConstants.sendTokenEndpoint,
        method: 'POST',
        // Registering the same token twice is harmless → safe to retry.
        idempotent: true,
        data: {
          'token': token,
          'uid': userId,
          'device': jsonEncode(device),
        },
      );
      _lastRegistered = key;
      if (kDebugMode) debugPrint('[FCM] token registered');
    } catch (e) {
      if (kDebugMode) debugPrint('[FCM] token registration failed: ${e.runtimeType}');
    }
  }
}
