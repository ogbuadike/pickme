// lib/services/driver_location_updater.dart
//
// Single owner of the driver's GPS stream and of the live-location heartbeat
// (driver_hub.php?action=heartbeat).
//
//  * One geolocator subscription, configured per [DriverTrackingMode].
//  * Poor / stale / teleporting fixes are dropped before anyone sees them.
//  * Adaptive send cadence (fast when moving, slow when idle, none offline).
//  * Never more than one request in flight; the newest fix always wins.
//  * 429 / failures back off (Retry-After honoured when the server sends it).
//  * Background tracking (Android foreground service / iOS background updates)
//    only while a trip is active.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../driver/state/driver_api.dart';

enum DriverTrackingMode {
  /// Driver offline: no GPS, no heartbeats.
  off,

  /// Online, waiting for requests: foreground-only, battery friendly.
  idle,

  /// Active job: navigation accuracy, keeps running in the background.
  onTrip,
}

/// A filtered GPS fix with a resolved bearing.
@immutable
class DriverLocationFix {
  final double lat;
  final double lng;

  /// Horizontal accuracy (m).
  final double accuracy;

  /// Ground speed (m/s), never negative.
  final double speed;

  /// Direction of travel 0..360. Keeps the last known course while stopped.
  final double bearing;
  final DateTime time;

  const DriverLocationFix({
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.speed,
    required this.bearing,
    required this.time,
  });

  LatLng get latLng => LatLng(lat, lng);
  bool get isMoving => speed >= DriverLocationUpdater.movingSpeedMps;
  Duration get age => DateTime.now().difference(time);

  DriverGpsPayload toPayload() =>
      DriverGpsPayload(lat: lat, lng: lng, heading: bearing, speed: speed, accuracy: accuracy);
}

typedef DriverHeartbeatSender = Future<void> Function(DriverLocationFix fix, String phase);

class DriverLocationUpdater {
  static const double movingSpeedMps = 1.5;
  static const double fastSpeedMps = 8.0; // ~29 km/h
  static const double maxAccuracyM = 50.0;
  static const double relaxedAccuracyM = 100.0;
  static const Duration maxFixAge = Duration(seconds: 20);
  static const double maxPlausibleSpeedMps = 70.0; // 250 km/h

  final ApiClient api;

  /// Latest accepted fix (drives the map). Updated at GPS rate.
  final ValueNotifier<DriverLocationFix?> fix = ValueNotifier<DriverLocationFix?>(null);

  /// Time of the last heartbeat the server acknowledged.
  final ValueNotifier<DateTime?> lastSentAt = ValueNotifier<DateTime?>(null);

  /// `phase` sent with each heartbeat (see `DriverRideStatus.heartbeatPhase`).
  String Function()? phaseProvider;

  final DriverHeartbeatSender? _sender;

  DriverLocationUpdater(this.api, {DriverHeartbeatSender? sender, this.phaseProvider}) : _sender = sender;

  DriverTrackingMode _mode = DriverTrackingMode.off;
  bool _foreground = true;
  bool _disposed = false;

  StreamSubscription<Position>? _sub;
  bool? _subConfiguredForBackground;

  Timer? _sendTimer;
  bool _inFlight = false;
  bool _pendingForce = false;
  DriverLocationFix? _lastSentFix;
  DateTime? _lastSentTime;
  DateTime? _backoffUntil;
  int _failures = 0;
  DateTime? _lastAcceptedAt;
  bool _refreshingFix = false;
  DateTime? _lastFixRefresh;

  Timer? _legacyTimer;
  String? _legacyUid;

  DriverTrackingMode get mode => _mode;

  /// Switches tracking profile. Re-subscribes only when the platform settings
  /// actually differ (background capability), so calling it often is cheap.
  void setMode(DriverTrackingMode mode) {
    if (_disposed) return;
    final changed = mode != _mode;
    _mode = mode;
    _reconcile();
    if (changed && mode != DriverTrackingMode.off) flush();
  }

  /// App lifecycle hint. Idle tracking stops in the background; trip tracking
  /// continues (foreground service / iOS background updates).
  void setForeground(bool foreground) {
    if (_disposed || foreground == _foreground) return;
    _foreground = foreground;
    _reconcile();
    if (foreground && _mode != DriverTrackingMode.off) flush();
  }

  /// Re-subscribes if the stream died (e.g. permission was granted after a
  /// failure) and sends a fresh heartbeat.
  void retry() {
    if (_disposed) return;
    _reconcile();
    if (_mode != DriverTrackingMode.off) flush();
  }

  /// Send the newest fix as soon as no other request is in flight
  /// (still honours a server back-off).
  void flush() => _maybeSend(force: true);

  /// One-shot fix (e.g. before going online). Falls back to a recent
  /// last-known position. Accepted fixes are also published on [fix].
  Future<DriverLocationFix?> currentFix({Duration timeout = const Duration(seconds: 8)}) async {
    final existing = fix.value;
    if (existing != null && existing.age < const Duration(seconds: 15)) return existing;
    Position? p;
    try {
      p = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high, timeLimit: timeout);
    } catch (_) {
      try {
        if (!kIsWeb) p = await Geolocator.getLastKnownPosition();
      } catch (_) {}
    }
    if (_disposed || p == null) return fix.value;
    _onPosition(p, allowOld: const Duration(minutes: 2));
    return fix.value;
  }

  /// Legacy API (BookingController): periodically publish an externally
  /// supplied anchor. Uses the same single-flight sender.
  void start(LatLng Function()? getAnchor) {
    _legacyTimer?.cancel();
    if (getAnchor == null) return;
    _legacyTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_inFlight || _disposed) return;
      final p = getAnchor();
      final prev = fix.value;
      unawaited(_send(DriverLocationFix(
        lat: p.latitude,
        lng: p.longitude,
        accuracy: 0,
        speed: 0,
        bearing: prev?.bearing ?? 0,
        time: DateTime.now(),
      )));
    });
  }

  /// Stops everything (legacy anchor pings and GPS tracking).
  void stop() {
    _legacyTimer?.cancel();
    _legacyTimer = null;
    setMode(DriverTrackingMode.off);
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    fix.dispose();
    lastSentAt.dispose();
  }

  // ---------------------------------------------------------------------------
  // Subscription management

  bool get _shouldStream =>
      _mode == DriverTrackingMode.onTrip || (_mode == DriverTrackingMode.idle && _foreground);

  void _reconcile() {
    if (!_shouldStream) {
      _cancelStream();
      _sendTimer?.cancel();
      return;
    }
    final background = _mode == DriverTrackingMode.onTrip;
    if (_sub != null && _subConfiguredForBackground == background) return;
    _cancelStream();
    _subConfiguredForBackground = background;
    _sub =Geolocator.getPositionStream(locationSettings: _settings(background: background)).listen(
      (p) => _onPosition(p),
      onError: (Object _) {
        // The plugin closes the stream on errors (permission revoked, service
        // off). Drop it; the next setMode/setForeground re-subscribes.
        _cancelStream();
      },
      cancelOnError: true,
    );
  }

  void _cancelStream() {
    final sub = _sub;
    _sub = null;
    _subConfiguredForBackground = null;
    if (sub != null) unawaited(sub.cancel());
  }

  LocationSettings _settings({required bool background}) {
    final accuracy = background ? LocationAccuracy.bestForNavigation : LocationAccuracy.high;
    final distanceFilter = background ? 4 : 10;
    if (kIsWeb) return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: accuracy,
          distanceFilter: distanceFilter,
          intervalDuration: Duration(milliseconds: background ? 1000 : 3000),
          foregroundNotificationConfig: background
              ? const ForegroundNotificationConfig(
                  notificationTitle: 'Pick Me · trip in progress',
                  notificationText: 'Sharing your live location with your customer.',
                  notificationChannelName: 'Live trip location',
                  enableWakeLock: true, // WAKE_LOCK declared in AndroidManifest.xml
                  setOngoing: true,
                )
              : null,
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: accuracy,
          distanceFilter: distanceFilter,
          activityType: ActivityType.automotiveNavigation,
          pauseLocationUpdatesAutomatically: !background,
          allowBackgroundLocationUpdates: background,
          showBackgroundLocationIndicator: background,
        );
      default:
        return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
    }
  }

  // ---------------------------------------------------------------------------
  // Fix filtering

  void _onPosition(Position p, {Duration allowOld = maxFixAge}) {
    if (_disposed) return;
    final lat = p.latitude, lng = p.longitude;
    if (!lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) return;

    final now = DateTime.now();
    var time = p.timestamp;
    if (time.isAfter(now)) time = now; // device clock skew
    if (now.difference(time) > allowOld) return;

    final accuracy = p.accuracy.isFinite && p.accuracy > 0 ? p.accuracy : relaxedAccuracyM;
    final prev = fix.value;
    // Strict accuracy normally; relax when we have had nothing usable for a while
    // (urban canyon) so the server fix does not go stale.
    final starving = _lastAcceptedAt == null || now.difference(_lastAcceptedAt!) > const Duration(seconds: 30);
    if (accuracy > (starving ? relaxedAccuracyM : maxAccuracyM)) return;

    final speed = p.speed.isFinite && p.speed > 0 ? p.speed : 0.0;
    var bearing = prev?.bearing ?? 0.0;
    if (prev != null) {
      final dist = Geolocator.distanceBetween(prev.lat, prev.lng, lat, lng);
      final dt = time.difference(prev.time).inMilliseconds / 1000.0;
      if (dt > 0.2 && dist > 200 && dist / dt > maxPlausibleSpeedMps) return; // teleport
      if (dt <= 0 && dist < 1) return; // duplicate
      final platformHeadingValid = p.heading.isFinite && p.heading >= 0 && (p.heading != 0 || p.headingAccuracy > 0);
      if (speed >= movingSpeedMps && platformHeadingValid) {
        bearing = p.heading % 360;
      } else if (dist >= math.max(8.0, accuracy * 0.5)) {
        bearing = _bearing(prev.lat, prev.lng, lat, lng);
      }
    } else if (p.heading.isFinite && p.heading > 0) {
      bearing = p.heading % 360;
    }

    _lastAcceptedAt = now;
    fix.value = DriverLocationFix(lat: lat, lng: lng, accuracy: accuracy, speed: speed, bearing: bearing, time: time);
    _maybeSend();
  }

  static double _bearing(double lat1, double lng1, double lat2, double lng2) {
    final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
    final dl = (lng2 - lng1) * math.pi / 180;
    final y = math.sin(dl) * math.cos(p2);
    final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  static double _angleDelta(double a, double b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  // ---------------------------------------------------------------------------
  // Adaptive, single-flight sender

  Duration _intervalFor(DriverLocationFix f) {
    final onTrip = _mode == DriverTrackingMode.onTrip;
    if (f.speed >= fastSpeedMps) return Duration(seconds: onTrip ? 3 : 5);
    if (f.isMoving) return Duration(seconds: onTrip ? 5 : 8);
    return Duration(seconds: onTrip ? 10 : 20);
  }

  void _maybeSend({bool force = false}) {
    if (_disposed || _mode == DriverTrackingMode.off) return;
    if (_inFlight) {
      _pendingForce = _pendingForce || force;
      return;
    }
    final f = fix.value;
    if (f == null) return;
    final now = DateTime.now();
    // distanceFilter means a parked driver produces no stream events; refresh
    // the fix with a one-shot read before re-publishing an old one.
    if (f.age > const Duration(seconds: 60) &&
        !_refreshingFix &&
        (_lastFixRefresh == null || now.difference(_lastFixRefresh!) > const Duration(seconds: 30))) {
      _refreshingFix = true;
      _lastFixRefresh = now;
      unawaited(currentFix(timeout: const Duration(seconds: 10)).whenComplete(() {
        _refreshingFix = false;
        if (!_disposed) _maybeSend(force: force);
      }));
      return;
    }
    // Never re-publish a fix that is long dead (GPS lost): the server would
    // treat it as a fresh position.
    if (f.age > const Duration(minutes: 10)) {
      _schedule(const Duration(seconds: 30));
      return;
    }

    final backoff = _backoffUntil;
    if (backoff != null && now.isBefore(backoff)) {
      _schedule(backoff.difference(now));
      return;
    }

    final interval = _intervalFor(f);
    final lastTime = _lastSentTime;
    final last = _lastSentFix;
    if (force || lastTime == null || last == null) {
      unawaited(_send(f));
      return;
    }
    final since = now.difference(lastTime);
    var due = since >= interval;
    if (!due && since >= const Duration(seconds: 2)) {
      final moved = Geolocator.distanceBetween(last.lat, last.lng, f.lat, f.lng);
      final turned = f.isMoving && _angleDelta(last.bearing, f.bearing) > 35;
      due = moved > 80 || turned;
    }
    if (due) {
      unawaited(_send(f));
    } else {
      // Keeps a stationary driver's server fix fresh (server rejects >180 s).
      _schedule(interval - since);
    }
  }

  void _schedule(Duration delay) {
    _sendTimer?.cancel();
    if (!_shouldStream && _legacyTimer == null) return;
    _sendTimer = Timer(delay.isNegative ? Duration.zero : delay, () => _maybeSend());
  }

  Future<void> _send(DriverLocationFix f) async {
    _inFlight = true;
    _sendTimer?.cancel();
    try {
      await (_sender ?? _defaultSend)(f, phaseProvider?.call() ?? 'idle');
      if (_disposed) return;
      _lastSentFix = f;
      _lastSentTime = DateTime.now();
      _failures = 0;
      _backoffUntil = null;
      lastSentAt.value = _lastSentTime;
    } catch (e) {
      if (_disposed) return;
      _failures++;
      final exp = Duration(seconds: math.min(60, 2 << math.min(_failures, 5)));
      final wait = (e is DriverApiException ? e.retryAfter : null) ?? exp;
      _backoffUntil = DateTime.now().add(wait);
    } finally {
      _inFlight = false;
      if (!_disposed) {
        final force = _pendingForce;
        _pendingForce = false;
        _maybeSend(force: force);
      }
    }
  }

  Future<void> _defaultSend(DriverLocationFix f, String phase) async {
    _legacyUid ??= (await SharedPreferences.getInstance()).getString('user_id')?.trim() ?? '';
    await DriverHubApi(api, () => _legacyUid ?? '').heartbeat(f.toPayload(), phase: phase);
  }
}
