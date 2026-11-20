// lib/screens/trip_navigation_page.dart
//
// Turn-by-turn trip navigation for riders (watching the driver) and drivers.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../services/booking_controller.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import 'state/location_permission_modal.dart';
import 'state/map_gesture_sensor.dart';
import 'state/map_graphics_engine.dart';
import 'state/marker_motion.dart';
import 'state/routing_engine.dart';

enum TripNavigationRole { rider, driver }

enum TripNavPhase {
  driverToPickup,
  waitingPickup,
  enRoute,
  arrivedDestination,
  completed,
  cancelled
}

enum NavigationViewMode { navigation, atAGlance }

class TripNavigationArgs {
  final String userId, driverId, tripId;
  final LatLng pickup, destination;
  final List<LatLng> dropOffs;
  final String originText, destinationText;
  final List<String> dropOffTexts;

  final String rideType;
  final VoidCallback? onSOSTap;

  final String? driverName, vehicleType, carPlate;
  final double? rating;
  final LatLng? initialDriverLocation, initialRiderLocation;
  final TripNavPhase initialPhase;
  final Stream<dynamic>? bookingUpdates;
  final Future<Map<String, dynamic>?> Function()? liveSnapshotProvider;
  final Future<void> Function()? onStartTrip,
      onCancelTrip,
      onArrivedPickup,
      onArrivedDestination,
      onCompleteTrip;
  final TripNavigationRole role;
  final Duration tickEvery, routeMinGap;
  final double arrivalMeters, routeMoveThresholdMeters;
  final bool autoFollowCamera,
      showStartTripButton,
      showCancelButton,
      showMetaCard,
      showDebugPanel;
  final bool enableLivePickupTracking, preserveStopOrder, autoCloseOnCancel;
  final bool showArrivedPickupButton,
      showArrivedDestinationButton,
      showCompleteTripButton;

  const TripNavigationArgs({
    required this.userId,
    required this.driverId,
    required this.tripId,
    required this.pickup,
    required this.destination,
    this.dropOffs = const [],
    required this.originText,
    required this.destinationText,
    this.dropOffTexts = const [],
    this.rideType = 'Standard Ride',
    this.onSOSTap,
    this.driverName,
    this.vehicleType,
    this.carPlate,
    this.rating,
    this.initialDriverLocation,
    this.initialRiderLocation,
    this.initialPhase = TripNavPhase.driverToPickup,
    this.bookingUpdates,
    this.liveSnapshotProvider,
    this.onStartTrip,
    this.onCancelTrip,
    this.onArrivedPickup,
    this.onArrivedDestination,
    this.onCompleteTrip,
    this.role = TripNavigationRole.rider,
    this.tickEvery = const Duration(seconds: 1),
    this.routeMinGap = const Duration(seconds: 20),
    this.arrivalMeters = 150.0,
    this.routeMoveThresholdMeters = 25.0,
    this.autoFollowCamera = true,
    this.showStartTripButton = true,
    this.showCancelButton = true,
    this.showMetaCard = true,
    this.showDebugPanel = false,
    this.enableLivePickupTracking = false,
    this.preserveStopOrder = true,
    this.autoCloseOnCancel = true,
    this.showArrivedPickupButton = true,
    this.showArrivedDestinationButton = true,
    this.showCompleteTripButton = true,
  });
}

class TripNavigationPage extends StatefulWidget {
  final TripNavigationArgs args;
  const TripNavigationPage({super.key, required this.args});

  @override
  State<TripNavigationPage> createState() => _TripNavigationPageState();
}


// ═════════════════════════════════════════════════════════════════════════════
//  STATE
//
//  Navigation model
//   • Route: computed once per target (pickup / stop / destination) with
//     turn-by-turn steps, re-computed only when the car is off-route
//     (2 consecutive fixes beyond the threshold, throttled), when the target
//     changes, or every 90 s for traffic-aware ETA.
//   • Every car fix is projected onto the active polyline (windowed search
//     around the previous segment). Remaining distance / ETA come from the
//     remaining polyline length; the active step from cumulative step lengths.
//   • The car marker is animated at display refresh rate by [MarkerMotion]
//     (eased lat/lng + shortest-arc bearing, jitter rejection, dead reckoning
//     along the route between fixes).
//   • Camera follow (bearing + tilt) is driven from the same frame callback,
//     pauses on any user drag/pinch and resumes with "Re-center".
//   • Driver role: the device GPS (1 Hz) is the primary car source; server
//     snapshots are only used when no fresh device fix exists.
// ═════════════════════════════════════════════════════════════════════════════
class _TripNavigationPageState extends State<TripNavigationPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const Duration _deviceFixFreshFor = Duration(seconds: 5);
  static const Duration _etaRefreshEvery = Duration(seconds: 90);
  static const Map<TripNavPhase, int> _phaseOrder = {
    TripNavPhase.driverToPickup: 0,
    TripNavPhase.waitingPickup: 1,
    TripNavPhase.enRoute: 2,
    TripNavPhase.arrivedDestination: 3,
    TripNavPhase.completed: 4,
    TripNavPhase.cancelled: 5,
  };

  // --- MAP LAYER NOTIFIERS ---
  final ValueNotifier<Set<Marker>> _markersNotifier = ValueNotifier<Set<Marker>>(<Marker>{});
  final ValueNotifier<Set<Polyline>> _polylinesNotifier = ValueNotifier<Set<Polyline>>(<Polyline>{});
  final ValueNotifier<Set<Circle>> _circlesNotifier = ValueNotifier<Set<Circle>>(<Circle>{});
  final ValueNotifier<EdgeInsets> _paddingNotifier = ValueNotifier<EdgeInsets>(EdgeInsets.zero);
  GoogleMapController? _mapController;
  Widget? _mapLayer;

  StreamSubscription<dynamic>? _bookingSub;
  StreamSubscription<Position>? _gpsSub;
  Timer? _tickTimer;
  late final Ticker _frameTicker;

  Map<MarkerId, Marker> _staticMarkers = <MarkerId, Marker>{};
  Marker? _carMarker;
  Marker? _riderMarker;
  Circle? _riderAccuracy;

  double? _iconsDpr;
  BitmapDescriptor? _carIcon, _pickupIcon, _dropIcon, _riderRingIcon, _waypointIcon, _riderDotIcon;

  // --- CAR MOTION ---
  MarkerMotion? _carMotion;
  LatLng? _lastRawCar;
  DateTime? _lastDeviceFixAt;

  // --- RIDER (own device for rider role, payload for driver role) ---
  LatLng? _riderLL;
  MarkerMotion? _riderMotion;
  double _riderAccuracyM = 0;
  bool _riderFromDevice = false;

  // --- ROUTE / PROGRESS ---
  RouteGeometry? _route;
  List<RouteStep> _steps = const <RouteStep>[];
  List<double> _stepEndAlong = const <double>[];
  LatLng? _routeTarget;
  int _routeDistanceM = 0;
  int _routeDurationS = 0;
  PolylineProjection? _lastProj;
  double _lastTrimAlong = -1;
  int _offRouteCount = 0;
  int _routeSeq = 0;
  bool _busyRoute = false;
  DateTime _lastRouteAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _stepIdx = 0;
  double? _distToManeuverM;

  TripNavPhase _phase = TripNavPhase.driverToPickup;
  DateTime? _optimisticPhaseSetAt;
  int _activeStopIndex = 0;

  NavigationViewMode _viewMode = NavigationViewMode.navigation;
  bool _isFollowCameraEnabled = true;
  bool _cameraMoveInFlight = false;
  LatLng? _lastCamTarget;
  double _lastCamBearing = 0;
  bool _booting = true;
  bool _appResumed = true;
  bool _closing = false;

  // --- UI FLAGS ---
  String? _distanceText, _durationText, _lastErrorText;
  bool _uiPending = false;

  bool _busyTick = false, _busyPrimaryAction = false, _busyCancel = false, _didInitialFit = false;
  bool _canArrivePickup = false, _canStartTrip = false, _canArriveDestination = false, _canCompleteRide = false;

  Duration get _tickEvery => widget.args.tickEvery > Duration.zero ? widget.args.tickEvery : const Duration(seconds: 2);

  /// Minimum gap between two re-routes (floor 8 s to protect quota/UI).
  Duration get _rerouteMinGap => widget.args.routeMinGap > const Duration(seconds: 8) ? widget.args.routeMinGap : const Duration(seconds: 8);
  double get _arrivalMeters => widget.args.arrivalMeters > 0 ? widget.args.arrivalMeters : 150.0;

  /// Distance from the polyline beyond which a fix counts as off-route.
  double _offRouteThreshold(double? accuracy) =>
      math.max(35.0, math.max(widget.args.routeMoveThresholdMeters, (accuracy ?? 0) * 1.5)).clamp(35.0, 80.0).toDouble();

  bool get _isDriver => widget.args.role == TripNavigationRole.driver;
  bool get _isTerminal => _phase == TripNavPhase.completed || _phase == TripNavPhase.cancelled;
  bool get _isTripLeg => _phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination;

  List<LatLng> get _allTargets => [...widget.args.dropOffs, widget.args.destination];
  List<String> get _allTargetTexts => [...widget.args.dropOffTexts, widget.args.destinationText];

  LatLng get _effectivePickupLL =>
      (widget.args.enableLivePickupTracking && _riderLL != null) ? _riderLL! : widget.args.pickup;

  LatLng get _currentTarget {
    if (!_isTripLeg) return _effectivePickupLL;
    final targets = _allTargets;
    return targets[_activeStopIndex.clamp(0, targets.length - 1)];
  }

  String get _currentTargetText {
    if (!_isTripLeg) return widget.args.originText;
    final texts = _allTargetTexts;
    if (texts.isEmpty) return widget.args.destinationText;
    return texts[_activeStopIndex.clamp(0, texts.length - 1)];
  }

  LatLng? get _carLL => _carMotion?.target;

  // ═══════════════════════════════════════════════════════════════════════════
  // Lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _frameTicker = createTicker(_onFrame);

    _phase = widget.args.initialPhase;
    _isFollowCameraEnabled = widget.args.autoFollowCamera;
    _riderLL = widget.args.initialRiderLocation;

    final initCar = widget.args.initialDriverLocation;
    if (initCar != null) {
      _carMotion = MarkerMotion(
        initial: initCar,
        bearing: RoutingEngine.bearingBetween(initCar, _currentTarget),
        jitterMeters: 3,
        maxExtrapolation: const Duration(milliseconds: 1600),
        maxExtrapolationMeters: 30,
      );
      _lastRawCar = initCar;
    }
    _bootstrap();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureIcons(MediaQuery.devicePixelRatioOf(context));
  }

  @override
  void dispose() {
    _closing = true;
    WidgetsBinding.instance.removeObserver(this);
    _bookingSub?.cancel();
    _gpsSub?.cancel();
    _tickTimer?.cancel();
    _frameTicker.dispose();
    _markersNotifier.dispose();
    _polylinesNotifier.dispose();
    _circlesNotifier.dispose();
    _paddingNotifier.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) return;
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _appResumed) return;
    _appResumed = resumed;
    if (resumed) {
      _startDeviceGps();
      _tick(force: true);
      _scheduleFrame();
    } else {
      // Cancel rather than pause: a paused subscription buffers fixes.
      _gpsSub?.cancel();
      _gpsSub = null;
    }
  }

  Future<void> _bootstrap() async {
    _listenBooking();
    await _startDeviceGps();
    if (!mounted) return;
    _tickTimer = Timer.periodic(_tickEvery, (_) => _tick());
    setState(() => _booting = false);
    _recomputePermissions();
    _tick(force: true);
  }

  void _markUi() {
    if (_uiPending || !mounted) return;
    _uiPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _uiPending = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
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
          MapGraphicsEngine.createCarMarker(devicePixelRatio: dpr, logicalWidth: 28),
          MapGraphicsEngine.createRingDotMarker(const Color(0xFF1A73E8)),
          MapGraphicsEngine.createRingDotMarker(const Color(0xFF00A651)),
          MapGraphicsEngine.createRingDotMarker(const Color(0xFFE91E63)),
          MapGraphicsEngine.createRingDotMarker(const Color(0xFFFF9800)),
          MapGraphicsEngine.createUserLocationDot(devicePixelRatio: dpr),
        ]);
        if (!mounted) return;
        _carIcon = r[0];
        _pickupIcon = r[1];
        _dropIcon = r[2];
        _riderRingIcon = r[3];
        _waypointIcon = r[4];
        _riderDotIcon = r[5];
        _carMarker = null;
        _riderMarker = null;
        _prebuildStaticMarkers();
        _scheduleFrame();
      } catch (_) {}
    }();
  }

  void _prebuildStaticMarkers() {
    final pickupIcon = _pickupIcon, dropIcon = _dropIcon, wpIcon = _waypointIcon;
    if (pickupIcon == null || dropIcon == null || wpIcon == null) return;
    final hidePickup = widget.args.enableLivePickupTracking && _riderLL != null;
    final next = <MarkerId, Marker>{
      if (!hidePickup)
        const MarkerId('pickup'): Marker(markerId: const MarkerId('pickup'), position: widget.args.pickup, icon: pickupIcon, anchor: const Offset(0.5, 0.5), zIndexInt: 35),
      const MarkerId('destination'): Marker(markerId: const MarkerId('destination'), position: widget.args.destination, icon: dropIcon, anchor: const Offset(0.5, 0.5), zIndexInt: 35),
      for (int i = 0; i < widget.args.dropOffs.length; i++)
        MarkerId('drop_$i'): Marker(markerId: MarkerId('drop_$i'), position: widget.args.dropOffs[i], icon: wpIcon, anchor: const Offset(0.5, 0.5), zIndexInt: 34),
    };
    if (!mapEquals(next, _staticMarkers)) {
      _staticMarkers = next;
      _scheduleFrame(force: true);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Frame loop (marker animation + camera follow)
  // ═══════════════════════════════════════════════════════════════════════════

  bool _frameDirty = false;

  void _scheduleFrame({bool force = false}) {
    if (force) _frameDirty = true;
    if (!mounted || _closing) return;
    if (!_frameTicker.isActive) _frameTicker.start();
  }

  void _onFrame(Duration _) {
    if (!mounted) return;
    final now = MarkerMotion.nowUs;
    bool animating = false;
    bool changed = _frameDirty;
    _frameDirty = false;

    MotionSample? car;
    final cm = _carMotion;
    final carIcon = _carIcon;
    if (cm != null && carIcon != null) {
      car = cm.sample(now);
      animating |= cm.isAnimating(now);
      final prev = _carMarker;
      if (prev == null ||
          RoutingEngine.haversine(prev.position, car.position) > 0.03 ||
          RoutingEngine.shortestAngleDelta(prev.rotation, car.bearing).abs() > 0.3) {
        _carMarker = Marker(
          markerId: const MarkerId('driver'),
          position: car.position,
          icon: carIcon,
          anchor: const Offset(0.5, 0.5),
          flat: true,
          rotation: car.bearing,
          zIndexInt: 50,
        );
        changed = true;
      }
    }

    // Rider marker: own blue dot (rider role, device GPS) or pink ring
    // (driver role, position from payload).
    final rm = _riderMotion;
    if (rm != null) {
      final s = rm.sample(now);
      animating |= rm.isAnimating(now);
      final icon = _riderFromDevice ? _riderDotIcon : _riderRingIcon;
      if (icon != null) {
        final prev = _riderMarker;
        if (prev == null || RoutingEngine.haversine(prev.position, s.position) > 0.05 || prev.icon != icon) {
          _riderMarker = Marker(
            markerId: const MarkerId('rider_live'),
            position: s.position,
            icon: icon,
            anchor: const Offset(0.5, 0.5),
            flat: true,
            zIndexInt: 45,
          );
          changed = true;
        }
        if (_riderFromDevice && _riderAccuracyM >= 3) {
          final pc = _riderAccuracy;
          if (pc == null || RoutingEngine.haversine(pc.center, s.position) > 0.25 || (pc.radius - _riderAccuracyM).abs() > 1) {
            _riderAccuracy = Circle(
              circleId: const CircleId('rider_accuracy'),
              center: s.position,
              radius: _riderAccuracyM.clamp(3.0, 1500.0).toDouble(),
              fillColor: const Color(0xFF1A73E8).withValues(alpha: 0.12),
              strokeColor: const Color(0xFF1A73E8).withValues(alpha: 0.28),
              strokeWidth: 1,
            );
            _circlesNotifier.value = {_riderAccuracy!};
          }
        }
      }
    }

    if (changed) {
      _markersNotifier.value = <Marker>{
        ..._staticMarkers.values,
        if (_riderMarker != null) _riderMarker!,
        if (_carMarker != null) _carMarker!,
      };
    }

    if (car != null) animating |= _followCamera(car);
    if (!animating) _frameTicker.stop();
  }

  /// Moves the camera with the car. Returns true while the camera still has
  /// to catch up (keeps the ticker alive).
  bool _followCamera(MotionSample car) {
    final map = _mapController;
    if (map == null || !_isFollowCameraEnabled || _viewMode != NavigationViewMode.navigation || _isTerminal) return false;
    final last = _lastCamTarget;
    final moved = last == null || RoutingEngine.haversine(last, car.position) > 0.2;
    final turned = RoutingEngine.shortestAngleDelta(_lastCamBearing, car.bearing).abs() > 0.3;
    if (!moved && !turned) return false;
    if (_cameraMoveInFlight) return true; // never queue camera updates
    _cameraMoveInFlight = true;
    _lastCamTarget = car.position;
    _lastCamBearing = car.bearing;
    map
        .moveCamera(CameraUpdate.newCameraPosition(CameraPosition(
          target: car.position,
          zoom: _isTripLeg ? 17.6 : 17.0,
          tilt: 50.0,
          bearing: car.bearing,
        )))
        .catchError((_) {})
        .whenComplete(() => _cameraMoveInFlight = false);
    return true;
  }

  void _onUserMapGesture() {
    if (!_isFollowCameraEnabled) return;
    setState(() => _isFollowCameraEnabled = false);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sources: device GPS, booking stream, snapshot polling
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _startDeviceGps() async {
    // Never prompt from here: the booking / driver console already went
    // through the location gate.
    if (_gpsSub != null) return;
    if (!await LocationPermissionModal.hasLocationAccess()) return;
    if (!mounted || _gpsSub != null || !_appResumed) return;
    final LocationSettings settings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 1, intervalDuration: const Duration(seconds: 1));
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
        activityType: _isDriver ? ActivityType.automotiveNavigation : ActivityType.otherNavigation,
        pauseLocationUpdatesAutomatically: false,
      );
    } else {
      settings = const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 1);
    }
    try {
      _gpsSub = Geolocator.getPositionStream(locationSettings: settings).listen(_onDevicePosition, onError: (_) {});
    } catch (_) {}
  }

  void _onDevicePosition(Position p) {
    if (!mounted || !p.latitude.isFinite || !p.longitude.isFinite) return;
    if (p.accuracy.isFinite && p.accuracy > 200) return; // unusable for navigation
    final ll = LatLng(p.latitude, p.longitude);
    final speed = (p.speed.isFinite && p.speed >= 0) ? p.speed : null;
    if (_isDriver) {
      _lastDeviceFixAt = DateTime.now();
      final course = (speed != null && speed >= 2.5 && p.heading.isFinite && p.heading >= 0) ? p.heading : null;
      _onCarFix(ll, accuracy: p.accuracy, speed: speed, heading: course, fromDevice: true);
    } else {
      _riderFromDevice = true;
      _riderAccuracyM = p.accuracy.isFinite ? p.accuracy : 0;
      _setRider(ll, accuracy: p.accuracy, speed: speed);
    }
  }

  void _setRider(LatLng ll, {double? accuracy, double? speed}) {
    final prev = _riderLL;
    _riderLL = ll;
    final m = _riderMotion;
    if (m == null) {
      _riderMotion = MarkerMotion(initial: ll, jitterMeters: 2.5, maxExtrapolationMeters: 10);
      _prebuildStaticMarkers();
    } else {
      m.push(ll, accuracyMeters: accuracy, speedMps: speed);
    }
    _scheduleFrame();
    if (widget.args.enableLivePickupTracking && !_isTripLeg && prev != null && RoutingEngine.haversine(prev, ll) > 2.5) {
      _recomputePermissions();
    }
  }

  void _listenBooking() {
    final updates = widget.args.bookingUpdates;
    if (updates == null) return;
    _bookingSub?.cancel();
    _bookingSub = updates.listen((event) {
      if (!mounted) return;
      _applyIncoming(event);
      _recomputePermissions();
    }, onError: (_) {}, cancelOnError: false);
  }

  Future<void> _tick({bool force = false}) async {
    if (!mounted || _busyTick || _booting || !_appResumed) return;
    _busyTick = true;
    try {
      await _applyLiveSnapshot();
      if (!mounted) return;
      _recomputePermissions();

      final target = _currentTarget;
      final targetMoved = _routeTarget == null || RoutingEngine.haversine(_routeTarget!, target) > 30;
      final etaStale = DateTime.now().difference(_lastRouteAt) > _etaRefreshEvery;
      if (force || targetMoved || etaStale) {
        await _requestRoute(force: force || targetMoved);
      }
    } finally {
      _busyTick = false;
    }
  }

  Future<void> _applyLiveSnapshot() async {
    final provider = widget.args.liveSnapshotProvider;
    if (provider == null) return;
    try {
      final snap = await provider();
      if (mounted && snap != null && snap.isNotEmpty) _applyIncoming(snap);
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Car fixes → snap-to-route → progress
  // ═══════════════════════════════════════════════════════════════════════════

  void _onCarFix(LatLng raw, {double? accuracy, double? speed, double? heading, required bool fromDevice}) {
    if (_isTerminal) return;
    if (!fromDevice) {
      final devFix = _lastDeviceFixAt;
      if (devFix != null && DateTime.now().difference(devFix) < _deviceFixFreshFor) return;
      // Snapshots often repeat the same coordinate: don't restart motion.
      final lastRaw = _lastRawCar;
      if (lastRaw != null && RoutingEngine.haversine(lastRaw, raw) < 0.5) return;
    }
    _lastRawCar = raw;

    LatLng target = raw;
    double? bearing = heading;
    final route = _route;
    if (route != null) {
      final proj = route.project(raw, hintSegment: _lastProj?.segmentIndex);
      if (proj != null && proj.distanceToRoute <= _offRouteThreshold(accuracy)) {
        _offRouteCount = 0;
        target = proj.point;
        bearing = proj.segmentBearing;
        _lastProj = proj;
        _updateProgress(proj);
      } else if (proj != null) {
        _offRouteCount++;
        if (_offRouteCount >= 2) _requestRoute(force: false, offRoute: true);
      }
    }

    final m = _carMotion;
    if (m == null) {
      _carMotion = MarkerMotion(
        initial: target,
        bearing: bearing ?? RoutingEngine.bearingBetween(target, _currentTarget),
        jitterMeters: 3,
        maxExtrapolation: const Duration(milliseconds: 1600),
        maxExtrapolationMeters: 30,
      )..route = route;
      if (_route == null) _requestRoute(force: true);
    } else {
      m.push(
        target,
        bearing: bearing,
        accuracyMeters: accuracy,
        speedMps: speed,
        expectedInterval: fromDevice ? const Duration(milliseconds: 1000) : null,
      );
    }
    _scheduleFrame();
  }

  void _updateProgress(PolylineProjection proj) {
    final route = _route;
    if (route == null) return;
    final remaining = math.max(0.0, route.length - proj.distanceAlong);
    final secs = route.length <= 0 ? 0 : (_routeDurationS * (remaining / route.length)).round();

    // Active step = first step whose end lies ahead of the car.
    if (_stepEndAlong.isNotEmpty) {
      int idx = _stepIdx.clamp(0, _stepEndAlong.length - 1);
      while (idx < _stepEndAlong.length - 1 && _stepEndAlong[idx] <= proj.distanceAlong + 3) {
        idx++;
      }
      _stepIdx = idx;
      _distToManeuverM = math.max(0.0, _stepEndAlong[idx] - proj.distanceAlong);
    }

    final dist = _fmtDistance(remaining.round());
    final dur = _fmtDuration(secs);
    if (dist != _distanceText || dur != _durationText) {
      _distanceText = dist;
      _durationText = dur;
      _markUi();
    } else if (_steps.isNotEmpty && _isDriver) {
      _markUi(); // maneuver distance changes
    }

    // Trim the travelled part of the line (not every frame: every ~8 m).
    if ((proj.distanceAlong - _lastTrimAlong).abs() > 8) {
      _lastTrimAlong = proj.distanceAlong;
      _publishRoutePolyline(route.remainingFrom(proj));
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Routing
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _requestRoute({required bool force, bool offRoute = false}) async {
    if (_busyRoute || _isTerminal || !mounted) return;
    final from = _lastRawCar ?? _carLL;
    if (from == null) return;
    final now = DateTime.now();
    final sinceLast = now.difference(_lastRouteAt);
    // Hard floor protects quota when the API keeps failing; the soft gap
    // throttles off-route / ETA refreshes.
    if (sinceLast < const Duration(seconds: 4)) return;
    if (!force && sinceLast < _rerouteMinGap) return;

    final to = _currentTarget;
    final seq = ++_routeSeq;
    _busyRoute = true;
    _lastRouteAt = now;
    try {
      final result = await RoutingEngine.computeRoute(origin: from, destination: to, includeSteps: true);
      if (!mounted || seq != _routeSeq || result == null || result.points.length < 2) return;
      _applyRoute(result, to);
      if (offRoute) _offRouteCount = 0;
    } finally {
      _busyRoute = false;
    }
  }

  void _applyRoute(RouteResult r, LatLng target) {
    final geo = RouteGeometry(r.points);
    _route = geo;
    _routeTarget = target;
    _routeDistanceM = r.distanceMeters > 0 ? r.distanceMeters : geo.length.round();
    _routeDurationS = r.durationSeconds;
    _steps = r.steps;
    _stepIdx = 0;
    _lastProj = null;
    _lastTrimAlong = -1;
    _carMotion?.route = geo;

    // Cumulative step ends, scaled to the decoded polyline length.
    if (r.steps.isNotEmpty) {
      final total = r.steps.fold<int>(0, (a, s) => a + s.distanceMeters);
      final scale = total > 0 ? geo.length / total : 1.0;
      double acc = 0;
      _stepEndAlong = [
        for (final s in r.steps) acc += s.distanceMeters * scale,
      ];
    } else {
      _stepEndAlong = const <double>[];
    }

    final car = _lastRawCar ?? _carLL;
    final proj = car == null ? null : geo.project(car);
    if (proj != null) {
      _lastProj = proj;
      _updateProgress(proj);
    } else {
      _distanceText = _fmtDistance(_routeDistanceM);
      _durationText = _fmtDuration(_routeDurationS);
      _publishRoutePolyline(r.points);
    }
    _markUi();

    if (!_didInitialFit) {
      _didInitialFit = true;
      if (!_isFollowCameraEnabled || _viewMode == NavigationViewMode.atAGlance) {
        _animateCamera(CameraUpdate.newLatLngBounds(_boundsFrom([if (car != null) car, target]), 90.0));
      } else {
        _scheduleFrame();
      }
    }
  }

  void _publishRoutePolyline(List<LatLng> pts) {
    if (!mounted || pts.length < 2) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    _polylinesNotifier.value = {
      Polyline(
        polylineId: const PolylineId('halo'),
        points: pts,
        color: isDark ? Colors.white.withValues(alpha: 0.9) : Colors.black.withValues(alpha: 0.85),
        width: 10,
        jointType: JointType.round,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        zIndex: 1,
      ),
      Polyline(
        polylineId: const PolylineId('main'),
        points: pts,
        color: AppColors.primary,
        width: 6,
        jointType: JointType.round,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        zIndex: 2,
      ),
    };
  }

  void _invalidateRoute() {
    _routeSeq++;
    _route = null;
    _routeTarget = null;
    _steps = const <RouteStep>[];
    _stepEndAlong = const <double>[];
    _lastProj = null;
    _distToManeuverM = null;
    _carMotion?.route = null;
  }

  void _animateCamera(CameraUpdate update) {
    _mapController?.animateCamera(update).catchError((_) {});
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Camera modes
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _activateOverviewMode() async {
    HapticFeedback.lightImpact();
    setState(() {
      _viewMode = NavigationViewMode.atAGlance;
      _isFollowCameraEnabled = false;
    });
    _paddingNotifier.value = _calcMapPadding(MediaQuery.of(context), UIScale.of(context));
    final pts = <LatLng>[
      if (_carLL != null) _carLL!,
      _effectivePickupLL,
      ...widget.args.dropOffs,
      widget.args.destination,
    ];
    _animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: pts.first, zoom: 14, tilt: 0, bearing: 0)));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (mounted) _animateCamera(CameraUpdate.newLatLngBounds(_boundsFrom(pts), 92.0));
  }

  Future<void> _recenterMap() async {
    HapticFeedback.selectionClick();
    setState(() {
      _isFollowCameraEnabled = true;
      _viewMode = NavigationViewMode.navigation;
    });
    _paddingNotifier.value = _calcMapPadding(MediaQuery.of(context), UIScale.of(context));
    final car = _carMotion?.sample();
    if (car != null) {
      _lastCamTarget = car.position;
      _lastCamBearing = car.bearing;
      _cameraMoveInFlight = true;
      try {
        await _mapController?.animateCamera(CameraUpdate.newCameraPosition(
          CameraPosition(target: car.position, zoom: _isTripLeg ? 17.6 : 17.0, tilt: 50, bearing: car.bearing),
        ));
      } catch (_) {
      } finally {
        _cameraMoveInFlight = false;
      }
    }
    _scheduleFrame();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Actions
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _handlePrimaryAction() async {
    if (_busyPrimaryAction || !_isDriver) return;

    Future<void> Function()? callback;
    TripNavPhase? nextOpt;
    switch (_phase) {
      case TripNavPhase.driverToPickup:
        callback = widget.args.onArrivedPickup;
        nextOpt = TripNavPhase.waitingPickup;
      case TripNavPhase.waitingPickup:
        callback = widget.args.onStartTrip;
        nextOpt = TripNavPhase.enRoute;
      case TripNavPhase.enRoute:
        callback = widget.args.onArrivedDestination;
        nextOpt = TripNavPhase.arrivedDestination;
      case TripNavPhase.arrivedDestination:
        callback = widget.args.onCompleteTrip;
        nextOpt = TripNavPhase.completed;
      case TripNavPhase.completed:
      case TripNavPhase.cancelled:
        break;
    }
    if (callback == null) return;

    setState(() => _busyPrimaryAction = true);
    try {
      await callback();
      if (!mounted) return;
      if (nextOpt != null) {
        _optimisticPhaseSetAt = DateTime.now(); // ignore stale (older) backend phases briefly
        _setPhase(nextOpt);
      }
      await _tick(force: true);
      if (mounted && _phase == TripNavPhase.enRoute) _recenterMap();
    } catch (e) {
      _emitError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busyPrimaryAction = false);
    }
  }

  Future<void> _cancelTripPressed() async {
    if (_busyCancel) return;
    if (_isTerminal) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _busyCancel = true);
    try {
      final cb = widget.args.onCancelTrip;
      if (cb != null) await cb();
      if (!mounted) return;
      _setPhase(TripNavPhase.cancelled);
      if (widget.args.autoCloseOnCancel) Navigator.of(context).maybePop();
    } catch (e) {
      _emitError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busyCancel = false);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Incoming events
  // ═══════════════════════════════════════════════════════════════════════════

  void _applyIncoming(dynamic event) {
    final payload = _eventMap(event);
    if (payload.isEmpty) return;

    if (event is BookingUpdate && event.status == BookingStatus.failed) {
      _emitError(event.displayMessage.isNotEmpty ? event.displayMessage : 'Trip issue.');
      return;
    }

    final rawCar = _coerceDriverLL(payload, event);
    if (rawCar != null) {
      final h = double.tryParse((payload['driver_heading'] ?? payload['heading'] ?? payload['bearing'])?.toString() ?? '');
      final sp = double.tryParse((payload['driver_speed'] ?? payload['speed'])?.toString() ?? '');
      _onCarFix(rawCar, heading: (h != null && h.isFinite && h >= 0 && (sp ?? 0) >= 2.5) ? h : null, speed: sp, fromDevice: false);
    }

    if (!_riderFromDevice) {
      final rider = _coerceRiderLL(payload);
      if (rider != null && (_riderLL == null || RoutingEngine.haversine(_riderLL!, rider) > 2.5)) {
        _setRider(rider);
      }
    }

    var nextPhase = _coercePhase(payload, event);
    if (nextPhase != null && nextPhase != _phase) {
      final lockAt = _optimisticPhaseSetAt;
      final locked = lockAt != null && DateTime.now().difference(lockAt) < const Duration(seconds: 15);
      final regress = (_phaseOrder[nextPhase] ?? 0) < (_phaseOrder[_phase] ?? 0);
      if (locked && regress) {
        nextPhase = null; // stale backend state right after our own action
      } else if (!locked) {
        _optimisticPhaseSetAt = null;
      }
    }
    if (nextPhase != null && nextPhase != _phase) _setPhase(nextPhase);

    final stopIndex = _coerceStopIndex(payload, event);
    if (stopIndex != null && _activeStopIndex != stopIndex) {
      _activeStopIndex = stopIndex.clamp(0, _allTargets.length - 1);
      if (_isTripLeg) {
        _invalidateRoute();
        _requestRoute(force: true);
      }
      _markUi();
    }
  }

  void _setPhase(TripNavPhase next) {
    if (next == _phase) return;
    final prevLeg = _isTripLeg;
    _phase = next;
    _didInitialFit = false;
    if (_isTerminal) {
      _invalidateRoute();
      _polylinesNotifier.value = <Polyline>{};
      if (next == TripNavPhase.cancelled && !_busyCancel) {
        _emitError('This trip was cancelled.');
        if (widget.args.autoCloseOnCancel) {
          Future<void>.delayed(const Duration(milliseconds: 1500), () {
            if (mounted) Navigator.of(context).maybePop();
          });
        }
      }
    } else if (prevLeg != _isTripLeg) {
      _invalidateRoute();
      _requestRoute(force: true);
    }
    _recomputePermissions();
    _markUi();
  }

  void _emitError(String message) {
    if (_lastErrorText != message) {
      _lastErrorText = message;
      _markUi();
    }
  }

  void _recomputePermissions() {
    final pos = _carLL;
    if (pos == null) return;
    final safeArrival = math.max(_arrivalMeters, 150.0);
    final cAP = _phase == TripNavPhase.driverToPickup && RoutingEngine.haversine(pos, _effectivePickupLL) <= safeArrival;
    final cST = _phase == TripNavPhase.waitingPickup;
    final cAD = _phase == TripNavPhase.enRoute && RoutingEngine.haversine(pos, _currentTarget) <= safeArrival;
    final cCR = _phase == TripNavPhase.arrivedDestination;
    if (_canArrivePickup != cAP || _canStartTrip != cST || _canArriveDestination != cAD || _canCompleteRide != cCR) {
      _canArrivePickup = cAP;
      _canStartTrip = cST;
      _canArriveDestination = cAD;
      _canCompleteRide = cCR;
      _markUi();
    }
  }

  Map<String, dynamic> _eventMap(dynamic event) {
    if (event is BookingUpdate) return {'booking_status': event.status.toString(), ...event.data};
    if (event is Map<String, dynamic>) return event;
    if (event is Map) return event.cast<String, dynamic>();
    try {
      final data = event.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return data.cast<String, dynamic>();
    } catch (_) {}
    return {};
  }

  static TripNavPhase? _phaseFromString(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'searching':
      case 'accepted':
      case 'driver_assigned':
      case 'driver_arriving':
      case 'arriving':
      case 'enroute_pickup':
        return TripNavPhase.driverToPickup;
      case 'arrived_pickup':
        return TripNavPhase.waitingPickup;
      case 'in_ride':
      case 'on_trip':
      case 'in_progress':
      case 'started':
        return TripNavPhase.enRoute;
      case 'arrived_destination':
        return TripNavPhase.arrivedDestination;
      case 'completed':
      case 'done':
      case 'finished':
        return TripNavPhase.completed;
      case 'cancelled':
      case 'canceled':
        return TripNavPhase.cancelled;
      default:
        return null;
    }
  }

  TripNavPhase? _coercePhase(Map<String, dynamic> payload, dynamic rawEvent) {
    if (rawEvent is BookingUpdate) {
      // The raw server status is more precise (e.g. arrived_pickup) than the enum.
      final fromRaw = _phaseFromString(rawEvent.rawStatus);
      if (fromRaw != null) return fromRaw;
      switch (rawEvent.status) {
        case BookingStatus.searching:
        case BookingStatus.driverAssigned:
        case BookingStatus.driverArriving:
          return TripNavPhase.driverToPickup;
        case BookingStatus.onTrip:
          return TripNavPhase.enRoute;
        case BookingStatus.completed:
          return TripNavPhase.completed;
        case BookingStatus.cancelled:
          return TripNavPhase.cancelled;
        case BookingStatus.failed:
          return null;
      }
    }
    final ride = payload['ride'];
    final raw = (payload['phase'] ?? payload['status'] ?? payload['state'] ?? (ride is Map ? ride['status'] : null))?.toString() ?? '';
    return _phaseFromString(raw);
  }

  int? _coerceStopIndex(Map<String, dynamic> payload, dynamic rawEvent) {
    final top = payload['stop_index'] ?? payload['waypoint_index'] ?? payload['active_stop_index'];
    if (top != null) return int.tryParse(top.toString());
    return null;
  }

  LatLng? _validLL(double? lat, double? lng) {
    if (lat == null || lng == null || !lat.isFinite || !lng.isFinite) return null;
    if (lat.abs() > 90 || lng.abs() > 180 || (lat == 0 && lng == 0)) return null;
    return LatLng(lat, lng);
  }

  LatLng? _coerceDriverLL(Map<String, dynamic> payload, dynamic rawEvent) {
    double? p(dynamic v) => v == null ? null : double.tryParse(v.toString());
    final ll = _validLL(
      p(payload['driver_lat'] ?? payload['driverLat'] ?? payload['lat'] ?? payload['latitude']),
      p(payload['driver_lng'] ?? payload['driverLng'] ?? payload['lng'] ?? payload['longitude']),
    );
    if (ll != null) return ll;
    final driver = payload['driver'];
    if (driver is Map) {
      return _validLL(p(driver['lat'] ?? driver['latitude']), p(driver['lng'] ?? driver['longitude']));
    }
    return null;
  }

  LatLng? _coerceRiderLL(Map<String, dynamic> payload) {
    double? p(dynamic v) => v == null ? null : double.tryParse(v.toString());
    // NB: pickup_lat/lng is the pickup point, not the rider's live position.
    return _validLL(
      p(payload['rider_lat'] ?? payload['riderLat'] ?? payload['user_lat']),
      p(payload['rider_lng'] ?? payload['riderLng'] ?? payload['user_lng']),
    );
  }

  LatLngBounds _boundsFrom(List<LatLng> pts) {
    if (pts.isEmpty) return RoutingEngine.computeSmartBounds([widget.args.pickup, widget.args.destination]);
    return RoutingEngine.computeSmartBounds(pts);
  }

  String _fmtDistance(int m) => m < 1000 ? '$m m' : '${(m / 1000).toStringAsFixed(1)} km';
  String _fmtDuration(int s) {
    final mins = (s / 60).round();
    if (mins < 1) return '<1m';
    return mins < 60 ? '${mins}m' : '${mins ~/ 60}h ${mins % 60}m';
  }

  String _phaseLabel() {
    if (_isDriver) {
      switch (_phase) {
        case TripNavPhase.driverToPickup:
          return 'TO PICKUP';
        case TripNavPhase.waitingPickup:
          return 'AT PICKUP';
        case TripNavPhase.enRoute:
          return 'TO DESTINATION';
        case TripNavPhase.arrivedDestination:
          return 'AT DESTINATION';
        case TripNavPhase.completed:
          return 'COMPLETED';
        case TripNavPhase.cancelled:
          return 'CANCELLED';
      }
    }
    switch (_phase) {
      case TripNavPhase.driverToPickup:
        return 'DRIVER ARRIVING';
      case TripNavPhase.waitingPickup:
        return 'PICKUP READY';
      case TripNavPhase.enRoute:
        return 'ON TRIP';
      case TripNavPhase.arrivedDestination:
        return 'ARRIVED';
      case TripNavPhase.completed:
        return 'COMPLETED';
      case TripNavPhase.cancelled:
        return 'CANCELLED';
    }
  }

  EdgeInsets _calcMapPadding(MediaQueryData mq, UIScale ui) {
    final bool showLandscapePanel = ui.landscape;
    final double landscapePanelWidth = showLandscapePanel ? (mq.size.width * 0.35).clamp(320.0, 400.0) : 0;
    final following = _viewMode == NavigationViewMode.navigation;
    return EdgeInsets.only(
      // A taller top padding in follow mode places the car in the lower part
      // of the visible map so more road ahead is visible.
      top: mq.padding.top + ui.gap(following ? 140 : 60),
      left: showLandscapePanel ? landscapePanelWidth + ui.inset(16) : 0,
      right: ui.landscape ? ui.inset(16) : 0,
      bottom: showLandscapePanel ? ui.inset(16) : (following ? ui.gap(100) : ui.gap(180)),
    );
  }

  RouteStep? get _nextStep {
    if (_steps.isEmpty || _stepIdx >= _steps.length) return null;
    // The maneuver happens at the END of the current step, i.e. it is the
    // instruction of the following step.
    final i = (_stepIdx + 1).clamp(0, _steps.length - 1);
    return _steps[i];
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Build
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mq = MediaQuery.of(context);
    final ui = UIScale.of(context);

    final bool showLandscapePanel = ui.landscape;
    final double landscapePanelWidth = showLandscapePanel ? (mq.size.width * 0.35).clamp(320.0, 400.0) : 0;

    final padding = _calcMapPadding(mq, ui);
    if (_paddingNotifier.value != padding) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _paddingNotifier.value = padding;
      });
    }

    String? primaryLabel;
    if (_isDriver) {
      if (_phase == TripNavPhase.driverToPickup && widget.args.showArrivedPickupButton) {
        primaryLabel = 'AT PICKUP';
      } else if (_phase == TripNavPhase.waitingPickup && widget.args.showStartTripButton) {
        primaryLabel = 'START TRIP';
      } else if (_phase == TripNavPhase.enRoute && widget.args.showArrivedDestinationButton) {
        primaryLabel = 'AT DESTINATION';
      } else if (_phase == TripNavPhase.arrivedDestination && widget.args.showCompleteTripButton) {
        primaryLabel = 'COMPLETE RIDE';
      }
    }

    final double sheetInitialSize = ui.landscape ? 1.0 : (ui.tiny ? 0.38 : (ui.compact ? 0.35 : 0.32));
    final double sheetMaxSize = ui.landscape ? 1.0 : (ui.tiny ? 0.65 : 0.55);

    final next = _nextStep;
    final showTurn = _isDriver && next != null && !_isTerminal && _phase != TripNavPhase.waitingPickup && _phase != TripNavPhase.arrivedDestination;

    _mapLayer ??= _TripMapLayer(
      markersNotifier: _markersNotifier,
      polylinesNotifier: _polylinesNotifier,
      circlesNotifier: _circlesNotifier,
      paddingNotifier: _paddingNotifier,
      initialTarget: _carLL ?? _effectivePickupLL,
      onUserGesture: _onUserMapGesture,
      onMapCreated: (controller) {
        _mapController = controller;
        _paddingNotifier.value = _calcMapPadding(MediaQuery.of(context), UIScale.of(context));
        if (_isFollowCameraEnabled) {
          _lastCamTarget = null;
          _scheduleFrame();
        } else {
          _animateCamera(CameraUpdate.newLatLngBounds(_boundsFrom([if (_carLL != null) _carLL!, _currentTarget]), 90.0));
        }
      },
    );

    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: theme.scaffoldBackgroundColor,
                child: _booting ? const SizedBox.shrink() : _mapLayer,
              ),
            ),
            if (!_booting) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: ui.gap(120),
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: mq.padding.top + ui.gap(8),
                left: ui.inset(10),
                right: ui.inset(10),
                child: _SolidHeader(
                  ui: ui,
                  phaseLabel: _phaseLabel(),
                  distanceText: _distanceText ?? '—',
                  durationText: _durationText ?? '—',
                  onBack: () => Navigator.of(context).maybePop(),
                ),
              ),
              if (showTurn)
                Positioned(
                  top: mq.padding.top + ui.gap(58),
                  left: showLandscapePanel ? landscapePanelWidth + ui.inset(20) : ui.inset(10),
                  right: ui.inset(10) + ui.gap(118),
                  child: _NextTurnBanner(
                    ui: ui,
                    instruction: next.instruction.isNotEmpty ? next.instruction : 'Continue',
                    maneuver: next.maneuver,
                    distanceText: _distToManeuverM == null ? null : _fmtDistance(_distToManeuverM!.round()),
                  ),
                ),
              Positioned(
                top: mq.padding.top + ui.gap(60),
                right: ui.inset(10),
                child: _PillActionRail(
                  ui: ui,
                  isFollowCameraEnabled: _isFollowCameraEnabled,
                  onOverviewMode: _activateOverviewMode,
                  onRecenter: _recenterMap,
                ),
              ),
              if (showLandscapePanel)
                Positioned(
                  top: mq.padding.top + ui.gap(60),
                  left: ui.inset(10),
                  bottom: ui.inset(10),
                  width: landscapePanelWidth,
                  child: SafeArea(top: false, child: _SolidPanelContainer(ui: ui, child: _buildSheetContent(ui, primaryLabel))),
                )
              else
                Positioned(
                  left: ui.inset(10),
                  right: ui.inset(10),
                  bottom: ui.inset(10),
                  height: math.min(mq.size.height * 0.70, mq.size.height - (mq.padding.top + ui.gap(80))),
                  child: SafeArea(
                    top: false,
                    child: DraggableScrollableSheet(
                      expand: true,
                      initialChildSize: sheetInitialSize,
                      minChildSize: 0.15,
                      maxChildSize: sheetMaxSize,
                      builder: (ctx, controller) => _SolidPanelContainer(
                        ui: ui,
                        child: _buildSheetContent(ui, primaryLabel, controller: controller),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSheetContent(UIScale ui, String? primaryLabel, {ScrollController? controller}) {
    return _PremiumDashboardSheet(
      controller: controller,
      ui: ui,
      role: widget.args.role,
      phaseLabel: _phaseLabel(),
      rideType: widget.args.rideType,
      onSOSTap: widget.args.onSOSTap,
      driverName: widget.args.driverName ?? 'Driver',
      vehicleType: widget.args.vehicleType ?? 'Car',
      carPlate: widget.args.carPlate ?? '',
      rating: widget.args.rating ?? 0.0,
      from: widget.args.originText,
      to: widget.args.destinationText,
      currentTarget: _currentTargetText,
      distanceText: _distanceText ?? '--',
      durationText: _durationText ?? '--',
      activeStopIndex: _activeStopIndex,
      showPrimaryAction: primaryLabel != null,
      primaryLabel: primaryLabel,
      showCancelButton: widget.args.showCancelButton &&
          !_isTerminal &&
          (_isDriver || _phase == TripNavPhase.driverToPickup || _phase == TripNavPhase.waitingPickup),
      busyPrimary: _busyPrimaryAction,
      busyCancel: _busyCancel,
      primaryEnabled: (_phase == TripNavPhase.driverToPickup && _canArrivePickup) ||
          (_phase == TripNavPhase.waitingPickup && _canStartTrip) ||
          (_phase == TripNavPhase.enRoute && _canArriveDestination) ||
          (_phase == TripNavPhase.arrivedDestination && _canCompleteRide),
      onPrimaryAction: _handlePrimaryAction,
      onCancelTrip: _cancelTripPressed,
      errorText: _lastErrorText,
    );
  }
}

class _TripMapLayer extends StatelessWidget {
  final ValueNotifier<Set<Marker>> markersNotifier;
  final ValueNotifier<Set<Polyline>> polylinesNotifier;
  final ValueNotifier<Set<Circle>> circlesNotifier;
  final ValueNotifier<EdgeInsets> paddingNotifier;
  final LatLng initialTarget;
  final VoidCallback onUserGesture;
  final void Function(GoogleMapController) onMapCreated;

  const _TripMapLayer({
    required this.markersNotifier,
    required this.polylinesNotifier,
    required this.circlesNotifier,
    required this.paddingNotifier,
    required this.initialTarget,
    required this.onUserGesture,
    required this.onMapCreated,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: MapGestureSensor(
        onUserGesture: onUserGesture,
        child: ListenableBuilder(
          listenable: Listenable.merge([markersNotifier, polylinesNotifier, circlesNotifier, paddingNotifier]),
          builder: (context, _) => GoogleMap(
            initialCameraPosition: CameraPosition(target: initialTarget, zoom: 17.0, tilt: 50.0),
            style: isDark ? MapGraphicsEngine.kDarkMapStyle : null,
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: false,
            mapToolbarEnabled: false,
            buildingsEnabled: false,
            indoorViewEnabled: false,
            trafficEnabled: false,
            rotateGesturesEnabled: true,
            tiltGesturesEnabled: false,
            padding: paddingNotifier.value,
            markers: markersNotifier.value,
            polylines: polylinesNotifier.value,
            circles: circlesNotifier.value,
            onMapCreated: onMapCreated,
          ),
        ),
      ),
    );
  }
}

/// Compact turn-by-turn banner (driver role).
class _NextTurnBanner extends StatelessWidget {
  final UIScale ui;
  final String instruction;
  final String maneuver;
  final String? distanceText;

  const _NextTurnBanner({required this.ui, required this.instruction, required this.maneuver, required this.distanceText});

  static IconData iconFor(String m) {
    switch (m) {
      case 'TURN_LEFT':
        return Icons.turn_left_rounded;
      case 'TURN_RIGHT':
        return Icons.turn_right_rounded;
      case 'TURN_SLIGHT_LEFT':
        return Icons.turn_slight_left_rounded;
      case 'TURN_SLIGHT_RIGHT':
        return Icons.turn_slight_right_rounded;
      case 'TURN_SHARP_LEFT':
        return Icons.turn_sharp_left_rounded;
      case 'TURN_SHARP_RIGHT':
        return Icons.turn_sharp_right_rounded;
      case 'UTURN_LEFT':
        return Icons.u_turn_left_rounded;
      case 'UTURN_RIGHT':
        return Icons.u_turn_right_rounded;
      case 'ROUNDABOUT_LEFT':
        return Icons.roundabout_left_rounded;
      case 'ROUNDABOUT_RIGHT':
        return Icons.roundabout_right_rounded;
      case 'RAMP_LEFT':
      case 'FORK_LEFT':
        return Icons.fork_left_rounded;
      case 'RAMP_RIGHT':
      case 'FORK_RIGHT':
        return Icons.fork_right_rounded;
      case 'MERGE':
        return Icons.merge_rounded;
      case 'FERRY':
      case 'FERRY_TRAIN':
        return Icons.directions_boat_rounded;
      default:
        return Icons.straight_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(12), vertical: ui.inset(10)),
      decoration: BoxDecoration(
        color: AppColors.deep.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(ui.radius(16)),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12), width: 1.0),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: [
          Icon(iconFor(maneuver), color: Colors.white, size: ui.icon(30)),
          SizedBox(width: ui.gap(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (distanceText != null)
                  Text(distanceText!, style: TextStyle(color: Colors.white, fontSize: ui.font(16), fontWeight: FontWeight.w900, height: 1.1)),
                Text(
                  instruction,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: ui.font(11.5), fontWeight: FontWeight.w700, height: 1.2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PremiumDashboardSheet extends StatelessWidget {
  final ScrollController? controller;
  final UIScale ui;
  final TripNavigationRole role;
  final String phaseLabel;
  final String rideType;
  final VoidCallback? onSOSTap;
  final String driverName, vehicleType, carPlate;
  final double rating;
  final String from, to, currentTarget;
  final String distanceText, durationText;
  final int activeStopIndex;
  final bool showPrimaryAction;
  final String? primaryLabel;
  final bool showCancelButton, busyPrimary, busyCancel, primaryEnabled;
  final VoidCallback onPrimaryAction, onCancelTrip;
  final String? errorText;

  const _PremiumDashboardSheet({
    required this.controller,
    required this.ui,
    required this.role,
    required this.phaseLabel,
    required this.rideType,
    this.onSOSTap,
    required this.driverName,
    required this.vehicleType,
    required this.carPlate,
    required this.rating,
    required this.from,
    required this.to,
    required this.currentTarget,
    required this.distanceText,
    required this.durationText,
    required this.activeStopIndex,
    required this.showPrimaryAction,
    required this.primaryLabel,
    required this.showCancelButton,
    required this.busyPrimary,
    required this.busyCancel,
    required this.primaryEnabled,
    required this.onPrimaryAction,
    required this.onCancelTrip,
    required this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    final Color os = Theme.of(context).colorScheme.onSurface;
    final String modeLabel =
    role == TripNavigationRole.driver ? "DRIVER COMMAND" : "RIDER MODE";
    final String profileTitle =
    role == TripNavigationRole.driver ? "YOUR RIDER" : "YOUR DRIVER";

    final List<Widget> content = [
      if (controller != null) ...[
        SizedBox(height: ui.gap(10)),
        Center(
            child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: os.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2)))),
        SizedBox(height: ui.gap(12))
      ] else
        SizedBox(height: ui.gap(12)),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Container(
            padding: EdgeInsets.symmetric(
                horizontal: ui.inset(8), vertical: ui.inset(4)),
            decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6)),
            child: Text("$modeLabel • ${rideType.toUpperCase()}",
                style: TextStyle(
                    color: AppColors.primary,
                    fontSize: ui.font(8.5),
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5))),
        GestureDetector(
            onTap: onSOSTap ?? () {},
            child: Container(
                padding: EdgeInsets.symmetric(
                    horizontal: ui.inset(10), vertical: ui.inset(4)),
                decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    border: Border.all(
                        color: Colors.red.withValues(alpha: 0.5), width: 1.0),
                    borderRadius: BorderRadius.circular(16)),
                child: Row(children: [
                  Icon(Icons.emergency_share_rounded,
                      color: Colors.red, size: ui.icon(14)),
                  SizedBox(width: ui.gap(4)),
                  Text("SOS",
                      style: TextStyle(
                          color: Colors.red,
                          fontSize: ui.font(10),
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5))
                ]))),
      ]),
      SizedBox(height: ui.gap(12)),
      Text(profileTitle,
          style: TextStyle(
              color: os.withValues(alpha: 0.5),
              fontSize: ui.font(8.5),
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5)),
      SizedBox(height: ui.gap(6)),
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        CircleAvatar(
            radius: ui.font(18),
            backgroundColor: AppColors.primary.withValues(alpha: 0.15),
            child:
            Icon(Icons.person, color: AppColors.primary, size: ui.icon(18))),
        SizedBox(width: ui.gap(10)),
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(driverName.toUpperCase(),
                      style: TextStyle(
                          color: os,
                          fontSize: ui.font(14),
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.2)),
                  SizedBox(height: ui.gap(2)),
                  Text(vehicleType,
                      style: TextStyle(
                          color: os.withValues(alpha: 0.6),
                          fontSize: ui.font(10),
                          fontWeight: FontWeight.w600))
                ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (rating > 0)
            Container(
                padding: EdgeInsets.symmetric(
                    horizontal: ui.inset(6), vertical: ui.inset(3)),
                decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Icon(Icons.star_rounded,
                      color: Colors.amber, size: ui.icon(12)),
                  SizedBox(width: ui.gap(2)),
                  Text(rating.toStringAsFixed(1),
                      style: TextStyle(
                          color: Colors.amber,
                          fontWeight: FontWeight.w800,
                          fontSize: ui.font(10)))
                ])),
          if (rating > 0) SizedBox(height: ui.gap(6)),
          if (carPlate.isNotEmpty)
            Container(
                padding: EdgeInsets.symmetric(
                    horizontal: ui.inset(6), vertical: ui.inset(3)),
                decoration: BoxDecoration(
                    color: const Color(0xFFFACC15),
                    borderRadius: BorderRadius.circular(4),
                    border:
                    Border.all(color: Colors.black87, width: 1.0)),
                child: Text(carPlate.toUpperCase(),
                    style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w900,
                        fontSize: ui.font(10),
                        letterSpacing: 1.0)))
        ])
      ]),
      SizedBox(height: ui.gap(16)),
      Container(
          padding: EdgeInsets.all(ui.inset(12)),
          decoration: BoxDecoration(
              gradient: LinearGradient(
                  colors: [AppColors.primary, AppColors.primary.withValues(alpha: 0.8)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(ui.radius(14))),
          child: Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('CURRENT TARGET',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontSize: ui.font(8.5),
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5)),
                      SizedBox(height: ui.gap(4)),
                      Text(currentTarget,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: ui.font(13),
                              fontWeight: FontWeight.w800))
                    ])),
            Container(
                width: 1,
                height: 24,
                color: Colors.white.withValues(alpha: 0.3),
                margin: EdgeInsets.symmetric(horizontal: ui.inset(10))),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(durationText,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: ui.font(16),
                      fontWeight: FontWeight.w900,
                      height: 1.0)),
              Text(distanceText,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: ui.font(9.5),
                      fontWeight: FontWeight.w700))
            ])
          ])),
      SizedBox(height: ui.gap(16)),
      Text('TRIP ROUTE',
          style: TextStyle(
              color: os.withValues(alpha: 0.5),
              fontSize: ui.font(8.5),
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5)),
      SizedBox(height: ui.gap(8)),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(children: [
          Icon(Icons.radio_button_checked,
              color: AppColors.primary, size: ui.icon(14)),
          Container(
              width: 1.5,
              height: ui.gap(18),
              color: os.withValues(alpha: 0.15)),
          Icon(Icons.location_on, color: Colors.green, size: ui.icon(14))
        ]),
        SizedBox(width: ui.gap(10)),
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(from,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: os,
                          fontSize: ui.font(11.5),
                          fontWeight: FontWeight.w700)),
                  SizedBox(height: ui.gap(16)),
                  Text(to,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: os,
                          fontSize: ui.font(11.5),
                          fontWeight: FontWeight.w700))
                ]))
      ]),
      if (errorText != null && errorText!.trim().isNotEmpty) ...[
        SizedBox(height: ui.gap(16)),
        Container(
            padding: EdgeInsets.all(ui.inset(10)),
            decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(ui.radius(10)),
                border: Border.all(
                    color: AppColors.error.withValues(alpha: 0.3))),
            child: Row(children: [
              Icon(Icons.error_outline_rounded,
                  color: AppColors.error, size: ui.icon(14)),
              SizedBox(width: ui.gap(6)),
              Expanded(
                  child: Text(errorText!,
                      style: TextStyle(
                          color: AppColors.error,
                          fontWeight: FontWeight.w800,
                          fontSize: ui.font(10))))
            ]))
      ],
      SizedBox(height: ui.gap(20)),
      Row(children: [
        if (showPrimaryAction)
          Expanded(
              flex: 2,
              child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _PremiumButton(
                      key: ValueKey(primaryLabel ?? 'ACTION'),
                      label: primaryLabel ?? 'ACTION',
                      isLoading: busyPrimary,
                      isDisabled: !primaryEnabled,
                      isPrimary: true,
                      onTap: onPrimaryAction,
                      ui: ui))),
        if (showPrimaryAction && showCancelButton) SizedBox(width: ui.gap(10)),
        if (showCancelButton)
          Expanded(
              flex: 1,
              child: _PremiumButton(
                  label: 'CANCEL',
                  isLoading: busyCancel,
                  isDisabled: false,
                  isPrimary: false,
                  onTap: onCancelTrip,
                  ui: ui))
      ]),
      SizedBox(height: ui.gap(16)),
    ];

    return controller != null
        ? ListView(
        controller: controller,
        padding: EdgeInsets.symmetric(horizontal: ui.inset(16)),
        children: content)
        : SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: ui.inset(16)),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: content));
  }
}

class _PremiumButton extends StatelessWidget {
  final String label;
  final bool isLoading, isDisabled, isPrimary;
  final VoidCallback onTap;
  final UIScale ui;

  const _PremiumButton({
    super.key,
    required this.label,
    required this.isLoading,
    this.isDisabled = false,
    required this.isPrimary,
    required this.onTap,
    required this.ui,
  });

  @override
  Widget build(BuildContext context) {
    final os = Theme.of(context).colorScheme.onSurface;
    final bool disabled = isLoading || isDisabled;
    return GestureDetector(
        onTap: disabled ? null : onTap,
        child: Container(
            height: ui.gap(44),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                gradient: isPrimary
                    ? LinearGradient(colors: [
                  disabled
                      ? AppColors.primary.withValues(alpha: 0.4)
                      : AppColors.primary,
                  disabled
                      ? AppColors.primary.withValues(alpha: 0.4)
                      : AppColors.primary.withRed(100)
                ])
                    : null,
                color: !isPrimary ? Colors.transparent : null,
                borderRadius: BorderRadius.circular(ui.radius(12)),
                border: Border.all(
                    color: isPrimary
                        ? Colors.transparent
                        : os.withValues(alpha: 0.2),
                    width: 1.0)),
            child: isLoading
                ? SizedBox(
                width: ui.gap(16),
                height: ui.gap(16),
                child: CircularProgressIndicator(
                    strokeWidth: 2.0,
                    color: isPrimary ? Colors.white : os))
                : Text(label,
                style: TextStyle(
                    color: isPrimary
                        ? Colors.white.withValues(alpha: disabled ? 0.7 : 1.0)
                        : os.withValues(alpha: disabled ? 0.5 : 0.9),
                    fontSize: ui.font(12.5),
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5))));
  }
}

class _SolidPanelContainer extends StatelessWidget {
  final Widget child;
  final UIScale ui;

  const _SolidPanelContainer({required this.child, required this.ui});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
        decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? cs.surface
                : Colors.white,
            borderRadius: BorderRadius.circular(ui.radius(20)),
            border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.3), width: 1.0)),
        child: ClipRRect(
            borderRadius: BorderRadius.circular(ui.radius(20)),
            child: child));
  }
}

class _SolidHeader extends StatelessWidget {
  final UIScale ui;
  final String phaseLabel, distanceText, durationText;
  final VoidCallback onBack;

  const _SolidHeader({
    required this.ui,
    required this.phaseLabel,
    required this.distanceText,
    required this.durationText,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
        height: ui.gap(44),
        padding: EdgeInsets.symmetric(horizontal: ui.inset(8)),
        decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(ui.radius(16)),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.15), width: 1.0)),
        child: Row(children: [
          IconButton(
              onPressed: onBack,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: Icon(Icons.close_rounded,
                  color: Colors.white, size: ui.icon(16))),
          SizedBox(width: ui.gap(10)),
          Container(
              width: 1,
              height: ui.gap(20),
              color: Colors.white.withValues(alpha: 0.2)),
          SizedBox(width: ui.gap(10)),
          Icon(Icons.directions_car_rounded,
              color: AppColors.primary, size: ui.icon(14)),
          SizedBox(width: ui.gap(6)),
          Expanded(
              child: Text(phaseLabel,
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: ui.font(11.5),
                      letterSpacing: 0.2))),
          Container(
              width: 1,
              height: ui.gap(20),
              color: Colors.white.withValues(alpha: 0.2)),
          SizedBox(width: ui.gap(10)),
          Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(durationText,
                    style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: ui.font(14),
                        height: 1.1)),
                Text(distanceText,
                    style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w700,
                        fontSize: ui.font(9.5),
                        height: 1.1))
              ])
        ]));
  }
}

class _PillActionRail extends StatelessWidget {
  final bool isFollowCameraEnabled;
  final VoidCallback onOverviewMode, onRecenter;
  final UIScale ui;

  const _PillActionRail({
    required this.isFollowCameraEnabled,
    required this.onOverviewMode,
    required this.onRecenter,
    required this.ui,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _ActionPill(
              icon: Icons.map_rounded,
              label: 'Overview',
              isActive: !isFollowCameraEnabled,
              onTap: onOverviewMode,
              ui: ui),
          SizedBox(height: ui.gap(8)),
          _ActionPill(
              icon: isFollowCameraEnabled
                  ? Icons.lock_rounded
                  : Icons.my_location_rounded,
              label: isFollowCameraEnabled ? 'Locked' : 'Re-center',
              isActive: isFollowCameraEnabled,
              onTap: isFollowCameraEnabled
                  ? null // already locked, do nothing
                  : onRecenter,
              ui: ui),
        ]);
  }
}

class _ActionPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback? onTap;
  final UIScale ui;

  const _ActionPill({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
    required this.ui,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
        onTap: onTap,
        child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: ui.inset(12), vertical: ui.inset(8)),
            decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(ui.radius(16)),
                border: Border.all(
                    color: isActive
                        ? AppColors.primary.withValues(alpha: 0.8)
                        : Colors.white.withValues(alpha: 0.15),
                    width: 1.0)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon,
                  color: isActive ? AppColors.primary : Colors.white70,
                  size: ui.icon(14)),
              SizedBox(width: ui.gap(8)),
              Text(label,
                  style: TextStyle(
                      color: isActive ? Colors.white : Colors.white70,
                      fontSize: ui.font(11.5),
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.2))
            ])));
  }
}
