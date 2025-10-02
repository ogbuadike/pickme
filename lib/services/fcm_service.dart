import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../api/api_client.dart';
import '../api/url.dart';
import '../utility/deviceInfoService.dart';  // Import the DeviceInfoService
import 'dart:convert';



class FCMService {
  final BuildContext context; // BuildContext to handle notifications or navigation if needed
  final ApiClient _apiClient; // ApiClient instance to send token to the server
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance; // Firebase Messaging instance

  // Constructor to receive context and initialize ApiClient
  FCMService(this.context) : _apiClient = ApiClient(http.Client(), context);

  // Initialize DeviceInfoService
  final DeviceInfoService _deviceInfoService = DeviceInfoService();

  // Initializes FCM: Requests permissions and retrieves the FCM token
  Future<void> initializeFCM() async {
    try {
      // Request notification permissions from the user (if needed)
      await _firebaseMessaging.requestPermission();

      // Get the FCM token for this device
      String? token = await _firebaseMessaging.getToken();

      // If token is successfully retrieved, send it to the server
      if (token != null) {
        await _sendTokenToServer(token);
      }
    } catch (e) {
      // Log any errors encountered during initialization
      debugPrint('Error initializing FCM: $e');
    }
  }

  // Sends the FCM token to the server along with the user's ID
  Future<void> _sendTokenToServer(String token) async {
    try {
      // Retrieve user ID from SharedPreferences
      SharedPreferences prefs = await SharedPreferences.getInstance();
      String userId = prefs.getString('user_id') ?? ''; // Default to empty string if not found


      // Fetch device information and handle empty email input
      final deviceInfo = await _deviceInfoService.getDeviceInfo();
      final deviceInfoString = deviceInfo.entries.map((entry) {
        return '${entry.key}: ${entry.value}';
      }).join('\n');

      // Convert the deviceInfo Map to a JSON string
      final deviceInfoJson = jsonEncode(deviceInfo);

      // Prepare data to be sent to the server
      Map<String, String> data = {
        'token': token,
        'uid': userId, // Include user ID if available
        'device': deviceInfoJson,
      };

      // Send token and user ID to the server using the ApiClient
      final response = await _apiClient.request(
        ApiConstants.sendTokenEndpoint, // API endpoint
        method: 'POST', // HTTP method
        data: data, // Payload
      );

      // Log success or failure based on response status code
      if (response.statusCode == 200) {
        debugPrint('FCM token sent successfully.');
      } else {
        debugPrint('Failed to send FCM token: ${response.statusCode}');
      }
    } catch (e) {
      // Log any errors encountered when sending the token
      debugPrint('Error sending FCM token: $e');
    }
  }
}
