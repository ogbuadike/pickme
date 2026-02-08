import 'dart:async';
import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../api/api_client.dart';
import '../api/url.dart';

class DriverLocationUpdater {
  final ApiClient api;
  Timer? _timer;

  DriverLocationUpdater(this.api);

  void start(LatLng Function()? getAnchor) {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) async {
      final p = getAnchor?.call();
      if (p == null) return;
      try {
        await api.request(
          'drivers_update_location.php',
          method: 'POST',
          data: {
            'lat': p.latitude.toString(),
            'lng': p.longitude.toString(),
            'vehicle': 'car',
          },
        );
      } catch (_) {}
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
