import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../api/api_client.dart';
import '../api/url.dart';
import '../utility/deviceInfoService.dart';

class FCMService {
  final BuildContext context;
  final ApiClient _apiClient;
  final FirebaseMessaging _fm = FirebaseMessaging.instance;
  final DeviceInfoService _deviceInfoService = DeviceInfoService();

  FCMService(this.context) : _apiClient = ApiClient(http.Client(), context);

  Future<void> initializeFCM() async {
    try {
      // 1. Fetch token immediately on app load with recovery logic
      final token = await _getFcmTokenWithRecovery();

      // 2. Send it to the backend immediately
      if (token != null) {
        await _sendTokenToServer(token);
      }

      // 3. Listen for mid-session refreshes
      _fm.onTokenRefresh.listen((newToken) async {
        if (kDebugMode) debugPrint('FCMService: token refresh → $newToken');
        await _sendTokenToServer(newToken);
      });
    } catch (e) {
      debugPrint('Error initializing FCM: $e');
    }
  }

  /// Robust token fetch with backoff-retry for FIS Auth Errors
  Future<String?> _getFcmTokenWithRecovery() async {
    try {
      return await _fm.getToken();
    } catch (e) {
      final msg = e.toString();
      final isFisAuthError = msg.contains('FIS_AUTH_ERROR') ||
          msg.contains('Firebase Installations Service is unavailable');

      if (isFisAuthError) {
        try { await _fm.deleteToken(); } catch (_) {}

        for (int i = 0; i < 3; i++) {
          await Future<void>.delayed(Duration(milliseconds: 400 * (1 << i)));
          try {
            final t = await _fm.getToken();
            if (t != null) return t;
          } catch (_) {}
        }
      }
      debugPrint('FCM Token recovery failed: $e');
      return null;
    }
  }

  Future<void> _sendTokenToServer(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? '';

      // If there is no user logged in, you might want to return early here,
      // depending on if your backend tracks anonymous devices.
      if (userId.isEmpty) {
        debugPrint('No user ID found, skipping token sync.');
        return;
      }

      final deviceInfo = await _deviceInfoService.getDeviceInfo();
      final deviceInfoJson = jsonEncode(deviceInfo);

      final data = {
        'token': token,
        'uid': userId,
        'device': deviceInfoJson,
      };

      final res = await _apiClient.request(
        ApiConstants.sendTokenEndpoint,
        method: 'POST',
        data: data,
      );

      if (res.statusCode == 200 || res.statusCode == 201) {
        debugPrint('FCM token synced with backend successfully.');
      } else {
        debugPrint('Failed to sync FCM token: ${res.statusCode}');
      }
    } catch (e) {
      debugPrint('Error sending FCM token to backend: $e');
    }
  }
}