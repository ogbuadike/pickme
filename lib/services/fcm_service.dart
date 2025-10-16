import 'dart:convert';
import 'dart:io' show Platform;
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
      // Permission (iOS only)
      if (Platform.isIOS) {
        await _fm.requestPermission(alert: true, badge: true, sound: true);
      }

      // Initial token (let PushNotificationService also do it; dedupe is fine)
      final token = await _safeGetToken();
      if (token != null) {
        await _sendTokenToServer(token);
      }

      // Keep backend updated
      _fm.onTokenRefresh.listen((newToken) async {
        if (kDebugMode) debugPrint('FCMService: token refresh → $newToken');
        await _sendTokenToServer(newToken);
      });
    } catch (e) {
      debugPrint('Error initializing FCM: $e');
    }
  }

  Future<String?> _safeGetToken() async {
    try {
      return await _fm.getToken();
    } catch (e) {
      // optional: copy the same recovery path from PushNotificationService
      return null;
    }
  }

  Future<void> _sendTokenToServer(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? '';

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

      if (res.statusCode == 200) {
        debugPrint('FCM token sent successfully.');
      } else {
        debugPrint('Failed to send FCM token: ${res.statusCode}');
      }
    } catch (e) {
      debugPrint('Error sending FCM token: $e');
    }
  }
}
