// lib/utility/session_manager.dart
//
// Owns the signed-in state on the device (docs/SECURITY_CONTRACT.md §2, §6):
//  * persists the session token + expiry from `login_msg` into secure storage;
//  * keeps only NON-sensitive, widely read values (uid, name, driver flags) in
//    SharedPreferences so existing screens keep working;
//  * logout (server revoke + local wipe) and account deletion.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/url.dart';

/// SharedPreferences keys that other screens read. These are not secrets.
class PrefKeys {
  PrefKeys._();
  static const userId = 'user_id';
  static const userName = 'user_name';
  static const isDriver = 'user_is_driver';
  static const driverId = 'user_driver_id';
  static const driverStatus = 'user_driver_status';
  static const postLoginHome = 'post_login_home';

  /// Flag only ('available' when a transaction PIN exists) – never the PIN.
  static const pinFlag = 'user_pin';

  /// Per-install identifier used for push-token registration. Survives logout.
  static const installId = 'install_id';

  /// Keys that used to hold sensitive data in SharedPreferences and are now
  /// kept in secure storage only.
  static const legacySensitive = <String>[
    'user_account_name',
    'user_account_number',
    'user_account_bank',
    'session_token',
    'session_expires_at',
    'password',
    'user_password',
    'pin',
  ];

  /// Device-level preferences kept across sign-out (theme, language, ...).
  static bool isDevicePreference(String key) =>
      key.startsWith('set_') || key == installId || key.startsWith('onboarding');
}

/// Secure-storage keys (besides the session token, see [SecureSessionStore]).
class SecureKeys {
  SecureKeys._();
  static const accountName = 'user_account_name';
  static const accountNumber = 'user_account_number';
  static const accountBank = 'user_account_bank';
}

class SessionManager {
  SessionManager._({ApiTransport? transport, FlutterSecureStorage? secure})
      : _transportOverride = transport,
        _secure = secure ?? SecureSessionStore.defaultSecureStorage;

  static SessionManager instance = SessionManager._();

  @visibleForTesting
  factory SessionManager.test({required ApiTransport transport, FlutterSecureStorage? secure}) =>
      SessionManager._(transport: transport, secure: secure);

  final ApiTransport? _transportOverride;
  final FlutterSecureStorage _secure;

  ApiTransport get _transport => _transportOverride ?? ApiTransport.shared;
  SessionStore get _store => _transport.sessionStore;

  /// Hooks run during sign-out (e.g. unregister the push token). Kept as a
  /// callback list so this file does not depend on Firebase.
  final List<Future<void> Function()> _signOutHooks = [];

  void addSignOutHook(Future<void> Function() hook) => _signOutHooks.add(hook);

  /// Fired after every successful sign-in (e.g. register the push token).
  final List<Future<void> Function()> _signInHooks = [];

  void addSignInHook(Future<void> Function() hook) => _signInHooks.add(hook);

  /// True when a non-expired session token is stored.
  Future<bool> hasValidSession() async {
    final s = await _store.read();
    return s != null && s.isValid;
  }

  /// Persists everything the app needs from a successful `user_login.php`
  /// (or auto-login `user_register.php`) response's `login_msg`.
  Future<void> persistLogin(Map<String, dynamic> loginMsg, {required bool isDriver}) async {
    final token = (loginMsg['session_token'] ?? '').toString().trim();
    final expires = SecureSessionStore.parseExpiry(loginMsg['session_expires_at']?.toString());

    if (token.isNotEmpty) {
      await _store.save(token, expires);
    } else if (kDebugMode) {
      debugPrint('[Session] login_msg carried no session_token (legacy backend?)');
    }

    final prefs = await SharedPreferences.getInstance();
    String str(String k) => (loginMsg[k] ?? '').toString();

    final previousUid = prefs.getString(PrefKeys.userId);
    final uid = str('uid');
    if (previousUid != null && previousUid.isNotEmpty && previousUid != uid) {
      // A different account on this device: drop the previous user's cache.
      await _wipePrefs(prefs);
    }

    await prefs.setString(PrefKeys.userId, uid);
    await prefs.setString(PrefKeys.userName, str('fname'));
    await prefs.setString(PrefKeys.driverStatus, (loginMsg['driver_status'] ?? 'not_started').toString());
    await prefs.setString(PrefKeys.driverId, str('driver_id'));
    await prefs.setBool(PrefKeys.isDriver, isDriver);
    await prefs.setString(PrefKeys.postLoginHome, isDriver ? 'driver_home' : 'home');

    // Newer backends tell us whether a transaction PIN exists.
    final hasPin = loginMsg['has_pin'];
    if (hasPin == true || hasPin == 1 || hasPin == '1' || hasPin == 'true') {
      await prefs.setString(PrefKeys.pinFlag, 'available');
    }

    // Bank details are personal financial data → secure storage only.
    await _secureWrite(SecureKeys.accountName, str('accountname'));
    await _secureWrite(SecureKeys.accountNumber, str('accountnumber'));
    await _secureWrite(SecureKeys.accountBank, str('bankname'));
    for (final k in PrefKeys.legacySensitive) {
      await prefs.remove(k);
    }

    for (final hook in List.of(_signInHooks)) {
      unawaited(hook().catchError((Object _) {}));
    }
  }

  /// One-time migration for installs that stored sensitive values in
  /// SharedPreferences. Safe to call on every start.
  Future<void> migrateLegacyStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in PrefKeys.legacySensitive) {
        final v = prefs.get(k);
        if (v == null) continue;
        if (k.startsWith('user_account_') && v is String && v.isNotEmpty) {
          await _secureWrite(k, v);
        }
        await prefs.remove(k);
      }
    } catch (_) {}
  }

  /// Revokes the session on the server (best effort) and wipes local data.
  Future<void> logout({bool allDevices = false}) async {
    final session = await _store.read();
    if (session != null && session.token.isNotEmpty) {
      try {
        await _transport.send(
          ApiConstants.logoutEndpoint,
          method: 'POST',
          data: {if (allDevices) 'all': '1'},
          retries: 0,
          timeout: const Duration(seconds: 6),
        );
      } catch (_) {
        // Offline or already revoked – the local wipe below still signs out.
      }
    }
    await wipeLocalData();
  }

  /// Permanently deletes the account (App Store 5.1.1(v) / Google Play).
  /// Throws [ApiException] (e.g. wrong password) or a transport exception.
  Future<void> deleteAccount(String password) async {
    final res = await _transport.send(
      ApiConstants.accountDeleteEndpoint,
      method: 'POST',
      data: {'password': password},
      retries: 0,
      timeout: const Duration(seconds: 30),
    );
    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map) body = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    if (body != null && body['error'] == true) {
      throw ApiException.fromResponse(statusCode: res.statusCode == 200 ? 400 : res.statusCode, body: res.body);
    }
    await wipeLocalData();
  }

  /// Removes the session token, secure data and every user-scoped preference.
  /// Device preferences (theme, language, install id) are kept.
  Future<void> wipeLocalData() async {
    await _store.clear();
    for (final hook in List.of(_signOutHooks)) {
      try {
        await hook().timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    try {
      await _secure.deleteAll();
    } catch (_) {}
    try {
      await _wipePrefs(await SharedPreferences.getInstance());
    } catch (_) {}
  }

  Future<void> _wipePrefs(SharedPreferences prefs) async {
    for (final key in prefs.getKeys().toList()) {
      if (!PrefKeys.isDevicePreference(key)) await prefs.remove(key);
    }
  }

  Future<void> _secureWrite(String key, String value) async {
    try {
      if (value.isEmpty) {
        await _secure.delete(key: key);
      } else {
        await _secure.write(key: key, value: value);
      }
    } catch (_) {}
  }

  /// Reads a value written by [persistLogin] (e.g. [SecureKeys.accountNumber]).
  Future<String?> readSecure(String key) async {
    try {
      return await _secure.read(key: key);
    } catch (_) {
      return null;
    }
  }
}
