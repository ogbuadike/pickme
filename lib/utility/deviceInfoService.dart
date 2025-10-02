import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';

class DeviceInfoService {
  // Singleton instance
  static final DeviceInfoService _instance = DeviceInfoService._internal();
  final DeviceInfoPlugin _deviceInfoPlugin = DeviceInfoPlugin();

  // Private constructor for singleton pattern
  DeviceInfoService._internal();

  // Public getter to access the singleton instance
  factory DeviceInfoService() {
    return _instance;
  }

  // Method to get all device information
  Future<Map<String, dynamic>> getDeviceInfo() async {
    if (Platform.isAndroid) {
      return await _getAndroidDeviceInfo();
    } else if (Platform.isIOS) {
      return await _getIOSDeviceInfo();
    } else {
      return {"Error": "Unsupported platform"};
    }
  }

  // Android: Collect all relevant device info
  Future<Map<String, dynamic>> _getAndroidDeviceInfo() async {
    AndroidDeviceInfo androidInfo = await _deviceInfoPlugin.androidInfo;
    return {
      'platform': 'Android',
      'brand': androidInfo.brand,
      'model': androidInfo.model,
      'androidVersion': androidInfo.version.release,
      'device': androidInfo.device,
      'manufacturer': androidInfo.manufacturer,
      // 'androidId' might not be available; check for updated property
      'androidId': androidInfo.id ?? "Unknown Android ID",  // Use 'id' if 'androidId' is not available
    };
  }

  // iOS: Collect all relevant device info
  Future<Map<String, dynamic>> _getIOSDeviceInfo() async {
    IosDeviceInfo iosInfo = await _deviceInfoPlugin.iosInfo;
    return {
      'platform': 'iOS',
      'name': iosInfo.name ?? "Unknown iOS Device",
      'model': iosInfo.model,
      'systemName': iosInfo.systemName,
      'systemVersion': iosInfo.systemVersion,
      'localizedModel': iosInfo.localizedModel,
      'identifierForVendor': iosInfo.identifierForVendor ?? "Unknown iOS ID",
    };
  }
}
