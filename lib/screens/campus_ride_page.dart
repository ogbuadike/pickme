// lib/screens/campus_ride_page.dart
//
// Campus Ride: intra-campus rides limited to a 5 km radius, driver market +
// booking through BookingFlowManager / BookingController.
//
// Fixes vs. the previous revision:
//  * map overlays are pushed at most once per frame (GPS 5 Hz + compass were
//    rebuilding GoogleMap dozens of times per second) and circles actually
//    update (the same Set instance was re-assigned to the notifier);
//  * location goes through the shared LocationPermissionModal.ensure gate;
//  * route / autocomplete / place-details results are sequence-checked so a
//    slow response can never overwrite a newer choice; no request is dropped
//    on the floor (which used to leave the "typing" spinner stuck);
//  * an active campus ride is resumed from the server after an app restart;
//  * work pauses while the app is backgrounded or the tab is hidden;
//  * dead trip-phase code removed (TripNavigationPage owns the live trip).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../routes/routes.dart';
import '../themes/app_theme.dart';
import '../utility/notification.dart';
import '../widgets/app_menu_drawer.dart';
import '../widgets/auto_overlay.dart';
import '../widgets/fund_account_sheet.dart';
import '../widgets/header_bar.dart';
import '../widgets/locate_fab.dart';
import '../widgets/ride_market_sheet.dart';
import '../widgets/route_sheet.dart';
import 'trip_navigation_page.dart';
import '../services/autocomplete_service.dart';
import '../services/booking_controller.dart';
import '../services/perf_profile.dart';
import '../services/ride_market_service.dart';
import '../models/geo_point.dart';
import '../ui/ui_scale.dart';

// --- OUR ENTERPRISE DELEGATES ---
import 'state/home_models.dart';
import 'state/location_permission_modal.dart';
import 'state/booking_flow_manager.dart';
import 'state/map_graphics_engine.dart';
import 'state/driver_polling_engine.dart';
import 'state/routing_engine.dart';

enum MovementMode { stationary, pedestrian, vehicle }
enum BearingSource { route, gps, compass }
enum _CamMode { follow, overview }
enum TripPhase { browsing, driverToPickup, waitingPickup, enRoute }

class _SpeedInterval {
  final int start;
  final int end;
  final String speed;
  const _SpeedInterval(this.start, this.end, this.speed);
}

class _V2Route {
  final List<LatLng> points;
  final int distanceMeters;
  final int durationSeconds;
  final List<_SpeedInterval> speedIntervals;
  const _V2Route(this.points, this.distanceMeters, this.durationSeconds, this.speedIntervals);
}

class _RouteCache {
  final _V2Route route;
  final DateTime timestamp;
  const _RouteCache(this.route, this.timestamp);
  bool get isStale => DateTime.now().difference(timestamp) > const Duration(hours: 24);
}

class _NetworkRequest {
  final String id;
  final Future<http.Response> Function() executor;
  final Completer<http.Response> completer;
  int retries;
  _NetworkRequest(this.id, this.executor) : completer = Completer<http.Response>(), retries = 0;
}

class _SpatialNode {
  final LatLng point;
  final int index;
  final double lat;
  final double lng;
  _SpatialNode(this.point, this.index) : lat = point.latitude, lng = point.longitude;
}

class CampusRidePage extends StatefulWidget {
  const CampusRidePage({super.key});

  @override
  State<CampusRidePage> createState() => _CampusRidePageState();
}

class _CampusRidePageState extends State<CampusRidePage> with WidgetsBindingObserver, TickerProviderStateMixin {
  static const double kBottomNavH = 74;
  static const double kHeaderVisualH = 88;

  static const Duration kApiTimeout = Duration(seconds: 15);
  static const int kMaxRetries = 3;

  static const Duration kGpsUpdateInterval = Duration(milliseconds: 200);
  static const Duration kHeadingTickMin = Duration(milliseconds: 100);
  static const double kVehicleSpeedThreshold = 1.5;
  static const double kPedestrianSpeedThreshold = 0.5;
  static const Duration kStationaryTimeout = Duration(minutes: 2);

  static const double kCenterSnapMeters = 6;
  static const double kBearingDeadbandDeg = 0.5;
  static const double kMaxBearingVel = 320.0;
  static const double kMaxBearingAccel = 1200.0;
  static const double kRouteDeviationThreshold = 50.0;

  static const CircleId _accuracyCircleId = CircleId('accuracy');
  static const CircleId _searchCircleId = CircleId('search_radius');
  static const double _searchCircleMinM = 220;
  static const double _searchCircleMaxM = 650;


  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _sheetKey = GlobalKey();

  double _sheetHeight = 0;
  EdgeInsets _mapPadding = EdgeInsets.zero;

  Size _cachedScreenSize = const Size(390, 844);

  late SharedPreferences _prefs;
  bool _prefsReady = false;
  late ApiClient _api;
  Map<String, dynamic>? _user;
  bool _busyProfile = false;

  // Visibility: app lifecycle + tab (IndexedStack tabs that are wrapped in
  // TickerMode(enabled: false) when hidden).
  bool _appResumed = true;
  bool _tabVisible = true;
  bool get _active => _appResumed && _tabVisible;

  // Resume of a server-side active campus ride (after app restart).
  Map<String, dynamic>? _resumableRide;
  bool _resumeChecked = false;
  bool _bookingInProgress = false;

  int _routeSeq = 0;
  bool _mapPushScheduled = false;

  int _indexOfFocus(FocusNode focus) {
    for (int i = 0; i < _pts.length; i++) {
      if (identical(_pts[i].focus, focus)) return i;
    }
    return 0;
  }

  // --- AAA-GRADE ISOLATED MAP STATE ---
  GoogleMapController? _mapController;
  final ValueNotifier<Set<Marker>> _markersNotifier = ValueNotifier({});
  final ValueNotifier<Set<Polyline>> _polylinesNotifier = ValueNotifier({});
  final ValueNotifier<Set<Circle>> _circlesNotifier = ValueNotifier({});

  final CameraPosition _initialCam = const CameraPosition(
    target: LatLng(4.9757, 8.3417),
    zoom: 15,
  );

  Position? _curPos;
  StreamSubscription<Position>? _gpsSub;
  Timer? _gpsThrottleTimer;
  Timer? _stationaryTimer;
  MovementMode _movementMode = MovementMode.stationary;
  bool _gpsActive = true;

  int _gpsInitAttempt = 0;
  int _gpsStreamErrorCount = 0;
  Timer? _gpsWatchdog;
  DateTime? _lastStreamUpdate;

  Completer<void>? _locInitCompleter;
  StreamSubscription<ServiceStatus>? _svcStatusSub;

  BitmapDescriptor? _userPinIcon;
  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _dropIcon;
  BitmapDescriptor? _etaBubbleIcon;
  BitmapDescriptor? _minsBubbleIcon;
  bool _iconsPreloaded = false;

  BitmapDescriptor? _driverIcon;

  // Raw Sets that hold the data before being pushed to Notifiers
  final Set<Marker> _driverMarkers = <Marker>{};
  final Set<Marker> _markers = <Marker>{};
  final Set<Polyline> _lines = <Polyline>{};
  final Set<Circle> _circles = <Circle>{};
  final Set<Polyline> _driverLines = <Polyline>{};

  static const MarkerId _userMarkerId = MarkerId('user_location');
  static const MarkerId _etaMarkerId = MarkerId('eta_label');
  static const MarkerId _minsMarkerId = MarkerId('mins_label');
  static const MarkerId _driverSelectedId = MarkerId('driver_selected');

  BookingController? _booking;
  StreamSubscription<dynamic>? _bookingSub;

  _CamMode _camMode = _CamMode.follow;
  bool _rotateWithHeading = true;
  bool _useForwardAnchor = true;

  LatLng? _lastCamTarget;
  DateTime _lastCamMove = DateTime.fromMillisecondsSinceEpoch(0);



  StreamSubscription<CompassEvent>? _compassSub;
  double? _compassDeg;
  double? _lastBearingDeg;
  double _bearingEma = 0;
  double _userMarkerRotation = 0;
  double _lastBearingVel = 0;
  DateTime _lastBearingTime = DateTime.now();
  DateTime _lastHeadingTick = DateTime.fromMillisecondsSinceEpoch(0);

  LatLng? _lastUserMarkerLL;
  double _lastUserMarkerRot = 0;
  LatLng? _lastAccuracyLL;
  double _lastAccuracyRadius = 0;

  final List<RoutePoint> _pts = <RoutePoint>[];
  int _activeIdx = 0;

  String? _distanceText;
  String? _durationText;
  double? _tripKm; // road distance of the current route
  DateTime? _arrivalTime;
  Timer? _routeRefreshTimer;
  _RouteCache? _cachedRoute;
  String? _lastRouteHash;
  List<LatLng> _routePts = <LatLng>[];
  final List<_SpatialNode> _spatialIndex = <_SpatialNode>[];
  DateTime _lastRerouteCheck = DateTime.now();
  bool _isRerouting = false;

  final Uuid _uuid = const Uuid();
  String _placesSession = '';
  Timer? _debounce;
  late final AutocompleteService _auto;
  List<Suggestion> _sugs = <Suggestion>[];
  List<Suggestion> _recents = <Suggestion>[];
  bool _isTyping = false;
  int _lastQueryId = 0;
  final Map<String, _NetworkRequest> _requestQueue = <String, _NetworkRequest>{};
  int _activeRequests = 0;
  String? _autoStatus;
  String? _autoError;

  bool _expanded = false;
  bool _isConnected = true;
  Orientation? _lastOrientation;
  late final AnimationController _overlayAnimController;
  late final Animation<double> _overlayFadeAnim;

  StreamSubscription<RideMarketSnapshot>? _marketSub;
  bool _marketOpen = false;
  bool _offersLoading = false;
  List<RideOffer> _offers = const <RideOffer>[];

  DriverPollingEngine? _pollingEngine;
  final Map<String, DriverCar> _drivers = <String, DriverCar>{};
  final Map<String, double> _driverComputedHeading = <String, double>{};

  Timer? _fitBoundsDebounce;

  TripPhase _tripPhase = TripPhase.browsing;
  bool _navMode = false;
  Timer? _tripTickTimer;

  late final RideMarketService _rideMarketService;

  // --- ISOLATED PUSH METHOD (coalesced to one push per frame) ---
  void _pushMapState() {
    if (_mapPushScheduled || !mounted) return;
    _mapPushScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _mapPushScheduled = false;
      if (!mounted) return;
      _markersNotifier.value = <Marker>{..._markers, ..._driverMarkers};
      _polylinesNotifier.value = <Polyline>{..._lines, ..._driverLines};
      // A new Set instance: ValueNotifier only notifies on a changed value.
      _circlesNotifier.value = Set<Circle>.of(_circles);
    });
  }

  LatLng? _pickupAnchorLL() {
    if (_pts.isNotEmpty && _pts.first.isCurrent && _curPos != null) {
      return LatLng(_curPos!.latitude, _curPos!.longitude);
    }
    return _pts.isNotEmpty ? _pts.first.latLng : null;
  }

  LatLng? _destLL() => _pts.isNotEmpty ? _pts.last.latLng : null;

  void _refreshDriverMarkers() {
    final icon = _driverIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
    final next = <Marker>{};
    for (final d in _drivers.values) {
      final computedRot = _driverComputedHeading[d.id] ?? d.heading;
      next.add(Marker(
        markerId: MarkerId('driver_${d.id}'),
        position: d.ll,
        icon: icon,
        flat: true,
        rotation: computedRot,
        anchor: const Offset(0.5, 0.5),
        zIndex: 5,
      ));
    }
    _driverMarkers..clear()..addAll(next);
    _pushMapState();
  }

  void _resetTripState({bool keepRoute = true}) {
    _tripTickTimer?.cancel();
    _navMode = false;
    _tripPhase = TripPhase.browsing;
    _bookingSub?.cancel();
    _bookingSub = null;

    _driverLines.clear();
    _markers.removeWhere((m) => m.markerId == _driverSelectedId);
    _pushMapState();

    _enterFollowMode();
    _syncSearchCircle();
  }

  // TIGHT CAMPUS RADIUS (5.0 KM)
  double _campusRadiusKm() => 5.0;

  Future<void> _useCurrentAsPickup() async {
    if (_curPos == null || _pts.isEmpty) return;
    try {
      final marks = await geo.placemarkFromCoordinates(_curPos!.latitude, _curPos!.longitude);
      final place = marks.isNotEmpty ? marks.first : null;
      final addr = _fmtPlacemark(place);
      final ll = LatLng(_curPos!.latitude, _curPos!.longitude);
      setState(() { _pts.first..latLng = ll..placeId = null..controller.text = addr..isCurrent = true; });
      _putMarker(0, ll, addr);
      _putLocationCircle(ll, accuracy: _curPos!.accuracy);
      _syncSearchCircle();
    } catch (_) {
      final ll = LatLng(_curPos!.latitude, _curPos!.longitude);
      setState(() { _pts.first..latLng = ll..controller.text = 'Current location'..isCurrent = true; });
      _putMarker(0, ll, 'Current location');
      _syncSearchCircle();
    }
  }

  void _updatePickupFromGps() {
    if (_curPos == null) return;
    final ll = LatLng(_curPos!.latitude, _curPos!.longitude);
    setState(() => _pts.first.latLng = ll);
    _putMarker(0, ll, _pts.first.controller.text);
    _syncSearchCircle();
  }

  String _pointLabel(PointType t) {
    switch (t) {
      case PointType.pickup: return 'Pickup';
      case PointType.destination: return 'Destination';
      case PointType.stop: return 'Stop';
    }
  }

  void _putMarker(int idx, LatLng pos, String title) {
    final p = _pts[idx];
    final id = MarkerId('p_$idx');
    final icon = p.type == PointType.pickup ? (_pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure)) : p.type == PointType.destination ? (_dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen)) : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    _markers.removeWhere((m) => m.markerId == id);
    _markers.add(Marker(markerId: id, position: pos, icon: icon, anchor: const Offset(0.5, 0.5), infoWindow: InfoWindow(title: _pointLabel(p.type), snippet: title), consumeTapEvents: false));
    _pushMapState();
  }

  String _fmtPlacemark(geo.Placemark? p) {
    if (p == null) return 'Current location';
    final parts = <String>[];
    if ((p.name ?? '').isNotEmpty) parts.add(p.name!);
    if ((p.street ?? '').isNotEmpty && p.street != p.name) parts.add(p.street!);
    if ((p.locality ?? '').isNotEmpty) parts.add(p.locality!);
    return parts.isEmpty ? 'Current location' : parts.join(', ');
  }

  Future<void> _bookingStartTrip() async {
    final b = _booking;
    if (b == null) throw Exception('Booking controller is null.');
    final bool ok = await b.startTrip();
    if (!ok) throw Exception(b.lastError?.message ?? 'Failed to start trip.');
  }

  Future<void> _bookingCancelTrip() async {
    final b = _booking;
    if (b == null) throw Exception('Booking controller is null.');
    final bool ok = await b.cancelTrip();
    if (!ok) throw Exception(b.lastError?.message ?? 'Failed to cancel trip.');
  }

  Future<Map<String, dynamic>?> _bookingLiveSnapshotProvider() async {
    final b = _booking;
    if (b == null) return null;
    final snap = b.currentSnapshot;
    return snap.isEmpty ? null : Map<String, dynamic>.from(snap);
  }

  void _dbg(String msg, [Object? data]) {
    assert(() {
      final d = data == null ? '' : ' → $data';
      debugPrint('[CampusRide] $msg$d');
      return true;
    }());
  }

  void _log(String msg, [Object? data]) => _dbg(msg, data);
  void _logLocationDiagnostic(String message) => _dbg('[GPS-DIAGNOSTICS] $message');

  MediaQueryData _safeMediaQuery() {
    if (mounted) {
      final mq = MediaQuery.maybeOf(context);
      if (mq != null) return mq;
    }
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty) return MediaQueryData.fromView(views.first);
    return const MediaQueryData(size: Size(390, 844));
  }

  double _scaleFromUi(UIScale uiScale) {
    double scale = (uiScale.shortest / 390.0).clamp(0.58, 1.12);
    if (uiScale.tiny) scale *= 0.88;
    if (uiScale.compact) scale *= 0.94;
    if (uiScale.landscape && !uiScale.tablet) scale *= 0.86;

    final aspect = uiScale.longest / uiScale.shortest;
    if (aspect > 2.0) scale *= 0.88;
    if (aspect < 1.45) scale *= 1.04;

    return scale.clamp(0.56, 1.12);
  }

  void _cacheUiMetrics(MediaQueryData mq) {
    _cachedScreenSize = mq.size;
  }

  double _effectiveBottomNavH() {
    if (_marketOpen) return 0;
    if (_tripPhase != TripPhase.browsing) return 0;
    return kBottomNavH;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = ApiClient();
    _auto = AutocompleteService(logger: _log);
    _rideMarketService = RideMarketService(api: _api, debug: false);

    _overlayAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _overlayFadeAnim = CurvedAnimation(
      parent: _overlayAnimController,
      curve: Curves.easeOutCubic,
    );

    _initPoints();
    _bootstrap();
    _startCompass();

    if (!kIsWeb) {
      try {
        _svcStatusSub = Geolocator.getServiceStatusStream().listen(
              (status) {
            if (status == ServiceStatus.enabled) _restartLocationStreamWithBackoff();
          },
          onError: (_) {},
        );
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollingEngine?.dispose();
    _debounce?.cancel();
    _gpsWatchdog?.cancel();
    _gpsSub?.cancel();
    _svcStatusSub?.cancel();
    _gpsThrottleTimer?.cancel();
    _routeRefreshTimer?.cancel();
    _compassSub?.cancel();
    _stationaryTimer?.cancel();
    _overlayAnimController.dispose();
    _marketSub?.cancel();
    _rideMarketService.dispose();
    _bookingSub?.cancel();
    try { _booking?.dispose(); } catch (_) {}
    _fitBoundsDebounce?.cancel();
    _tripTickTimer?.cancel();

    // Dispose Notifiers
    _markersNotifier.dispose();
    _polylinesNotifier.dispose();
    _circlesNotifier.dispose();

    for (final p in _pts) {
      p.controller.dispose();
      p.focus.dispose();
    }
    try { _mapController?.dispose(); } catch (_) {}
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool visible = TickerMode.of(context);
    if (visible != _tabVisible) {
      _tabVisible = visible;
      _onActiveChanged();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool resumed = state == AppLifecycleState.resumed;
    if (resumed == _appResumed) return;
    _appResumed = resumed;
    _onActiveChanged();
  }

  /// Pauses GPS / compass / polling / route refresh while the app is in the
  /// background or this tab is hidden; resumes them when visible again.
  void _onActiveChanged() {
    if (!_active) {
      _gpsSub?.pause();
      _compassSub?.pause();
      _pollingEngine?.stop();
      _routeRefreshTimer?.cancel();
      _gpsWatchdog?.cancel();
      return;
    }
    if (_gpsSub?.isPaused ?? false) _gpsSub!.resume();
    if (_compassSub?.isPaused ?? false) _compassSub!.resume();
    if (_curPos == null) {
      _initLocation();
    } else {
      _refreshUserPosition();
      if (!_marketOpen && _tripPhase == TripPhase.browsing) {
        _pollingEngine?.start(LatLng(_curPos!.latitude, _curPos!.longitude), radiusKm: _campusRadiusKm(), rideType: 'campus_ride');
      }
    }
    if (_hasPickupAndDropoff) _armRouteRefresh();
    if (_routePts.isNotEmpty && _camMode == _CamMode.overview && _mapController != null) {
      Future<void>.delayed(const Duration(milliseconds: 80), () {
        if (mounted) _fitCurrentRouteToViewportV2(waitForLayout: false);
      });
    }
    if (_prefsReady && !_bookingInProgress) _checkResumableRide();
  }

  void _armRouteRefresh() {
    _routeRefreshTimer?.cancel();
    _routeRefreshTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      if (_active && _hasPickupAndDropoff && !_expanded) {
        _cachedRoute = null;
        _buildRoute();
      }
    });
  }

  Future<void> _primeNearbyDriversAsap() async {
    if (!mounted) return;
    if (_tripPhase != TripPhase.browsing) return;
    if (_marketOpen) return;

    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever || perm == LocationPermission.unableToDetermine) return;
      final svc = await Geolocator.isLocationServiceEnabled();
      if (!svc) return;
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) return;

      _curPos ??= last;
      final ll = LatLng(last.latitude, last.longitude);
      _pollingEngine?.start(ll, radiusKm: _campusRadiusKm(), rideType: 'campus_ride');
      _updateUserMarker(ll, rotation: (last.heading.isFinite && last.heading >= 0) ? last.heading : 0);
    } catch (_) {}
  }

  Future<void> _bootstrap() async {
    _prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _prefsReady = true;

    _pollingEngine = DriverPollingEngine(
      api: _api,
      userId: _prefs.getString('user_id') ?? _user?['id']?.toString() ?? 'guest',
      onDriversUpdated: (activeDrivers, computedHeadings) {
        _drivers..clear()..addEntries(activeDrivers.map((d) => MapEntry(d.id, d)));
        _driverComputedHeading..clear()..addAll(computedHeadings);
        _refreshDriverMarkers();
      },
    );

    await _primeNearbyDriversAsap();
    await Future.wait<void>([
      _initLocation(),
      _fetchUser(),
      _loadRecents(),
      _preloadAllIcons(),
      _checkResumableRide(),
    ]);
    if (!mounted) return;
    _refreshDriverMarkers();
    _scheduleMapPaddingUpdate();
  }

  String _riderId() => (_prefs.getString('user_id') ?? _user?['id']?.toString() ?? '').trim();

  /// Finds an active campus ride on the server (e.g. after the app was
  /// killed mid-trip) so the rider can jump back into live tracking.
  Future<void> _checkResumableRide() async {
    final String rider = _riderId();
    if (rider.isEmpty) return;
    final Map<String, dynamic>? active = await BookingController.fetchActiveRide(_api, rider);
    if (!mounted) return;
    final dynamic ride = active?['ride'];
    final bool campus = ride is Map && (ride['ride_type'] ?? '').toString() == 'campus_ride';
    setState(() {
      _resumeChecked = true;
      _resumableRide = campus ? active : null;
    });
  }

  Future<void> _resumeActiveRide() async {
    final Map<String, dynamic>? active = _resumableRide;
    if (active == null || _bookingInProgress) return;
    final Map<String, dynamic> ride = (active['ride'] as Map).cast<String, dynamic>();
    final String rideId = (ride['id'] ?? active['ride_id'] ?? '').toString();
    if (rideId.isEmpty) return;
    LatLng? ll(dynamic m) {
      if (m is! Map) return null;
      final double? la = double.tryParse('${m['lat']}');
      final double? lo = double.tryParse('${m['lng']}');
      if (la == null || lo == null || (la == 0 && lo == 0)) return null;
      return LatLng(la, lo);
    }

    final LatLng? pickup = ll(ride['pickup']);
    final LatLng? dest = ll(ride['destination']);
    if (pickup == null || dest == null) return;
    final dynamic driver = active['driver'];
    final String rider = _riderId();

    _booking?.dispose();
    final BookingController booking = BookingController(_api);
    _booking = booking;
    booking.attachToRide(
      rideId: rideId,
      riderId: rider,
      driverId: (ride['driver_id'] ?? '').toString(),
      rideType: 'campus_ride',
      initialPayload: active,
    );
    final String status = RideStatusCode.normalize(ride['status']);
    final TripNavPhase phase = status == RideStatusCode.inProgress
        ? TripNavPhase.enRoute
        : status == RideStatusCode.arrivedDestination
            ? TripNavPhase.arrivedDestination
            : status == RideStatusCode.arrivedPickup
                ? TripNavPhase.waitingPickup
                : TripNavPhase.driverToPickup;
    final double dLat = double.tryParse('${active['driver_lat']}') ?? 0;
    final double dLng = double.tryParse('${active['driver_lng']}') ?? 0;

    setState(() => _resumableRide = null);
    _stopRideMarket(restartNearbyPolling: false);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TripNavigationPage(
          args: TripNavigationArgs(
            userId: rider,
            driverId: (ride['driver_id'] ?? '').toString(),
            tripId: rideId,
            pickup: pickup,
            destination: dest,
            rideType: 'campus_ride',
            originText: (ride['pickup'] as Map)['text']?.toString() ?? '',
            destinationText: (ride['destination'] as Map)['text']?.toString() ?? '',
            driverName: driver is Map ? driver['name']?.toString() : null,
            vehicleType: driver is Map ? driver['vehicle_type']?.toString() : null,
            carPlate: driver is Map ? driver['car_plate']?.toString() : null,
            initialDriverLocation: (dLat == 0 && dLng == 0) ? null : LatLng(dLat, dLng),
            initialPhase: phase,
            bookingUpdates: booking.updates,
            liveSnapshotProvider: _bookingLiveSnapshotProvider,
            onStartTrip: _bookingStartTrip,
            onCancelTrip: _bookingCancelTrip,
            role: TripNavigationRole.rider,
            tickEvery: const Duration(seconds: 2),
            routeMinGap: const Duration(seconds: 2),
            arrivalMeters: 35.0,
            routeMoveThresholdMeters: 8.0,
            showStartTripButton: true,
            showCancelButton: true,
            showMetaCard: true,
            preserveStopOrder: true,
            autoCloseOnCancel: true,
          ),
        ),
      ),
    );
    if (!mounted) return;
    _resetTripState(keepRoute: true);
    _stopRideMarket();
    _checkResumableRide();
  }

  Future<void> _fetchUser() async {
    if (!mounted) return;
    setState(() => _busyProfile = true);
    try {
      final uid = _prefs.getString('user_id') ?? '';
      if (uid.isEmpty) return;
      final res = await _executeWithRetry('fetch_user', () => _api.request(ApiConstants.userInfoEndpoint, method: 'POST', data: <String, String>{'user': uid}, idempotent: true, retryCount: 0, timeout: kApiTimeout));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map<String, dynamic> && body['error'] == false) {
          if (!mounted) return;
          setState(() => _user = body['user'] as Map<String, dynamic>?);
          await _createUserPinIcon();
        }
      }
      if (mounted) setState(() => _isConnected = true);
    } catch (_) {
      if (mounted) setState(() => _isConnected = false);
    } finally {
      if (mounted) setState(() => _busyProfile = false);
    }
  }

  Future<http.Response> _executeWithRetry(String id, Future<http.Response> Function() executor) async {
    if (_requestQueue.containsKey(id)) return _requestQueue[id]!.completer.future;
    final request = _NetworkRequest(id, executor);
    _requestQueue[id] = request;

    try {
      while (request.retries <= kMaxRetries) {
        try {
          final response = await executor();
          request.completer.complete(response);
          return response;
        } catch (e) {
          request.retries++;
          if (request.retries > kMaxRetries) {
            request.completer.completeError(e);
            rethrow;
          }
          await Future.delayed(Duration(milliseconds: (400 * math.pow(2, request.retries - 1)).toInt()));
        }
      }
      throw Exception('Max retries exceeded');
    } finally {
      _requestQueue.remove(id);
    }
  }

  Future<void> _preloadAllIcons() async {
    if (_iconsPreloaded) return;
    try {
      await Future.wait<void>([_ensurePointIcons(), _createUserPinIcon(), _createDriverIcon()]);
      _iconsPreloaded = true;
      _refreshDriverMarkers();
    } catch (_) {}
  }

  /// Heading-aware location dot (anchor centre, flat, rotated by heading).
  /// The old avatar pin rotated its label with the compass.
  Future<void> _createUserPinIcon() async {
    try {
      if (!mounted) return;
      final double dpr = MediaQuery.devicePixelRatioOf(context);
      _userPinIcon = await MapGraphicsEngine.createUserLocationDot(devicePixelRatio: dpr, withHeading: true);
      if (!mounted) return;

      if (_curPos != null) {
        _updateUserMarker(
          LatLng(_curPos!.latitude, _curPos!.longitude),
          rotation: _userMarkerRotation,
        );
      }
    } catch (_) {}
  }


  Future<void> _ensurePointIcons() async {
    if (_pickupIcon != null && _dropIcon != null) return;
    final results = await Future.wait<BitmapDescriptor>([
      MapGraphicsEngine.createRingDotMarker(const Color(0xFF1A73E8)),
      MapGraphicsEngine.createRingDotMarker(const Color(0xFF00A651)),
    ]);
    _pickupIcon = results[0];
    _dropIcon = results[1];
  }

  Future<void> _createDriverIcon() async {
    if (_driverIcon != null) return;
    try {
      _driverIcon = await MapGraphicsEngine.assetToMarker('assets/images/open_top_view_car.png', targetWidth: 96);
      _refreshDriverMarkers();
    } catch (_) {}
  }

  void _updateUserMarker(LatLng pos, {double? rotation}) {
    if (_userPinIcon == null) return;
    if (rotation != null) _userMarkerRotation = rotation;

    final last = _lastUserMarkerLL;
    final rotDiff = (_userMarkerRotation - _lastUserMarkerRot).abs();

    if (last != null) {
      final moved = RoutingEngine.haversine(last, pos);
      if (moved < 0.9 && rotDiff < 2.0) return;
    }

    _lastUserMarkerLL = pos;
    _lastUserMarkerRot = _userMarkerRotation;

    _markers.removeWhere((m) => m.markerId == _userMarkerId);
    _markers.add(Marker(markerId: _userMarkerId, position: pos, icon: _userPinIcon!, anchor: const Offset(0.5, 0.5), flat: true, rotation: _userMarkerRotation, zIndexInt: 999));
    _pushMapState();
  }

  void _startCompass() {
    _compassSub?.cancel();
    _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
      final h = event.heading;
      if (h == null) return;
      _compassDeg = RoutingEngine.normalizeDeg(h);

      final now = DateTime.now();
      if (now.difference(_lastHeadingTick) < kHeadingTickMin) return;
      _lastHeadingTick = now;

      _applyHeadingTick();
    });
  }

  void _applyHeadingTick() {
    if (_expanded || _navMode || !_active) return;

    double? heading;
    final sp = _curPos?.speed ?? 0.0;

    if (sp >= kPedestrianSpeedThreshold && _curPos != null && _curPos!.heading.isFinite && _curPos!.heading >= 0) {
      heading = _curPos!.heading;
    } else if (_compassDeg != null) {
      heading = _compassDeg;
    }

    if (heading == null) return;

    final smooth = _smoothBearingWithJerkLimit(heading);
    final pos = _curPos != null ? LatLng(_curPos!.latitude, _curPos!.longitude) : null;

    if (pos != null) _updateUserMarker(pos, rotation: smooth);

    if (_camMode == _CamMode.follow && _rotateWithHeading && _mapController != null && pos != null) {
      _moveCameraRealtimeV2(
        target: _forwardBiasTarget(user: pos, bearingDeg: smooth),
        bearing: _rotateWithHeading ? smooth : 0,
        zoom: (sp >= kVehicleSpeedThreshold) ? 17.5 : (sp >= kPedestrianSpeedThreshold ? 17.0 : 16.5),
        tilt: Perf.I.tiltFor(sp),
      );
    }
  }

  double _shortestDiffDeg(double a, double b) => (a - b + 540) % 360 - 180;

  double _smoothBearingWithJerkLimit(double targetDeg) {
    final now = DateTime.now();
    final dt = (now.difference(_lastBearingTime).inMilliseconds / 1000.0).clamp(1e-3, 1.0);
    _lastBearingTime = now;

    if (_lastBearingDeg == null) {
      _lastBearingDeg = targetDeg;
      _bearingEma = targetDeg;
      _lastBearingVel = 0;
      return targetDeg;
    }

    final err = _shortestDiffDeg(targetDeg, _bearingEma);
    if (err.abs() < kBearingDeadbandDeg) return _bearingEma;

    final desiredVel = (err * 3.0).clamp(-kMaxBearingVel, kMaxBearingVel);
    final accel = ((desiredVel - _lastBearingVel) / dt).clamp(-kMaxBearingAccel, kMaxBearingAccel);
    _lastBearingVel = (_lastBearingVel + accel * dt).clamp(-kMaxBearingVel, kMaxBearingVel);
    _bearingEma = RoutingEngine.normalizeDeg(_bearingEma + _lastBearingVel * dt);
    return _bearingEma;
  }

  LatLng _forwardBiasTarget({required LatLng user, required double bearingDeg}) {
    if (!_useForwardAnchor) return user;
    final sp = _curPos?.speed ?? 0.0;
    final metersAhead = (_camMode == _CamMode.follow && sp > 0) ? (sp * 3.5).clamp(30.0, 180.0) : 0.0;
    return RoutingEngine.offsetLatLng(user, metersAhead, bearingDeg);
  }

  void _applyMapPadding() {
    if (!mounted) return;
    final mq = _safeMediaQuery();
    final uiScale = UIScale.of(context);
    final size = mq.size;
    final topPad = mq.padding.top + (kHeaderVisualH * _scaleFromUi(uiScale));
    final baseBottomPad = _sheetHeight + _effectiveBottomNavH();
    final bottomPad = mq.orientation == Orientation.landscape
        ? (baseBottomPad * (uiScale.tablet ? 0.78 : 0.68)).clamp(10.0, 260.0)
        : (baseBottomPad + uiScale.gap(uiScale.compact ? 8 : 12)).clamp(20.0, 520.0);
    final minScreenDim = math.min(size.width, size.height);
    final hPad = minScreenDim < 360 ? 4.0 : minScreenDim < 480 ? 6.0 : 8.0;
    setState(() => _mapPadding = EdgeInsets.fromLTRB(hPad, topPad, hPad, bottomPad));
  }

  double _effectiveBoundsPaddingV2(double basePad) {
    final mq = _safeMediaQuery();
    final minSide = math.min(mq.size.width, mq.size.height);
    final extra = math.max(math.max(_mapPadding.top, _mapPadding.bottom), math.max(_mapPadding.left, _mapPadding.right));
    return (basePad + extra + 16.0).clamp(basePad, (minSide * 0.35).clamp(basePad, 600.0));
  }

  Future<void> _animateBoundsSafeV2(LatLngBounds bounds, {double basePadding = 70}) async {
    if (_mapController == null) return;
    _camMode = _CamMode.overview;
    _rotateWithHeading = false;
    final pad = _effectiveBoundsPaddingV2(basePadding);
    const delayMs = [0, 80, 160];

    for (int attempt = 0; attempt < 3; attempt++) {
      if (!mounted || _mapController == null) return;
      try {
        await Future.delayed(Duration(milliseconds: delayMs[attempt]));
        await _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, pad));
        return;
      } catch (_) {
        if (attempt == 2) {
          try {
            final center = LatLng((bounds.northeast.latitude + bounds.southwest.latitude) / 2, (bounds.northeast.longitude + bounds.southwest.longitude) / 2);
            await _mapController!.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: center, zoom: 14.5, bearing: 0)));
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _fitCurrentRouteToViewportV2({bool waitForLayout = true}) async {
    if (!mounted) return;
    final pts = _routePts.isNotEmpty ? _routePts : <LatLng>[if (_pts.isNotEmpty && _pts.first.latLng != null) _pts.first.latLng!, if (_pts.isNotEmpty && _pts.last.latLng != null) _pts.last.latLng!];
    if (pts.length < 2) return;
    if (waitForLayout) {
      _scheduleMapPaddingUpdate();
      await Future.delayed(const Duration(milliseconds: 32));
    }
    await _animateBoundsSafeV2(RoutingEngine.computeSmartBounds(pts), basePadding: 70);
  }

  Future<void> _moveCameraRealtimeV2({required LatLng target, required double bearing, required double zoom, required double tilt}) async {
    if (!mounted || _mapController == null) return;
    final now = DateTime.now();
    final isLandscape = _cachedScreenSize.width > _cachedScreenSize.height;
    final minMoveInterval = isLandscape ? Duration(milliseconds: (Perf.I.camMoveMin.inMilliseconds * 1.2).round()) : Perf.I.camMoveMin;
    if (now.difference(_lastCamMove) < minMoveInterval) return;
    _lastCamMove = now;
    try {
      await _mapController!.moveCamera(CameraUpdate.newCameraPosition(CameraPosition(target: target, zoom: zoom, tilt: tilt, bearing: bearing)));
      _lastCamTarget = target;
    } catch (_) {}
  }

  void _scheduleMapPaddingUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _sheetKey.currentContext;
      double newHeight = 0;
      if (ctx != null) {
        final box = ctx.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) newHeight = box.size.height;
      }
      if (_sheetHeight != newHeight) {
        _sheetHeight = newHeight;
        _applyMapPadding();
        if (_routePts.isNotEmpty && !_expanded && _mapController != null) {
          _fitBoundsDebounce?.cancel();
          _fitBoundsDebounce = Timer(const Duration(milliseconds: 120), () {
            if (!mounted) return;
            if (_camMode == _CamMode.overview) _fitCurrentRouteToViewportV2(waitForLayout: false);
          });
        }
      }
    });
  }

  void _buildSpatialIndex() {
    _spatialIndex.clear();
    if (_routePts.isEmpty) return;
    for (int i = 0; i < _routePts.length; i++) {
      _spatialIndex.add(_SpatialNode(_routePts[i], i));
    }
  }

  int _nearestRouteIndex(LatLng p) {
    if (_spatialIndex.isEmpty) return -1;
    int bestIdx = -1;
    double bestDist = double.infinity;
    final step = math.max(1, _spatialIndex.length ~/ 100);
    for (int i = 0; i < _spatialIndex.length; i += step) {
      final node = _spatialIndex[i];
      final d = RoutingEngine.haversine(p, node.point);
      if (d < bestDist) { bestDist = d; bestIdx = node.index; }
    }
    if (bestIdx >= 0) {
      final start = math.max(0, bestIdx - 20);
      final end = math.min(_spatialIndex.length - 1, bestIdx + 20);
      for (int i = start; i <= end; i++) {
        final node = _spatialIndex[i];
        final d = RoutingEngine.haversine(p, node.point);
        if (d < bestDist) { bestDist = d; bestIdx = node.index; }
      }
    }
    return bestIdx;
  }

  double? _routeAwareBearing(LatLng user) {
    if (_spatialIndex.isEmpty) return null;
    final idx = _nearestRouteIndex(user);
    if (idx < 0) return null;
    final near = _routePts[idx];
    final distToRoute = RoutingEngine.haversine(user, near);
    if (distToRoute > kRouteDeviationThreshold) {
      _checkReroute(distToRoute);
      return null;
    }
    final speed = _curPos?.speed ?? 0.0;
    final lookAheadPoints = speed > kVehicleSpeedThreshold ? 10 : 5;
    final aheadIdx = (idx + lookAheadPoints).clamp(idx, _routePts.length - 1);
    if (idx == aheadIdx) return null;
    return RoutingEngine.bearingBetween(near, _routePts[aheadIdx]);
  }

  void _checkReroute(double deviation) {
    if (_isRerouting) return;
    final now = DateTime.now();
    if (now.difference(_lastRerouteCheck) < const Duration(seconds: 10)) return;
    _lastRerouteCheck = now;
    _isRerouting = true;
    _cachedRoute = null;
    Future<void>.delayed(const Duration(milliseconds: 500), () async {
      if (mounted && _pts.first.latLng != null && _pts.last.latLng != null) await _buildRoute();
      _isRerouting = false;
    });
  }

  void _enterFollowMode() {
    _camMode = _CamMode.follow;
    _rotateWithHeading = true;
    _useForwardAnchor = true;
  }

  LocationSettings _platformLocationSettings({required bool moving}) {
    final gp = Perf.I.gpsProfile(moving: moving);
    final accuracy = moving ? gp.accuracy : LocationAccuracy.high;
    final int distanceFilter = (moving ? gp.distanceFilterM : math.max(12, gp.distanceFilterM)).toInt();
    if (kIsWeb) return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
    final tp = defaultTargetPlatform;
    if (tp == TargetPlatform.android) return AndroidSettings(accuracy: accuracy, distanceFilter: distanceFilter, intervalDuration: Duration(milliseconds: gp.intervalMs), forceLocationManager: false);
    if (tp == TargetPlatform.iOS) return AppleSettings(accuracy: accuracy, distanceFilter: distanceFilter, activityType: ActivityType.automotiveNavigation, pauseLocationUpdatesAutomatically: true, showBackgroundLocationIndicator: false);
    return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  }

  bool _isGoodFix(Position p, double maxAccM) {
    if (!p.latitude.isFinite || !p.longitude.isFinite) return false;
    if (p.latitude == 0 && p.longitude == 0) return false;
    if (p.accuracy <= 0) return false;
    return p.accuracy <= maxAccM;
  }

  Future<Position?> _acquirePositionRobust() async {
    const maxAcceptableAcc = 2500.0;
    const tries = 2;
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && DateTime.now().difference(last.timestamp).inMinutes < 10 && _isGoodFix(last, 3500)) {
        _logLocationDiagnostic('Using fresh last-known');
        return last;
      }
    } catch (_) {}

    for (var attempt = 1; attempt <= tries; attempt++) {
      try {
        final p = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high, timeLimit: const Duration(seconds: 8));
        if (_isGoodFix(p, maxAcceptableAcc)) return p;
      } catch (_) {}
      final sample = await _firstStreamFix(deadline: const Duration(seconds: 4), moving: true, maxAccM: maxAcceptableAcc * 2);
      if (sample != null) return sample;
    }
    try { return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium, timeLimit: const Duration(seconds: 5)); } catch (_) {}
    try { return await Geolocator.getLastKnownPosition(); } catch (_) {}
    return null;
  }

  Future<Position?> _firstStreamFix({required Duration deadline, required bool moving, double maxAccM = 200}) async {
    StreamSubscription<Position>? sub;
    final completer = Completer<Position?>();
    void finish(Position? p) { if (!completer.isCompleted) completer.complete(p); }
    sub = Geolocator.getPositionStream(locationSettings: _platformLocationSettings(moving: moving)).listen((p) {
      if (_isGoodFix(p, maxAccM)) { finish(p); sub?.cancel(); }
    }, onError: (_) {});
    Future<void>.delayed(deadline).then((_) async { await sub?.cancel(); finish(null); });
    return completer.future;
  }

  Future<void> _awaitOrCreateInitFlight(Future<void> Function() action) async {
    if (_locInitCompleter != null) {
      try { await _locInitCompleter!.future; } catch (_) {}
      return;
    }
    _locInitCompleter = Completer<void>();
    try {
      await action();
      _locInitCompleter?.complete();
    } catch (e) {
      _locInitCompleter?.completeError(e);
      rethrow;
    } finally {
      _locInitCompleter = null;
    }
  }

  Future<void> _startGpsStream(Position seed) async {
    await _gpsSub?.cancel();
    _gpsStreamErrorCount = 0;
    _lastStreamUpdate = DateTime.now();
    _curPos = seed;
    _onGpsUpdate(seed);

    _gpsSub = Geolocator.getPositionStream(locationSettings: _platformLocationSettings(moving: true)).listen((p) {
      try {
        _lastStreamUpdate = DateTime.now();
        _gpsStreamErrorCount = 0;
        if (!_isGoodFix(p, 10000)) return;
        _onGpsUpdate(p);
      } catch (_) {}
    }, onError: (err) {
      _gpsStreamErrorCount++;
      if (_gpsStreamErrorCount >= 5) {
        _gpsSub?.cancel();
        _gpsStreamErrorCount = 0;
        _restartLocationStreamWithBackoff();
      }
    }, cancelOnError: false);

    _gpsWatchdog?.cancel();
    _gpsWatchdog = Timer.periodic(const Duration(seconds: 27), (_) {
      if (_lastStreamUpdate == null || !_active) return;
      if (DateTime.now().difference(_lastStreamUpdate!).inSeconds > 40) {
        _gpsSub?.cancel();
        _restartLocationStreamWithBackoff();
      }
    });
  }

  Future<void> _initLocation({bool userTriggered = false}) async {
    if (!mounted) return;
    await _awaitOrCreateInitFlight(() async {
      _gpsWatchdog?.cancel();
      // Shared gate: service + permission, prompts at most once per session
      // for automatic calls (no duplicate sheets with the Street Ride tab).
      final LocationGateStatus st = await LocationPermissionModal.ensure(
        context,
        userTriggered: userTriggered,
        message: 'Pick Me uses your location to match you with nearby campus drivers and set accurate pickups.',
      );
      if (!mounted || !st.isGranted) return;

      final pos = await _acquirePositionRobust();
      if (!mounted) return;
      if (pos == null) {
        if (userTriggered) _toast('Location Unavailable', 'We could not determine your position. Move to open space and try again.');
        return;
      }

      _curPos = pos;
      final ll = LatLng(pos.latitude, pos.longitude);
      _lastStreamUpdate = DateTime.now();

      if (_mapController != null) {
        try { await _mapController!.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: ll, zoom: 16.5, tilt: 45, bearing: pos.heading.isFinite && pos.heading >= 0 ? pos.heading : 0))); } catch (_) {}
      }

      try {
        await _useCurrentAsPickup();
        _updateUserMarker(ll, rotation: pos.heading >= 0 ? pos.heading : 0);
        _lastCamTarget = ll;
      } catch (_) {}

      await _startGpsStream(pos);
      if (!mounted) return;
      if (!_active) _gpsSub?.pause();
      if (!_marketOpen && _tripPhase == TripPhase.browsing && _active) {
        _pollingEngine?.start(ll, radiusKm: _campusRadiusKm(), rideType: 'campus_ride');
      }
    });
  }

  Future<void> _restartLocationStreamWithBackoff() async {
    if (!mounted || !_active) return;
    if (_locInitCompleter != null) return;
    _gpsInitAttempt = (_gpsInitAttempt + 1).clamp(1, 5);
    await Future.delayed(Duration(seconds: 2 * _gpsInitAttempt, milliseconds: (300 * (math.Random().nextDouble())).round()));
    if (!mounted) return;
    await _initLocation(userTriggered: false);
  }

  void _onGpsUpdate(Position pos) {
    if (_gpsThrottleTimer?.isActive ?? false) return;
    if (!_isGoodFix(pos, 10000)) return;

    _gpsThrottleTimer = Timer(kGpsUpdateInterval, () {
      if (!mounted) return;
      final now = DateTime.now();
      _curPos = pos;
      final ll = LatLng(pos.latitude, pos.longitude);

      final sp = pos.speed;
      if (sp >= kVehicleSpeedThreshold) {
        _movementMode = MovementMode.vehicle;
      } else if (sp >= kPedestrianSpeedThreshold) {
        _movementMode = MovementMode.pedestrian;
      } else {
        _movementMode = MovementMode.stationary;
      }

      if (sp >= kPedestrianSpeedThreshold) {
        if (!_gpsActive) { _gpsActive = true; _stationaryTimer?.cancel(); }
      } else {
        _checkStationaryTimeout();
      }

      _updateUserMarker(ll, rotation: (pos.heading.isFinite && pos.heading >= 0) ? pos.heading : _userMarkerRotation);

      if (!_navMode && !_expanded && _camMode == _CamMode.follow) {
        double? bearing = _routeAwareBearing(ll) ?? ((pos.heading.isFinite && pos.heading >= 0 && pos.speed >= kPedestrianSpeedThreshold) ? pos.heading : _compassDeg);
        if (bearing != null) {
          final smoothed = _smoothBearingWithJerkLimit(bearing);
          _moveCameraRealtimeV2(target: _forwardBiasTarget(user: ll, bearingDeg: smoothed), bearing: _rotateWithHeading ? smoothed : 0, zoom: (pos.speed >= kVehicleSpeedThreshold) ? 17.5 : (pos.speed >= kPedestrianSpeedThreshold ? 17.0 : 16.5), tilt: Perf.I.tiltFor(pos.speed));
        } else if (now.difference(_lastCamMove) > Perf.I.camMoveMin) {
          if (_lastCamTarget == null || RoutingEngine.haversine(_lastCamTarget!, ll) > kCenterSnapMeters) {
            _mapController?.moveCamera(CameraUpdate.newLatLng(ll));
            _lastCamTarget = ll;
            _lastCamMove = now;
          }
        }
      }
      if (_pts.isNotEmpty && _pts.first.isCurrent) _updatePickupFromGps();
      _putLocationCircle(ll, accuracy: pos.accuracy);
      _syncSearchCircle();
    });
  }

  void _checkStationaryTimeout() {
    _stationaryTimer?.cancel();
    _stationaryTimer = Timer(kStationaryTimeout, () {
      if (_movementMode == MovementMode.stationary && _gpsActive) _gpsActive = false;
    });
  }

  Future<void> _refreshUserPosition() async {
    if (_curPos == null) { await _initLocation(); return; }
    try { _onGpsUpdate(await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.bestForNavigation, timeLimit: const Duration(seconds: 5))); } catch (_) {}
  }

  void _putLocationCircle(LatLng c, {double accuracy = 50}) {
    if (!mounted) return;
    final r = accuracy.clamp(8, 100).toDouble();
    if (_lastAccuracyLL != null && RoutingEngine.haversine(_lastAccuracyLL!, c) < 2.0 && (r - _lastAccuracyRadius).abs() < 2.0) return;
    _lastAccuracyLL = c; _lastAccuracyRadius = r;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    _circles.removeWhere((x) => x.circleId == _accuracyCircleId);
    _circles.add(Circle(circleId: _accuracyCircleId, center: c, radius: r, fillColor: (isDark ? cs.primary : AppColors.primary).withValues(alpha: 0.10), strokeColor: (isDark ? cs.primary : AppColors.primary).withValues(alpha: 0.32), strokeWidth: 2));
    _pushMapState();
  }

  double _visualSearchRadiusMeters() => (_campusRadiusKm() * 1000.0).clamp(_searchCircleMinM, _searchCircleMaxM).toDouble();
  LatLng? _searchCircleCenter() => _pts.isNotEmpty && _pts.first.latLng != null ? _pts.first.latLng! : (_curPos != null ? LatLng(_curPos!.latitude, _curPos!.longitude) : null);
  bool _shouldShowSearchCircle() => _tripPhase == TripPhase.browsing && (_offersLoading || (_marketOpen && _drivers.isEmpty));

  void _syncSearchCircle() {
    if (!mounted) return;
    final show = _shouldShowSearchCircle();
    final center = _searchCircleCenter();
    if (!show || center == null) {
      _circles.removeWhere((x) => x.circleId == _searchCircleId);
      _pushMapState();
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    _circles.removeWhere((x) => x.circleId == _searchCircleId);
    _circles.add(Circle(circleId: _searchCircleId, center: center, radius: _visualSearchRadiusMeters(), fillColor: (isDark ? cs.primary : const Color(0xFF00A651)).withValues(alpha: 0.12), strokeColor: (isDark ? cs.primary : const Color(0xFF00A651)).withValues(alpha: 0.30), strokeWidth: 2));
    _pushMapState();
  }

  bool get _hasPickupAndDropoff => _pts.length >= 2 && _pts.first.latLng != null && _pts.last.latLng != null;
  String _computeRouteHash() => _pts.where((p) => p.latLng != null).map((p) => '${p.latLng!.latitude.toStringAsFixed(6)},${p.latLng!.longitude.toStringAsFixed(6)}').join('|');

  Future<void> _buildRoute() async {
    if (!_hasPickupAndDropoff || !mounted) return;
    final int seq = ++_routeSeq;
    final routeHash = _computeRouteHash();
    if (_cachedRoute != null && _lastRouteHash == routeHash && !_cachedRoute!.isStale) {
      _applyRouteFromCache(_cachedRoute!.route);
      await _fitCurrentRouteToViewportV2(waitForLayout: true);
      return;
    }
    setState(() { _distanceText = null; _durationText = null; _arrivalTime = null; });

    _lines.clear();
    _markers.removeWhere((m) => m.markerId == _etaMarkerId || m.markerId == _minsMarkerId);
    _routePts.clear(); _spatialIndex.clear();
    _pushMapState();

    final origin = _pts.first.latLng!;
    final destination = _pts.last.latLng!;
    final stops = <LatLng>[for (int i = 1; i < _pts.length - 1; i++) if (_pts[i].latLng != null) _pts[i].latLng!];

    RouteResult? result;
    try {
      result = await RoutingEngine.computeRoute(origin: origin, destination: destination, stops: stops);
    } catch (_) {
      result = null;
    }
    // A newer route request (pick / swap / stop) won, or the page is gone.
    if (!mounted || seq != _routeSeq || routeHash != _computeRouteHash()) return;

    if (result != null && result.points.isNotEmpty) {
      _lastRouteHash = routeHash;
      final adaptedRoute = _V2Route(result.points, result.distanceMeters, result.durationSeconds, const []);

      _cachedRoute = _RouteCache(adaptedRoute, DateTime.now());
      _applyRouteFromCache(adaptedRoute);
      await _fitCurrentRouteToViewportV2(waitForLayout: true);

      _armRouteRefresh();
    } else {
      setState(() => _isConnected = false);
      _toast('Route Error', 'Unable to calculate route.');
    }
  }

  void _applyRouteFromCache(_V2Route route) {
    if (route.points.isEmpty || !mounted) return;
    setState(() {
      _arrivalTime = DateTime.now().add(Duration(seconds: route.durationSeconds));
      _distanceText = _fmtDistance(route.distanceMeters);
      _durationText = _fmtDuration(route.durationSeconds);
      _tripKm = route.distanceMeters / 1000.0;
      _isConnected = true;
    });

    _lines.clear();
    _routePts = route.points;
    _buildSpatialIndex();
    _buildSpeedColoredPolylines(route.points, route.speedIntervals);
    _updateRouteBubbles(origin: _pts.first.latLng!, destination: _pts.last.latLng!, secs: route.durationSeconds).then((_) {
      if (mounted) _fitCurrentRouteToViewportV2(waitForLayout: true);
    });
  }

  void _buildSpeedColoredPolylines(List<LatLng> decPts, List<_SpeedInterval> intervals) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    _lines.add(Polyline(polylineId: const PolylineId('route_halo'), points: decPts, color: isDark ? Colors.white.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.92), width: 11, startCap: Cap.roundCap, endCap: Cap.roundCap, jointType: JointType.round, geodesic: true));
    _lines.add(Polyline(polylineId: const PolylineId('route_main'), points: decPts, color: AppColors.primary, width: 3, startCap: Cap.roundCap, endCap: Cap.roundCap, jointType: JointType.round, geodesic: true));
    _pushMapState();
  }

  Future<void> _updateRouteBubbles({required LatLng origin, required LatLng destination, required int secs}) async {
    final minutes = math.max(1, (secs / 60).round());
    final arrive = 'Arrive by ${DateFormat('h:mm a').format(DateTime.now().add(Duration(seconds: secs)))}';

    if (!mounted) return;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    _minsBubbleIcon = await MapGraphicsEngine.createMinutesCircleBadge(minutes: minutes, isDark: isDark, cs: cs);
    _etaBubbleIcon = await MapGraphicsEngine.createArrivePillBadge(text: arrive, isDark: isDark, cs: cs);
    if (!mounted) return;

    _markers.removeWhere((m) => m.markerId == _etaMarkerId || m.markerId == _minsMarkerId);
    _markers.add(Marker(markerId: _minsMarkerId, position: destination, icon: _minsBubbleIcon!, anchor: const Offset(0.5, 1.0), consumeTapEvents: false, zIndex: 998));
    _markers.add(Marker(markerId: _etaMarkerId, position: origin, icon: _etaBubbleIcon!, anchor: const Offset(0.5, 1.0), consumeTapEvents: false, zIndex: 998));
    _pushMapState();
  }

  String _fmtDistance(int m) => (m < 1000) ? '$m m' : '${(m / 1000.0).toStringAsFixed(1)} km';
  String _fmtDuration(int s) { final mins = (s / 60).round(); return mins < 60 ? '$mins min' : '${mins ~/ 60}h ${mins % 60}m'; }

  // ----------------------------------------------------
  // PERFECTLY ISOLATED CAMPUS HISTORY KEY
  // ----------------------------------------------------
  static const _kRecentsKey = 'campus_recent_places_v1';
  static const int _maxRecents = 30;

  Future<void> _loadRecents() async {
    final raw = _prefs.getString(_kRecentsKey);
    if (raw == null || raw.isEmpty || !mounted) return;
    try {
      setState(() {
        _recents = (jsonDecode(raw) as List).cast<Map<String, dynamic>>().map(Suggestion.fromJson).toList().take(_maxRecents).toList();
        _sugs = _recents;
      });
    } catch (_) { await _prefs.remove(_kRecentsKey); }
  }

  void _saveRecent(Suggestion s) {
    final up = List<Suggestion>.from(_recents)..removeWhere((e) => e.placeId == s.placeId)..insert(0, s);
    final cap = up.take(_maxRecents).toList();
    _prefs.setString(_kRecentsKey, jsonEncode(cap.map((e) => e.toJson()).toList()));
    if (mounted) setState(() => _recents = cap);
  }

  void _initPoints() {
    final pickupFocus = FocusNode(), pickupCtl = TextEditingController();
    pickupFocus.addListener(() { if (pickupFocus.hasFocus) _onFocused(0); });
    final destFocus = FocusNode(), destCtl = TextEditingController();
    destFocus.addListener(() { if (destFocus.hasFocus) _onFocused(1); });
    _pts.addAll([RoutePoint(type: PointType.pickup, controller: pickupCtl, focus: pickupFocus, hint: 'Pickup location'), RoutePoint(type: PointType.destination, controller: destCtl, focus: destFocus, hint: 'Where to on campus?')]);
  }

  void _onFocused(int index) { setState(() { _activeIdx = index; _sugs = _recents; _autoStatus = null; _autoError = null; }); _expand(); }
  void _expand() { setState(() => _expanded = true); _overlayAnimController.forward(); _scheduleMapPaddingUpdate(); }
  void _collapse() { FocusScope.of(context).unfocus(); setState(() => _expanded = false); _overlayAnimController.reverse(); _scheduleMapPaddingUpdate(); }

  void _openWallet() {
    final balance = _user != null ? double.tryParse(_user!['user_bal']?.toString() ?? _user!['bal']?.toString() ?? '0.0') ?? 0.0 : null;
    final currency = _user?['user_currency']?.toString() ?? 'NGN';
    showModalBottomSheet(context: context, backgroundColor: Theme.of(context).scaffoldBackgroundColor, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (_) => FundAccountSheet(account: _user, balance: balance, currency: currency));
  }

  void _toast(String title, String msg) { if (!mounted) return; showToastNotification(context: context, title: title, message: msg, isSuccess: false); }

  void _ensurePlacesSession() { if (_placesSession.isEmpty) _placesSession = _uuid.v4(); }

  void _onTyping(String q) {
    _debounce?.cancel();
    final query = q.trim();
    if (query.isEmpty) { if (mounted) setState(() { _sugs = _recents; _isTyping = false; _autoStatus = null; _autoError = null; }); return; }
    if (!_expanded) _expand();
    if (mounted) setState(() => _isTyping = true);
    _debounce = Timer(const Duration(milliseconds: 260), () => _fetchSugs(query));
  }

  Future<void> _fetchSugs(String input) async {
    // Never drop the latest query (that left the spinner stuck): older ones
    // are simply ignored when they return (query id check below).
    _ensurePlacesSession();
    final int myQueryId = ++_lastQueryId; _activeRequests++;
    final origin = _curPos == null ? null : LatLng(_curPos!.latitude, _curPos!.longitude);

    try {
      dynamic result = await _auto.autocomplete(input: input, sessionToken: _placesSession, apiKey: ApiConstants.kGoogleApiKey, country: 'ng', origin: origin).timeout(kApiTimeout);
      if (!mounted || myQueryId != _lastQueryId) return;
      try { _autoStatus = result.status?.toString(); _autoError = result.errorMessage?.toString(); } catch (_) {}
      List<Suggestion> sugs = const [];
      try { final preds = result.predictions; sugs = preds is List<Suggestion> ? preds : (preds is List ? preds.whereType<Suggestion>().toList() : const []); } catch (_) {}

      if (sugs.isEmpty) {
        try {
          result = await _auto.autocomplete(input: input, sessionToken: _placesSession, apiKey: ApiConstants.kGoogleApiKey, country: 'ng', origin: origin, relaxedTypes: true).timeout(kApiTimeout);
          if (!mounted || myQueryId != _lastQueryId) return;
          try { _autoStatus = result.status?.toString(); _autoError = result.errorMessage?.toString(); } catch (_) {}
          final preds = result.predictions; sugs = preds is List<Suggestion> ? preds : (preds is List ? preds.whereType<Suggestion>().toList() : const []);
        } catch (_) {}
      }
      if (sugs.isEmpty) {
        try {
          final alt = await _auto.findPlaceText(input: input, apiKey: ApiConstants.kGoogleApiKey, origin: origin).timeout(kApiTimeout);
          if (!mounted || myQueryId != _lastQueryId) return;
          sugs = alt;
          _autoStatus = _autoStatus ?? 'FALLBACK_FIND_PLACE';
        } catch (_) {}
      }
      if (mounted && myQueryId == _lastQueryId) setState(() { _sugs = sugs.isNotEmpty ? sugs : _recents; _isTyping = false; _isConnected = true; });
    } catch (_) {
      if (mounted && myQueryId == _lastQueryId) setState(() { _isTyping = false; _isConnected = false; _sugs = _recents; });
    } finally { _activeRequests = (_activeRequests - 1).clamp(0, 9999); }
  }

  Future<void> _selectSug(Suggestion s) async {
    HapticFeedback.selectionClick();
    _ensurePlacesSession();
    // Bind to the field that was active when tapped (recents on the
    // collapsed sheet always fill the destination).
    final RoutePoint target = _expanded ? _pts[_activeIdx.clamp(0, _pts.length - 1)] : _pts.last;
    try {
      final det = await _auto.placeDetails(placeId: s.placeId, sessionToken: _placesSession, apiKey: ApiConstants.kGoogleApiKey).timeout(kApiTimeout);
      if (det.latLng == null) { _toast('Place Error', 'Could not read location details.'); return; }
      if (!mounted) return;
      final int idx = _pts.indexOf(target);
      if (idx < 0) return; // the stop was removed while loading
      setState(() {
        target..latLng = det.latLng..placeId = s.placeId..controller.text = (s.mainText.isNotEmpty ? s.mainText : s.description)..isCurrent = false;
      });
      _putMarker(idx, det.latLng!, s.description);
      _saveRecent(s);
      _placesSession = '';
      if (_hasPickupAndDropoff) {
        _collapse();
        _cachedRoute = null;
        await _buildRoute();
        if (!mounted) return;
        await _startRideMarket();
      } else {
        for (int i = 0; i < _pts.length; i++) { if (_pts[i].controller.text.trim().isEmpty) { _activeIdx = i; _pts[i].focus.requestFocus(); return; } }
        _collapse();
      }
    } catch (_) { if (mounted) _toast('Network Error', 'Failed to load place details.'); }
  }

  void _addStop() {
    HapticFeedback.selectionClick();
    if (_pts.length >= 6) { _toast('Limit', 'Maximum stops reached.'); return; }
    final insertAt = (_pts.length - 1).clamp(1, _pts.length);
    final stopFocus = FocusNode(), stopCtl = TextEditingController();
    stopFocus.addListener(() { if (stopFocus.hasFocus) _onFocused(_indexOfFocus(stopFocus)); });
    if (!mounted) return;
    setState(() { _pts.insert(insertAt, RoutePoint(type: PointType.stop, controller: stopCtl, focus: stopFocus, hint: 'Add stop')); _activeIdx = insertAt; });
    _expand();
    Future.delayed(const Duration(milliseconds: 40), () { if (mounted) stopFocus.requestFocus(); });
  }

  void _removeStop(int index) {
    if (index <= 0 || index >= _pts.length - 1) return;
    HapticFeedback.selectionClick();
    final removed = _pts[index];
    if (!mounted) return;
    setState(() => _pts.removeAt(index));
    removed.controller.dispose(); removed.focus.dispose();
    _rebuildPointMarkers();
    if (_hasPickupAndDropoff) { _cachedRoute = null; _buildRoute(); }
  }

  void _rebuildPointMarkers() {
    _markers.removeWhere((m) => m.markerId.value.startsWith('p_'));
    for (int i = 0; i < _pts.length; i++) {
      if (_pts[i].latLng == null) continue;
      final icon = _pts[i].type == PointType.pickup ? (_pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure)) : _pts[i].type == PointType.destination ? (_dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen)) : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
      _markers.add(Marker(markerId: MarkerId('p_$i'), position: _pts[i].latLng!, icon: icon, anchor: const Offset(0.5, 0.5), infoWindow: InfoWindow(title: _pointLabel(_pts[i].type), snippet: _pts[i].controller.text), consumeTapEvents: false));
    }
    _pushMapState();
  }

  void _swap() {
    if (_pts.length < 2) return;
    HapticFeedback.selectionClick();
    final a = _pts.first, b = _pts.last;
    if (!mounted) return;
    setState(() {
      final ll = a.latLng, pid = a.placeId, txt = a.controller.text, isCur = a.isCurrent;
      a..latLng = b.latLng..placeId = b.placeId..controller.text = b.controller.text..isCurrent = false;
      b..latLng = ll..placeId = pid..controller.text = txt..isCurrent = isCur;
    });
    _rebuildPointMarkers();
    if (_hasPickupAndDropoff) { _cachedRoute = null; _buildRoute(); }
  }

  Future<void> _startRideMarket() async {
    if (!_hasPickupAndDropoff || !mounted) return;
    _pollingEngine?.stop();
    await _marketSub?.cancel(); _marketSub = null;
    if (!mounted) return;
    setState(() { _offersLoading = true; _marketOpen = true; });
    _syncSearchCircle();
    LatLng safePickup() => _pts.isNotEmpty && _pts.first.latLng != null ? _pts.first.latLng! : (_curPos != null ? LatLng(_curPos!.latitude, _curPos!.longitude) : _initialCam.target);
    LatLng safeDrop() => _pts.isNotEmpty && _pts.last.latLng != null ? _pts.last.latLng! : _initialCam.target;

    _marketSub = _rideMarketService.stream(
      origin: safePickup(),
      destination: safeDrop(),
      originProvider: safePickup,
      destinationProvider: safeDrop,
      userIdProvider: _riderId,
      tripKmProvider: () => _tripKm ?? 0,
      radiusKm: _campusRadiusKm(),
      pollInterval: const Duration(seconds: 3),
      rideType: 'campus_ride',
    ).listen((snap) {
      if (!mounted) return;
      _offers = snap.offers;
      _drivers..clear()..addEntries(snap.drivers.map((d) => MapEntry(d.id, d)));
      _refreshDriverMarkers();
      setState(() => _offersLoading = false);
      _syncSearchCircle();
    }, onError: (_) {
      if (mounted) {
        setState(() => _offersLoading = false);
        _syncSearchCircle();
      }
    });
  }

  void _stopRideMarket({bool restartNearbyPolling = true}) {
    _marketSub?.cancel(); _marketSub = null;
    if (mounted) setState(() { _marketOpen = false; _offersLoading = false; _offers = const []; });
    _syncSearchCircle();
    if (restartNearbyPolling && _curPos != null) {
      _pollingEngine?.start(LatLng(_curPos!.latitude, _curPos!.longitude), radiusKm: _campusRadiusKm(), rideType: 'campus_ride');
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    _cacheUiMetrics(mq);
    final s = _scaleFromUi(uiScale);
    final safeTop = mq.padding.top;

    if (_lastOrientation != mq.orientation) {
      _lastOrientation = mq.orientation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduleMapPaddingUpdate();
        if (_routePts.isNotEmpty && _camMode == _CamMode.overview) {
          Future.delayed(const Duration(milliseconds: 220), () { if (mounted) _fitCurrentRouteToViewportV2(waitForLayout: true); });
        }
      });
    }

    final bottomNavH = _effectiveBottomNavH();
    final fabBottom = uiScale.landscape
        ? (_sheetHeight + math.max(bottomNavH * 0.45, uiScale.gap(8)) + uiScale.gap(10)).clamp(uiScale.gap(54), uiScale.height * 0.42)
        : (_sheetHeight + bottomNavH + uiScale.gap(uiScale.compact ? 10 : 16)).clamp(uiScale.gap(84), uiScale.height * 0.62);

    final fabRight = uiScale.landscape ? uiScale.inset(uiScale.tiny ? 8 : 12).clamp(8.0, 24.0) : uiScale.inset(14).clamp(12.0, 24.0);
    final hasSummary = _distanceText != null && _durationText != null;

    final bottomSheetMaxH = uiScale.landscape
        ? mq.size.height * (uiScale.tablet ? 0.75 : 0.70)
        : mq.size.height * (uiScale.tiny ? 0.68 : (uiScale.compact ? 0.60 : 0.55));

    final summaryMaxWidth = uiScale.tablet ? 920.0 : uiScale.landscape ? mq.size.width * 0.78 : mq.size.width - 24;

    return Scaffold(
      key: _scaffoldKey,
      drawer: AppMenuDrawer(user: _user),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: _IsolatedHomeMapLayer(
              markersNotifier: _markersNotifier,
              polylinesNotifier: _polylinesNotifier,
              circlesNotifier: _circlesNotifier,
              initialCameraPosition: _initialCam,
              padding: _mapPadding,
              isDark: isDark,
              onMapCreated: (c) {
                _mapController = c;
                _scheduleMapPaddingUpdate();
                _lastCamTarget = _initialCam.target;
                if (_routePts.isNotEmpty) Future.delayed(const Duration(milliseconds: 80), () => _fitCurrentRouteToViewportV2(waitForLayout: false));
              },
              onCameraMove: (pos) => _lastCamTarget = pos.target,
              onTap: (_) => _collapse(),
            ),
          ),

          if (!_isConnected)
            Positioned(
              top: safeTop + (kHeaderVisualH * s) + uiScale.gap(8),
              left: uiScale.inset(10),
              right: uiScale.inset(10),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: summaryMaxWidth),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(uiScale.radius(10)),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: uiScale.inset(16), vertical: uiScale.inset(12)),
                        decoration: BoxDecoration(
                          color: isDark ? cs.errorContainer.withValues(alpha: 0.85) : Colors.orange.shade700.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(uiScale.radius(10)),
                          border: Border.all(color: isDark ? cs.error.withValues(alpha: 0.5) : Colors.orange.shade300, width: 1),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 10, offset: const Offset(0, 4))],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.wifi_off, size: uiScale.icon(18), color: isDark ? cs.onErrorContainer : Colors.white),
                            SizedBox(width: uiScale.gap(10)),
                            Expanded(
                              child: Text('Connection issue. Retrying...', style: TextStyle(color: isDark ? cs.onErrorContainer : Colors.white, fontSize: uiScale.font(13), fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: Container(
                height: safeTop + (kHeaderVisualH * s),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: isDark ? [Colors.black.withValues(alpha: 0.85), Colors.black.withValues(alpha: 0.0)] : [Colors.white.withValues(alpha: 0.9), Colors.white.withValues(alpha: 0.0)],
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            top: safeTop, left: 0, right: 0,
            child: HeaderBar(user: _user, busyProfile: _busyProfile, onMenu: () => _scaffoldKey.currentState?.openDrawer(), onWallet: _openWallet, onNotifications: () => Navigator.pushNamed(context, AppRoutes.notifications)),
          ),

          // 🎓 BEAUTIFUL CAMPUS MODE BADGE
          Positioned(
            top: safeTop + (kHeaderVisualH * s) - uiScale.gap(16),
            left: 0,
            right: 0,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(uiScale.radius(20)),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: uiScale.inset(16), vertical: uiScale.inset(8)),
                    decoration: BoxDecoration(
                      color: isDark ? cs.primary.withValues(alpha: 0.2) : AppColors.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(uiScale.radius(20)),
                      border: Border.all(color: isDark ? cs.primary.withValues(alpha: 0.5) : AppColors.primary.withValues(alpha: 0.5), width: 1.2),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 4))],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.school_rounded, color: isDark ? cs.primary : AppColors.primary, size: uiScale.icon(16)),
                        SizedBox(width: uiScale.gap(8)),
                        Text('CAMPUS MODE', style: TextStyle(color: isDark ? cs.onSurface : AppColors.textPrimary, fontWeight: FontWeight.w900, fontSize: uiScale.font(12), letterSpacing: 1.0)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          if (_resumableRide != null && _resumeChecked)
            Positioned(
              top: safeTop + (kHeaderVisualH * s) + uiScale.gap(hasSummary ? 70 : 26),
              left: uiScale.inset(10), right: uiScale.inset(10),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: summaryMaxWidth),
                  child: Material(
                    color: isDark ? cs.primaryContainer : AppColors.primary,
                    borderRadius: BorderRadius.circular(uiScale.radius(16)),
                    elevation: 6,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(uiScale.radius(16)),
                      onTap: _resumeActiveRide,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: uiScale.inset(14), vertical: uiScale.inset(10)),
                        child: Row(
                          children: [
                            Icon(Icons.directions_car_filled_rounded, color: isDark ? cs.onPrimaryContainer : Colors.white),
                            SizedBox(width: uiScale.gap(10)),
                            Expanded(
                              child: Text('You have an active campus ride. Tap to track it.',
                                  style: TextStyle(fontWeight: FontWeight.w800, color: isDark ? cs.onPrimaryContainer : Colors.white)),
                            ),
                            Icon(Icons.chevron_right_rounded, color: isDark ? cs.onPrimaryContainer : Colors.white),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          if (hasSummary)
            Positioned(
              top: safeTop + (kHeaderVisualH * s) + uiScale.gap(26),
              left: uiScale.inset(10), right: uiScale.inset(10),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: summaryMaxWidth),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(uiScale.radius(20)),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: uiScale.inset(uiScale.compact ? 12 : 16), vertical: uiScale.inset(uiScale.compact ? 8 : 10)),
                        decoration: BoxDecoration(
                          color: isDark ? cs.surfaceContainerHighest.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(uiScale.radius(20)),
                          border: Border.all(color: isDark ? cs.outline.withValues(alpha: 0.4) : AppColors.mintBgLight.withValues(alpha: 0.5), width: 1.2),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.5 : .15), blurRadius: 16, offset: const Offset(0, 6))],
                        ),
                        child: Wrap(
                          alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: uiScale.gap(10), runSpacing: uiScale.gap(6),
                          children: [
                            Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.schedule_rounded, size: uiScale.icon(16), color: isDark ? cs.primary : AppColors.primary), SizedBox(width: uiScale.gap(6)), Text(_durationText!, style: TextStyle(fontWeight: FontWeight.w800, fontSize: uiScale.font(12.5), color: isDark ? cs.onSurface : AppColors.textPrimary))]),
                            Container(height: uiScale.gap(16), width: 1, color: isDark ? cs.outline : AppColors.mintBgLight.withValues(alpha: .5)),
                            Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.straighten_rounded, size: uiScale.icon(16), color: isDark ? cs.primary : AppColors.primary), SizedBox(width: uiScale.gap(6)), Text(_distanceText!, style: TextStyle(fontWeight: FontWeight.w800, fontSize: uiScale.font(12.5), color: isDark ? cs.onSurface : AppColors.textPrimary))]),
                            if (_arrivalTime != null) ...[
                              Container(height: uiScale.gap(16), width: 1, color: isDark ? cs.outline : AppColors.mintBgLight.withValues(alpha: .5)),
                              Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.flag_rounded, size: uiScale.icon(16), color: isDark ? cs.primary : AppColors.primary), SizedBox(width: uiScale.gap(6)), Text('Arrive ${DateFormat('h:mm a').format(_arrivalTime!)}', style: TextStyle(fontWeight: FontWeight.w800, fontSize: uiScale.font(12.5), color: isDark ? cs.onSurface : AppColors.textPrimary))]),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          Positioned(
            right: fabRight, bottom: fabBottom,
            child: LocateFab(onTap: () async {
              HapticFeedback.selectionClick();
              _enterFollowMode();
              if (_curPos != null) {
                final ll = LatLng(_curPos!.latitude, _curPos!.longitude);
                _applyHeadingTick();
                await _mapController?.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: ll, zoom: 17, tilt: 45)));
              } else {
                await _initLocation(userTriggered: true);
              }
            }),
          ),

          Positioned(
            left: 0, right: 0, bottom: 0,
            child: KeyedSubtree(
              key: _sheetKey,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: bottomSheetMaxH),
                child: !_hasPickupAndDropoff
                    ? RouteSheet(
                  key: ValueKey('route_sheet_${_expanded}_$_marketOpen'),
                  bottomNavHeight: bottomNavH,

                  sheetTitle: 'Campus Transit',
                  sheetSubtitle: 'Exclusive intra-campus rides for students and staff.',

                  recentDestinations: _recents,
                  onSearchTap: () {
                    setState(() { _activeIdx = _pts.length - 1; _expanded = true; _pts.last.focus.requestFocus(); });
                    _scheduleMapPaddingUpdate();
                  },
                  onRecentTap: (sug) async { await _selectSug(sug); },
                )
                    : RideMarketSheet(
                  bottomNavHeight: bottomNavH,
                  originText: _pts.first.controller.text,
                  destinationText: _pts.last.controller.text,
                  distanceText: _distanceText,
                  durationText: _durationText,
                  tripDistanceKm: _tripKm,
                  offers: _offers,
                  loading: _offersLoading,
                  drivers: _drivers.values.toList(),
                  driversNearbyCount: _drivers.length,
                  userLocation: _curPos == null ? null : GeoPoint(_curPos!.latitude, _curPos!.longitude),
                  pickupLocation: _pickupAnchorLL() == null ? null : GeoPoint(_pickupAnchorLL()!.latitude, _pickupAnchorLL()!.longitude),
                  dropLocation: _destLL() == null ? null : GeoPoint(_destLL()!.latitude, _destLL()!.longitude),
                  onRefresh: _startRideMarket,
                  onCancel: () {
                    _stopRideMarket();
                    _resetTripState(keepRoute: false);
                    setState(() {
                      _marketOpen = false;
                      if (_pts.length >= 2) {
                        _pts.last.latLng = null;
                        _pts.last.controller.clear();
                        _pts.last.placeId = null;
                      }
                      if (_pts.length > 2) {
                        _pts.removeRange(1, _pts.length - 1);
                      }
                      _lines.clear();
                      _routePts.clear();
                      _distanceText = null;
                      _durationText = null;
                      _tripKm = null;
                      _arrivalTime = null;
                      _cachedRoute = null;
                      _routeSeq++; // drop any route still being computed
                    });
                    _rebuildPointMarkers();
                    _syncSearchCircle();
                    if (_curPos != null) {
                      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(_curPos!.latitude, _curPos!.longitude), 16.5));
                    }
                  },
                  onBook: (driver, offer) async {
                    if (_bookingInProgress) return;
                    _bookingInProgress = true;
                    try {
                    await BookingFlowManager.initiateBooking(
                      context: context,
                      apiClient: _api,
                      prefs: _prefs,
                      user: _user,
                      driver: driver,
                      offer: offer,
                      pickup: _pickupAnchorLL() ?? _pts.first.latLng!,
                      destination: _destLL() ?? _pts.last.latLng!,
                      stops: [for (int i = 1; i < _pts.length - 1; i++) if (_pts[i].latLng != null) _pts[i].latLng!],
                      dropOffTexts: [for (int i = 1; i < _pts.length - 1; i++) if (_pts[i].latLng != null) _pts[i].controller.text.trim()],
                      pickupText: _pts.first.controller.text.trim(),
                      destinationText: _pts.last.controller.text.trim(),
                      isCurrentPickup: _pts.first.isCurrent,
                      rideType: 'campus_ride',
                      onStopRideMarket: () => _stopRideMarket(restartNearbyPolling: false),
                      onStartRideMarket: () => _startRideMarket(),
                      onResetTripState: () => _resetTripState(keepRoute: true),
                      onDriverEngaged: (_, __) {},
                      onBookingControllerCreated: (controller) {
                        // Release the previous ride's controller (it kept polling).
                        if (!identical(_booking, controller)) _booking?.dispose();
                        _booking = controller;
                      },
                      onSubscriptionCreated: (sub) {
                        _bookingSub?.cancel();
                        _bookingSub = sub;
                      },
                      snapshotProvider: _bookingLiveSnapshotProvider,
                      onStartTrip: _bookingStartTrip,
                      onCancelTrip: _bookingCancelTrip,
                    );
                    } finally {
                      _bookingInProgress = false;
                      if (mounted) _checkResumableRide();
                    }
                  },
                ),
              ),
            ),
          ),
          if (_expanded)
            FadeTransition(
              opacity: _overlayFadeAnim,
              child: AutoOverlay(
                safeTop: safeTop,
                bottomPadding: bottomNavH + uiScale.gap(12),
                autoStatus: _autoStatus,
                autoError: _autoError,
                isTyping: _isTyping,
                activeIndex: _activeIdx,
                points: _pts,
                suggestions: _sugs,
                recents: _recents,
                hasGps: _curPos != null,
                onUseCurrentPickup: _useCurrentAsPickup,
                onTyping: _onTyping,
                onFocused: _onFocused,
                onSelectSuggestion: _selectSug,
                fmtDistance: _fmtDistance,
                onAddStop: _addStop,
                onRemoveStop: _removeStop,
                onClose: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  _collapse();
                  Future.delayed(const Duration(milliseconds: 50), () { if (mounted) setState(() {}); });
                },
                onSwap: _swap,
              ),
            ),
        ],
      ),

      /*
      bottomNavigationBar: (!_marketOpen && _tripPhase == TripPhase.browsing)
          ? CustomBottomNavBar(
        currentIndex: _currentIndex,
        onTap: (i) {
          HapticFeedback.selectionClick();
          setState(() => _currentIndex = i);
          switch (i) {
            case 0: Navigator.pushNamed(context, AppRoutes.home); break;
            case 1:  break;
            case 2: break;
            case 3: break;
            case 4: Navigator.pushNamed(context, AppRoutes.profile); break;
          }
        },
      )
          : null,

       */
    );
  }
}

// --- ④ ISOLATED MAP LAYER WIDGET (Using ValueNotifier) ---
class _IsolatedHomeMapLayer extends StatelessWidget {
  final ValueNotifier<Set<Marker>> markersNotifier;
  final ValueNotifier<Set<Polyline>> polylinesNotifier;
  final ValueNotifier<Set<Circle>> circlesNotifier;

  final CameraPosition initialCameraPosition;
  final EdgeInsets padding;
  final bool isDark;
  final void Function(GoogleMapController) onMapCreated;
  final void Function(CameraPosition) onCameraMove;
  final void Function(LatLng) onTap;

  const _IsolatedHomeMapLayer({
    required this.markersNotifier,
    required this.polylinesNotifier,
    required this.circlesNotifier,
    required this.initialCameraPosition,
    required this.padding,
    required this.isDark,
    required this.onMapCreated,
    required this.onCameraMove,
    required this.onTap,
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
                    padding: padding,
                    myLocationEnabled: false,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: false,
                    compassEnabled: false,
                    mapToolbarEnabled: false,
                    rotateGesturesEnabled: false,
                    tiltGesturesEnabled: false,
                    // --- MASSIVE MEMORY FIXES ---
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
                    onCameraMove: onCameraMove,
                    onTap: onTap,
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