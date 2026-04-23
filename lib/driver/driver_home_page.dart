// lib/driver/driver_home_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
import '../widgets/inner_background.dart';
import '../screens/trip_navigation_page.dart';
import '../screens/authentication/transactionAuthSheet.dart';

// --- ENTERPRISE DELEGATES ---
import '../screens/state/map_graphics_engine.dart';
import '../screens/state/location_permission_modal.dart';
import 'state/driver_models.dart';
import 'state/driver_command_center.dart';

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
  bool _booting = true;
  bool _busyOnlineToggle = false;
  bool _busyRideAction = false;
  bool _dashboardConnected = true;
  bool _panelExpanded = false;
  int _currentIndex = 0;

  DriverProfile? _driver;
  RideJob? _activeRide;
  List<RideJob> _queue = const <RideJob>[];

  GoogleMapController? _map;
  Position? _currentPosition;
  StreamSubscription<Position>? _locationSub;
  Timer? _dashboardTimer;
  Timer? _heartbeatTimer;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = ApiClient(http.Client(), context);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dashboardTimer?.cancel();
    _heartbeatTimer?.cancel();
    _locationSub?.cancel();
    try { _map?.dispose(); } catch (_) {}
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

  Future<void> _bootstrap() async {
    if (mounted) setState(() => _booting = true);

    try {
      _prefs = await SharedPreferences.getInstance();

      await _preloadIcons();
      await Future.wait<void>([
        _fetchUser(),
        _fetchDashboard(initial: true),
      ]);

      _startDashboardPolling(forceNow: false);

      if (_driver?.isOnline == true) {
        await _startLocationEngine();
      }
    } catch (e) {
      if (!mounted) return;
      _statusMessage = e.toString().replaceFirst('Exception: ', '');
      showToastNotification(context: context, title: 'Dashboard unavailable', message: _statusMessage ?? 'Please try again.', isSuccess: false);
    } finally {
      if (mounted) setState(() => _booting = false);
    }
  }

  Future<void> _preloadIcons() async {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final results = await Future.wait<BitmapDescriptor>([
      MapGraphicsEngine.createPremiumAvatarPin(avatarImage: null, isDark: isDark, cs: cs),
      MapGraphicsEngine.createRingDotMarker(const Color(0xFF1E8E3E)), // Pickup (Green)
      MapGraphicsEngine.createRingDotMarker(const Color(0xFFE53935)), // Drop (Red)
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

      final res = await _api.request(ApiConstants.userInfoEndpoint, method: 'POST', data: {'user': uid});
      final body = jsonDecode(res.body);

      if (res.statusCode == 200 && body is Map && body['error'] == false) {
        final raw = body['user'];
        if (raw is Map) {
          if (!mounted) return;
          setState(() {
            _user = raw.map((k, v) => MapEntry<String, dynamic>(k.toString(), v));
          });

          // Re-generate pin if avatar exists
          final avatarUrl = raw['user_logo']?.toString() ?? '';
          if (avatarUrl.isNotEmpty) {
            try {
              final resp = await http.get(Uri.parse(avatarUrl)).timeout(const Duration(seconds: 5));
              if (resp.statusCode == 200) {
                final codec = await ui.instantiateImageCodec(resp.bodyBytes);
                final frame = await codec.getNextFrame();
                final theme = Theme.of(context);
                _userPinIcon = await MapGraphicsEngine.createPremiumAvatarPin(
                  avatarImage: frame.image,
                  isDark: theme.brightness == Brightness.dark,
                  cs: theme.colorScheme,
                );
                if (mounted) setState(() {});
              }
            } catch (_) {}
          }
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

    final res = await _api.request(_driverHubEndpoint, method: 'POST', data: {'action': 'dashboard', 'user': uid});
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
    _fitMapToContext();
  }

  void _startDashboardPolling({required bool forceNow}) {
    _dashboardTimer?.cancel();
    if (forceNow) _safeDashboardRefresh();
    _dashboardTimer = Timer.periodic(_dashboardPollInterval, (_) => _safeDashboardRefresh());
  }

  Future<void> _safeDashboardRefresh() async {
    try {
      await _fetchDashboard();
    } catch (_) {
      if (mounted) setState(() => _dashboardConnected = false);
    }
  }

  Future<void> _primeCurrentLocation({bool initial = false}) async {
    try {
      final hasPermission = await _ensureLocationPermission();
      if (!hasPermission) return;
      final fix = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.bestForNavigation);
      _currentPosition = fix;
      if (initial) _initialCamera = CameraPosition(target: LatLng(fix.latitude, fix.longitude), zoom: 15.8);
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
      if (mounted) setState(() {});
    } catch (_) {
      if (!silent && mounted) showToastNotification(context: context, title: 'Fix unavailable', message: 'Unable to refresh live location.', isSuccess: false);
    }
  }

  Future<void> _startLocationEngine() async {
    if (!await _ensureLocationPermission()) return;
    await _refreshCurrentPosition();
    await _locationSub?.cancel();

    _locationSub = Geolocator.getPositionStream(locationSettings: _platformLocationSettings()).listen(
          (pos) { _currentPosition = pos; if (mounted) setState(() {}); _fitMapToContext(); },
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
          'heading': (pos.heading.isFinite ? pos.heading : 0).toStringAsFixed(2),
          'phase': _phaseForHeartbeat(_activeRide?.status),
        },
      );
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

    // --- REQUIRE PIN AUTHORIZATION BEFORE ACCEPTING ---
    final bool authorized = await TransactionPinBottomSheet.show(context, _api);
    if (!authorized) {
      // User cancelled the PIN sheet or failed authentication
      return;
    }

    // Proceed with acceptance
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
      final res = await _api.request(_driverHubEndpoint, method: 'POST', data: {'action': 'dashboard', 'user': uid});
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
        'driver_heading': (live is Map ? live['heading'] : null) ?? _currentPosition?.heading ?? 0.0,
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
            onCompleteTrip: () async => _performRideAction('complete_trip'),
            onCancelTrip: () async => _performRideAction('cancel'),
            role: TripNavigationRole.driver,
            tickEvery: const Duration(seconds: 2),
            routeMinGap: const Duration(seconds: 2),
            arrivalMeters: 35.0,
            routeMoveThresholdMeters: 8.0,
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

    if (mounted) await _fetchDashboard();
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
          if (pos != null) 'heading': (pos.heading.isFinite ? pos.heading : 0).toStringAsFixed(2),
          if (pos != null) 'accuracy': pos.accuracy.toStringAsFixed(2),
        },
      );

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
    final map = _map;
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

    map.animateCamera(CameraUpdate.newLatLngBounds(LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)), 140));
  }

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{};
    if (_currentPosition != null && _userPinIcon != null) {
      markers.add(Marker(
        markerId: const MarkerId('driver_self'),
        position: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        icon: _userPinIcon!,
        rotation: _currentPosition!.heading.isFinite ? _currentPosition!.heading : 0,
        flat: true,
        zIndex: 999,
      ));
    }

    if (_activeRide != null) {
      if (_pickupIcon != null) markers.add(Marker(markerId: const MarkerId('pickup'), position: LatLng(_activeRide!.pickupLat, _activeRide!.pickupLng), icon: _pickupIcon!));
      if (_dropIcon != null) markers.add(Marker(markerId: const MarkerId('destination'), position: LatLng(_activeRide!.destLat, _activeRide!.destLng), icon: _dropIcon!));
    }

    return markers;
  }

  Set<Polyline> _buildPolylines() {
    if (_currentPosition == null || _activeRide == null) return const <Polyline>{};
    final current = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
    final pickup = LatLng(_activeRide!.pickupLat, _activeRide!.pickupLng);
    final dest = LatLng(_activeRide!.destLat, _activeRide!.destLng);
    final status = _activeRide!.status.toLowerCase();

    final points = (status == 'in_progress' || status == 'arrived_destination') ? [current, dest] : [current, pickup];
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return <Polyline>{
      Polyline(polylineId: const PolylineId('active_trip_halo'), width: 10, points: points, color: isDark ? Colors.white.withOpacity(0.85) : Colors.white.withOpacity(0.92), startCap: Cap.roundCap, endCap: Cap.roundCap, jointType: JointType.round),
      Polyline(polylineId: const PolylineId('active_trip_line'), width: 6, points: points, color: AppColors.primary, startCap: Cap.roundCap, endCap: Cap.roundCap, jointType: JointType.round),
    };
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
          const BackgroundWidget(style: HoloStyle.vapor, animate: true, intensity: 0.7),
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: _initialCamera,
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              compassEnabled: false,
              mapToolbarEnabled: false,
              zoomControlsEnabled: false,
              rotateGesturesEnabled: true,
              tiltGesturesEnabled: true,
              markers: _buildMarkers(),
              polylines: _buildPolylines(),
              onMapCreated: (controller) {
                _map = controller;
                if (theme.brightness == Brightness.dark) {
                  _map!.setMapStyle('''[{"elementType":"geometry","stylers":[{"color":"#212121"}]},{"elementType":"labels.icon","stylers":[{"visibility":"off"}]},{"elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},{"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#2c2c2c"}]},{"featureType":"water","elementType":"geometry","stylers":[{"color":"#000000"}]}]''');
                }
                _fitMapToContext();
              },
            ),
          ),
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
          if (!_booting)
            Positioned(
              right: uiScale.inset(14), bottom: 12,
              child: FloatingActionButton.small(
                heroTag: 'driver_locate_fab',
                backgroundColor: cs.surface.withOpacity(0.96),
                onPressed: () {
                  if (_map != null && _currentPosition != null) _map!.animateCamera(CameraUpdate.newLatLngZoom(LatLng(_currentPosition!.latitude, _currentPosition!.longitude), 16.4));
                },
                child: const Icon(Icons.my_location_rounded),
              ),
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
              onRefresh: () => unawaited(_fetchDashboard()),
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
                if (i == 1) Navigator.pushNamed(context, AppRoutes.rideHistory);
                if (i == 4) Navigator.pushNamed(context, AppRoutes.profile);
              },
            ),
          ),
        ],
      ),
    );
  }
}