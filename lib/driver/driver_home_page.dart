import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
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

class DriverHomePage extends StatefulWidget {
  const DriverHomePage({super.key});

  @override
  State<DriverHomePage> createState() => _DriverHomePageState();
}

class _DriverHomePageState extends State<DriverHomePage>
    with WidgetsBindingObserver {
  static const String _driverHubEndpoint = 'driver_hub.php';
  static const Duration _dashboardPollInterval = Duration(seconds: 2);
  static const Duration _heartbeatInterval = Duration(seconds: 2);
  static const double _fallbackLat = 6.458985;
  static const double _fallbackLng = 7.548266;
  static const double _headerVisualH = 88.0;
  static const double _bottomNavVisualH = 82.0;
  static const Duration _driverFixMaxAge = Duration(seconds: 20);
  static const double _pickupArrivalRadiusM = 80.0;
  static const double _tripStartRadiusM = 90.0;
  static const double _destinationArrivalRadiusM = 90.0;
  static const double _rideCompleteRadiusM = 120.0;

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

  _DriverProfile? _driver;
  _RideJob? _activeRide;
  List<_RideJob> _queue = const <_RideJob>[];

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dashboardTimer?.cancel();
    _heartbeatTimer?.cancel();
    _locationSub?.cancel();
    try {
      _map?.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _dashboardTimer?.cancel();
      _heartbeatTimer?.cancel();
      _locationSub?.pause();
      return;
    }

    if (state == AppLifecycleState.resumed) {
      _locationSub?.resume();
      _startDashboardPolling(forceNow: true);
      if (_driver?.isOnline == true) {
        unawaited(_startLocationEngine());
      }
    }
  }

  Future<void> _bootstrap() async {
    if (mounted) setState(() => _booting = true);

    try {
      _prefs = await SharedPreferences.getInstance();
      _api = ApiClient(http.Client(), context);

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
      showToastNotification(
        context: context,
        title: 'Driver dashboard unavailable',
        message: _statusMessage ?? 'Please try again.',
        isSuccess: false,
      );
    } finally {
      if (mounted) setState(() => _booting = false);
    }
  }

  Future<void> _fetchUser() async {
    if (!mounted) return;
    setState(() => _busyProfile = true);

    try {
      final uid = _prefs.getString('user_id')?.trim() ?? '';
      if (uid.isEmpty) return;

      final res = await _api.request(
        ApiConstants.userInfoEndpoint,
        method: 'POST',
        data: {'user': uid},
      );

      final body = jsonDecode(res.body);
      if (res.statusCode == 200 && body is Map && body['error'] == false) {
        final raw = body['user'];
        if (raw is Map) {
          if (!mounted) return;
          setState(() {
            _user = raw.map(
                  (k, v) => MapEntry<String, dynamic>(k.toString(), v),
            );
          });
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
    if (uid.isEmpty) {
      throw Exception('User ID missing');
    }

    final res = await _api.request(
      _driverHubEndpoint,
      method: 'POST',
      data: {
        'action': 'dashboard',
        'user': uid,
      },
    );

    final body = jsonDecode(res.body);
    if (res.statusCode != 200 || body is! Map || body['error'] == true) {
      final msg = body is Map
          ? ((body['message'] ?? body['error_msg'])?.toString())
          : null;
      throw Exception(msg ?? 'Unable to load driver dashboard');
    }

    final data = body['data'];
    if (data is! Map) {
      throw Exception('Dashboard payload missing');
    }

    final driver = _DriverProfile.fromJson(data['driver'] as Map? ?? const {});
    final activeRide = data['active_ride'] is Map
        ? _RideJob.fromJson(data['active_ride'] as Map)
        : null;
    final queue = (data['queue'] is List)
        ? (data['queue'] as List)
        .whereType<Map>()
        .map(_RideJob.fromJson)
        .toList(growable: false)
        : const <_RideJob>[];

    if (!mounted) return;

    setState(() {
      _driver = driver;
      _activeRide = activeRide;
      _queue = queue;
      _dashboardConnected = true;
      _statusMessage = (data['message'] ?? body['message'])?.toString();
      _lastDashboardSyncAt = DateTime.now();
      if (_activeRide != null) {
        _panelExpanded = true;
      }
    });

    await _primeCurrentLocation(initial: initial);
    _fitMapToContext();
  }

  void _startDashboardPolling({required bool forceNow}) {
    _dashboardTimer?.cancel();

    if (forceNow) {
      unawaited(_safeDashboardRefresh());
    }

    _dashboardTimer = Timer.periodic(_dashboardPollInterval, (_) {
      unawaited(_safeDashboardRefresh());
    });
  }

  Future<void> _safeDashboardRefresh() async {
    try {
      await _fetchDashboard();
    } catch (_) {
      if (mounted) {
        setState(() => _dashboardConnected = false);
      }
    }
  }

  Future<void> _primeCurrentLocation({bool initial = false}) async {
    try {
      final hasPermission = await _ensureLocationPermission();
      if (!hasPermission) return;

      final fix = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );
      _currentPosition = fix;

      if (initial) {
        _initialCamera = CameraPosition(
          target: LatLng(fix.latitude, fix.longitude),
          zoom: 15.8,
        );
      }
    } catch (_) {}
  }

  LocationSettings _platformLocationSettings() {
    if (kIsWeb) {
      return const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 3,
      );
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
        intervalDuration: const Duration(seconds: 1),
        forceLocationManager: false,
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'Pick Me Driver',
          notificationText: 'Driver availability is active.',
          enableWakeLock: false,
          setOngoing: true,
        ),
      );
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: false,
      );
    }

    return const LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 3,
    );
  }

  Future<bool> _ensureLocationPermission() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      if (mounted) {
        showToastNotification(
          context: context,
          title: 'Location off',
          message: 'Turn on location services to go online as a driver.',
          isSuccess: false,
        );
      }
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        showToastNotification(
          context: context,
          title: 'Location permission needed',
          message: 'Grant location access to publish your live driver position.',
          isSuccess: false,
        );
      }
      return false;
    }

    return true;
  }

  Future<void> _refreshCurrentPosition({bool silent = true}) async {
    try {
      final hasPermission = await _ensureLocationPermission();
      if (!hasPermission) return;
      final fix = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );
      _currentPosition = fix;
      if (mounted) setState(() {});
    } catch (_) {
      if (!silent && mounted) {
        showToastNotification(
          context: context,
          title: 'Location fix unavailable',
          message: 'Unable to refresh your live location right now.',
          isSuccess: false,
        );
      }
    }
  }

  Future<void> _startLocationEngine() async {
    final hasPermission = await _ensureLocationPermission();
    if (!hasPermission) return;

    await _refreshCurrentPosition();

    await _locationSub?.cancel();
    _locationSub = Geolocator.getPositionStream(
      locationSettings: _platformLocationSettings(),
    ).listen(
          (position) {
        _currentPosition = position;
        if (mounted) setState(() {});
        _fitMapToContext();
      },
      onError: (_) {
        if (!mounted) return;
        showToastNotification(
          context: context,
          title: 'Location stream interrupted',
          message: 'Your live location stream will retry automatically.',
          isSuccess: false,
        );
      },
    );

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      unawaited(_pushHeartbeat());
    });

    await _pushHeartbeat();
  }

  Future<void> _stopLocationEngine() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _locationSub?.cancel();
    _locationSub = null;
  }

  Future<void> _pushHeartbeat() async {
    final driver = _driver;
    if (!mounted || driver == null || !driver.isOnline) return;

    Position? pos = _currentPosition;
    if (pos == null) {
      await _refreshCurrentPosition();
      pos = _currentPosition;
    }
    if (pos == null) return;

    try {
      await _api.request(
        _driverHubEndpoint,
        method: 'POST',
        data: {
          'action': 'heartbeat',
          'user': _prefs.getString('user_id')?.trim() ?? '',
          'lat': pos.latitude.toStringAsFixed(7),
          'lng': pos.longitude.toStringAsFixed(7),
          'heading': (pos.heading.isFinite ? pos.heading : 0).toStringAsFixed(2),
          'phase': _phaseForHeartbeat(_activeRide?.status),
        },
      );

      if (!mounted) return;
      setState(() => _lastHeartbeatAt = DateTime.now());
    } catch (_) {}
  }

  String _phaseForHeartbeat(String? rideStatus) {
    switch ((rideStatus ?? '').trim().toLowerCase()) {
      case 'accepted':
      case 'enroute_pickup':
        return 'enroute_pickup';
      case 'arrived_pickup':
        return 'waiting_pickup';
      case 'in_progress':
        return 'enroute_destination';
      case 'arrived_destination':
        return 'arrived_destination';
      default:
        return 'idle';
    }
  }

  Future<void> _toggleOnline(bool value) async {
    final driver = _driver;
    if (driver == null || _busyOnlineToggle) return;

    setState(() => _busyOnlineToggle = true);

    try {
      final uid = _prefs.getString('user_id')?.trim() ?? '';
      final res = await _api.request(
        _driverHubEndpoint,
        method: 'POST',
        data: {
          'action': 'set_online',
          'user': uid,
          'is_online': value ? '1' : '0',
        },
      );

      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body is! Map || body['error'] == true) {
        throw Exception(
          body is Map
              ? (body['message'] ?? body['error_msg'])
              : 'Unable to update online status',
        );
      }

      if (!mounted) return;
      setState(() {
        _driver = driver.copyWith(isOnline: value);
        _statusMessage = (body['message'] ?? 'Status updated').toString();
      });

      if (value) {
        await _startLocationEngine();
      } else {
        await _stopLocationEngine();
      }

      await _fetchDashboard();
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (!mounted) return;
      showToastNotification(
        context: context,
        title: 'Status update failed',
        message: e.toString().replaceFirst('Exception: ', ''),
        isSuccess: false,
      );
    } finally {
      if (mounted) setState(() => _busyOnlineToggle = false);
    }
  }

  Future<void> _acceptRide(_RideJob ride) async {
    if (_busyRideAction) return;
    setState(() => _busyRideAction = true);

    try {
      final res = await _api.request(
        _driverHubEndpoint,
        method: 'POST',
        data: {
          'action': 'accept_ride',
          'user': _prefs.getString('user_id')?.trim() ?? '',
          'ride_id': ride.id.toString(),
        },
      );

      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body is! Map || body['error'] == true) {
        throw Exception(
          body is Map
              ? (body['message'] ?? body['error_msg'])
              : 'Ride acceptance failed',
        );
      }

      if (!mounted) return;
      HapticFeedback.heavyImpact();
      showToastNotification(
        context: context,
        title: 'Ride accepted',
        message: (body['message'] ?? 'Trip assigned to you.').toString(),
        isSuccess: true,
      );
      await _fetchDashboard();
    } catch (e) {
      if (!mounted) return;
      showToastNotification(
        context: context,
        title: 'Unable to accept',
        message: e.toString().replaceFirst('Exception: ', ''),
        isSuccess: false,
      );
    } finally {
      if (mounted) setState(() => _busyRideAction = false);
    }
  }

  double _distanceMeters(LatLng a, LatLng b) => Geolocator.distanceBetween(
    a.latitude,
    a.longitude,
    b.latitude,
    b.longitude,
  );

  bool _isFixFresh(Position? pos) {
    final DateTime? stamp = pos?.timestamp;
    if (stamp == null) return pos != null;
    return DateTime.now().difference(stamp) <= _driverFixMaxAge;
  }

  String? _localRideActionGuard(_RideJob ride, String action) {
    final pos = _currentPosition;
    final normalized = action.trim().toLowerCase();
    if (normalized == 'enroute_pickup' || normalized == 'head_to_pickup') {
      return null;
    }
    if (pos == null) {
      return 'Current GPS fix unavailable. Wait for location to stabilise and try again.';
    }
    if (!_isFixFresh(pos)) {
      return 'Location fix is stale. Keep the app open until live GPS updates again.';
    }

    final driverLL = LatLng(pos.latitude, pos.longitude);
    final pickupLL = LatLng(ride.pickupLat, ride.pickupLng);
    final destLL = LatLng(ride.destLat, ride.destLng);

    if (normalized == 'arrived_pickup') {
      final meters = _distanceMeters(driverLL, pickupLL);
      if (meters > _pickupArrivalRadiusM) {
        return 'You must be at the rider pickup point before marking arrived. Current gap: ${meters.toStringAsFixed(0)} m.';
      }
      return null;
    }

    if (normalized == 'start_trip') {
      final meters = _distanceMeters(driverLL, pickupLL);
      if (meters > _tripStartRadiusM) {
        return 'Trip can only start when driver and rider are together at pickup. Current gap: ${meters.toStringAsFixed(0)} m.';
      }
      return null;
    }

    if (normalized == 'arrived_destination') {
      final meters = _distanceMeters(driverLL, destLL);
      if (meters > _destinationArrivalRadiusM) {
        return 'You need to reach the trip destination before marking arrived. Current gap: ${meters.toStringAsFixed(0)} m.';
      }
      return null;
    }

    if (normalized == 'complete' || normalized == 'complete_trip') {
      final meters = _distanceMeters(driverLL, destLL);
      if (meters > _rideCompleteRadiusM) {
        return 'Ride can only be completed at the destination zone. Current gap: ${meters.toStringAsFixed(0)} m.';
      }
      return null;
    }

    return null;
  }

  TripNavPhase _driverTripPhaseFor(String status) {
    switch (status.trim().toLowerCase()) {
      case 'completed':
        return TripNavPhase.completed;
      case 'canceled':
      case 'cancelled':
        return TripNavPhase.cancelled;
      case 'arrived_pickup':
        return TripNavPhase.waitingPickup;
      case 'in_progress':
      case 'arrived_destination':
        return TripNavPhase.enRoute;
      default:
        return TripNavPhase.driverToPickup;
    }
  }

  Future<Map<String, dynamic>?> _driverTripSnapshotProvider() async {
    final ride = _activeRide;
    final driver = _driver;
    if (ride == null || driver == null) return null;

    try {
      final uid = _prefs.getString('user_id')?.trim() ?? '';
      if (uid.isEmpty) return null;
      final res = await _api.request(
        _driverHubEndpoint,
        method: 'POST',
        data: {
          'action': 'dashboard',
          'user': uid,
        },
      );
      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body is! Map || body['error'] == true) {
        return null;
      }
      final data = body['data'];
      if (data is! Map) return null;
      final activeRide = data['active_ride'];
      final live = data['driver_live'];
      if (activeRide is! Map) return null;
      final status = (activeRide['status'] ?? ride.status).toString();
      final lat = _toDouble((live is Map ? live['lat'] : null) ?? _currentPosition?.latitude, fallback: ride.pickupLat);
      final lng = _toDouble((live is Map ? live['lng'] : null) ?? _currentPosition?.longitude, fallback: ride.pickupLng);
      final heading = _toDouble((live is Map ? live['heading'] : null) ?? _currentPosition?.heading, fallback: 0);
      return <String, dynamic>{
        'ride_id': activeRide['id']?.toString() ?? ride.id.toString(),
        'trip_id': activeRide['id']?.toString() ?? ride.id.toString(),
        'status': status,
        'phase': status,
        'ride_status': status,
        'driver_id': driver.id.toString(),
        'driver_lat': lat,
        'driver_lng': lng,
        'driver_heading': heading,
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
      final pos = _currentPosition;
      if (pos == null) return null;
      return <String, dynamic>{
        'ride_id': ride.id.toString(),
        'trip_id': ride.id.toString(),
        'status': ride.status,
        'phase': ride.status,
        'ride_status': ride.status,
        'driver_id': driver.id.toString(),
        'driver_lat': pos.latitude,
        'driver_lng': pos.longitude,
        'driver_heading': pos.heading.isFinite ? pos.heading : 0,
        'pickup_lat': ride.pickupLat,
        'pickup_lng': ride.pickupLng,
        'pickup_text': ride.pickupText,
        'destination_lat': ride.destLat,
        'destination_lng': ride.destLng,
        'destination_text': ride.destText,
        'rider_lat': ride.pickupLat,
        'rider_lng': ride.pickupLng,
      };
    }
  }

  Future<void> _openTripNavigation() async {
    final ride = _activeRide;
    final driver = _driver;
    if (ride == null || driver == null) return;

    final LatLng? initialDriverLocation = _currentPosition == null
        ? null
        : LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

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
            initialDriverLocation: initialDriverLocation,
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
            showArrivedPickupButton: const {
              'accepted',
              'driver_assigned',
              'driver_arriving',
              'enroute_pickup',
            }.contains(ride.status.trim().toLowerCase()),
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

    if (!mounted) return;
    await _fetchDashboard();
  }

  Future<void> _performRideAction(String action, {bool showFeedback = true}) async {
    final ride = _activeRide;
    if (ride == null || _busyRideAction) return;

    final String? guard = _localRideActionGuard(ride, action);
    if (guard != null) {
      if (showFeedback && mounted) {
        showToastNotification(
          context: context,
          title: 'Action blocked',
          message: guard,
          isSuccess: false,
        );
      }
      return;
    }

    if (mounted) setState(() => _busyRideAction = true);

    try {
      await _refreshCurrentPosition(silent: false);
      final pos = _currentPosition;
      final res = await _api.request(
        _driverHubEndpoint,
        method: 'POST',
        data: {
          'action': 'ride_action',
          'user': _prefs.getString('user_id')?.trim() ?? '',
          'ride_id': ride.id.toString(),
          'ride_action': action,
          if (pos != null) 'lat': pos.latitude.toStringAsFixed(7),
          if (pos != null) 'lng': pos.longitude.toStringAsFixed(7),
          if (pos != null) 'heading': (pos.heading.isFinite ? pos.heading : 0).toStringAsFixed(2),
        },
      );

      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body is! Map || body['error'] == true) {
        throw Exception(body is Map ? (body['message'] ?? body['error_msg']) : 'Ride update failed');
      }

      if (!mounted) return;
      if (showFeedback) {
        showToastNotification(
          context: context,
          title: 'Trip updated',
          message: (body['message'] ?? 'Driver trip status updated.').toString(),
          isSuccess: true,
        );
      }
      HapticFeedback.selectionClick();
      await _fetchDashboard();
      await _pushHeartbeat();
    } catch (e) {
      if (!mounted) return;
      if (showFeedback) {
        showToastNotification(
          context: context,
          title: 'Ride action failed',
          message: e.toString().replaceFirst('Exception: ', ''),
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) setState(() => _busyRideAction = false);
    }
  }

  Future<void> _rideAction(String action) async {
    await _performRideAction(action);
  }

  void _fitMapToContext() {
    final map = _map;
    if (map == null) return;

    final points = <LatLng>[];
    final pos = _currentPosition;
    final ride = _activeRide;

    if (pos != null) points.add(LatLng(pos.latitude, pos.longitude));
    if (ride != null) {
      points.add(LatLng(ride.pickupLat, ride.pickupLng));
      points.add(LatLng(ride.destLat, ride.destLng));
    }

    if (points.isEmpty) return;
    if (points.length == 1) {
      unawaited(map.animateCamera(CameraUpdate.newLatLngZoom(points.first, 16.0)));
      return;
    }

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final point in points.skip(1)) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    unawaited(map.animateCamera(CameraUpdate.newLatLngBounds(bounds, 140)));
  }

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{};
    final pos = _currentPosition;
    if (pos != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('driver_self'),
          position: LatLng(pos.latitude, pos.longitude),
          infoWindow: const InfoWindow(title: 'Your live position'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          rotation: pos.heading.isFinite ? pos.heading : 0,
          flat: true,
        ),
      );
    }

    final ride = _activeRide;
    if (ride != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: LatLng(ride.pickupLat, ride.pickupLng),
          infoWindow: InfoWindow(title: 'Pickup', snippet: ride.pickupText),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        ),
      );
      markers.add(
        Marker(
          markerId: const MarkerId('destination'),
          position: LatLng(ride.destLat, ride.destLng),
          infoWindow: InfoWindow(title: 'Destination', snippet: ride.destText),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ),
      );
    }

    return markers;
  }

  Set<Polyline> _buildPolylines() {
    final pos = _currentPosition;
    final ride = _activeRide;
    if (pos == null || ride == null) return const <Polyline>{};

    final current = LatLng(pos.latitude, pos.longitude);
    final pickup = LatLng(ride.pickupLat, ride.pickupLng);
    final dest = LatLng(ride.destLat, ride.destLng);

    final status = ride.status.toLowerCase();
    final points = status == 'in_progress' || status == 'arrived_destination'
        ? <LatLng>[current, dest]
        : <LatLng>[current, pickup];

    return <Polyline>{
      Polyline(
        polylineId: const PolylineId('active_trip_line'),
        width: 5,
        points: points,
        color: AppColors.primary,
      ),
    };
  }

  void _openWallet() {
    final balance = _extractBalance(_user);
    final currency = (_user?['user_currency'] ?? _user?['currency'] ?? 'NGN')
        .toString();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FundAccountSheet(
        account: _user,
        balance: balance,
        currency: currency,
      ),
    );
  }

  void _handleBottomNavTap(int index) {
    if (!mounted) return;
    setState(() => _currentIndex = index);
    HapticFeedback.selectionClick();

    switch (index) {
      case 0:
        return;
      case 1:
        Navigator.pushNamed(context, AppRoutes.rideHistory);
        return;
      case 2:
        Navigator.pushNamed(context, AppRoutes.profile);
        return;
    }
  }

  Future<void> _locateDriver() async {
    final pos = _currentPosition;
    if (_map == null || pos == null) return;
    await _map!.animateCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(pos.latitude, pos.longitude),
        16.4,
      ),
    );
  }

  Future<void> _logout() async {
    Navigator.of(context).maybePop();
    await _prefs.remove('user_id');
    await _prefs.remove('user_pin');
    await _prefs.remove('user_driver_id');
    await _prefs.remove('user_driver_status');
    await _prefs.remove('post_login_home');
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _togglePanel() {
    if (!mounted) return;
    setState(() => _panelExpanded = !_panelExpanded);
  }

  @override
  Widget build(BuildContext context) {
    final ui = UIScale.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mq = MediaQuery.of(context);
    final safeTop = mq.padding.top;
    final safeBottom = mq.padding.bottom;
    final headerHeight = safeTop + _headerVisualH;
    final panelCollapsedHeight = mq.orientation == Orientation.landscape ? 102.0 : 108.0;
    final panelExpandedHeight = mq.orientation == Orientation.landscape
        ? (mq.size.height * 0.34).clamp(250.0, 320.0)
        : (mq.size.height * 0.38).clamp(300.0, 420.0);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: theme.scaffoldBackgroundColor,
      drawer: AppMenuDrawer(user: _user),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          const BackgroundWidget(
            style: HoloStyle.vapor,
            animate: true,
            intensity: 0.7,
          ),
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
                _fitMapToContext();
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: headerHeight + 18,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(.64),
                      Colors.black.withOpacity(.22),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.7, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: safeTop,
            left: 0,
            right: 0,
            child: HeaderBar(
              user: _user,
              busyProfile: _busyProfile,
              onMenu: () => _scaffoldKey.currentState?.openDrawer(),
              onWallet: _openWallet,
              onNotifications: () =>
                  Navigator.pushNamed(context, AppRoutes.notifications),
            ),
          ),
          if (!_dashboardConnected)
            Positioned(
              top: headerHeight + 8,
              left: ui.inset(14),
              right: ui.inset(14),
              child: _NetworkBanner(ui: ui),
            ),
          if (!_booting)
            Positioned(
              right: ui.inset(14),
              bottom: 12,
              child: FloatingActionButton.small(
                heroTag: 'driver_locate_fab',
                backgroundColor: cs.surface.withOpacity(0.96),
                onPressed: _locateDriver,
                child: const Icon(Icons.my_location_rounded),
              ),
            ),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: ui.inset(12)),
            child: _booting
                ? _LoadingDriverPanel(ui: ui)
                : _FloatingDriverPanel(
              ui: ui,
              height: _panelExpanded ? panelExpandedHeight : panelCollapsedHeight,
              expanded: _panelExpanded,
              driver: _driver,
              activeRide: _activeRide,
              queue: _queue,
              statusMessage: _statusMessage,
              lastSyncAt: _lastDashboardSyncAt,
              lastHeartbeatAt: _lastHeartbeatAt,
              busyOnlineToggle: _busyOnlineToggle,
              busyRideAction: _busyRideAction,
              onExpandToggle: _togglePanel,
              onOnlineToggle: _toggleOnline,
              onWallet: _openWallet,
              onHistory: () => Navigator.pushNamed(context, AppRoutes.rideHistory),
              onProfile: () => Navigator.pushNamed(context, AppRoutes.profile),
              onRefresh: () => unawaited(_fetchDashboard()),
              onAccept: _acceptRide,
              onRideAction: _rideAction,
              onNavigate: _openTripNavigation,
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -1),
            child: CustomBottomNavBar(
              currentIndex: _currentIndex,
              onTap: _handleBottomNavTap,
            ),
          ),
        ],
      ),
    );
  }
}

class _FloatingDriverPanel extends StatelessWidget {
  final UIScale ui;
  final double height;
  final bool expanded;
  final _DriverProfile? driver;
  final _RideJob? activeRide;
  final List<_RideJob> queue;
  final String? statusMessage;
  final DateTime? lastSyncAt;
  final DateTime? lastHeartbeatAt;
  final bool busyOnlineToggle;
  final bool busyRideAction;
  final VoidCallback onExpandToggle;
  final ValueChanged<bool> onOnlineToggle;
  final VoidCallback onWallet;
  final VoidCallback onHistory;
  final VoidCallback onProfile;
  final VoidCallback onRefresh;
  final ValueChanged<_RideJob> onAccept;
  final ValueChanged<String> onRideAction;
  final VoidCallback onNavigate;

  const _FloatingDriverPanel({
    required this.ui,
    required this.height,
    required this.expanded,
    required this.driver,
    required this.activeRide,
    required this.queue,
    required this.statusMessage,
    required this.lastSyncAt,
    required this.lastHeartbeatAt,
    required this.busyOnlineToggle,
    required this.busyRideAction,
    required this.onExpandToggle,
    required this.onOnlineToggle,
    required this.onWallet,
    required this.onHistory,
    required this.onProfile,
    required this.onRefresh,
    required this.onAccept,
    required this.onRideAction,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final driverOnline = driver?.isOnline == true;
    final status = activeRide?.status ?? (driverOnline ? 'online' : 'offline');
    final statusColor = _statusColor(status);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      constraints: BoxConstraints(
        minHeight: expanded ? math.min(220, height) : 96,
        maxHeight: height,
      ),
      decoration: BoxDecoration(
        color: cs.surface.withOpacity(0.97),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(ui.radius(28)),
          topRight: Radius.circular(ui.radius(28)),
          bottomLeft: const Radius.circular(0),
          bottomRight: const Radius.circular(0),
        ),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.10),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(ui.radius(28)),
          topRight: Radius.circular(ui.radius(28)),
          bottomLeft: const Radius.circular(0),
          bottomRight: const Radius.circular(0),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: expanded
              ? _ExpandedDriverPanelBody(
            key: const ValueKey('expanded_driver_panel'),
            ui: ui,
            driver: driver,
            activeRide: activeRide,
            queue: queue,
            statusMessage: statusMessage,
            lastSyncAt: lastSyncAt,
            lastHeartbeatAt: lastHeartbeatAt,
            busyOnlineToggle: busyOnlineToggle,
            busyRideAction: busyRideAction,
            status: status,
            statusColor: statusColor,
            onExpandToggle: onExpandToggle,
            onOnlineToggle: onOnlineToggle,
            onWallet: onWallet,
            onHistory: onHistory,
            onProfile: onProfile,
            onRefresh: onRefresh,
            onAccept: onAccept,
            onRideAction: onRideAction,
            onNavigate: onNavigate,
          )
              : _CollapsedDriverPanelBody(
            key: const ValueKey('collapsed_driver_panel'),
            ui: ui,
            driver: driver,
            activeRide: activeRide,
            queue: queue,
            busyOnlineToggle: busyOnlineToggle,
            status: status,
            statusColor: statusColor,
            lastSyncAt: lastSyncAt,
            onExpandToggle: onExpandToggle,
            onOnlineToggle: onOnlineToggle,
            onWallet: onWallet,
            onRefresh: onRefresh,
          ),
        ),
      ),
    );
  }
}

class _CollapsedDriverPanelBody extends StatelessWidget {
  final UIScale ui;
  final _DriverProfile? driver;
  final _RideJob? activeRide;
  final List<_RideJob> queue;
  final bool busyOnlineToggle;
  final String status;
  final Color statusColor;
  final DateTime? lastSyncAt;
  final VoidCallback onExpandToggle;
  final ValueChanged<bool> onOnlineToggle;
  final VoidCallback onWallet;
  final VoidCallback onRefresh;

  const _CollapsedDriverPanelBody({
    super.key,
    required this.ui,
    required this.driver,
    required this.activeRide,
    required this.queue,
    required this.busyOnlineToggle,
    required this.status,
    required this.statusColor,
    required this.lastSyncAt,
    required this.onExpandToggle,
    required this.onOnlineToggle,
    required this.onWallet,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final online = driver?.isOnline == true;

    return Padding(
      padding: EdgeInsets.fromLTRB(ui.inset(12), ui.gap(5), ui.inset(12), ui.gap(3)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Driver command center',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(12.8),
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface,
                  ),
                ),
              ),
              SizedBox(width: ui.gap(6)),
              _StatusDotChip(ui: ui, color: statusColor, label: _statusLabel(status)),
              SizedBox(width: ui.gap(2)),
              IconButton(
                onPressed: onExpandToggle,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
              ),
            ],
          ),
          SizedBox(height: ui.gap(3)),
          Align(
            alignment: Alignment.centerLeft,
            child: _CompactSummaryRow(
              ui: ui,
              driver: driver,
              activeRide: activeRide,
              lastSyncAt: lastSyncAt,
              lastHeartbeatAt: lastSyncAt,
              queueCount: queue.length,
              dense: true,
              online: online,
              busyOnlineToggle: busyOnlineToggle,
              onOnlineToggle: () => onOnlineToggle(!online),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpandedDriverPanelBody extends StatelessWidget {

  final UIScale ui;
  final _DriverProfile? driver;
  final _RideJob? activeRide;
  final List<_RideJob> queue;
  final String? statusMessage;
  final DateTime? lastSyncAt;
  final DateTime? lastHeartbeatAt;
  final bool busyOnlineToggle;
  final bool busyRideAction;
  final String status;
  final Color statusColor;
  final VoidCallback onExpandToggle;
  final ValueChanged<bool> onOnlineToggle;
  final VoidCallback onWallet;
  final VoidCallback onHistory;
  final VoidCallback onProfile;
  final VoidCallback onRefresh;
  final ValueChanged<_RideJob> onAccept;
  final ValueChanged<String> onRideAction;
  final VoidCallback onNavigate;

  const _ExpandedDriverPanelBody({
    super.key,
    required this.ui,
    required this.driver,
    required this.activeRide,
    required this.queue,
    required this.statusMessage,
    required this.lastSyncAt,
    required this.lastHeartbeatAt,
    required this.busyOnlineToggle,
    required this.busyRideAction,
    required this.status,
    required this.statusColor,
    required this.onExpandToggle,
    required this.onOnlineToggle,
    required this.onWallet,
    required this.onHistory,
    required this.onProfile,
    required this.onRefresh,
    required this.onAccept,
    required this.onRideAction,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final driverOnline = driver?.isOnline == true;

    return ListView(
      padding: EdgeInsets.fromLTRB(ui.inset(14), ui.gap(10), ui.inset(14), ui.gap(14)),
      children: [
        Center(
          child: GestureDetector(
            onTap: onExpandToggle,
            child: Container(
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: cs.onSurface.withOpacity(0.16),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
        SizedBox(height: ui.gap(10)),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    activeRide != null ? 'Active trip control' : 'Driver command center',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: ui.font(16),
                      fontWeight: FontWeight.w900,
                      color: cs.onSurface,
                    ),
                  ),
                  SizedBox(height: ui.gap(3)),
                  Text(
                    statusMessage?.trim().isNotEmpty == true
                        ? statusMessage!.trim()
                        : (activeRide != null
                        ? 'Pickup and destination are live on the map.'
                        : 'Go online to appear to riders and start receiving ride requests.'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: ui.font(11.5),
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface.withOpacity(0.66),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: ui.gap(10)),
            _StatusDotChip(ui: ui, color: statusColor, label: _statusLabel(status)),
            SizedBox(width: ui.gap(4)),
            IconButton(
              onPressed: onExpandToggle,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
          ],
        ),
        SizedBox(height: ui.gap(12)),
        _CompactSummaryRow(
          ui: ui,
          driver: driver,
          activeRide: activeRide,
          lastSyncAt: lastSyncAt,
          lastHeartbeatAt: lastHeartbeatAt,
        ),
        SizedBox(height: ui.gap(12)),
        _OnlineRow(
          ui: ui,
          online: driverOnline,
          busy: busyOnlineToggle,
          onToggle: onOnlineToggle,
        ),
        SizedBox(height: ui.gap(12)),
        _QuickActionStrip(
          ui: ui,
          onWallet: onWallet,
          onHistory: onHistory,
          onProfile: onProfile,
          onRefresh: onRefresh,
        ),
        SizedBox(height: ui.gap(12)),
        if (activeRide != null) ...[
          _TripStateCard(
            ui: ui,
            ride: activeRide!,
            busy: busyRideAction,
            onRideAction: onRideAction,
            onNavigate: onNavigate,
          ),
          SizedBox(height: ui.gap(12)),
        ],
        _QueueCard(
          ui: ui,
          rides: queue,
          busy: busyRideAction,
          onAccept: onAccept,
        ),
      ],
    );
  }
}

class _CollapsedInfoPill extends StatelessWidget {
  final UIScale ui;
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _CollapsedInfoPill({
    required this.ui,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(12), vertical: ui.inset(8)),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(ui.radius(16)),
        border: Border.all(color: color.withOpacity(0.14)),
      ),
      child: Row(
        children: [
          Icon(icon, size: ui.icon(16), color: color),
          SizedBox(width: ui.gap(8)),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(11.2),
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface,
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(10.2),
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.60),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniActionButton extends StatelessWidget {
  final UIScale ui;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MiniActionButton({
    required this.ui,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.onSurface.withOpacity(0.05),
      borderRadius: BorderRadius.circular(ui.radius(14)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ui.radius(14)),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: ui.inset(10), vertical: ui.inset(9)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: ui.icon(15), color: cs.onSurface.withOpacity(0.80)),
              SizedBox(width: ui.gap(5)),
              Text(
                label,
                style: TextStyle(
                  fontSize: ui.font(10.5),
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface.withOpacity(0.82),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CollapsedTopRow extends StatelessWidget {
  final UIScale ui;
  final bool online;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final DateTime? lastSyncAt;

  const _CollapsedTopRow({
    required this.ui,
    required this.online,
    required this.busy,
    required this.onToggle,
    required this.lastSyncAt,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = online ? AppColors.primary : Colors.grey.shade700;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(12),
        vertical: ui.inset(8),
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(ui.radius(16)),
        border: Border.all(color: color.withOpacity(0.16)),
      ),
      child: Row(
        children: [
          Container(
            width: ui.inset(30),
            height: ui.inset(30),
            decoration: BoxDecoration(
              color: color.withOpacity(0.14),
              borderRadius: BorderRadius.circular(ui.radius(12)),
            ),
            child: Icon(
              online ? Icons.radio_button_checked_rounded : Icons.pause_circle_rounded,
              color: color,
              size: ui.icon(17),
            ),
          ),
          SizedBox(width: ui.gap(10)),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  online ? 'You are visible to riders' : 'You are offline',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(12),
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface,
                  ),
                ),
                Text(
                  'Sync ${_fmtTime(lastSyncAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(10.5),
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.58),
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: online,
            onChanged: busy ? null : onToggle,
          ),
        ],
      ),
    );
  }
}


class _MiniOnlineTogglePill extends StatelessWidget {
  final UIScale ui;
  final bool online;
  final bool busy;
  final VoidCallback onTap;

  const _MiniOnlineTogglePill({
    required this.ui,
    required this.online,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = online ? AppColors.primary.withOpacity(0.14) : cs.onSurface.withOpacity(0.06);
    final fg = online ? AppColors.primary : cs.onSurface.withOpacity(0.62);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          padding: EdgeInsets.symmetric(
            horizontal: ui.inset(9),
            vertical: ui.inset(5),
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: online ? AppColors.primary.withOpacity(0.18) : cs.onSurface.withOpacity(0.08)),
          ),
          child: Text(
            busy ? '...' : (online ? 'Online' : 'Offline'),
            style: TextStyle(
              fontSize: ui.font(9.8),
              fontWeight: FontWeight.w900,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactSummaryRow extends StatelessWidget {
  final UIScale ui;
  final _DriverProfile? driver;
  final _RideJob? activeRide;
  final DateTime? lastSyncAt;
  final DateTime? lastHeartbeatAt;
  final int queueCount;
  final bool dense;
  final bool online;
  final bool busyOnlineToggle;
  final VoidCallback? onOnlineToggle;

  const _CompactSummaryRow({
    required this.ui,
    required this.driver,
    required this.activeRide,
    required this.lastSyncAt,
    required this.lastHeartbeatAt,
    this.queueCount = 0,
    this.dense = false,
    this.online = false,
    this.busyOnlineToggle = false,
    this.onOnlineToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (dense) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final compactPlate = driver?.carPlate?.trim();
          final items = <Widget>[
            _DenseSummaryPill(ui: ui, label: 'Trips', value: '${driver?.completedTrips ?? 0}'),
            _DenseSummaryPill(
              ui: ui,
              label: activeRide != null ? 'Trip' : 'Queue',
              value: activeRide != null ? 'Live' : '$queueCount',
            ),
            _DenseSummaryPill(ui: ui, label: 'Sync', value: _fmtTime(lastSyncAt)),
            _DenseTogglePill(
              ui: ui,
              online: online,
              busy: busyOnlineToggle,
              onTap: onOnlineToggle,
            ),
            if (compactPlate != null && compactPlate.isNotEmpty && constraints.maxWidth > 390)
              _DenseSummaryPill(ui: ui, label: 'Plate', value: compactPlate),
          ];

          return SizedBox(
            height: 36,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  for (int i = 0; i < items.length; i++) ...[
                    if (i > 0) SizedBox(width: ui.gap(6)),
                    items[i],
                  ],
                ],
              ),
            ),
          );
        },
      );
    }

    return SizedBox(
      height: ui.gap(72),
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        children: [
          _MiniMetricCard(
            ui: ui,
            label: 'Trips',
            value: '${driver?.completedTrips ?? 0}',
            hint: 'completed',
          ),
          SizedBox(width: ui.gap(8)),
          _MiniMetricCard(
            ui: ui,
            label: 'Rating',
            value: (driver?.rating ?? 0).toStringAsFixed(2),
            hint: driver?.category ?? 'driver',
          ),
          SizedBox(width: ui.gap(8)),
          _MiniMetricCard(
            ui: ui,
            label: 'Sync',
            value: _fmtTime(lastSyncAt),
            hint: 'dashboard',
          ),
          SizedBox(width: ui.gap(8)),
          _MiniMetricCard(
            ui: ui,
            label: 'Live',
            value: _fmtTime(lastHeartbeatAt),
            hint: activeRide != null ? 'trip heartbeat' : 'heartbeat',
          ),
          if (driver?.carPlate != null) ...[
            SizedBox(width: ui.gap(8)),
            _MiniMetricCard(
              ui: ui,
              label: 'Plate',
              value: driver!.carPlate!,
              hint: driver?.vehicleType ?? 'vehicle',
            ),
          ],
          SizedBox(width: ui.gap(4)),
        ],
      ),
    );
  }
}

class _DenseSummaryPill extends StatelessWidget {
  final UIScale ui;
  final String label;
  final String value;

  const _DenseSummaryPill({
    required this.ui,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(10),
        vertical: ui.inset(6),
      ),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.05),
        borderRadius: BorderRadius.circular(ui.radius(999)),
        border: Border.all(color: cs.onSurface.withOpacity(0.06)),
      ),
      child: RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: TextStyle(
                fontSize: ui.font(10.0),
                fontWeight: FontWeight.w700,
                color: cs.onSurface.withOpacity(0.56),
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                fontSize: ui.font(10.8),
                fontWeight: FontWeight.w900,
                color: cs.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DenseTogglePill extends StatelessWidget {
  final UIScale ui;
  final bool online;
  final bool busy;
  final VoidCallback? onTap;

  const _DenseTogglePill({
    required this.ui,
    required this.online,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(6),
        vertical: ui.inset(2),
      ),
      decoration: BoxDecoration(
        color: (online ? AppColors.primary : cs.onSurface).withOpacity(0.08),
        borderRadius: BorderRadius.circular(ui.radius(999)),
        border: Border.all(
          color: (online ? AppColors.primary : cs.onSurface).withOpacity(0.12),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            online ? 'Online' : 'Offline',
            style: TextStyle(
              fontSize: ui.font(10.0),
              fontWeight: FontWeight.w800,
              color: online ? AppColors.primary : cs.onSurface.withOpacity(0.72),
            ),
          ),
          SizedBox(width: ui.gap(2)),
          Transform.scale(
            scale: 0.62,
            child: Switch.adaptive(
              value: online,
              onChanged: busy || onTap == null ? null : (_) => onTap!.call(),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              activeColor: AppColors.primary,
              activeTrackColor: AppColors.primary.withOpacity(0.42),
              inactiveThumbColor: cs.surface,
              inactiveTrackColor: cs.onSurface.withOpacity(0.16),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniMetricCard extends StatelessWidget {
  final UIScale ui;
  final String label;
  final String value;
  final String hint;

  const _MiniMetricCard({
    required this.ui,
    required this.label,
    required this.value,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: ui.gap(102),
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(12),
        vertical: ui.inset(10),
      ),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.04),
        borderRadius: BorderRadius.circular(ui.radius(18)),
        border: Border.all(color: cs.onSurface.withOpacity(0.06)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: ui.font(10.5),
              fontWeight: FontWeight.w700,
              color: cs.onSurface.withOpacity(0.56),
            ),
          ),
          SizedBox(height: ui.gap(3)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: ui.font(13.8),
                fontWeight: FontWeight.w900,
                color: cs.onSurface,
              ),
            ),
          ),
          SizedBox(height: ui.gap(2)),
          Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: ui.font(9.6),
              fontWeight: FontWeight.w700,
              color: cs.onSurface.withOpacity(0.46),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnlineRow extends StatelessWidget {
  final UIScale ui;
  final bool online;
  final bool busy;
  final ValueChanged<bool> onToggle;

  const _OnlineRow({
    required this.ui,
    required this.online,
    required this.busy,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = online ? AppColors.primary : Colors.grey.shade700;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(12),
        vertical: ui.inset(10),
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(ui.radius(18)),
        border: Border.all(color: color.withOpacity(0.16)),
      ),
      child: Row(
        children: [
          Container(
            width: ui.inset(40),
            height: ui.inset(40),
            decoration: BoxDecoration(
              color: color.withOpacity(0.14),
              borderRadius: BorderRadius.circular(ui.radius(14)),
            ),
            child: Icon(
              online ? Icons.radio_button_checked_rounded : Icons.pause_circle_rounded,
              color: color,
            ),
          ),
          SizedBox(width: ui.gap(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  online ? 'You are visible to riders' : 'You are currently offline',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(13),
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface,
                  ),
                ),
                SizedBox(height: ui.gap(2)),
                Text(
                  online
                      ? 'Live location updates publish automatically every 2 seconds.'
                      : 'Turn on availability when you are ready to receive requests.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(10.6),
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.62),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: ui.gap(8)),
          busy
              ? SizedBox(
            width: ui.inset(22),
            height: ui.inset(22),
            child: const CircularProgressIndicator(strokeWidth: 2),
          )
              : Switch.adaptive(
            value: online,
            onChanged: onToggle,
            activeColor: AppColors.primary,
            activeTrackColor: AppColors.primary.withOpacity(0.42),
            inactiveThumbColor: cs.surface,
            inactiveTrackColor: cs.onSurface.withOpacity(0.16),
          ),
        ],
      ),
    );
  }
}

class _QuickActionStrip extends StatelessWidget {
  final UIScale ui;
  final VoidCallback onWallet;
  final VoidCallback onHistory;
  final VoidCallback onProfile;
  final VoidCallback onRefresh;

  const _QuickActionStrip({
    required this.ui,
    required this.onWallet,
    required this.onHistory,
    required this.onProfile,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _ActionPill(ui: ui, icon: Icons.account_balance_wallet_rounded, label: 'Wallet', onTap: onWallet),
          SizedBox(width: ui.gap(8)),
          _ActionPill(ui: ui, icon: Icons.receipt_long_rounded, label: 'History', onTap: onHistory),
          SizedBox(width: ui.gap(8)),
          _ActionPill(ui: ui, icon: Icons.person_rounded, label: 'Profile', onTap: onProfile),
          SizedBox(width: ui.gap(8)),
          _ActionPill(ui: ui, icon: Icons.sync_rounded, label: 'Refresh', onTap: onRefresh),
        ],
      ),
    );
  }
}

class _ActionPill extends StatelessWidget {
  final UIScale ui;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionPill({
    required this.ui,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ui.radius(999)),
        child: Ink(
          padding: EdgeInsets.symmetric(
            horizontal: ui.inset(12),
            vertical: ui.inset(9),
          ),
          decoration: BoxDecoration(
            color: cs.onSurface.withOpacity(0.04),
            borderRadius: BorderRadius.circular(ui.radius(999)),
            border: Border.all(color: cs.onSurface.withOpacity(0.06)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: ui.icon(16), color: AppColors.primary),
              SizedBox(width: ui.gap(7)),
              Text(
                label,
                style: TextStyle(
                  fontSize: ui.font(11.4),
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TripStateCard extends StatelessWidget {
  final UIScale ui;
  final _RideJob ride;
  final bool busy;
  final ValueChanged<String> onRideAction;
  final VoidCallback onNavigate;

  const _TripStateCard({
    required this.ui,
    required this.ride,
    required this.busy,
    required this.onRideAction,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final actions = _rideActionsForStatus(ride.status);

    return Container(
      padding: EdgeInsets.all(ui.inset(14)),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.surface,
            AppColors.primary.withOpacity(0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(ui.radius(22)),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Current ride · ${ride.riderName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(14.5),
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface,
                  ),
                ),
              ),
              _StatusDotChip(
                ui: ui,
                color: _statusColor(ride.status),
                label: _statusLabel(ride.status),
              ),
            ],
          ),
          SizedBox(height: ui.gap(12)),
          _RouteLine(ui: ui, icon: Icons.place_rounded, title: 'Pickup', subtitle: ride.pickupText),
          SizedBox(height: ui.gap(8)),
          _RouteLine(ui: ui, icon: Icons.flag_rounded, title: 'Destination', subtitle: ride.destText),
          SizedBox(height: ui.gap(12)),
          Wrap(
            spacing: ui.gap(8),
            runSpacing: ui.gap(8),
            children: [
              _InfoBadge(ui: ui, label: '${ride.currency} ${ride.price.toStringAsFixed(2)}'),
              _InfoBadge(ui: ui, label: 'ETA ${ride.etaMin} min'),
              _InfoBadge(ui: ui, label: ride.payMethod.toUpperCase()),
              _InfoBadge(ui: ui, label: '${ride.vehicleType.toUpperCase()} · ${ride.seats} seats'),
            ],
          ),
          if (actions.isNotEmpty) ...[
            SizedBox(height: ui.gap(12)),
            Wrap(
              spacing: ui.gap(8),
              runSpacing: ui.gap(8),
              children: [
                FilledButton.tonalIcon(
                  onPressed: onNavigate,
                  icon: const Icon(Icons.navigation_rounded),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary.withOpacity(0.10),
                    foregroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(ui.radius(999)),
                    ),
                  ),
                  label: const Text('Navigation'),
                ),
                ...actions.map((a) {
                  final destructive = a == 'cancel';
                  return FilledButton.tonalIcon(
                    onPressed: busy ? null : () => onRideAction(a),
                    icon: busy
                        ? SizedBox(
                      width: ui.inset(14),
                      height: ui.inset(14),
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    )
                        : Icon(_actionIcon(a)),
                    style: FilledButton.styleFrom(
                      backgroundColor: destructive
                          ? Colors.red.withOpacity(0.12)
                          : AppColors.primary.withOpacity(0.10),
                      foregroundColor: destructive ? Colors.red : AppColors.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(ui.radius(999)),
                      ),
                    ),
                    label: Text(_actionLabel(a)),
                  );
                }).toList(growable: false),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _QueueCard extends StatelessWidget {
  final UIScale ui;
  final List<_RideJob> rides;
  final bool busy;
  final ValueChanged<_RideJob> onAccept;

  const _QueueCard({
    required this.ui,
    required this.rides,
    required this.busy,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.all(ui.inset(14)),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(ui.radius(22)),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Nearby incoming requests',
                  style: TextStyle(
                    fontSize: ui.font(14.5),
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface,
                  ),
                ),
              ),
              _InfoBadge(ui: ui, label: '${rides.length} live'),
            ],
          ),
          SizedBox(height: ui.gap(10)),
          if (rides.isEmpty)
            Text(
              'No rider request is waiting right now. Stay online and nearby requests will appear here automatically.',
              style: TextStyle(
                fontSize: ui.font(11.4),
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withOpacity(0.62),
                height: 1.4,
              ),
            )
          else
            ...rides.take(5).map((ride) => Padding(
              padding: EdgeInsets.only(bottom: ui.gap(10)),
              child: _QueueRideTile(
                ui: ui,
                ride: ride,
                busy: busy,
                onAccept: () => onAccept(ride),
              ),
            )),
        ],
      ),
    );
  }
}

class _QueueRideTile extends StatelessWidget {
  final UIScale ui;
  final _RideJob ride;
  final bool busy;
  final VoidCallback onAccept;

  const _QueueRideTile({
    required this.ui,
    required this.ride,
    required this.busy,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.all(ui.inset(12)),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.035),
        borderRadius: BorderRadius.circular(ui.radius(18)),
        border: Border.all(color: cs.onSurface.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  ride.riderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(12.8),
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface,
                  ),
                ),
              ),
              _InfoBadge(ui: ui, label: '${ride.currency} ${ride.price.toStringAsFixed(0)}'),
            ],
          ),
          SizedBox(height: ui.gap(8)),
          Text(
            ride.pickupText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: ui.font(10.8),
              fontWeight: FontWeight.w700,
              color: cs.onSurface.withOpacity(0.64),
            ),
          ),
          SizedBox(height: ui.gap(4)),
          Text(
            ride.destText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: ui.font(10.8),
              fontWeight: FontWeight.w700,
              color: cs.onSurface.withOpacity(0.64),
            ),
          ),
          SizedBox(height: ui.gap(10)),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: ui.gap(6),
                  runSpacing: ui.gap(6),
                  children: [
                    _InfoBadge(ui: ui, label: 'ETA ${ride.etaMin}m'),
                    _InfoBadge(ui: ui, label: ride.category),
                  ],
                ),
              ),
              SizedBox(width: ui.gap(8)),
              FilledButton(
                onPressed: busy ? null : onAccept,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(ui.radius(999)),
                  ),
                ),
                child: busy
                    ? SizedBox(
                  width: ui.inset(14),
                  height: ui.inset(14),
                  child: const CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
                    : const Text('Accept'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CollapsedTripPreview extends StatelessWidget {
  final UIScale ui;
  final _RideJob ride;

  const _CollapsedTripPreview({
    required this.ui,
    required this.ride,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(ui.inset(12)),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(ui.radius(18)),
      ),
      child: Row(
        children: [
          Container(
            width: ui.inset(42),
            height: ui.inset(42),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(ui.radius(14)),
            ),
            child: const Icon(Icons.navigation_rounded, color: AppColors.primary),
          ),
          SizedBox(width: ui.gap(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Active trip · ${ride.riderName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(12.8),
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface,
                  ),
                ),
                SizedBox(height: ui.gap(3)),
                Text(
                  '${_statusLabel(ride.status)} · ${ride.currency} ${ride.price.toStringAsFixed(2)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(10.8),
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface.withOpacity(0.64),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CollapsedQueuePreview extends StatelessWidget {
  final UIScale ui;
  final List<_RideJob> queue;

  const _CollapsedQueuePreview({
    required this.ui,
    required this.queue,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = queue.isEmpty
        ? 'No pending rider request yet. Keep your dashboard online.'
        : '${queue.length} rider request${queue.length == 1 ? '' : 's'} waiting near you.';

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(ui.inset(12)),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.04),
        borderRadius: BorderRadius.circular(ui.radius(18)),
      ),
      child: Row(
        children: [
          Container(
            width: ui.inset(42),
            height: ui.inset(42),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(ui.radius(14)),
            ),
            child: const Icon(Icons.local_taxi_rounded, color: AppColors.primary),
          ),
          SizedBox(width: ui.gap(10)),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: ui.font(11.2),
                fontWeight: FontWeight.w700,
                color: cs.onSurface.withOpacity(0.68),
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingDriverPanel extends StatelessWidget {
  final UIScale ui;

  const _LoadingDriverPanel({required this.ui});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 150,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
        borderRadius: BorderRadius.circular(ui.radius(28)),
      ),
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

class _NetworkBanner extends StatelessWidget {
  final UIScale ui;

  const _NetworkBanner({required this.ui});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.orange.shade700,
      borderRadius: BorderRadius.circular(ui.radius(12)),
      elevation: 4,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: ui.inset(14),
          vertical: ui.inset(10),
        ),
        child: Row(
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: ui.icon(18),
              color: Colors.white,
            ),
            SizedBox(width: ui.gap(8)),
            Expanded(
              child: Text(
                'Connection issue. Driver dashboard will retry automatically.',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: ui.font(12),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDotChip extends StatelessWidget {
  final UIScale ui;
  final Color color;
  final String label;

  const _StatusDotChip({
    required this.ui,
    required this.color,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(10),
        vertical: ui.inset(7),
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(ui.radius(999)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          SizedBox(width: ui.gap(6)),
          Text(
            label,
            style: TextStyle(
              fontSize: ui.font(10.8),
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteLine extends StatelessWidget {
  final UIScale ui;
  final IconData icon;
  final String title;
  final String subtitle;

  const _RouteLine({
    required this.ui,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: ui.inset(34),
          height: ui.inset(34),
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.10),
            borderRadius: BorderRadius.circular(ui.radius(12)),
          ),
          child: Icon(icon, size: ui.icon(16), color: AppColors.primary),
        ),
        SizedBox(width: ui.gap(10)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: ui.font(10.4),
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface.withOpacity(0.54),
                ),
              ),
              SizedBox(height: ui.gap(2)),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: ui.font(11.6),
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoBadge extends StatelessWidget {
  final UIScale ui;
  final String label;

  const _InfoBadge({
    required this.ui,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(9),
        vertical: ui.inset(6),
      ),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.05),
        borderRadius: BorderRadius.circular(ui.radius(999)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: ui.font(10.2),
          fontWeight: FontWeight.w800,
          color: cs.onSurface.withOpacity(0.72),
        ),
      ),
    );
  }
}

class _DriverProfile {
  final int id;
  final String name;
  final String? phone;
  final String? rank;
  final String category;
  final double rating;
  final String? carPlate;
  final String vehicleType;
  final int seats;
  final int completedTrips;
  final int totalTrips;
  final int cancelledTrips;
  final int incompleteTrips;
  final bool isOnline;
  final String? avatarUrl;
  final String? status;

  const _DriverProfile({
    required this.id,
    required this.name,
    required this.phone,
    required this.rank,
    required this.category,
    required this.rating,
    required this.carPlate,
    required this.vehicleType,
    required this.seats,
    required this.completedTrips,
    required this.totalTrips,
    required this.cancelledTrips,
    required this.incompleteTrips,
    required this.isOnline,
    required this.avatarUrl,
    required this.status,
  });

  factory _DriverProfile.fromJson(Map<dynamic, dynamic> json) {
    return _DriverProfile(
      id: _toInt(json['id']),
      name: (json['name'] ?? 'Driver').toString(),
      phone: _stringOrNull(json['phone']),
      rank: _stringOrNull(json['rank']),
      category: (json['category'] ?? 'Standard').toString(),
      rating: _toDouble(json['rating'], fallback: 5.0),
      carPlate: _stringOrNull(json['car_plate']),
      vehicleType: (json['vehicle_type'] ?? 'car').toString(),
      seats: _toInt(json['seats'], fallback: 4),
      completedTrips: _toInt(json['completed_trips']),
      totalTrips: _toInt(json['total_trips']),
      cancelledTrips: _toInt(json['cancelled_trips']),
      incompleteTrips: _toInt(json['incomplete_trips']),
      isOnline: _toBool(json['is_online']),
      avatarUrl: _stringOrNull(json['avatar_url']),
      status: _stringOrNull(json['status']),
    );
  }

  _DriverProfile copyWith({bool? isOnline}) {
    return _DriverProfile(
      id: id,
      name: name,
      phone: phone,
      rank: rank,
      category: category,
      rating: rating,
      carPlate: carPlate,
      vehicleType: vehicleType,
      seats: seats,
      completedTrips: completedTrips,
      totalTrips: totalTrips,
      cancelledTrips: cancelledTrips,
      incompleteTrips: incompleteTrips,
      isOnline: isOnline ?? this.isOnline,
      avatarUrl: avatarUrl,
      status: status,
    );
  }
}

class _RideJob {
  final int id;
  final String riderId;
  final String riderName;
  final String? riderPhone;
  final String status;
  final String category;
  final String vehicleType;
  final int seats;
  final double price;
  final String currency;
  final double pickupLat;
  final double pickupLng;
  final String pickupText;
  final double destLat;
  final double destLng;
  final String destText;
  final int etaMin;
  final String payMethod;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const _RideJob({
    required this.id,
    required this.riderId,
    required this.riderName,
    required this.riderPhone,
    required this.status,
    required this.category,
    required this.vehicleType,
    required this.seats,
    required this.price,
    required this.currency,
    required this.pickupLat,
    required this.pickupLng,
    required this.pickupText,
    required this.destLat,
    required this.destLng,
    required this.destText,
    required this.etaMin,
    required this.payMethod,
    required this.createdAt,
    required this.updatedAt,
  });

  factory _RideJob.fromJson(Map<dynamic, dynamic> json) {
    return _RideJob(
      id: _toInt(json['id']),
      riderId: (json['rider_id'] ?? '').toString(),
      riderName: (json['rider_name'] ?? 'Rider').toString(),
      riderPhone: _stringOrNull(json['rider_phone']),
      status: (json['status'] ?? 'searching').toString(),
      category: (json['category'] ?? 'Standard').toString(),
      vehicleType: (json['vehicle_type'] ?? 'car').toString(),
      seats: _toInt(json['seats'], fallback: 4),
      price: _toDouble(json['price']),
      currency: (json['currency'] ?? 'NGN').toString(),
      pickupLat: _toDouble(json['pickup_lat'], fallback: _DriverHomePageState._fallbackLat),
      pickupLng: _toDouble(json['pickup_lng'], fallback: _DriverHomePageState._fallbackLng),
      pickupText: (json['pickup_text'] ?? 'Pickup').toString(),
      destLat: _toDouble(json['dest_lat'], fallback: _DriverHomePageState._fallbackLat),
      destLng: _toDouble(json['dest_lng'], fallback: _DriverHomePageState._fallbackLng),
      destText: (json['dest_text'] ?? 'Destination').toString(),
      etaMin: _toInt(json['eta_min']),
      payMethod: (json['pay_method'] ?? 'cash').toString(),
      createdAt: _parseDate(json['created_at']),
      updatedAt: _parseDate(json['updated_at']),
    );
  }
}

int _toInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  return int.tryParse((value ?? '').toString()) ?? fallback;
}

double _toDouble(dynamic value, {double fallback = 0}) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  return double.tryParse((value ?? '').toString()) ?? fallback;
}

bool _toBool(dynamic value) {
  if (value is bool) return value;
  final text = (value ?? '').toString().trim().toLowerCase();
  return text == '1' || text == 'true' || text == 'yes' || text == 'online';
}

String? _stringOrNull(dynamic value) {
  final text = (value ?? '').toString().trim();
  return text.isEmpty ? null : text;
}

DateTime? _parseDate(dynamic value) {
  final text = (value ?? '').toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text.replaceFirst(' ', 'T'));
}

double _extractBalance(Map<String, dynamic>? user) {
  if (user == null) return 0.0;
  for (final key in ['user_bal', 'bal', 'balance']) {
    final raw = user[key];
    final parsed = double.tryParse((raw ?? '').toString());
    if (parsed != null) return parsed;
  }
  return 0.0;
}

String _fmtTime(DateTime? value) {
  if (value == null) return '—';
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute = value.minute.toString().padLeft(2, '0');
  final meridian = value.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $meridian';
}

Color _statusColor(String status) {
  switch (status.trim().toLowerCase()) {
    case 'online':
    case 'accepted':
    case 'enroute_pickup':
    case 'in_progress':
      return AppColors.primary;
    case 'arrived_pickup':
    case 'arrived_destination':
      return Colors.orange;
    case 'completed':
      return Colors.green;
    case 'cancel':
    case 'canceled':
      return Colors.red;
    default:
      return Colors.grey.shade700;
  }
}

String _statusLabel(String status) {
  switch (status.trim().toLowerCase()) {
    case 'accepted':
      return 'Accepted';
    case 'enroute_pickup':
      return 'To pickup';
    case 'arrived_pickup':
      return 'At pickup';
    case 'in_progress':
      return 'On trip';
    case 'arrived_destination':
      return 'At destination';
    case 'completed':
      return 'Completed';
    case 'online':
      return 'Online';
    case 'offline':
      return 'Offline';
    default:
      return status.isEmpty ? 'Offline' : status;
  }
}

List<String> _rideActionsForStatus(String status) {
  switch (status.trim().toLowerCase()) {
    case 'accepted':
    case 'enroute_pickup':
      return const ['arrived_pickup', 'cancel'];
    case 'arrived_pickup':
      return const ['start_trip', 'cancel'];
    case 'in_progress':
      return const ['arrived_destination', 'cancel'];
    case 'arrived_destination':
      return const ['complete_trip'];
    default:
      return const <String>[];
  }
}

String _actionLabel(String action) {
  switch (action) {
    case 'arrived_pickup':
      return 'At pickup';
    case 'start_trip':
      return 'Start trip';
    case 'arrived_destination':
      return 'At destination';
    case 'complete_trip':
      return 'Complete';
    case 'cancel':
      return 'Cancel';
    default:
      return action;
  }
}

IconData _actionIcon(String action) {
  switch (action) {
    case 'arrived_pickup':
      return Icons.pin_drop_rounded;
    case 'start_trip':
      return Icons.play_arrow_rounded;
    case 'arrived_destination':
      return Icons.flag_rounded;
    case 'complete_trip':
      return Icons.check_circle_rounded;
    case 'cancel':
      return Icons.close_rounded;
    default:
      return Icons.bolt_rounded;
  }
}
