// lib/services/perf_profile.dart
// Lightweight perf governor used across UI, map, and GPS.

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

class GpsProfile {
  final LocationAccuracy accuracy;
  final int distanceFilterM;
  final int intervalMs;
  const GpsProfile({
    required this.accuracy,
    required this.distanceFilterM,
    required this.intervalMs,
  });
}

class Perf with ChangeNotifier {
  Perf._();
  static final Perf I = Perf._();

  /// When the full-screen overlay is showing (typing/searching).
  bool _overlayOpen = false;

  /// Visual effects / blur budget (auto-tightened when overlay opens).
  bool reducedEffects = false;

  /// Lowering camera move cadence reduces jank and battery.
  Duration camMoveMin = const Duration(milliseconds: 60);

  /// Show lighter map while overlay is open, and hide traffic to save GPU.
  bool liteMapDuringOverlay = true;
  bool showTraffic = false;

  /// Called by the overlay on open/close.
  void setOverlayOpen(bool v) {
    if (_overlayOpen == v) return;
    _overlayOpen = v;

    // Tighten budgets while typing
    if (_overlayOpen) {
      reducedEffects = true;
      camMoveMin = const Duration(milliseconds: 120);
      showTraffic = false;
    } else {
      reducedEffects = false;
      camMoveMin = const Duration(milliseconds: 60);
      // keep traffic off by default (safer on low-end devices)
    }
    notifyListeners();
  }

  double tiltFor(double speedMps) => speedMps >= 1.5 ? 55.0 : 45.0;

  /// Keep the profile conservative; we throttle UI more than GPS to ensure
  /// location is fresh, but we skip heavy camera work while overlay is open.
  GpsProfile gpsProfile({required bool moving}) {
    if (_overlayOpen) {
      return const GpsProfile(
        accuracy: LocationAccuracy.medium,
        distanceFilterM: 12,
        intervalMs: 1500,
      );
    }
    if (moving) {
      return const GpsProfile(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilterM: 6,
        intervalMs: 900,
      );
    }
    return const GpsProfile(
      accuracy: LocationAccuracy.medium,
      distanceFilterM: 10,
      intervalMs: 1500,
    );
  }
}

class MapToggles {
  static bool liteEnabled(BuildContext _) => Perf.I.liteMapDuringOverlay;
  static bool trafficEnabled(BuildContext _) => Perf.I.showTraffic;
}
