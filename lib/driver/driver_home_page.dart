// lib/driver/driver_home_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../routes/routes.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../utility/notification.dart';
import '../widgets/app_menu_drawer.dart';
import '../widgets/bottom_navigation_bar.dart';
import '../widgets/fund_account_sheet.dart';
import '../widgets/header_bar.dart';
import '../screens/trip_navigation_page.dart';
import '../screens/authentication/transactionAuthSheet.dart';
import '../screens/state/map_graphics_engine.dart';
import '../screens/state/location_permission_modal.dart';
import 'state/driver_models.dart';
import 'state/driver_command_center.dart';
import 'widgets/delivery_otp_sheet.dart';

class _Kalman1D {
  final double q;
  final double r;
  double x;
  double p;
  double k;

  _Kalman1D({this.q = 0.00001, this.r = 0.0001, required this.x, this.p = 1.0, this.k = 0.0});

  double update(double measurement) {
    p = p + q;
    k = p / (p + r);
    x = x + k * (measurement - x);
    p = (1 - k) * p;
    return x;
  }
}

class DriverHomePage extends StatefulWidget {
  const DriverHomePage({super.key});

  @override
  State<DriverHomePage> createState() => _DriverHomePageState();
}

class _DriverHomePageState extends State<DriverHomePage> with WidgetsBindingObserver {
  static const String _driverHubEndpoint = 'driver_hub.php';
  static const Duration _dashboardPollInterval = Duration(seconds: 2);
  static const Duration _heartbeatInterval = Duration(seconds: 2);
  static const double _fallbackLat = 6.458985;
  static const double _fallbackLng = 7.548266;
  static const double _headerVisualH = 88.0;

  static const Duration _driverFixMaxAge = Duration(seconds: 180);
  static const double _pickupArrivalRadiusM = 150.0;
  static const double _tripStartRadiusM = 150.0;
  static const double _destinationArrivalRadiusM = 150.0;
  static const double _rideCompleteRadiusM = 200.0;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  late SharedPreferences _prefs;
  late ApiClient _api;

  Map<String, dynamic>? _user;
  bool _busyProfile = false;
  bool _busyOnlineToggle = false;
  bool _busyRideAction = false;
  bool _dashboardConnected = true;
  bool _panelExpanded = false;
  int _currentIndex = 2;

  GoogleMapController? _mapController;
  final ValueNotifier<Set<Marker>> _markersNotifier = ValueNotifier({});
  final ValueNotifier<Set<Polyline>> _polylinesNotifier = ValueNotifier({});
  final ValueNotifier<Set<Circle>> _circlesNotifier = ValueNotifier({});

  bool _booting = true;
  bool _fetchingDashboard = false;

  DriverProfile? _driver;
  RideJob? _activeRide;
  List<RideJob> _queue = const <RideJob>[];

  Position? _currentPosition;
  StreamSubscription<Position>? _locationSub;
  StreamSubscription<CompassEvent>? _compassSub;
  Timer? _dashboardTimer;
  Timer? _heartbeatTimer;
  Timer? _compassThrottleTimer;

  DateTime? _lastDashboardSyncAt;
  DateTime? _lastHeartbeatAt;
  String? _statusMessage;

  CameraPosition _initialCamera = const CameraPosition(
    target: LatLng(_fallbackLat, _fallbackLng),
    zoom: 15.3,
  );

  BitmapDescriptor? _userPinIcon;
  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _dropIcon;

  _Kalman1D? _latKalman;
  _Kalman1D? _lngKalman;
  double _emaHeading = 0.0;
  static const double _smoothingFactor = 0.25;

  List<LatLng> _overviewRoutePoints = [];
  String? _lastRouteId;

  final Set<Marker> _markers = <Marker>{};
  final Set<Polyline> _polylines = <Polyline>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = ApiClient(http.Client(), context);
    _bootstrap();
  }

  void _pushMapState() {
    _buildMarkersAndLines();
    _markersNotifier.value = Set.from(_markers);
    _polylinesNotifier.value = Set.from(_polylines);
  }

  void _buildMarkersAndLines() {
    _markers.clear();
    _polylines.clear();

    if (_currentPosition != null && _userPinIcon != null) {
      _markers.add(Marker(
        markerId: const MarkerId('driver_self'),
        position: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        icon: _userPinIcon!,
        rotation: _emaHeading,
        anchor: const Offset(0.5, 0.5),
        flat: true,
        zIndex: 999,
      ));
    }

    if (_activeRide != null) {
      if (_pickupIcon != null) _markers.add(Marker(markerId: const MarkerId('pickup'), position: LatLng(_activeRide!.pickupLat, _activeRide!.pickupLng), icon: _pickupIcon!, anchor: const Offset(0.5, 0.5), zIndex: 35));
      if (_dropIcon != null) _markers.add(Marker(markerId: const MarkerId('destination'), position: LatLng(_activeRide!.destLat, _activeRide!.destLng), icon: _dropIcon!, anchor: const Offset(0.5, 0.5), zIndex: 35));

      final List<LatLng> points = _overviewRoutePoints.isNotEmpty
          ? _overviewRoutePoints
          : [
        if (_currentPosition != null) LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        (_activeRide!.status.toLowerCase() == 'in_progress' || _activeRide!.status.toLowerCase() == 'arrived_destination')
            ? LatLng(_activeRide!.destLat, _activeRide!.destLng)
            : LatLng(_activeRide!.pickupLat, _activeRide!.pickupLng)
      ];

      if (points.isNotEmpty) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        _polylines.add(Polyline(polylineId: const PolylineId('active_trip_halo'), width: 10, points: points, color: isDark ? Colors.white.withOpacity(0.85) : Colors.white.withOpacity(0.92), startCap: Cap.roundCap, endCap: Cap.roundCap, jointType: JointType.round));
        _polylines.add(Polyline(polylineId: const PolylineId('active_trip_line'), width: 5, points: points, color: AppColors.primary, startCap: Cap.roundCap, endCap: Cap.roundCap, jointType: JointType.round));
      }
    }
  }

  Future<void> _bootstrap() async {
    if (mounted) setState(() => _booting = true);

    try {
      _prefs = await SharedPreferences.getInstance();
      await _preloadIcons();

      await Future.wait<void>([
        _fetchUser(),
        _fetchDashboard(initial: true),
      ]);

      _startHardwareCompass();
      _startDashboardPolling(forceNow: false);

      if (_driver?.isOnline == true) {
        await _startLocationEngine();
      }

      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      if (!mounted) return;
      _statusMessage = e.toString().replaceFirst('Exception: ', '');
      showToastNotification(context: context, title: 'Dashboard unavailable', message: _statusMessage ?? 'Please try again.', isSuccess: false);
    } finally {
      if (mounted) {
        setState(() => _booting = false);
        _pushMapState();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dashboardTimer?.cancel();
    _heartbeatTimer?.cancel();
    _locationSub?.cancel();
    _compassSub?.cancel();
    _compassThrottleTimer?.cancel();
    _markersNotifier.dispose();
    _polylinesNotifier.dispose();
    _circlesNotifier.dispose();
    try { _mapController?.dispose(); } catch (_) {}
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
      _dashboardTimer?.cancel();
      _heartbeatTimer?.cancel();
      _locationSub?.pause();
      return;
    }

    if (state == AppLifecycleState.resumed) {
      _locationSub?.resume();
      _startDashboardPolling(forceNow: true);
      if (_driver?.isOnline == true) {
        _startLocationEngine();
      }
    }
  }

  void _startHardwareCompass() {
    _compassSub?.cancel();
    _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
      if (event.heading == null) return;

      double targetHeading = event.heading! % 360.0;
      if (targetHeading < 0) targetHeading += 360.0;

      double diff = targetHeading - _emaHeading;
      while (diff < -180.0) diff += 360.0;
      while (diff > 180.0) diff -= 360.0;
      _emaHeading += diff * _smoothingFactor;

      if (_compassThrottleTimer?.isActive ?? false) return;
      _compassThrottleTimer = Timer(const Duration(milliseconds: 60), () {
        if (mounted) _pushMapState();
      });
    });
  }

  Future<void> _preloadIcons() async {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final results = await Future.wait<BitmapDescriptor>([
      MapGraphicsEngine.createPremiumAvatarPin(avatarImage: null, isDark: isDark, cs: cs),
      MapGraphicsEngine.createRingDotMarker(const Color(0xFF1A73E8)),
      MapGraphicsEngine.createRingDotMarker(const Color(0xFF00A651)),
    ]);

    _userPinIcon = results[0];
    _pickupIcon = results[1];
    _dropIcon = results[2];
  }

  Future<void> _fetchUser() async {
    if (!mounted) return;
    setState(() => _busyProfile = true);

    try {
      final uid = _prefs.getString('user_id')?.trim() ?? '';
      if (uid.isEmpty) return;

      final res = await _api.request(ApiConstants.userInfoEndpoint, method: 'POST', data: {'user': uid}).timeout(const Duration(seconds: 10));
      final body = jsonDecode(res.body);

      if (res.statusCode == 200 && body is Map && body['error'] == false) {
        final raw = body['user'];
        if (raw is Map) {
          if (!mounted) return;
          setState(() { _user = raw.map((k, v) => MapEntry<String, dynamic>(k.toString(), v)); });
        }
      }
    } catch (_) {
      _dashboardConnected = false;
    } finally {
      if (mounted) setState(() => _busyProfile = false);
    }
  }

  Future<void> _fetchDashboard({bool initial = false}) async {
    final uid = _prefs.getString('user_id')?.trim() ?? '';
    if (uid.isEmpty) throw Exception('User ID missing');

    final res = await _api.request(_driverHubEndpoint, method: 'POST', data: {'action': 'dashboard', 'user': uid}).timeout(const Duration(seconds: 10));
    final body = jsonDecode(res.body);

    if (res.statusCode != 200 || body is! Map || body['error'] == true) {
      throw Exception(body is Map ? ((body['message'] ?? body['error_msg'])?.toString()) : 'Unable to load dashboard');
    }

    final data = body['data'];
    if (data is! Map) throw Exception('Dashboard payload missing');

    final driver = DriverProfile.fromJson(data['driver'] as Map? ?? const {});
    final activeRide = data['active_ride'] is Map ? RideJob.fromJson(data['active_ride'] as Map) : null;
    final queue = (data['queue'] is List) ? (data['queue'] as List).whereType<Map>().map(RideJob.fromJson).toList(growable: false) : const <RideJob>[];

    if (!mounted) return;

    setState(() {
      _driver = driver;
      _activeRide = activeRide;
      _queue = queue;
      _dashboardConnected = true;
      _statusMessage = (data['message'] ?? body['message'])?.toString();
      _lastDashboardSyncAt = DateTime.now();
      if (_activeRide != null) _panelExpanded = true;
    });

    await _primeCurrentLocation(initial: initial);
    _fetchOverviewRoute();
    _pushMapState();
  }

  Future<void> _fetchOverviewRoute() async {
    if (_activeRide == null || _currentPosition == null) {
      if (_overviewRoutePoints.isNotEmpty) {
        _overviewRoutePoints.clear();
        _pushMapState();
      }
      return;
    }

    final status = _activeRide!.status.toLowerCase();
    final LatLng origin = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
    final LatLng dest = (status == 'in_progress' || status == 'arrived_destination')
        ? LatLng(_activeRide!.destLat, _activeRide!.destLng)
        : LatLng(_activeRide!.pickupLat, _activeRide!.pickupLng);

    final String routeId = '${_activeRide!.id}_${origin.latitude.toStringAsFixed(3)}_${dest.latitude.toStringAsFixed(3)}';
    if (_lastRouteId == routeId) return;

    try {
      final Uri url = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');
      final Map<String, dynamic> body = {
        'origin': {'location': {'latLng': {'latitude': origin.latitude, 'longitude': origin.longitude}}},
        'destination': {'location': {'latLng': {'latitude': dest.latitude, 'longitude': dest.longitude}}},
        'travelMode': 'DRIVE',
        'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
        'polylineQuality': 'OVERVIEW',
      };
      final Map<String, String> headers = {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': ApiConstants.kGoogleApiKey,
        'X-Goog-FieldMask': 'routes.polyline.encodedPolyline',
      };

      final http.Response res = await http.post(url, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body) as Map<String, dynamic>;
        final List<Map<String, dynamic>> routes = (decoded['routes'] as List?)?.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() ?? [];
        if (routes.isNotEmpty) {
          final String encoded = routes.first['polyline']?['encodedPolyline']?.toString() ?? '';
          if (encoded.isNotEmpty) {
            _lastRouteId = routeId;
            _overviewRoutePoints = _decodePolyline(encoded);
            _pushMapState();
            _fitMapToContext();
          }
        }
      }
    } catch (_) {}
  }

  List<LatLng> _decodePolyline(String enc) {
    final List<LatLng> out = [];
    int idx = 0, lat = 0, lng = 0;
    while (idx < enc.length) {
      int b, shift = 0, result = 0;
      do { b = enc.codeUnitAt(idx++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      shift = 0; result = 0;
      do { b = enc.codeUnitAt(idx++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      out.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return out;
  }

  void _startDashboardPolling({required bool forceNow}) {
    _dashboardTimer?.cancel();
    if (forceNow) _safeDashboardRefresh();
    _dashboardTimer = Timer.periodic(_dashboardPollInterval, (_) => _safeDashboardRefresh());
  }

  Future<void> _safeDashboardRefresh() async {
    if (_fetchingDashboard) return;
    _fetchingDashboard = true;
    try {
      await _fetchDashboard();
    } catch (_) {
      if (mounted) setState(() => _dashboardConnected = false);
    } finally {
      _fetchingDashboard = false;
    }
  }

  Future<void> _primeCurrentLocation({bool initial = false}) async {
    try {
      if (!await _ensureLocationPermission()) return;
      final fix = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.bestForNavigation);
      _currentPosition = fix;

      if (_latKalman == null) {
        _latKalman = _Kalman1D(x: fix.latitude);
        _lngKalman = _Kalman1D(x: fix.longitude);
      } else {
        _latKalman!.update(fix.latitude);
        _lngKalman!.update(fix.longitude);
      }

      if (initial) _initialCamera = CameraPosition(target: LatLng(fix.latitude, fix.longitude), zoom: 15.8);
      _pushMapState();
    } catch (_) {}
  }

  LocationSettings _platformLocationSettings() {
    if (kIsWeb) return const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 3);
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 3, intervalDuration: const Duration(seconds: 1), forceLocationManager: false,
        foregroundNotificationConfig: const ForegroundNotificationConfig(notificationTitle: 'Pick Me Driver', notificationText: 'Driver availability is active.', enableWakeLock: false, setOngoing: true),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 3, activityType: ActivityType.automotiveNavigation, pauseLocationUpdatesAutomatically: false, showBackgroundLocationIndicator: false);
    }
    return const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 3);
  }

  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) await LocationPermissionModal.show(context: context, title: 'Location off', message: 'Turn on location services to go online.', isServiceIssue: true);
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      if (mounted) await LocationPermissionModal.show(context: context, title: 'Permission needed', message: 'Grant location access to publish your live driver position.', isServiceIssue: false);
      return false;
    }
    return true;
  }

  Future<void> _refreshCurrentPosition({bool silent = true}) async {
    try {
      if (!await _ensureLocationPermission()) return;
      _currentPosition = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.bestForNavigation);
      _pushMapState();
    } catch (_) {
      if (!silent && mounted) showToastNotification(context: context, title: 'Fix unavailable', message: 'Unable to refresh live location.', isSuccess: false);
    }
  }

  Future<void> _startLocationEngine() async {
    if (!await _ensureLocationPermission()) return;
    await _refreshCurrentPosition();
    await _locationSub?.cancel();

    _locationSub = Geolocator.getPositionStream(locationSettings: _platformLocationSettings()).listen(
          (pos) {
        if (_latKalman != null && _lngKalman != null) {
          double lat = _latKalman!.update(pos.latitude);
          double lng = _lngKalman!.update(pos.longitude);
          _currentPosition = Position(longitude: lng, latitude: lat, timestamp: pos.timestamp, accuracy: pos.accuracy, altitude: pos.altitude, altitudeAccuracy: pos.altitudeAccuracy, heading: pos.heading, headingAccuracy: pos.headingAccuracy, speed: pos.speed, speedAccuracy: pos.speedAccuracy);
        } else {
          _currentPosition = pos;
        }
        _pushMapState();
        _fetchOverviewRoute();
      },
      onError: (_) { if (mounted) showToastNotification(context: context, title: 'Stream interrupted', message: 'Live location stream will retry.', isSuccess: false); },
    );

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _pushHeartbeat());
    await _pushHeartbeat();
  }

  Future<void> _stopLocationEngine() async {
    _heartbeatTimer?.cancel(); _heartbeatTimer = null;
    await _locationSub?.cancel(); _locationSub = null;
  }

  Future<void> _pushHeartbeat() async {
    final driver = _driver;
    if (!mounted || driver == null || !driver.isOnline) return;

    Position? pos = _currentPosition;
    if (pos == null) { await _refreshCurrentPosition(); pos = _currentPosition; }
    if (pos == null) return;

    try {
      await _api.request(
        _driverHubEndpoint, method: 'POST',
        data: {
          'action': 'heartbeat', 'user': _prefs.getString('user_id')?.trim() ?? '',
          'lat': pos.latitude.toStringAsFixed(7), 'lng': pos.longitude.toStringAsFixed(7),
          'heading': _emaHeading.toStringAsFixed(2),
          'phase': _phaseForHeartbeat(_activeRide?.status),
        },
      ).timeout(const Duration(seconds: 5));

      if (mounted) setState(() => _lastHeartbeatAt = DateTime.now());
    } catch (_) {}
  }

  String _phaseForHeartbeat(String? rideStatus) {
    switch ((rideStatus ?? '').trim().toLowerCase()) {
      case 'accepted': case 'enroute_pickup': return 'enroute_pickup';
      case 'arrived_pickup': return 'waiting_pickup';
      case 'in_progress': return 'enroute_destination';
      case 'arrived_destination': return 'arrived_destination';
      default: return 'idle';
    }
  }

  Future<void> _toggleOnline(bool value) async {
    final driver = _driver;
    if (driver == null || _busyOnlineToggle) return;
    setState(() => _busyOnlineToggle = true);

    try {
      final uid = _prefs.getString('user_id')?.trim() ?? '';
      final res = await _api.request(_driverHubEndpoint, method: 'POST', data: {'action': 'set_online', 'user': uid, 'is_online': value ? '1' : '0'});
      final body = jsonDecode(res.body);

      if (res.statusCode != 200 || body is! Map || body['error'] == true) {
        throw Exception(body is Map ? (body['message'] ?? body['error_msg']) : 'Unable to update online status');
      }

      if (!mounted) return;
      setState(() {
        _driver = driver.copyWith(isOnline: value);
        _statusMessage = (body['message'] ?? 'Status updated').toString();
      });

      if (value) { await _startLocationEngine(); } else { await _stopLocationEngine(); }
      await _fetchDashboard();
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (mounted) showToastNotification(context: context, title: 'Update failed', message: e.toString().replaceFirst('Exception: ', ''), isSuccess: false);
    } finally {
      if (mounted) setState(() => _busyOnlineToggle = false);
    }
  }

  Future<void> _acceptRide(RideJob ride) async {
    if (_busyRideAction) return;

    final bool authorized = await TransactionPinBottomSheet.show(context, _api);
    if (!authorized) return;

    setState(() => _busyRideAction = true);

    try {
      final res = await _api.request(_driverHubEndpoint, method: 'POST', data: {'action': 'accept_ride', 'user': _prefs.getString('user_id')?.trim() ?? '', 'ride_id': ride.id.toString()});
      final body = jsonDecode(res.body);

      if (res.statusCode != 200 || body is! Map || body['error'] == true) throw Exception(body is Map ? (body['message'] ?? body['error_msg']) : 'Ride acceptance failed');

      if (!mounted) return;
      HapticFeedback.heavyImpact();
      showToastNotification(context: context, title: 'Ride accepted', message: (body['message'] ?? 'Trip assigned to you.').toString(), isSuccess: true);
      await _fetchDashboard();
    } catch (e) {
      if (mounted) showToastNotification(context: context, title: 'Unable to accept', message: e.toString().replaceFirst('Exception: ', ''), isSuccess: false);
    } finally {
      if (mounted) setState(() => _busyRideAction = false);
    }
  }

  double _distanceMeters(LatLng a, LatLng b) => Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude);

  String? _localRideActionGuard(RideJob ride, String action) {
    final pos = _currentPosition;
    final normalized = action.trim().toLowerCase();

    if (normalized == 'enroute_pickup' || normalized == 'head_to_pickup' || normalized.contains('cancel')) return null;

    if (pos == null) return 'Current GPS fix unavailable. Wait for location to stabilise.';
    if (pos.timestamp != null && DateTime.now().difference(pos.timestamp!) > _driverFixMaxAge) return 'Location fix is stale. Wait for GPS update.';

    final gpsErrorMargin = pos.accuracy > 0 ? pos.accuracy : 10.0;
    final compensation = math.min(gpsErrorMargin, 150.0);

    final driverLL = LatLng(pos.latitude, pos.longitude);
    final pickupLL = LatLng(ride.pickupLat, ride.pickupLng);
    final destLL = LatLng(ride.destLat, ride.destLng);

    if (normalized == 'arrived_pickup' && _distanceMeters(driverLL, pickupLL) > (_pickupArrivalRadiusM + compensation)) {
      return 'You must be at the pickup point. Current gap: ${_distanceMeters(driverLL, pickupLL).toStringAsFixed(0)}m.';
    }
    if (normalized == 'start_trip' && _distanceMeters(driverLL, pickupLL) > (_tripStartRadiusM + compensation)) {
      return 'Trip can only start at pickup. Current gap: ${_distanceMeters(driverLL, pickupLL).toStringAsFixed(0)}m.';
    }
    if (normalized == 'arrived_destination' && _distanceMeters(driverLL, destLL) > (_destinationArrivalRadiusM + compensation)) {
      return 'You need to reach destination first. Current gap: ${_distanceMeters(driverLL, destLL).toStringAsFixed(0)}m.';
    }
    if ((normalized == 'complete' || normalized == 'complete_trip') && _distanceMeters(driverLL, destLL) > (_rideCompleteRadiusM + compensation)) {
      return 'Ride can only be completed at destination. Current gap: ${_distanceMeters(driverLL, destLL).toStringAsFixed(0)}m.';
    }
    return null;
  }

  TripNavPhase _driverTripPhaseFor(String status) {
    switch (status.trim().toLowerCase()) {
      case 'completed': return TripNavPhase.completed;
      case 'canceled': case 'cancelled': return TripNavPhase.cancelled;
      case 'arrived_pickup': return TripNavPhase.waitingPickup;
      case 'in_progress': case 'arrived_destination': return TripNavPhase.enRoute;
      default: return TripNavPhase.driverToPickup;
    }
  }

  Future<Map<String, dynamic>?> _driverTripSnapshotProvider() async {
    final ride = _activeRide;
    final driver = _driver;
    if (ride == null || driver == null) return null;

    try {
      final uid = _prefs.getString('user_id')?.trim() ?? '';
      if (uid.isEmpty) return null;
      final res = await _api.request(_driverHubEndpoint, method: 'POST', data: {'action': 'dashboard', 'user': uid}).timeout(const Duration(seconds: 10));
      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body is! Map || body['error'] == true) return null;

      final data = body['data'];
      final activeRide = data['active_ride'];
      final live = data['driver_live'];
      final status = (activeRide['status'] ?? ride.status).toString();

      return <String, dynamic>{
        'ride_id': activeRide['id']?.toString() ?? ride.id.toString(),
        'status': status, 'phase': status, 'ride_status': status,
        'driver_id': driver.id.toString(),
        'driver_lat': (live is Map ? live['lat'] : null) ?? _currentPosition?.latitude ?? ride.pickupLat,
        'driver_lng': (live is Map ? live['lng'] : null) ?? _currentPosition?.longitude ?? ride.pickupLng,
        'driver_heading': _emaHeading,
        'pickup_lat': activeRide['pickup_lat'] ?? ride.pickupLat,
        'pickup_lng': activeRide['pickup_lng'] ?? ride.pickupLng,
        'pickup_text': activeRide['pickup_text'] ?? ride.pickupText,
        'destination_lat': activeRide['dest_lat'] ?? ride.destLat,
        'destination_lng': activeRide['dest_lng'] ?? ride.destLng,
        'destination_text': activeRide['dest_text'] ?? ride.destText,
        'rider_lat': activeRide['pickup_lat'] ?? ride.pickupLat,
        'rider_lng': activeRide['pickup_lng'] ?? ride.pickupLng,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _openTripNavigation() async {
    final ride = _activeRide;
    final driver = _driver;
    if (ride == null || driver == null) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripNavigationPage(
          args: TripNavigationArgs(
            userId: ride.riderId,
            driverId: driver.id.toString(),
            tripId: ride.id.toString(),
            pickup: LatLng(ride.pickupLat, ride.pickupLng),
            destination: LatLng(ride.destLat, ride.destLng),
            originText: ride.pickupText,
            destinationText: ride.destText,
            driverName: driver.name,
            vehicleType: driver.vehicleType,
            carPlate: driver.carPlate,
            rating: driver.rating,
            initialDriverLocation: _currentPosition == null ? null : LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            initialRiderLocation: LatLng(ride.pickupLat, ride.pickupLng),
            initialPhase: _driverTripPhaseFor(ride.status),
            liveSnapshotProvider: _driverTripSnapshotProvider,
            onArrivedPickup: () async => _performRideAction('arrived_pickup'),
            onStartTrip: () async => _performRideAction('start_trip'),
            onArrivedDestination: () async => _performRideAction('arrived_destination'),
            onCompleteTrip: () async {
              final String type = (ride.rideType).trim().toLowerCase();

              if (type == 'send_me' || type == 'dispatch') {
                final phoneToCall = type == 'dispatch' ? (ride.recipientPhone ?? ride.riderPhone ?? 'Customer') : (ride.riderPhone ?? 'Customer');

                final bool isVerified = await DeliveryOtpSheet.show(
                  context,
                  _api,
                  _prefs.getString('user_id')?.trim() ?? '',
                  ride.id.toString(),
                  phoneToCall,
                );

                if (isVerified) {
                  await _performRideAction('complete_trip');
                }
              } else {
                await _performRideAction('complete_trip');
              }
            },
            onCancelTrip: () async => _performRideAction('cancel'),
            role: TripNavigationRole.driver,
            tickEvery: const Duration(seconds: 1),
            routeMinGap: const Duration(seconds: 20),
            arrivalMeters: 35.0,
            routeMoveThresholdMeters: 25.0,
            autoFollowCamera: true,
            showArrivedPickupButton: const {'accepted', 'driver_assigned', 'driver_arriving', 'enroute_pickup'}.contains(ride.status.trim().toLowerCase()),
            showStartTripButton: ride.status.trim().toLowerCase() == 'arrived_pickup',
            showArrivedDestinationButton: ride.status.trim().toLowerCase() == 'in_progress',
            showCompleteTripButton: ride.status.trim().toLowerCase() == 'arrived_destination',
            showCancelButton: true,
            showMetaCard: true,
            showDebugPanel: false,
            enableLivePickupTracking: false,
            preserveStopOrder: true,
            autoCloseOnCancel: false,
          ),
        ),
      ),
    );

    if (mounted) {
      await _fetchDashboard();
    }
  }

  Future<void> _performRideAction(String action, {bool showFeedback = true}) async {
    final ride = _activeRide;
    if (ride == null || _busyRideAction) return;

    final String? guard = _localRideActionGuard(ride, action);
    if (guard != null) {
      if (showFeedback && mounted) showToastNotification(context: context, title: 'Action blocked', message: guard, isSuccess: false);
      return;
    }

    if (mounted) setState(() => _busyRideAction = true);

    try {
      await _refreshCurrentPosition(silent: false);
      final pos = _currentPosition;
      final res = await _api.request(
        _driverHubEndpoint, method: 'POST',
        data: {
          'action': 'ride_action', 'user': _prefs.getString('user_id')?.trim() ?? '',
          'ride_id': ride.id.toString(), 'ride_action': action,
          if (pos != null) 'lat': pos.latitude.toStringAsFixed(7),
          if (pos != null) 'lng': pos.longitude.toStringAsFixed(7),
          if (pos != null) 'heading': _emaHeading.toStringAsFixed(2),
          if (pos != null) 'accuracy': pos.accuracy.toStringAsFixed(2),
        },
      ).timeout(const Duration(seconds: 10));

      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body is! Map || body['error'] == true) throw Exception(body is Map ? (body['message'] ?? body['error_msg']) : 'Ride update failed');

      if (mounted && showFeedback) showToastNotification(context: context, title: 'Trip updated', message: (body['message'] ?? 'Driver trip status updated.').toString(), isSuccess: true);
      HapticFeedback.selectionClick();
      await _fetchDashboard();
      await _pushHeartbeat();
    } catch (e) {
      if (mounted && showFeedback) showToastNotification(context: context, title: 'Ride action failed', message: e.toString().replaceFirst('Exception: ', ''), isSuccess: false);
    } finally {
      if (mounted) setState(() => _busyRideAction = false);
    }
  }

  void _fitMapToContext() {
    final map = _mapController;
    if (map == null) return;

    final points = <LatLng>[];
    if (_currentPosition != null) points.add(LatLng(_currentPosition!.latitude, _currentPosition!.longitude));
    if (_activeRide != null) {
      points.add(LatLng(_activeRide!.pickupLat, _activeRide!.pickupLng));
      points.add(LatLng(_activeRide!.destLat, _activeRide!.destLng));
    }

    if (points.isEmpty) return;
    if (points.length == 1) {
      map.animateCamera(CameraUpdate.newLatLngZoom(points.first, 16.0));
      return;
    }

    double minLat = points.first.latitude, maxLat = points.first.latitude;
    double minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final point in points.skip(1)) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    map.animateCamera(CameraUpdate.newLatLngBounds(LatLngBounds(southwest: LatLng(minLat - 0.005, minLng - 0.005), northeast: LatLng(maxLat + 0.005, maxLng + 0.005)), 140));
  }

  void _openWallet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FundAccountSheet(
        account: _user,
        balance: double.tryParse((_user?['user_bal'] ?? _user?['bal'])?.toString() ?? '0') ?? 0.0,
        currency: (_user?['user_currency'] ?? 'NGN').toString(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mq = MediaQuery.of(context);
    final safeTop = mq.padding.top;
    final headerHeight = safeTop + _headerVisualH;

    final panelExpandedHeight = uiScale.landscape ? (mq.size.height * 0.45).clamp(250.0, 320.0) : (mq.size.height * 0.45).clamp(300.0, 420.0);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: theme.scaffoldBackgroundColor,
      drawer: AppMenuDrawer(user: _user),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: _booting
                ? Container(color: theme.scaffoldBackgroundColor)
                : _IsolatedDriverMapLayer(
              markersNotifier: _markersNotifier,
              polylinesNotifier: _polylinesNotifier,
              circlesNotifier: _circlesNotifier,
              initialCameraPosition: _initialCamera,
              isDark: theme.brightness == Brightness.dark,
              onMapCreated: (controller) {
                _mapController = controller;
                _fitMapToContext();
              },
            ),
          ),

          if (!_booting)
            Stack(
              children: [
                Positioned(
                  top: 0, left: 0, right: 0,
                  child: IgnorePointer(
                    child: Container(
                      height: headerHeight + 18,
                      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withOpacity(.64), Colors.transparent])),
                    ),
                  ),
                ),
                Positioned(
                  top: safeTop, left: 0, right: 0,
                  child: HeaderBar(user: _user, busyProfile: _busyProfile, onMenu: () => _scaffoldKey.currentState?.openDrawer(), onWallet: _openWallet, onNotifications: () => Navigator.pushNamed(context, AppRoutes.notifications)),
                ),
                if (!_dashboardConnected)
                  Positioned(
                    top: headerHeight + 8, left: uiScale.inset(14), right: uiScale.inset(14),
                    child: Material(
                      color: Colors.orange.shade700, borderRadius: BorderRadius.circular(uiScale.radius(12)),
                      child: Padding(
                        padding: EdgeInsets.all(uiScale.inset(10)),
                        child: Row(children: [Icon(Icons.wifi_off_rounded, size: uiScale.icon(18), color: Colors.white), SizedBox(width: uiScale.gap(8)), Expanded(child: Text('Connection issue. Dashboard will retry automatically.', style: TextStyle(color: Colors.white, fontSize: uiScale.font(12), fontWeight: FontWeight.w700)))]),
                      ),
                    ),
                  ),
                Positioned(
                  right: uiScale.inset(14), bottom: 12,
                  child: FloatingActionButton.small(
                    heroTag: 'driver_locate_fab',
                    backgroundColor: cs.surface.withOpacity(0.96),
                    onPressed: () {
                      if (_mapController != null && _currentPosition != null) _mapController!.animateCamera(CameraUpdate.newLatLngZoom(LatLng(_currentPosition!.latitude, _currentPosition!.longitude), 16.4));
                    },
                    child: const Icon(Icons.my_location_rounded),
                  ),
                ),
              ],
            ),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: uiScale.inset(12)),
            child: _booting
                ? Container(height: 150, decoration: BoxDecoration(color: cs.surface.withOpacity(0.95), borderRadius: BorderRadius.circular(uiScale.radius(28))), child: const Center(child: CircularProgressIndicator()))
                : (_activeRide != null)
            // 🚀 HIGH-END ACTIVE RIDE UI
                ? _AdvancedActiveRideCard(
              ride: _activeRide!,
              uiScale: uiScale,
              onNavigate: _openTripNavigation,
            )
            // 🛑 STANDARD COMMAND CENTER
                : DriverCommandCenter(
              uiScale: uiScale,
              height: panelExpandedHeight,
              expanded: _panelExpanded,
              driver: _driver,
              activeRide: _activeRide,
              queue: _queue,
              statusMessage: _statusMessage,
              lastSyncAt: _lastDashboardSyncAt,
              lastHeartbeatAt: _lastHeartbeatAt,
              busyOnlineToggle: _busyOnlineToggle,
              busyRideAction: _busyRideAction,
              onExpandToggle: () => setState(() => _panelExpanded = !_panelExpanded),
              onOnlineToggle: _toggleOnline,
              onWallet: _openWallet,
              onHistory: () => Navigator.pushNamed(context, AppRoutes.rideHistory),
              onProfile: () => Navigator.pushNamed(context, AppRoutes.profile),
              onRefresh: () => unawaited(_safeDashboardRefresh()),
              onAccept: _acceptRide,
              onRideAction: (action) => unawaited(_performRideAction(action)),
              onNavigate: _openTripNavigation,
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -1),
            child: CustomBottomNavBar(
              currentIndex: _currentIndex,
              onTap: (i) {
                HapticFeedback.selectionClick();
                setState(() => _currentIndex = i);
                switch (i) {
                  case 0: Navigator.pushNamed(context, AppRoutes.rideHistory); break;
                  case 1: Navigator.pushNamed(context, AppRoutes.transactions); break;
                  case 2: break;
                  case 3: Navigator.pushNamed(context, AppRoutes.settings); break;
                  case 4: Navigator.pushNamed(context, AppRoutes.profile); break;
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _IsolatedDriverMapLayer extends StatelessWidget {
  final ValueNotifier<Set<Marker>> markersNotifier;
  final ValueNotifier<Set<Polyline>> polylinesNotifier;
  final ValueNotifier<Set<Circle>> circlesNotifier;

  final CameraPosition initialCameraPosition;
  final bool isDark;
  final void Function(GoogleMapController) onMapCreated;

  const _IsolatedDriverMapLayer({
    super.key,
    required this.markersNotifier,
    required this.polylinesNotifier,
    required this.circlesNotifier,
    required this.initialCameraPosition,
    required this.isDark,
    required this.onMapCreated,
  });

  String? _getMapStyle() {
    if (!isDark) return null;
    return '''[{"elementType":"geometry","stylers":[{"color":"#212121"}]},{"elementType":"labels.icon","stylers":[{"visibility":"off"}]},{"elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},{"elementType":"labels.text.stroke","stylers":[{"color":"#212121"}]},{"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#757575"}]},{"featureType":"administrative.country","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]},{"featureType":"administrative.land_parcel","stylers":[{"visibility":"off"}]},{"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#bdbdbd"}]},{"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},{"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#181818"}]},{"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},{"featureType":"poi.park","elementType":"labels.text.stroke","stylers":[{"color":"#1b1b1b"}]},{"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#2c2c2c"}]},{"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#8a8a8a"}]},{"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#373737"}]},{"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3c3c3c"}]},{"featureType":"road.highway.controlled_access","elementType":"geometry","stylers":[{"color":"#4e4e4e"}]},{"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},{"featureType":"transit","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},{"featureType":"water","elementType":"geometry","stylers":[{"color":"#000000"}]},{"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#3d3d3d"}]}]''';
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<Set<Marker>>(
        valueListenable: markersNotifier,
        builder: (context, markers, _) {
          return ValueListenableBuilder<Set<Polyline>>(
            valueListenable: polylinesNotifier,
            builder: (context, polylines, _) {
              return ValueListenableBuilder<Set<Circle>>(
                valueListenable: circlesNotifier,
                builder: (context, circles, _) {
                  return GoogleMap(
                    initialCameraPosition: initialCameraPosition,
                    myLocationEnabled: false,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: false,
                    compassEnabled: false,
                    mapToolbarEnabled: false,
                    rotateGesturesEnabled: true,
                    tiltGesturesEnabled: true,
                    buildingsEnabled: false,
                    indoorViewEnabled: false,
                    trafficEnabled: false,
                    markers: markers,
                    polylines: polylines,
                    circles: circles,
                    onMapCreated: (c) {
                      if (isDark) c.setMapStyle(_getMapStyle());
                      onMapCreated(c);
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

// ============================================================================
// 🚀 ADVANCED ACTIVE RIDE CARD (TREE LAYOUT, IMAGE VIEWER, CALLS & FINANCES)
// ============================================================================

class _AdvancedActiveRideCard extends StatelessWidget {
  final RideJob ride;
  final UIScale uiScale;
  final VoidCallback onNavigate;

  const _AdvancedActiveRideCard({
    required this.ride,
    required this.uiScale,
    required this.onNavigate,
  });

  Future<void> _makePhoneCall(String phoneNumber) async {
    final Uri launchUri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(launchUri)) {
      await launchUrl(launchUri);
    }
  }

  void _showFullImage(BuildContext context, String imageUrl) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.all(uiScale.inset(12)),
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              panEnabled: true,
              boundaryMargin: EdgeInsets.zero,
              minScale: 1.0,
              maxScale: 4.0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(uiScale.radius(16)),
                child: Image.network(imageUrl, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white, size: 32),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final os = cs.onSurface;
    final isDark = theme.brightness == Brightness.dark;

    // -------------------------------------------------------------
    // DYNAMIC VARIABLES & FINANCIAL MATH
    // -------------------------------------------------------------
    String displayType = ride.rideType.replaceAll('_', ' ').toUpperCase();
    bool isDelivery = ride.rideType == 'send_me' || ride.rideType == 'dispatch';

    // Explicitly grab Sender and Receiver phones
    final String senderPhone = ride.riderPhone ?? '';
    final String receiverPhone = ride.recipientPhone ?? '';

    // 🔥 Dynamic Math Driven Completely by your PHP Backend
    final double feePercent = ride.appFeePercentage; // Pulled straight from DB via PHP
    final double driverPercent = 100.0 - feePercent;

    final double totalFare = ride.price;
    final double appFee = totalFare * (feePercent / 100);
    final double driverEarnings = totalFare - appFee;

    final String currency = ride.currency;
    final String payMethod = (ride.payMethod).toUpperCase();

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(uiScale.inset(16)),
      decoration: BoxDecoration(
        color: isDark ? cs.surface : Colors.white,
        borderRadius: BorderRadius.circular(uiScale.radius(24)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 20, offset: const Offset(0, 8)),
        ],
        border: Border.all(color: cs.outlineVariant.withOpacity(0.3), width: 1.0),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // HEADER (Type & Status)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Active $displayType',
                style: TextStyle(color: os, fontSize: uiScale.font(14), fontWeight: FontWeight.w900, letterSpacing: 0.3),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: uiScale.inset(10), vertical: uiScale.inset(4)),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle)),
                    SizedBox(width: uiScale.gap(6)),
                    Text('Live', style: TextStyle(color: AppColors.primary, fontSize: uiScale.font(10), fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            ],
          ),

          // SECURE OTP WARNING
          if (ride.deliveryOtp != null && ride.deliveryOtp!.isNotEmpty) ...[
            SizedBox(height: uiScale.gap(12)),
            Container(
              padding: EdgeInsets.all(uiScale.inset(8)),
              decoration: BoxDecoration(color: Colors.orange.withOpacity(0.15), borderRadius: BorderRadius.circular(uiScale.radius(8))),
              child: Row(
                children: [
                  Icon(Icons.shield_rounded, color: Colors.orange.shade700, size: uiScale.icon(14)),
                  SizedBox(width: uiScale.gap(8)),
                  Expanded(child: Text('Secure OTP required at destination to complete dropoff.', style: TextStyle(color: Colors.orange.shade800, fontSize: uiScale.font(10), fontWeight: FontWeight.w700))),
                ],
              ),
            ),
          ],

          SizedBox(height: uiScale.gap(16)),

          // FULL IMAGE VIEWER (FOR DELIVERIES)
          if (isDelivery && ride.packageImage != null && ride.packageImage!.isNotEmpty) ...[
            GestureDetector(
              onTap: () => _showFullImage(context, ride.packageImage!),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(uiScale.radius(12)),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Image.network(
                      ride.packageImage!,
                      width: double.infinity,
                      height: uiScale.gap(120),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(height: uiScale.gap(120), color: cs.surfaceVariant, child: const Icon(Icons.inventory_2_rounded)),
                    ),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.fullscreen_rounded, color: Colors.white, size: 24),
                    )
                  ],
                ),
              ),
            ),
            SizedBox(height: uiScale.gap(8)),
            Text(
              "${(ride.packageSize ?? 'PACKAGE').toUpperCase()} • ${ride.packageWeight.toStringAsFixed(1)}kg",
              style: TextStyle(color: os.withOpacity(0.6), fontSize: uiScale.font(10), fontWeight: FontWeight.w800, letterSpacing: 0.5),
            ),
            SizedBox(height: uiScale.gap(16)),
          ],

          // TREE LAYOUT FOR LOCATIONS & DUAL CALL BUTTONS
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Tree Graphics Column
              Column(
                children: [
                  Icon(Icons.radio_button_checked, color: AppColors.primary, size: uiScale.icon(16)),
                  Container(width: 2, height: uiScale.gap(45), color: os.withOpacity(0.15)),
                  Icon(Icons.location_on, color: Colors.green, size: uiScale.icon(16)),
                ],
              ),
              SizedBox(width: uiScale.gap(12)),

              // Locations Data Column
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // FROM (PICKUP / SENDER)
                    Text('FROM', style: TextStyle(color: os.withOpacity(0.5), fontSize: uiScale.font(8), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                    Text(ride.pickupText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: os, fontSize: uiScale.font(13), fontWeight: FontWeight.w800)),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(ride.riderName.isNotEmpty ? ride.riderName : 'Sender', style: TextStyle(color: os.withOpacity(0.6), fontSize: uiScale.font(11), fontWeight: FontWeight.w600)),
                            if (senderPhone.isNotEmpty)
                              Text(senderPhone, style: TextStyle(color: os.withOpacity(0.45), fontSize: uiScale.font(9), fontWeight: FontWeight.w700)),
                          ],
                        ),
                        if (senderPhone.isNotEmpty)
                          GestureDetector(
                            onTap: () => _makePhoneCall(senderPhone),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                              child: Row(
                                children: [
                                  Icon(Icons.call, color: Colors.green, size: uiScale.icon(12)),
                                  const SizedBox(width: 4),
                                  Text("Call Sender", style: TextStyle(color: Colors.green, fontWeight: FontWeight.w700, fontSize: uiScale.font(10))),
                                ],
                              ),
                            ),
                          )
                      ],
                    ),

                    SizedBox(height: uiScale.gap(16)),

                    // TO (DESTINATION / RECEIVER)
                    Text('TO', style: TextStyle(color: os.withOpacity(0.5), fontSize: uiScale.font(8), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                    Text(ride.destText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: os, fontSize: uiScale.font(13), fontWeight: FontWeight.w800)),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(isDelivery ? 'Receiver' : 'Dropoff Point', style: TextStyle(color: os.withOpacity(0.6), fontSize: uiScale.font(11), fontWeight: FontWeight.w600)),
                            if (isDelivery && receiverPhone.isNotEmpty && receiverPhone != senderPhone)
                              Text(receiverPhone, style: TextStyle(color: os.withOpacity(0.45), fontSize: uiScale.font(9), fontWeight: FontWeight.w700)),
                          ],
                        ),
                        if (isDelivery && receiverPhone.isNotEmpty && receiverPhone != senderPhone)
                          GestureDetector(
                            onTap: () => _makePhoneCall(receiverPhone),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                              child: Row(
                                children: [
                                  Icon(Icons.call, color: Colors.blue, size: uiScale.icon(12)),
                                  const SizedBox(width: 4),
                                  Text("Call Receiver", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.w700, fontSize: uiScale.font(10))),
                                ],
                              ),
                            ),
                          )
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          SizedBox(height: uiScale.gap(20)),

          // -------------------------------------------------------------
          // 💰 PROFESSIONAL FINANCIAL BREAKDOWN BLOCK (DYNAMIC FROM DB)
          // -------------------------------------------------------------
          Container(
            padding: EdgeInsets.all(uiScale.inset(14)),
            decoration: BoxDecoration(
              color: isDark ? Colors.black26 : Colors.grey.shade50,
              borderRadius: BorderRadius.circular(uiScale.radius(16)),
              border: Border.all(color: cs.outlineVariant.withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Fare & Payment Method Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                        'TOTAL FARE',
                        style: TextStyle(color: os.withOpacity(0.5), fontSize: uiScale.font(9), fontWeight: FontWeight.w800, letterSpacing: 1.0)
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                          color: payMethod == 'WALLET' ? Colors.blue.withOpacity(0.1) : Colors.orange.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: payMethod == 'WALLET' ? Colors.blue.withOpacity(0.3) : Colors.orange.withOpacity(0.3))
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(payMethod == 'WALLET' ? Icons.account_balance_wallet_rounded : Icons.payments_rounded,
                              color: payMethod == 'WALLET' ? Colors.blue : Colors.orange.shade700,
                              size: uiScale.icon(10)
                          ),
                          const SizedBox(width: 4),
                          Text(
                              payMethod,
                              style: TextStyle(color: payMethod == 'WALLET' ? Colors.blue : Colors.orange.shade700, fontSize: uiScale.font(9), fontWeight: FontWeight.w900, letterSpacing: 0.5)
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                Text(
                    '$currency ${totalFare.toStringAsFixed(2)}',
                    style: TextStyle(color: os, fontSize: uiScale.font(20), fontWeight: FontWeight.w900)
                ),

                Padding(
                  padding: EdgeInsets.symmetric(vertical: uiScale.gap(12)),
                  child: Divider(color: cs.outlineVariant.withOpacity(0.4), height: 1, thickness: 1),
                ),

                // Dynamic Revenue Split Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('YOUR EARNINGS (${driverPercent.toStringAsFixed(0)}%)', style: TextStyle(color: Colors.green, fontSize: uiScale.font(8.5), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                        Text('$currency ${driverEarnings.toStringAsFixed(2)}', style: TextStyle(color: Colors.green, fontSize: uiScale.font(14), fontWeight: FontWeight.w900)),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('APP FEE (${feePercent.toStringAsFixed(0)}%)', style: TextStyle(color: os.withOpacity(0.5), fontSize: uiScale.font(8.5), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                        Text('$currency ${appFee.toStringAsFixed(2)}', style: TextStyle(color: os.withOpacity(0.7), fontSize: uiScale.font(14), fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          // -------------------------------------------------------------

          SizedBox(height: uiScale.gap(20)),

          // MAIN ACTION BUTTON
          GestureDetector(
            onTap: onNavigate,
            child: Container(
              height: uiScale.gap(48),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(uiScale.radius(14))),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.navigation_rounded, color: Colors.white, size: uiScale.icon(16)),
                  SizedBox(width: uiScale.gap(8)),
                  Text('Open Navigation', style: TextStyle(color: Colors.white, fontSize: uiScale.font(13), fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}