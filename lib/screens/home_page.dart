// lib/screens/home_page.dart
//
// Rider home (Street Ride): live map, blue-dot user location, animated nearby
// cars, route planning + ride market.
//
// Performance model
//  • The GoogleMap widget is built once and only rebuilt through
//    ValueNotifiers (markers / polylines / circles / padding).
//  • All marker motion (user dot, cars) is sampled from a single Ticker that
//    only runs while something is animating, and is muted automatically when
//    this tab is hidden in the IndexedStack (TickerMode).
//  • GPS / compass updates never call setState.
//  • GPS, compass and driver polling pause when the app is backgrounded or the
//    tab is not visible.
//  • Location permission goes through the single app-wide gate in
//    [LocationPermissionModal] (one prompt at a time, no re-pop on resume).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
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
import '../services/autocomplete_service.dart';
import '../services/booking_controller.dart';
import '../services/ride_market_service.dart';
import '../models/geo_point.dart';
import '../ui/ui_scale.dart';

import 'state/home_models.dart';
import 'state/location_permission_modal.dart';
import 'state/booking_flow_manager.dart';
import 'state/map_graphics_engine.dart';
import 'state/driver_polling_engine.dart';
import 'state/map_gesture_sensor.dart';
import 'state/marker_motion.dart';
import 'state/routing_engine.dart';

class _RouteCache {
  final RouteResult route;
  final String hash;
  final DateTime timestamp;
  const _RouteCache(this.route, this.hash, this.timestamp);
  bool get isStale => DateTime.now().difference(timestamp) > const Duration(minutes: 10);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver, TickerProviderStateMixin {
  static const double kBottomNavH = 74;
  static const double kHeaderVisualH = 88;
  static const Duration kApiTimeout = Duration(seconds: 15);
  static const int kMaxRetries = 3;
  static const double kHomeRadiusKm = 50.0;

  static const CircleId _accuracyCircleId = CircleId('accuracy');
  static const CircleId _searchCircleId = CircleId('search_radius');
  static const double _searchCircleMinM = 220;
  static const double _searchCircleMaxM = 650;

  static const MarkerId _userMarkerId = MarkerId('user_location');
  static const MarkerId _etaMarkerId = MarkerId('eta_label');
  static const MarkerId _minsMarkerId = MarkerId('mins_label');

  static const String _kRecentsKey = 'recent_places_v5';
  static const int _maxRecents = 30;

  static const CameraPosition _initialCam = CameraPosition(target: LatLng(4.9757, 8.3417), zoom: 15);

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _sheetKey = GlobalKey();

  double _sheetHeight = 0;
  final ValueNotifier<EdgeInsets> _mapPadding = ValueNotifier<EdgeInsets>(EdgeInsets.zero);

  SharedPreferences? _prefs;
  late final ApiClient _api;
  Map<String, dynamic>? _user;
  bool _busyProfile = false;
  bool _isConnected = true;

  // ── Map state (isolated from setState) ─────────────────────────────────────
  GoogleMapController? _map;
  final ValueNotifier<Set<Marker>> _markersNotifier = ValueNotifier<Set<Marker>>(<Marker>{});
  final ValueNotifier<Set<Polyline>> _polylinesNotifier = ValueNotifier<Set<Polyline>>(<Polyline>{});
  final ValueNotifier<Set<Circle>> _circlesNotifier = ValueNotifier<Set<Circle>>(<Circle>{});
  late final Widget _mapLayer;

  final Map<MarkerId, Marker> _staticMarkers = <MarkerId, Marker>{};
  final Map<CircleId, Circle> _staticCircles = <CircleId, Circle>{};
  final Map<PolylineId, Polyline> _routeLines = <PolylineId, Polyline>{};

  late final Ticker _frameTicker;
  bool _mapDirty = false;

  // ── Icons (generated once per devicePixelRatio) ─────────────────────────────
  double? _iconsDpr;
  BitmapDescriptor? _userDotIcon;
  BitmapDescriptor? _userBeamIcon;
  BitmapDescriptor? _driverIcon;
  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _dropIcon;

  // ── User location ───────────────────────────────────────────────────────────
  Position? _curPos;
  MarkerMotion? _userMotion;
  Marker? _userMarker;
  Circle? _accuracyCircle;
  double _userAccuracy = 0;
  bool _headingKnown = false;
  double? _lastAppliedCompass;
  int _lastCompassUs = 0;

  StreamSubscription<Position>? _gpsSub;
  StreamSubscription<ServiceStatus>? _svcStatusSub;
  StreamSubscription<CompassEvent>? _compassSub;
  Timer? _gpsWatchdog;
  DateTime? _lastFixAt;
  int _gpsRestartAttempt = 0;
  Future<void>? _locFlight;
  bool _locationBootstrapped = false;

  // ── Visibility / lifecycle ─────────────────────────────────────────────────
  bool _tabVisible = true;
  bool _appResumed = true;
  bool get _active => _tabVisible && _appResumed;

  // ── Camera ─────────────────────────────────────────────────────────────────
  bool _followUser = true;
  bool _didCenterOnUser = false;
  LatLng? _lastCamTarget;
  DateTime _lastFollowMove = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _fitBoundsDebounce;

  // ── Drivers ────────────────────────────────────────────────────────────────
  DriverPollingEngine? _pollingEngine;
  final Map<String, DriverCar> _drivers = <String, DriverCar>{};
  final Map<String, MarkerMotion> _driverMotions = <String, MarkerMotion>{};
  final Map<String, Marker> _driverMarkerCache = <String, Marker>{};

  // ── Route planning ─────────────────────────────────────────────────────────
  final List<RoutePoint> _pts = <RoutePoint>[];
  int _activeIdx = 0;
  String? _distanceText;
  String? _durationText;
  DateTime? _arrivalTime;
  List<LatLng> _routePts = <LatLng>[];
  _RouteCache? _cachedRoute;
  int _routeSeq = 0;
  Timer? _routeRefreshTimer;

  // ── Places autocomplete ────────────────────────────────────────────────────
  final Uuid _uuid = const Uuid();
  String _placesSession = '';
  Timer? _debounce;
  late final AutocompleteService _auto;
  List<Suggestion> _sugs = <Suggestion>[];
  List<Suggestion> _recents = <Suggestion>[];
  bool _isTyping = false;
  int _lastQueryId = 0;
  String? _autoStatus;
  String? _autoError;
  bool _expanded = false;

  // ── Ride market / booking ──────────────────────────────────────────────────
  late final RideMarketService _rideMarketService;
  StreamSubscription<RideMarketSnapshot>? _marketSub;
  bool _marketOpen = false;
  bool _offersLoading = false;
  List<RideOffer> _offers = const <RideOffer>[];
  BookingController? _booking;
  StreamSubscription<dynamic>? _bookingSub;
  bool _bookingInProgress = false;

  final Map<String, Future<http.Response>> _inflightRequests = <String, Future<http.Response>>{};

  Orientation? _lastOrientation;

  // ═══════════════════════════════════════════════════════════════════════════
  // Lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = ApiClient(http.Client(), context);
    _auto = AutocompleteService(logger: _log);
    _rideMarketService = RideMarketService(api: _api, debug: false);
    _frameTicker = createTicker(_onFrame);

    _mapLayer = _HomeMapLayer(
      markersNotifier: _markersNotifier,
      polylinesNotifier: _polylinesNotifier,
      circlesNotifier: _circlesNotifier,
      paddingNotifier: _mapPadding,
      initialCameraPosition: _initialCam,
      onMapCreated: _onMapCreated,
      onCameraMove: (pos) => _lastCamTarget = pos.target,
      onTap: (_) {
        if (_expanded) _collapse();
      },
      onUserGesture: _onUserMapGesture,
    );

    _initPoints();
    _bootstrap();

    if (!kIsWeb) {
      try {
        _svcStatusSub = Geolocator.getServiceStatusStream().listen(
          (status) {
            if (!mounted) return;
            if (status == ServiceStatus.enabled) {
              if (_active) _ensureLocation(userTriggered: false);
            } else {
              _stopLocationPipeline();
            }
          },
          onError: (_) {},
        );
      } catch (_) {}
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureIcons(MediaQuery.devicePixelRatioOf(context));

    // IndexedStack hides inactive tabs with TickerMode(enabled: false).
    final visible = TickerMode.of(context);
    if (visible != _tabVisible) {
      _tabVisible = visible;
      _onActiveChanged();
    } else if (!_locationBootstrapped && _active) {
      _locationBootstrapped = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active) _ensureLocation(userTriggered: false);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frameTicker.dispose();
    _pollingEngine?.dispose();
    _debounce?.cancel();
    _gpsWatchdog?.cancel();
    _gpsSub?.cancel();
    _svcStatusSub?.cancel();
    _compassSub?.cancel();
    _routeRefreshTimer?.cancel();
    _fitBoundsDebounce?.cancel();
    _marketSub?.cancel();
    _rideMarketService.dispose();
    _bookingSub?.cancel();
    try {
      _booking?.dispose();
    } catch (_) {}
    _auto.dispose();

    _markersNotifier.dispose();
    _polylinesNotifier.dispose();
    _circlesNotifier.dispose();
    _mapPadding.dispose();

    for (final p in _pts) {
      p.controller.dispose();
      p.focus.dispose();
    }
    _map?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    // `inactive` happens for system dialogs (incl. the permission dialog):
    // treat only paused/hidden/detached as "away".
    if (state == AppLifecycleState.inactive) return;
    if (resumed == _appResumed) return;
    _appResumed = resumed;
    _onActiveChanged();
  }

  /// Single place reacting to tab visibility + app foreground changes.
  void _onActiveChanged() {
    if (!mounted) return;
    if (_active) {
      _lastFixAt = DateTime.now(); // don't let the watchdog fire immediately
      _resumeDriverPolling();
      if (_marketOpen) _startRideMarket();
      _recheckLocationSilently();
      _scheduleFrame();
    } else {
      // Cancel (not pause): paused broadcast subscriptions buffer every event
      // and keep the platform sensors running in the background.
      _stopLocationPipeline();
      _pollingEngine?.stop();
      if (_marketOpen) {
        _marketSub?.cancel();
        _marketSub = null;
      }
    }
  }

  /// Resume path: no UI when already granted; otherwise one auto attempt (the
  /// gate never re-shows a prompt it already showed this session).
  Future<void> _recheckLocationSilently() async {
    final st = await LocationPermissionModal.status();
    if (!mounted || !_active) return;
    if (st.isGranted) {
      if (_gpsSub == null) await _startLocationPipeline();
    } else if (!_locationBootstrapped) {
      _locationBootstrapped = true;
      await _ensureLocation(userTriggered: false);
    } else if (st != LocationGateStatus.serviceDisabled && !LocationPermissionModal.isShowing) {
      // Came back from Settings: the gate suppresses repeated auto prompts.
      await _ensureLocation(userTriggered: false);
    }
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _prefs = prefs;

    _pollingEngine = DriverPollingEngine(
      api: _api,
      userId: prefs.getString('user_id') ?? 'guest',
      onDriversUpdated: (activeDrivers, computedHeadings) {
        if (!mounted || _marketOpen) return;
        _applyDrivers(activeDrivers, headings: computedHeadings);
      },
    );

    await _primeNearbyDriversAsap();
    await Future.wait<void>([_fetchUser(), _loadRecents()]);
    _scheduleMapPaddingUpdate();
  }

  /// Starts nearby-driver polling from the last known position without any
  /// permission UI (only if permission is already granted).
  Future<void> _primeNearbyDriversAsap() async {
    if (!mounted || _marketOpen) return;
    try {
      if (!(await LocationPermissionModal.hasLocationAccess())) return;
      final last = await Geolocator.getLastKnownPosition();
      if (last == null || !mounted) return;
      if (_curPos == null) _onFix(last, isSeed: true);
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Icons
  // ═══════════════════════════════════════════════════════════════════════════

  void _ensureIcons(double dpr) {
    if (_iconsDpr == dpr) return;
    _iconsDpr = dpr;
    () async {
      try {
        final r = await Future.wait<BitmapDescriptor>([
          MapGraphicsEngine.createUserLocationDot(devicePixelRatio: dpr),
          MapGraphicsEngine.createUserLocationDot(devicePixelRatio: dpr, withHeading: true),
          MapGraphicsEngine.createCarMarker(devicePixelRatio: dpr),
          MapGraphicsEngine.createRingDotMarker(const Color(0xFF1A73E8)),
          MapGraphicsEngine.createRingDotMarker(const Color(0xFF00A651)),
        ]);
        if (!mounted) return;
        _userDotIcon = r[0];
        _userBeamIcon = r[1];
        _driverIcon = r[2];
        _pickupIcon = r[3];
        _dropIcon = r[4];
        _driverMarkerCache.clear();
        _userMarker = null;
        _rebuildPointMarkers();
        _scheduleFrame(dirty: true);
      } catch (e) {
        _log('icon generation failed', e);
      }
    }();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Frame loop: samples marker motions, publishes map sets
  // ═══════════════════════════════════════════════════════════════════════════

  void _scheduleFrame({bool dirty = false}) {
    if (dirty) _mapDirty = true;
    if (!mounted) return;
    if (!_frameTicker.isActive) _frameTicker.start();
  }

  void _onFrame(Duration _) {
    if (!mounted) return;
    final now = MarkerMotion.nowUs;
    bool animating = false;
    bool changed = _mapDirty;
    _mapDirty = false;

    // User dot + accuracy circle.
    final um = _userMotion;
    final dot = _userDotIcon;
    if (um != null && dot != null) {
      final s = um.sample(now);
      animating |= um.isAnimating(now);
      final useBeam = _headingKnown && _userBeamIcon != null;
      final rotation = useBeam ? s.bearing : 0.0;
      final prev = _userMarker;
      if (prev == null ||
          RoutingEngine.haversine(prev.position, s.position) > 0.05 ||
          RoutingEngine.shortestAngleDelta(prev.rotation, rotation).abs() > 0.4 ||
          (prev.icon != (useBeam ? _userBeamIcon : dot))) {
        _userMarker = Marker(
          markerId: _userMarkerId,
          position: s.position,
          icon: useBeam ? _userBeamIcon! : dot,
          anchor: const Offset(0.5, 0.5),
          flat: true,
          rotation: rotation,
          zIndexInt: 999,
          consumeTapEvents: false,
        );
        changed = true;
      }

      final radius = _userAccuracy.clamp(0.0, 1500.0).toDouble();
      final prevC = _accuracyCircle;
      if (radius < 3) {
        if (prevC != null) {
          _accuracyCircle = null;
          changed = true;
        }
      } else if (prevC == null ||
          RoutingEngine.haversine(prevC.center, s.position) > 0.25 ||
          (prevC.radius - radius).abs() > math.max(0.5, radius * 0.03)) {
        _accuracyCircle = Circle(
          circleId: _accuracyCircleId,
          center: s.position,
          radius: radius,
          fillColor: const Color(0xFF1A73E8).withValues(alpha: 0.12),
          strokeColor: const Color(0xFF1A73E8).withValues(alpha: 0.28),
          strokeWidth: 1,
          zIndex: 1,
        );
        changed = true;
      }
    }

    // Driver cars.
    final carIcon = _driverIcon;
    if (carIcon != null) {
      for (final e in _driverMotions.entries) {
        final m = e.value;
        final cached = _driverMarkerCache[e.key];
        final moving = m.isAnimating(now);
        if (cached != null && !moving) continue;
        animating |= moving;
        final s = m.sample(now);
        _driverMarkerCache[e.key] = Marker(
          markerId: MarkerId('driver_${e.key}'),
          position: s.position,
          icon: carIcon,
          flat: true,
          rotation: s.bearing,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 5,
          consumeTapEvents: false,
        );
        changed = true;
      }
    }

    if (changed) _publishMapSets();
    if (!animating) _frameTicker.stop();
  }

  void _publishMapSets() {
    _markersNotifier.value = <Marker>{
      ..._staticMarkers.values,
      ..._driverMarkerCache.values,
      if (_userMarker != null) _userMarker!,
    };
    _circlesNotifier.value = <Circle>{
      ..._staticCircles.values,
      if (_accuracyCircle != null) _accuracyCircle!,
    };
  }

  void _publishPolylines() => _polylinesNotifier.value = Set<Polyline>.of(_routeLines.values);

  // ═══════════════════════════════════════════════════════════════════════════
  // Location pipeline
  // ═══════════════════════════════════════════════════════════════════════════

  /// Single-flight: permission gate + GPS stream start.
  Future<void> _ensureLocation({required bool userTriggered}) {
    final existing = _locFlight;
    if (existing != null) return existing;
    final f = _ensureLocationImpl(userTriggered);
    _locFlight = f;
    return f.whenComplete(() {
      if (identical(_locFlight, f)) _locFlight = null;
    });
  }

  Future<void> _ensureLocationImpl(bool userTriggered) async {
    if (!mounted) return;
    final st = await LocationPermissionModal.ensure(
      context,
      userTriggered: userTriggered,
      message: 'Pick Me uses your location to match you with nearby drivers, set accurate pickups and calculate fares while you use the app.',
    );
    if (!mounted || !st.isGranted) return;
    await _startLocationPipeline();
  }

  LocationSettings _locationSettings() {
    if (kIsWeb) return const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 2);
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 2,
          intervalDuration: const Duration(seconds: 1),
          forceLocationManager: false,
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 2,
          activityType: ActivityType.otherNavigation,
          pauseLocationUpdatesAutomatically: true,
          showBackgroundLocationIndicator: false,
        );
      default:
        return const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 2);
    }
  }

  Future<void> _startLocationPipeline() async {
    if (!mounted) return;
    if (_gpsSub != null || !_active) return;

    try {
      final last = await Geolocator.getLastKnownPosition();
      if (!mounted) return;
      if (last != null && _curPos == null) _onFix(last, isSeed: true);
    } catch (_) {}
    if (_gpsSub != null || !mounted) return; // raced with another start

    _lastFixAt = DateTime.now();
    _gpsSub = Geolocator.getPositionStream(locationSettings: _locationSettings()).listen(
      (p) => _onFix(p),
      onError: _onGpsError,
      cancelOnError: false,
    );
    _startCompass();

    _gpsWatchdog?.cancel();
    _gpsWatchdog = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!_active || _lastFixAt == null) return;
      if (DateTime.now().difference(_lastFixAt!) > const Duration(seconds: 45)) {
        _restartGpsWithBackoff();
      }
    });
  }

  void _stopLocationPipeline() {
    _gpsWatchdog?.cancel();
    _gpsWatchdog = null;
    _gpsSub?.cancel();
    _gpsSub = null;
    _compassSub?.cancel();
    _compassSub = null;
  }

  void _onGpsError(Object err) {
    if (err is LocationServiceDisabledException) {
      _stopLocationPipeline(); // the service-status stream restarts us
      return;
    }
    _restartGpsWithBackoff();
  }

  Future<void> _restartGpsWithBackoff() async {
    _stopLocationPipeline();
    _gpsRestartAttempt = (_gpsRestartAttempt + 1).clamp(1, 5);
    await Future<void>.delayed(Duration(seconds: 2 * _gpsRestartAttempt));
    if (!mounted || !_active) return;
    if ((await LocationPermissionModal.status()).isGranted) await _startLocationPipeline();
  }

  void _startCompass() {
    if (_compassSub != null) return;
    final events = FlutterCompass.events;
    if (events == null) return;
    _compassSub = events.listen((event) {
      final h = event.heading;
      if (h == null || !h.isFinite || !_active) return;
      final now = MarkerMotion.nowUs;
      if (now - _lastCompassUs < 66000) return; // ~15 Hz is plenty for a beam
      _lastCompassUs = now;
      // While driving, the GPS course is better than the magnetometer.
      if ((_curPos?.speed ?? 0) >= 2.0) return;
      final deg = RoutingEngine.normalizeDeg(h);
      final last = _lastAppliedCompass;
      if (last != null && RoutingEngine.shortestAngleDelta(last, deg).abs() < 2.0) return;
      _lastAppliedCompass = deg;
      _headingKnown = true;
      _userMotion?.setBearing(deg);
      _scheduleFrame();
    }, onError: (_) {});
  }

  bool _isGoodFix(Position p) {
    if (!p.latitude.isFinite || !p.longitude.isFinite) return false;
    if (p.latitude == 0 && p.longitude == 0) return false;
    if (p.accuracy.isFinite && p.accuracy > 5000) return false;
    return true;
  }

  void _onFix(Position p, {bool isSeed = false}) {
    if (!mounted || !_isGoodFix(p)) return;
    final hadFix = _curPos != null;
    _curPos = p;
    if (!isSeed) {
      _lastFixAt = DateTime.now();
      _gpsRestartAttempt = 0;
    }
    final ll = LatLng(p.latitude, p.longitude);
    final speed = (p.speed.isFinite && p.speed >= 0) ? p.speed : null;
    final course = (speed != null && speed >= 2.0 && p.heading.isFinite && p.heading >= 0) ? p.heading : null;
    if (course != null) _headingKnown = true;

    final motion = _userMotion;
    if (motion == null) {
      _userMotion = MarkerMotion(
        initial: ll,
        bearing: course ?? _lastAppliedCompass ?? 0,
        jitterMeters: 2.5,
        maxExtrapolation: const Duration(milliseconds: 1200),
        maxExtrapolationMeters: 15,
      );
    } else {
      // Slow / standing: keep the compass heading instead of jittery GPS course.
      final keep = course == null ? _lastAppliedCompass : null;
      motion.push(ll, bearing: course ?? keep, accuracyMeters: p.accuracy, speedMps: speed);
    }
    _userAccuracy = p.accuracy.isFinite ? p.accuracy : 0;
    _scheduleFrame();

    if (!hadFix) setState(() {}); // "Use current location" affordances

    // Pickup follows GPS only when it is "current location" and no booking.
    if (_pts.isNotEmpty && _pts.first.isCurrent && !_marketOpen) {
      final old = _pts.first.latLng;
      if (old == null || RoutingEngine.haversine(old, ll) > 12) {
        _pts.first.latLng = ll;
        _putPointMarker(0);
        _syncSearchCircle();
      }
    } else if (_pts.isNotEmpty && _pts.first.controller.text.trim().isEmpty && !isSeed && !_expanded) {
      _useCurrentAsPickup();
    }

    if (!_marketOpen) {
      if (_pollingEngine?.isRunning ?? false) {
        _pollingEngine!.updateLocation(ll);
      } else {
        _resumeDriverPolling();
      }
    }

    _followCameraTo(ll);
  }

  void _followCameraTo(LatLng ll) {
    final map = _map;
    if (map == null || !_active || _expanded || _hasPickupAndDropoff) return;
    if (!_didCenterOnUser) {
      _didCenterOnUser = true;
      _lastCamTarget = ll;
      map.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: ll, zoom: 16.5))).catchError((_) {});
      return;
    }
    if (!_followUser) return;
    final now = DateTime.now();
    if (now.difference(_lastFollowMove) < const Duration(milliseconds: 900)) return;
    final cam = _lastCamTarget;
    if (cam != null && RoutingEngine.haversine(cam, ll) < 20) return;
    _lastFollowMove = now;
    _lastCamTarget = ll;
    map.animateCamera(CameraUpdate.newLatLng(ll)).catchError((_) {});
  }

  void _onUserMapGesture() {
    // Any pan/zoom by the user pauses camera follow until "locate" is tapped.
    if (!_followUser) return;
    setState(() => _followUser = false); // updates the locate button state
  }

  Future<void> _onLocateTap() async {
    HapticFeedback.selectionClick();
    await _ensureLocation(userTriggered: true);
    if (!mounted) return;
    final target = _userMotion?.target ?? (_curPos == null ? null : LatLng(_curPos!.latitude, _curPos!.longitude));
    if (target == null) {
      if ((await LocationPermissionModal.status()).isGranted) {
        _toast('Finding you…', 'Waiting for a GPS fix. Move to open sky for better accuracy.');
      }
      return;
    }
    setState(() => _followUser = true);
    _didCenterOnUser = true;
    _lastCamTarget = target;
    try {
      await _map?.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: target, zoom: 17)));
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Drivers
  // ═══════════════════════════════════════════════════════════════════════════

  void _resumeDriverPolling() {
    if (!_active || _marketOpen || _bookingInProgress) return;
    final p = _curPos;
    if (p == null) return;
    _pollingEngine?.start(LatLng(p.latitude, p.longitude), radiusKm: kHomeRadiusKm, rideType: 'street_ride');
  }

  void _applyDrivers(List<DriverCar> list, {Map<String, double>? headings}) {
    final seen = <String>{};
    for (final d in list) {
      seen.add(d.id);
      final motion = _driverMotions[d.id];
      final serverHeading = (d.heading.isFinite && d.heading > 0) ? d.heading : null;
      if (motion == null) {
        _driverMotions[d.id] = MarkerMotion(
          initial: d.ll,
          bearing: headings?[d.id] ?? serverHeading ?? 0,
          jitterMeters: 4,
          maxExtrapolation: const Duration(milliseconds: 1800),
          maxExtrapolationMeters: 30,
        );
      } else {
        final moved = RoutingEngine.haversine(motion.target, d.ll) > 4;
        motion.push(d.ll, bearing: moved ? null : serverHeading, expectedInterval: const Duration(seconds: 3));
      }
      _driverMarkerCache.remove(d.id);
    }
    _driverMotions.removeWhere((id, _) => !seen.contains(id));
    _driverMarkerCache.removeWhere((id, _) => !seen.contains(id));

    _drivers
      ..clear()
      ..addEntries(list.map((d) => MapEntry(d.id, d)));
    _scheduleFrame(dirty: true);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Profile / recents
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _fetchUser() async {
    final prefs = _prefs;
    if (!mounted || prefs == null) return;
    final uid = prefs.getString('user_id') ?? '';
    if (uid.isEmpty) return;
    setState(() => _busyProfile = true);
    try {
      final res = await _executeWithRetry(
        'fetch_user',
        () => _api.request(ApiConstants.userInfoEndpoint, method: 'POST', data: <String, String>{'user': uid}).timeout(kApiTimeout),
      );
      if (!mounted) return;
      Map<String, dynamic>? user;
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map && body['error'] == false && body['user'] is Map) {
          user = Map<String, dynamic>.from(body['user'] as Map);
        }
      }
      setState(() {
        if (user != null) _user = user;
        _isConnected = true;
      });
    } catch (_) {
      if (mounted) setState(() => _isConnected = false);
    } finally {
      if (mounted) setState(() => _busyProfile = false);
    }
  }

  /// Coalesces identical in-flight requests and retries with exponential backoff.
  Future<http.Response> _executeWithRetry(String id, Future<http.Response> Function() executor) {
    final existing = _inflightRequests[id];
    if (existing != null) return existing;
    Future<http.Response> run() async {
      for (int attempt = 0;; attempt++) {
        try {
          return await executor();
        } catch (e) {
          if (attempt >= kMaxRetries || !mounted) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 400 * (1 << attempt)));
        }
      }
    }

    final f = run();
    _inflightRequests[id] = f;
    f.whenComplete(() => _inflightRequests.remove(id)).ignore();
    return f;
  }

  Future<void> _loadRecents() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final raw = prefs.getString(_kRecentsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((m) => Suggestion.fromJson(Map<String, dynamic>.from(m)))
          .where((s) => s.placeId.isNotEmpty)
          .take(_maxRecents)
          .toList();
      if (!mounted) return;
      setState(() {
        _recents = list;
        if (!_isTyping) _sugs = list;
      });
    } catch (_) {
      await prefs.remove(_kRecentsKey);
    }
  }

  void _saveRecent(Suggestion s) {
    final up = List<Suggestion>.from(_recents)
      ..removeWhere((e) => e.placeId == s.placeId)
      ..insert(0, s);
    final cap = up.take(_maxRecents).toList();
    _prefs?.setString(_kRecentsKey, jsonEncode(cap.map((e) => e.toJson()).toList()));
    if (mounted) setState(() => _recents = cap);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Route points / markers
  // ═══════════════════════════════════════════════════════════════════════════

  void _initPoints() {
    _pts.addAll([
      RoutePoint(type: PointType.pickup, controller: TextEditingController(), focus: FocusNode(), hint: 'Pickup location'),
      RoutePoint(type: PointType.destination, controller: TextEditingController(), focus: FocusNode(), hint: 'Where to?'),
    ]);
    // Focus handling is done by RouteField (onFocused) – no duplicate listeners.
  }

  bool get _hasPickupAndDropoff => _pts.length >= 2 && _pts.first.latLng != null && _pts.last.latLng != null;
  LatLng? _destLL() => _pts.isNotEmpty ? _pts.last.latLng : null;
  LatLng? _pickupLL() {
    if (_pts.isEmpty) return null;
    if (_pts.first.isCurrent && _curPos != null) return LatLng(_curPos!.latitude, _curPos!.longitude);
    return _pts.first.latLng;
  }

  List<LatLng> _stopLatLngs() => [for (int i = 1; i < _pts.length - 1; i++) if (_pts[i].latLng != null) _pts[i].latLng!];

  String _pointLabel(PointType t) => t.label;

  BitmapDescriptor _iconFor(PointType t) {
    switch (t) {
      case PointType.pickup:
        return _pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
      case PointType.destination:
        return _dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
      case PointType.stop:
        return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    }
  }

  void _putPointMarker(int idx) {
    if (idx < 0 || idx >= _pts.length) return;
    final p = _pts[idx];
    final id = MarkerId('p_$idx');
    final ll = p.latLng;
    // A "current location" pickup is already represented by the blue dot
    // until a route is planned.
    if (ll == null || (p.type == PointType.pickup && p.isCurrent && !_hasPickupAndDropoff)) {
      _staticMarkers.remove(id);
    } else {
      _staticMarkers[id] = Marker(
        markerId: id,
        position: ll,
        icon: _iconFor(p.type),
        anchor: const Offset(0.5, 0.5),
        infoWindow: InfoWindow(title: _pointLabel(p.type), snippet: p.controller.text),
        zIndexInt: 20,
      );
    }
    _scheduleFrame(dirty: true);
  }

  void _rebuildPointMarkers() {
    _staticMarkers.removeWhere((k, _) => k.value.startsWith('p_'));
    for (int i = 0; i < _pts.length; i++) {
      _putPointMarker(i);
    }
    _scheduleFrame(dirty: true);
  }

  Future<void> _useCurrentAsPickup() async {
    final pos = _curPos;
    if (pos == null || _pts.isEmpty) {
      await _ensureLocation(userTriggered: true);
      return;
    }
    final ll = LatLng(pos.latitude, pos.longitude);
    final pickup = _pts.first;
    setState(() {
      pickup
        ..latLng = ll
        ..placeId = null
        ..isCurrent = true;
      if (pickup.controller.text.trim().isEmpty) pickup.controller.text = 'Current location';
    });
    _putPointMarker(0);
    _syncSearchCircle();
    if (_hasPickupAndDropoff) _buildRoute();

    String addr = 'Current location';
    try {
      final marks = await geo.placemarkFromCoordinates(ll.latitude, ll.longitude);
      addr = _fmtPlacemark(marks.isNotEmpty ? marks.first : null);
    } catch (_) {}
    if (!mounted || !pickup.isCurrent) return; // user changed pickup meanwhile
    setState(() => pickup.controller.text = addr);
    _putPointMarker(0);
  }

  String _fmtPlacemark(geo.Placemark? p) {
    if (p == null) return 'Current location';
    final parts = <String>[];
    if ((p.name ?? '').isNotEmpty) parts.add(p.name!);
    if ((p.street ?? '').isNotEmpty && p.street != p.name) parts.add(p.street!);
    if ((p.locality ?? '').isNotEmpty) parts.add(p.locality!);
    return parts.isEmpty ? 'Current location' : parts.join(', ');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Map padding / camera fitting
  // ═══════════════════════════════════════════════════════════════════════════

  void _onMapCreated(GoogleMapController c) {
    _map = c;
    _lastCamTarget = _initialCam.target;
    _scheduleMapPaddingUpdate();
    final pos = _curPos;
    if (_routePts.isNotEmpty) {
      _fitCurrentRoute();
    } else if (pos != null) {
      _didCenterOnUser = false;
      _followCameraTo(LatLng(pos.latitude, pos.longitude));
    }
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

  double _effectiveBottomNavH() => _marketOpen ? 0 : kBottomNavH;

  void _applyMapPadding() {
    if (!mounted) return;
    final mq = MediaQuery.of(context);
    final uiScale = UIScale.of(context);
    final topPad = mq.padding.top + (kHeaderVisualH * _scaleFromUi(uiScale));
    final baseBottomPad = _sheetHeight + _effectiveBottomNavH();
    final bottomPad = mq.orientation == Orientation.landscape
        ? (baseBottomPad * (uiScale.tablet ? 0.78 : 0.68)).clamp(10.0, 260.0)
        : (baseBottomPad + uiScale.gap(uiScale.compact ? 8 : 12)).clamp(20.0, 520.0);
    final minScreenDim = math.min(mq.size.width, mq.size.height);
    final hPad = minScreenDim < 360 ? 4.0 : minScreenDim < 480 ? 6.0 : 8.0;
    _mapPadding.value = EdgeInsets.fromLTRB(hPad, topPad, hPad, bottomPad);
  }

  void _scheduleMapPaddingUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _sheetKey.currentContext?.findRenderObject() as RenderBox?;
      final newHeight = (box != null && box.hasSize) ? box.size.height : 0.0;
      final changed = (_sheetHeight - newHeight).abs() > 0.5;
      if (changed) setState(() => _sheetHeight = newHeight); // FAB position depends on it
      _applyMapPadding();
      if (changed && _routePts.isNotEmpty && !_expanded) {
        _fitBoundsDebounce?.cancel();
        _fitBoundsDebounce = Timer(const Duration(milliseconds: 140), () {
          if (mounted) _fitCurrentRoute();
        });
      }
    });
  }

  Future<void> _fitCurrentRoute() async {
    if (!mounted || _map == null) return;
    final pts = _routePts.isNotEmpty
        ? _routePts
        : <LatLng>[if (_pts.first.latLng != null) _pts.first.latLng!, if (_pts.last.latLng != null) _pts.last.latLng!];
    if (pts.length < 2) return;
    _followUser = false;
    final mq = MediaQuery.of(context);
    final pad = _mapPadding.value;
    final extra = math.max(math.max(pad.top, pad.bottom), math.max(pad.left, pad.right));
    final minSide = math.min(mq.size.width, mq.size.height);
    final padding = (70.0 + extra * 0.25).clamp(48.0, minSide * 0.3);
    final bounds = RoutingEngine.computeSmartBounds(pts);
    for (int attempt = 0; attempt < 3; attempt++) {
      if (!mounted || _map == null) return;
      try {
        // Map padding already reserves header/sheet space.
        await _map!.animateCamera(CameraUpdate.newLatLngBounds(bounds, padding));
        return;
      } catch (_) {
        // Map not laid out yet.
        await Future<void>.delayed(Duration(milliseconds: 120 * (attempt + 1)));
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Search circle
  // ═══════════════════════════════════════════════════════════════════════════

  double _visualSearchRadiusMeters() => (kHomeRadiusKm * 1000.0).clamp(_searchCircleMinM, _searchCircleMaxM).toDouble();
  LatLng? _searchCircleCenter() => _pts.isNotEmpty && _pts.first.latLng != null
      ? _pts.first.latLng!
      : (_curPos != null ? LatLng(_curPos!.latitude, _curPos!.longitude) : null);
  bool _shouldShowSearchCircle() => _offersLoading || (_marketOpen && _offers.isEmpty);

  void _syncSearchCircle() {
    final center = _searchCircleCenter();
    if (!_shouldShowSearchCircle() || center == null || !mounted) {
      if (_staticCircles.remove(_searchCircleId) != null) _scheduleFrame(dirty: true);
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = isDark ? Theme.of(context).colorScheme.primary : const Color(0xFF00A651);
    _staticCircles[_searchCircleId] = Circle(
      circleId: _searchCircleId,
      center: center,
      radius: _visualSearchRadiusMeters(),
      fillColor: c.withValues(alpha: 0.12),
      strokeColor: c.withValues(alpha: 0.30),
      strokeWidth: 2,
    );
    _scheduleFrame(dirty: true);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Routing
  // ═══════════════════════════════════════════════════════════════════════════

  String _computeRouteHash() => _pts
      .where((p) => p.latLng != null)
      .map((p) => '${p.latLng!.latitude.toStringAsFixed(5)},${p.latLng!.longitude.toStringAsFixed(5)}')
      .join('|');

  /// Builds (or reuses) the planned route. Concurrent calls are race-free: only
  /// the newest request is applied.
  Future<void> _buildRoute({bool fit = true}) async {
    if (!_hasPickupAndDropoff) return;
    final hash = _computeRouteHash();
    final seq = ++_routeSeq;

    final cached = _cachedRoute;
    if (cached != null && cached.hash == hash && !cached.isStale) {
      await _applyRoute(cached.route, fit: fit);
      return;
    }

    final origin = _pts.first.latLng!;
    final destination = _pts.last.latLng!;
    final result = await RoutingEngine.computeRoute(origin: origin, destination: destination, stops: _stopLatLngs());
    if (!mounted || seq != _routeSeq) return; // superseded

    if (result == null || result.points.isEmpty) {
      setState(() => _isConnected = false);
      _toast('Route Error', 'Unable to calculate route.');
      return;
    }
    _cachedRoute = _RouteCache(result, hash, DateTime.now());
    await _applyRoute(result, fit: fit);

    _routeRefreshTimer?.cancel();
    _routeRefreshTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      if (!mounted || !_active || !_hasPickupAndDropoff || _expanded || _bookingInProgress) return;
      _cachedRoute = null;
      _buildRoute(fit: false);
    });
  }

  Future<void> _applyRoute(RouteResult route, {required bool fit}) async {
    if (!mounted || route.points.isEmpty) return;
    setState(() {
      _arrivalTime = DateTime.now().add(Duration(seconds: route.durationSeconds));
      _distanceText = _fmtDistance(route.distanceMeters);
      _durationText = _fmtDuration(route.durationSeconds);
      _isConnected = true;
    });

    _routePts = route.points;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    _routeLines
      ..clear()
      ..[const PolylineId('route_halo')] = Polyline(
        polylineId: const PolylineId('route_halo'),
        points: route.points,
        color: Colors.white.withValues(alpha: isDark ? 0.85 : 0.92),
        width: 9,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        zIndex: 1,
      )
      ..[const PolylineId('route_main')] = Polyline(
        polylineId: const PolylineId('route_main'),
        points: route.points,
        color: AppColors.primary,
        width: 5,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        zIndex: 2,
      );
    _publishPolylines();
    _rebuildPointMarkers();

    await _updateRouteBubbles(origin: _pts.first.latLng!, destination: _pts.last.latLng!, secs: route.durationSeconds);
    if (fit && mounted) await _fitCurrentRoute();
  }

  Future<void> _updateRouteBubbles({required LatLng origin, required LatLng destination, required int secs}) async {
    final minutes = math.max(1, (secs / 60).round());
    final arrive = 'Arrive by ${DateFormat('h:mm a').format(DateTime.now().add(Duration(seconds: secs)))}';
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;
    try {
      final icons = await Future.wait<BitmapDescriptor>([
        MapGraphicsEngine.createMinutesCircleBadge(minutes: minutes, isDark: isDark, cs: cs),
        MapGraphicsEngine.createArrivePillBadge(text: arrive, isDark: isDark, cs: cs),
      ]);
      if (!mounted || _routePts.isEmpty) return;
      _staticMarkers[_minsMarkerId] = Marker(markerId: _minsMarkerId, position: destination, icon: icons[0], anchor: const Offset(0.5, 1.0), zIndexInt: 998);
      _staticMarkers[_etaMarkerId] = Marker(markerId: _etaMarkerId, position: origin, icon: icons[1], anchor: const Offset(0.5, 1.0), zIndexInt: 998);
      _scheduleFrame(dirty: true);
    } catch (_) {}
  }

  void _clearRoute() {
    _routeSeq++; // invalidate in-flight builds
    _routeRefreshTimer?.cancel();
    _routePts = <LatLng>[];
    _cachedRoute = null;
    _routeLines.clear();
    _publishPolylines();
    _staticMarkers.remove(_etaMarkerId);
    _staticMarkers.remove(_minsMarkerId);
    _distanceText = null;
    _durationText = null;
    _arrivalTime = null;
    _scheduleFrame(dirty: true);
  }

  String _fmtDistance(int m) => (m < 1000) ? '$m m' : '${(m / 1000.0).toStringAsFixed(1)} km';
  String _fmtDuration(int s) {
    final mins = (s / 60).round();
    return mins < 60 ? '$mins min' : '${mins ~/ 60}h ${mins % 60}m';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Overlay / autocomplete
  // ═══════════════════════════════════════════════════════════════════════════

  void _onFocused(int index) {
    if (index < 0 || index >= _pts.length) return;
    if (_activeIdx == index && _expanded) return;
    setState(() {
      _activeIdx = index;
      if (!_isTyping) _sugs = _recents;
      _autoStatus = null;
      _autoError = null;
    });
    _expand();
  }

  void _expand() {
    if (_expanded) return;
    _ensurePlacesSession();
    setState(() => _expanded = true);
    _scheduleMapPaddingUpdate();
  }

  void _collapse() {
    FocusManager.instance.primaryFocus?.unfocus();
    _debounce?.cancel();
    _auto.cancelPending();
    _lastQueryId++; // drop late responses
    _placesSession = ''; // a session without a Details call ends here
    if (!_expanded && !_isTyping) return;
    setState(() {
      _expanded = false;
      _isTyping = false;
    });
    _scheduleMapPaddingUpdate();
  }

  void _ensurePlacesSession() {
    if (_placesSession.isEmpty) _placesSession = _uuid.v4();
  }

  void _onTyping(String q) {
    _debounce?.cancel();
    final query = q.trim();
    if (query.isEmpty) {
      _lastQueryId++; // invalidate in-flight results
      _auto.cancelPending();
      setState(() {
        _sugs = _recents;
        _isTyping = false;
        _autoStatus = null;
        _autoError = null;
      });
      return;
    }
    // Typing invalidates a previously chosen place for this field.
    if (_activeIdx < _pts.length && _pts[_activeIdx].placeId != null) {
      _pts[_activeIdx]
        ..placeId = null
        ..isCurrent = false;
    }
    if (!_expanded) _expand();
    if (!_isTyping) setState(() => _isTyping = true);
    _debounce = Timer(const Duration(milliseconds: 250), () => _fetchSugs(query));
  }

  Future<void> _fetchSugs(String input) async {
    _ensurePlacesSession();
    final int myQueryId = ++_lastQueryId;
    final session = _placesSession;
    final pos = _curPos;
    final origin = pos == null ? null : LatLng(pos.latitude, pos.longitude);
    bool stale() => !mounted || myQueryId != _lastQueryId;

    try {
      var result = await _auto.autocomplete(input: input, sessionToken: session, apiKey: ApiConstants.kGoogleApiKey, country: 'ng', origin: origin);
      if (stale() || result.status == AutocompleteService.kCancelledStatus) return;
      var sugs = result.predictions;
      var status = result.status;
      var error = result.errorMessage;

      if (sugs.isEmpty && (status == 'OK' || status == null)) {
        result = await _auto.autocomplete(input: input, sessionToken: session, apiKey: ApiConstants.kGoogleApiKey, country: 'ng', origin: origin, relaxedTypes: true);
        if (stale() || result.status == AutocompleteService.kCancelledStatus) return;
        sugs = result.predictions;
        status = result.status;
        error = result.errorMessage;
      }
      if (sugs.isEmpty && (status == 'OK' || status == null)) {
        final alt = await _auto.findPlaceText(input: input, apiKey: ApiConstants.kGoogleApiKey, origin: origin);
        if (stale()) return;
        sugs = alt;
      }
      final networkFailure = status == 'NETWORK_ERROR' || status == 'TIMEOUT';
      setState(() {
        _sugs = sugs.isNotEmpty ? sugs : _recents;
        _autoStatus = status;
        _autoError = error;
        _isTyping = false;
        _isConnected = !networkFailure;
      });
    } catch (_) {
      if (stale()) return;
      setState(() {
        _isTyping = false;
        _isConnected = false;
        _sugs = _recents;
      });
    }
  }

  Future<void> _selectSug(Suggestion s) async {
    HapticFeedback.selectionClick();
    _ensurePlacesSession();
    final idx = _activeIdx.clamp(0, _pts.length - 1);
    final session = _placesSession;
    PlaceDetails det;
    try {
      det = await _auto.placeDetails(placeId: s.placeId, sessionToken: session, apiKey: ApiConstants.kGoogleApiKey);
    } catch (_) {
      _toast('Network Error', 'Failed to load place details.');
      return;
    }
    if (!mounted) return;
    final ll = det.latLng;
    if (ll == null) {
      _toast('Place Error', 'Could not read location details.');
      return;
    }
    if (idx >= _pts.length) return;
    // Details call closes the billing session.
    _placesSession = '';
    setState(() {
      _pts[idx]
        ..latLng = ll
        ..placeId = s.placeId
        ..controller.text = (s.mainText.isNotEmpty ? s.mainText : s.description)
        ..isCurrent = false;
      _isTyping = false;
    });
    _putPointMarker(idx);
    _saveRecent(s);

    if (_hasPickupAndDropoff) {
      _collapse();
      _cachedRoute = null;
      await _buildRoute();
      if (!mounted) return;
      await _startRideMarket();
    } else {
      for (int i = 0; i < _pts.length; i++) {
        if (_pts[i].latLng == null) {
          setState(() => _activeIdx = i);
          _focusField(i);
          return;
        }
      }
      _collapse();
    }
  }

  /// Opens the overlay (if needed) and focuses field [i] once it is built.
  void _focusField(int i) {
    _expand();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && i < _pts.length) _pts[i].focus.requestFocus();
    });
  }

  void _addStop() {
    HapticFeedback.selectionClick();
    if (_pts.length >= 6) {
      _toast('Limit', 'Maximum stops reached.');
      return;
    }
    final insertAt = (_pts.length - 1).clamp(1, _pts.length);
    final stop = RoutePoint(type: PointType.stop, controller: TextEditingController(), focus: FocusNode(), hint: 'Add stop');
    setState(() {
      _pts.insert(insertAt, stop);
      _activeIdx = insertAt;
    });
    _rebuildPointMarkers(); // indices shifted
    _expand();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pts.contains(stop)) stop.focus.requestFocus();
    });
  }

  void _removeStop(int index) {
    if (index <= 0 || index >= _pts.length - 1) return;
    HapticFeedback.selectionClick();
    final removed = _pts[index];
    setState(() {
      _pts.removeAt(index);
      if (_activeIdx >= _pts.length) _activeIdx = _pts.length - 1;
    });
    // Dispose after the frame so the RouteField can detach its listeners.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      removed.controller.dispose();
      removed.focus.dispose();
    });
    _rebuildPointMarkers();
    if (_hasPickupAndDropoff) {
      _cachedRoute = null;
      _buildRoute();
    }
  }

  void _swap() {
    if (_pts.length < 2) return;
    HapticFeedback.selectionClick();
    final a = _pts.first, b = _pts.last;
    setState(() {
      final ll = a.latLng, pid = a.placeId, txt = a.controller.text, isCur = a.isCurrent;
      a
        ..latLng = b.latLng
        ..placeId = b.placeId
        ..controller.text = b.controller.text
        ..isCurrent = false;
      b
        ..latLng = ll
        ..placeId = pid
        ..controller.text = txt
        ..isCurrent = false; // destination can't track GPS
      if (isCur && ll != null) b.controller.text = txt.isEmpty ? 'Current location' : txt;
    });
    _rebuildPointMarkers();
    if (_hasPickupAndDropoff) {
      _cachedRoute = null;
      _buildRoute();
    } else {
      _clearRoute();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Ride market / booking
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _startRideMarket() async {
    if (!_hasPickupAndDropoff || !mounted) return;
    _pollingEngine?.stop();
    await _marketSub?.cancel();
    _marketSub = null;
    if (!mounted) return;
    setState(() {
      _offersLoading = _offers.isEmpty;
      _marketOpen = true;
    });
    _syncSearchCircle();
    _scheduleMapPaddingUpdate();
    if (!_active) return; // resumes in _onActiveChanged

    LatLng safePickup() => _pickupLL() ?? _initialCam.target;
    LatLng safeDrop() => _destLL() ?? _initialCam.target;

    _marketSub = _rideMarketService
        .stream(
          origin: safePickup(),
          destination: safeDrop(),
          originProvider: safePickup,
          destinationProvider: safeDrop,
          userIdProvider: () => _prefs?.getString('user_id') ?? _user?['id']?.toString() ?? '',
          pollInterval: const Duration(seconds: 2),
          rideType: 'street_ride',
        )
        .listen((snap) {
      if (!mounted) return;
      _applyDrivers(snap.drivers);
      setState(() {
        _offers = snap.offers;
        _offersLoading = false;
      });
      _syncSearchCircle();
    }, onError: (_) {
      if (!mounted) return;
      setState(() => _offersLoading = false);
      _syncSearchCircle();
    });
  }

  void _stopRideMarket({bool restartNearbyPolling = true}) {
    _marketSub?.cancel();
    _marketSub = null;
    if (mounted) {
      setState(() {
        _marketOpen = false;
        _offersLoading = false;
        _offers = const <RideOffer>[];
      });
    }
    _syncSearchCircle();
    _scheduleMapPaddingUpdate();
    if (restartNearbyPolling) _resumeDriverPolling();
  }

  /// Clears the destination/stops and returns to browsing.
  void _resetPlanning() {
    _stopRideMarket();
    setState(() {
      if (_pts.length > 2) {
        final removed = _pts.sublist(1, _pts.length - 1);
        _pts.removeRange(1, _pts.length - 1);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final r in removed) {
            r.controller.dispose();
            r.focus.dispose();
          }
        });
      }
      final dest = _pts.last;
      dest
        ..latLng = null
        ..placeId = null
        ..controller.clear();
      _activeIdx = _pts.length - 1;
      _clearRoute();
    });
    _rebuildPointMarkers();
    _syncSearchCircle();
    _followUser = true;
    final pos = _curPos;
    if (pos != null) {
      _lastCamTarget = LatLng(pos.latitude, pos.longitude);
      _map?.animateCamera(CameraUpdate.newLatLngZoom(_lastCamTarget!, 16.5)).catchError((_) {});
    }
  }

  void _onBookingFlowFinished() {
    _bookingInProgress = false;
    _bookingSub?.cancel();
    _bookingSub = null;
    try {
      _booking?.dispose();
    } catch (_) {}
    _booking = null;
    if (!mounted) return;
    _resetPlanning();
  }

  Future<void> _bookingStartTrip() async {
    final b = _booking;
    if (b == null) throw Exception('Booking controller is null.');
    final ok = await b.startTrip();
    if (!ok) throw Exception(b.lastError?.message ?? 'Failed to start trip.');
  }

  Future<void> _bookingCancelTrip() async {
    final b = _booking;
    if (b == null) throw Exception('Booking controller is null.');
    final ok = await b.cancelTrip();
    if (!ok) throw Exception(b.lastError?.message ?? 'Failed to cancel trip.');
  }

  Future<Map<String, dynamic>?> _bookingLiveSnapshotProvider() async {
    final b = _booking;
    if (b == null) return null;
    final snap = b.currentSnapshot;
    return snap.isEmpty ? null : Map<String, dynamic>.from(snap);
  }

  Future<void> _onBook(dynamic driver, RideOffer offer) async {
    final prefs = _prefs;
    final pickup = _pickupLL();
    final dest = _destLL();
    if (_bookingInProgress || prefs == null || pickup == null || dest == null) return;
    // Booking needs a usable pickup; make sure location state is sane if the
    // pickup is "current location".
    if (_pts.first.isCurrent) {
      final st = await LocationPermissionModal.ensure(context, userTriggered: true);
      if (!mounted || !st.isGranted) return;
    }
    _bookingInProgress = true;
    try {
      await BookingFlowManager.initiateBooking(
        context: context,
        apiClient: _api,
        prefs: prefs,
        user: _user,
        driver: driver,
        offer: offer,
        pickup: pickup,
        destination: dest,
        stops: _stopLatLngs(),
        dropOffTexts: [for (int i = 1; i < _pts.length - 1; i++) if (_pts[i].latLng != null) _pts[i].controller.text.trim()],
        pickupText: _pts.first.controller.text.trim(),
        destinationText: _pts.last.controller.text.trim(),
        isCurrentPickup: _pts.first.isCurrent,
        onStopRideMarket: () => _stopRideMarket(restartNearbyPolling: false),
        onStartRideMarket: () => _startRideMarket(),
        onResetTripState: _onBookingFlowFinished,
        onDriverEngaged: (id, ll) {},
        onBookingControllerCreated: (controller) {
          try {
            _booking?.dispose();
          } catch (_) {}
          _booking = controller;
        },
        onSubscriptionCreated: (sub) {
          _bookingSub?.cancel();
          _bookingSub = sub;
        },
        snapshotProvider: _bookingLiveSnapshotProvider,
        onStartTrip: _bookingStartTrip,
        onCancelTrip: _bookingCancelTrip,
        rideType: 'street_ride',
      );
    } finally {
      // Paths that return early (sheet dismissed / booking failed) never call
      // onResetTripState.
      _bookingInProgress = false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Misc
  // ═══════════════════════════════════════════════════════════════════════════

  void _openWallet() {
    final balance = _user != null ? double.tryParse(_user!['user_bal']?.toString() ?? _user!['bal']?.toString() ?? '0.0') ?? 0.0 : null;
    final currency = _user?['user_currency']?.toString() ?? 'NGN';
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => FundAccountSheet(account: _user, balance: balance, currency: currency),
    );
  }

  void _toast(String title, String msg) {
    if (!mounted) return;
    showToastNotification(context: context, title: title, message: msg, isSuccess: false);
  }

  void _log(String msg, [Object? data]) {
    assert(() {
      debugPrint('[Home] $msg${data == null ? '' : ' → $data'}');
      return true;
    }());
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Build
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;
    final s = _scaleFromUi(uiScale);
    final safeTop = mq.padding.top;

    if (_lastOrientation != mq.orientation) {
      final first = _lastOrientation == null;
      _lastOrientation = mq.orientation;
      if (!first) {
        _scheduleMapPaddingUpdate();
        if (_routePts.isNotEmpty) {
          Future<void>.delayed(const Duration(milliseconds: 220), () {
            if (mounted) _fitCurrentRoute();
          });
        }
      }
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
    final pickupLL = _pickupLL();
    final destLL = _destLL();
    final textColor = isDark ? cs.onSurface : AppColors.textPrimary;
    final accent = isDark ? cs.primary : AppColors.primary;

    return Scaffold(
      key: _scaffoldKey,
      drawer: AppMenuDrawer(user: _user),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          Positioned.fill(child: _mapLayer),

          if (!_isConnected)
            Positioned(
              top: safeTop + (kHeaderVisualH * s) + uiScale.gap(hasSummary ? 52 : 8),
              left: uiScale.inset(10),
              right: uiScale.inset(10),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: summaryMaxWidth),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: uiScale.inset(16), vertical: uiScale.inset(12)),
                    decoration: BoxDecoration(
                      color: isDark ? cs.errorContainer.withValues(alpha: 0.95) : Colors.orange.shade700.withValues(alpha: 0.96),
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
                          child: Text(
                            'Connection issue. Retrying...',
                            style: TextStyle(color: isDark ? cs.onErrorContainer : Colors.white, fontSize: uiScale.font(13), fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: safeTop + (kHeaderVisualH * s),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: isDark
                        ? [Colors.black.withValues(alpha: 0.85), Colors.black.withValues(alpha: 0.0)]
                        : [Colors.white.withValues(alpha: 0.9), Colors.white.withValues(alpha: 0.0)],
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
              onNotifications: () => Navigator.pushNamed(context, AppRoutes.notifications),
            ),
          ),

          if (hasSummary)
            Positioned(
              top: safeTop + (kHeaderVisualH * s) + uiScale.gap(6),
              left: uiScale.inset(10),
              right: uiScale.inset(10),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: summaryMaxWidth),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: uiScale.inset(uiScale.compact ? 12 : 16), vertical: uiScale.inset(uiScale.compact ? 8 : 10)),
                    decoration: BoxDecoration(
                      color: isDark ? cs.surfaceContainerHighest.withValues(alpha: 0.96) : Colors.white.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(uiScale.radius(20)),
                      border: Border.all(color: isDark ? cs.outline.withValues(alpha: 0.4) : AppColors.mintBgLight.withValues(alpha: 0.5), width: 1.2),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.5 : .15), blurRadius: 16, offset: const Offset(0, 6))],
                    ),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: uiScale.gap(10),
                      runSpacing: uiScale.gap(6),
                      children: [
                        _summaryItem(uiScale, Icons.schedule_rounded, _durationText!, accent, textColor),
                        Container(height: uiScale.gap(16), width: 1, color: isDark ? cs.outline : AppColors.mintBgLight.withValues(alpha: .5)),
                        _summaryItem(uiScale, Icons.straighten_rounded, _distanceText!, accent, textColor),
                        if (_arrivalTime != null) ...[
                          Container(height: uiScale.gap(16), width: 1, color: isDark ? cs.outline : AppColors.mintBgLight.withValues(alpha: .5)),
                          _summaryItem(uiScale, Icons.flag_rounded, 'Arrive ${DateFormat('h:mm a').format(_arrivalTime!)}', accent, textColor),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),

          Positioned(
            right: fabRight,
            bottom: fabBottom,
            child: LocateFab(onTap: _onLocateTap, active: _followUser && _curPos != null && !_hasPickupAndDropoff),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: KeyedSubtree(
              key: _sheetKey,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: bottomSheetMaxH),
                child: !_hasPickupAndDropoff
                    ? RouteSheet(
                        key: const ValueKey('route_sheet'),
                        bottomNavHeight: bottomNavH,
                        sheetTitle: 'Street Ride',
                        sheetSubtitle: 'Seamless city transit for your daily commute.',
                        recentDestinations: _recents,
                        onSearchTap: () {
                          setState(() => _activeIdx = _pts.length - 1);
                          _focusField(_pts.length - 1);
                        },
                        onRecentTap: (sug) async {
                          // Recents on the sheet are destinations.
                          setState(() => _activeIdx = _pts.length - 1);
                          await _selectSug(sug);
                        },
                      )
                    : RideMarketSheet(
                        bottomNavHeight: bottomNavH,
                        originText: _pts.first.controller.text,
                        destinationText: _pts.last.controller.text,
                        distanceText: _distanceText,
                        durationText: _durationText,
                        offers: _offers,
                        loading: _offersLoading,
                        drivers: _drivers.values.toList(),
                        driversNearbyCount: _drivers.length,
                        userLocation: _curPos == null ? null : GeoPoint(_curPos!.latitude, _curPos!.longitude),
                        pickupLocation: pickupLL == null ? null : GeoPoint(pickupLL.latitude, pickupLL.longitude),
                        dropLocation: destLL == null ? null : GeoPoint(destLL.latitude, destLL.longitude),
                        onRefresh: _startRideMarket,
                        onCancel: _resetPlanning,
                        onBook: (driver, offer) => _onBook(driver, offer),
                      ),
              ),
            ),
          ),

          if (_expanded)
            AutoOverlay(
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
              onUseCurrentPickup: () {
                _useCurrentAsPickup();
                if (_activeIdx == 0) {
                  // Move on to the next empty field.
                  for (int i = 1; i < _pts.length; i++) {
                    if (_pts[i].latLng == null) {
                      setState(() => _activeIdx = i);
                      _focusField(i);
                      return;
                    }
                  }
                }
              },
              onTyping: _onTyping,
              onFocused: _onFocused,
              onSelectSuggestion: _selectSug,
              fmtDistance: _fmtDistance,
              onAddStop: _addStop,
              onRemoveStop: _removeStop,
              onClose: _collapse,
              onSwap: _swap,
            ),
        ],
      ),
    );
  }

  Widget _summaryItem(UIScale uiScale, IconData icon, String text, Color accent, Color textColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: uiScale.icon(16), color: accent),
        SizedBox(width: uiScale.gap(6)),
        Text(text, style: TextStyle(fontWeight: FontWeight.w800, fontSize: uiScale.font(12.5), color: textColor)),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Isolated map layer: built once, updated only through notifiers.
// ═════════════════════════════════════════════════════════════════════════════
class _HomeMapLayer extends StatelessWidget {
  final ValueNotifier<Set<Marker>> markersNotifier;
  final ValueNotifier<Set<Polyline>> polylinesNotifier;
  final ValueNotifier<Set<Circle>> circlesNotifier;
  final ValueNotifier<EdgeInsets> paddingNotifier;
  final CameraPosition initialCameraPosition;
  final void Function(GoogleMapController) onMapCreated;
  final void Function(CameraPosition) onCameraMove;
  final void Function(LatLng) onTap;
  final VoidCallback onUserGesture;

  const _HomeMapLayer({
    required this.markersNotifier,
    required this.polylinesNotifier,
    required this.circlesNotifier,
    required this.paddingNotifier,
    required this.initialCameraPosition,
    required this.onMapCreated,
    required this.onCameraMove,
    required this.onTap,
    required this.onUserGesture,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final merged = Listenable.merge([markersNotifier, polylinesNotifier, circlesNotifier, paddingNotifier]);
    return RepaintBoundary(
      child: MapGestureSensor(
        onUserGesture: onUserGesture,
        child: ListenableBuilder(
          listenable: merged,
          builder: (context, _) => GoogleMap(
            initialCameraPosition: initialCameraPosition,
            padding: paddingNotifier.value,
            style: isDark ? MapGraphicsEngine.kDarkMapStyle : null,
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: false,
            mapToolbarEnabled: false,
            rotateGesturesEnabled: false,
            tiltGesturesEnabled: false,
            buildingsEnabled: false,
            indoorViewEnabled: false,
            trafficEnabled: false,
            markers: markersNotifier.value,
            polylines: polylinesNotifier.value,
            circles: circlesNotifier.value,
            onMapCreated: onMapCreated,
            onCameraMove: onCameraMove,
            onTap: onTap,
          ),
        ),
      ),
    );
  }
}
