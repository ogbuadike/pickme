// lib/driver/state/driver_location_permission.dart
//
// Driver entry points to the app-wide location gate
// (lib/screens/state/location_permission_modal.dart). Driver code must not
// call Geolocator.requestPermission() or show its own permission UI.
import 'package:flutter/widgets.dart';

import '../../screens/state/location_permission_modal.dart';

class DriverLocationPermissionGate {
  DriverLocationPermissionGate._();

  static const String _title = 'Location for driving';
  static const String _message =
      'Pick Me uses your location while you are online to match you with nearby requests, show '
      'customers where you are and verify pickups and drop-offs. During an active trip your '
      'location is also used while the app is in the background or the screen is off.';

  /// Silent check (never shows UI): safe from polling and lifecycle callbacks.
  static Future<bool> hasAccess() => LocationPermissionModal.hasLocationAccess();

  /// Interactive check. Shares the app-wide single in-flight prompt. Pass
  /// [userTriggered] = false for automatic checks: the gate then shows each
  /// prompt at most once per session.
  static Future<bool> ensure(BuildContext context, {bool userTriggered = true}) async {
    final status = await LocationPermissionModal.ensure(
      context,
      userTriggered: userTriggered,
      title: _title,
      message: _message,
    );
    return status.isGranted;
  }
}
