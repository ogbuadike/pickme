// lib/utility/device_info_service.dart
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'session_manager.dart' show PrefKeys;

/// Minimal, non-identifying device description sent with push-token
/// registration. It deliberately excludes the user-assigned device name and
/// hardware identifiers; an app-generated [installId] is used instead so the
/// backend can tell devices apart (the Android build `id` is shared by every
/// device on the same firmware and must not be used as a key).
class DeviceInfoService {
  DeviceInfoService._internal();

  static final DeviceInfoService _instance = DeviceInfoService._internal();

  factory DeviceInfoService() => _instance;

  final DeviceInfoPlugin _plugin = DeviceInfoPlugin();
  Map<String, dynamic>? _cache;

  /// Random per-install identifier (reset on reinstall, kept across sign-out).
  Future<String> installId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(PrefKeys.installId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(PrefKeys.installId, id);
    }
    return id;
  }

  Future<Map<String, dynamic>> getDeviceInfo() async {
    final cached = _cache;
    if (cached != null) return cached;
    final id = await installId();
    Map<String, dynamic> info;
    try {
      if (Platform.isAndroid) {
        final a = await _plugin.androidInfo;
        info = {
          'platform': 'Android',
          'install_id': id,
          'brand': a.brand,
          'model': a.model,
          'manufacturer': a.manufacturer,
          'androidVersion': a.version.release,
          'sdkInt': a.version.sdkInt,
        };
      } else if (Platform.isIOS) {
        final i = await _plugin.iosInfo;
        info = {
          'platform': 'iOS',
          'install_id': id,
          'model': i.utsname.machine,
          'systemName': i.systemName,
          'systemVersion': i.systemVersion,
        };
      } else {
        info = {'platform': Platform.operatingSystem, 'install_id': id};
      }
    } catch (_) {
      info = {'platform': Platform.operatingSystem, 'install_id': id};
    }
    return _cache = info;
  }
}
