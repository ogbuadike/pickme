// lib/screens/trip_navigation_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../api/url.dart';
import '../services/booking_controller.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../utility/notification.dart';

enum TripNavigationRole { rider, driver }
enum TripNavPhase { driverToPickup, waitingPickup, enRoute, arrivedDestination, completed, cancelled }
enum NavigationViewMode { navigation, atAGlance }

// --- PURE DART KALMAN FILTER ---
class _Kalman1D {
  final double q;
  final double r;
  double x;
  double p;
  double k;

  _Kalman1D({this.q = 0.5, this.r = 3.0, required this.x, this.p = 1.0, this.k = 0.0});

  double update(double measurement) {
    p = p + q;
    k = p / (p + r);
    x = x + k * (measurement - x);
    p = (1 - k) * p;
    return x;
  }
}

class TripNavigationArgs {
  final String userId, driverId, tripId;
  final LatLng pickup, destination;
  final List<LatLng> dropOffs;
  final String originText, destinationText;
  final List<String> dropOffTexts;

  // New Additions for Advanced UI
  final String rideType;
  final VoidCallback? onSOSTap;

  final String? driverName, vehicleType, carPlate;
  final double? rating;
  final LatLng? initialDriverLocation, initialRiderLocation;
  final TripNavPhase initialPhase;
  final Stream<dynamic>? bookingUpdates;
  final Future<Map<String, dynamic>?> Function()? liveSnapshotProvider;
  final Future<void> Function()? onStartTrip, onCancelTrip, onArrivedPickup, onArrivedDestination, onCompleteTrip;
  final TripNavigationRole role;
  final Duration tickEvery, routeMinGap;
  final double arrivalMeters, routeMoveThresholdMeters;
  final bool autoFollowCamera, showStartTripButton, showCancelButton, showMetaCard, showDebugPanel;
  final bool enableLivePickupTracking, preserveStopOrder, autoCloseOnCancel;
  final bool showArrivedPickupButton, showArrivedDestinationButton, showCompleteTripButton;

  const TripNavigationArgs({
    required this.userId, required this.driverId, required this.tripId, required this.pickup, required this.destination,
    this.dropOffs = const [], required this.originText, required this.destinationText, this.dropOffTexts = const [],
    this.rideType = 'Standard Ride', this.onSOSTap,
    this.driverName, this.vehicleType, this.carPlate, this.rating, this.initialDriverLocation, this.initialRiderLocation,
    this.initialPhase = TripNavPhase.driverToPickup, this.bookingUpdates, this.liveSnapshotProvider,
    this.onStartTrip, this.onCancelTrip, this.onArrivedPickup, this.onArrivedDestination, this.onCompleteTrip,
    this.role = TripNavigationRole.rider, this.tickEvery = const Duration(seconds: 1), this.routeMinGap = const Duration(seconds: 20),
    this.arrivalMeters = 150.0, this.routeMoveThresholdMeters = 25.0, this.autoFollowCamera = true,
    this.showStartTripButton = true, this.showCancelButton = true, this.showMetaCard = true, this.showDebugPanel = false,
    this.enableLivePickupTracking = false, this.preserveStopOrder = true, this.autoCloseOnCancel = true,
    this.showArrivedPickupButton = true, this.showArrivedDestinationButton = true, this.showCompleteTripButton = true,
  });
}

class TripNavigationPage extends StatefulWidget {
  final TripNavigationArgs args;
  const TripNavigationPage({super.key, required this.args});

  @override
  State<TripNavigationPage> createState() => _TripNavigationPageState();
}

class _TripNavigationPageState extends State<TripNavigationPage> with TickerProviderStateMixin, WidgetsBindingObserver {

  // --- ISOLATED MAP LAYER NOTIFIERS ---
  final ValueNotifier<Set<Marker>> _markersNotifier = ValueNotifier({});
  final ValueNotifier<Set<Polyline>> _polylinesNotifier = ValueNotifier({});
  GoogleMapController? _mapController;

  StreamSubscription<dynamic>? _bookingSub;
  StreamSubscription<CompassEvent>? _compassSub;
  Timer? _tickTimer;
  Timer? _compassThrottleTimer;

  Set<Marker> _staticMarkers = {};
  Set<Marker> _dynamicMarkers = {};
  Set<Polyline> _polylines = {};

  BitmapDescriptor? _driverIcon, _pickupIcon, _dropIcon, _riderIcon, _waypointIcon;

  // --- 60FPS GLIDE ENGINE ---
  AnimationController? _glideController;
  CurvedAnimation? _glideCurve;
  LatLng? _rawDriverLL, _animStartLL, _animTargetLL, _displayDriverLL;
  LatLng? _riderLL;

  // --- FILTER STATE ---
  _Kalman1D? _latKalman;
  _Kalman1D? _lngKalman;
  final List<LatLng> _recentPositions = [];
  LatLng? _stationaryAnchor;
  DateTime _lastLocationTime = DateTime.now();

  // --- SPLIT HEADING EMA ---
  double _backendDriverHeading = 0.0;
  double? _localHardwareHeading;
  double _carIconHeading = 0.0;
  double _cameraBearingEMA = 0.0;

  TripNavPhase _phase = TripNavPhase.driverToPickup;
  TripNavPhase? _optimisticPhase;
  DateTime? _optimisticPhaseSetAt;
  int _activeStopIndex = 0;

  NavigationViewMode _viewMode = NavigationViewMode.navigation;
  bool _isFollowCameraEnabled = true;
  bool _isProgrammaticCameraMove = false;
  bool _userIsPanning = false;
  bool _booting = true;

  // --- DIRTY FLAG STATE ---
  String? _distanceText, _durationText, _lastErrorText;
  bool _uiNeedsRebuild = false;

  bool _busyRoute = false, _busyTick = false, _busyPrimaryAction = false, _busyCancel = false, _didInitialFit = false;
  bool _canArrivePickup = false, _canStartTrip = false, _canArriveDestination = false, _canCompleteRide = false;

  DateTime _lastRouteAt = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _lastDriverRouteLL;
  List<LatLng> _latestRoutePoints = [];

  Duration get _tickEvery => widget.args.tickEvery;
  Duration get _routeMinGap => widget.args.routeMinGap;
  double get _arrivalMeters => widget.args.arrivalMeters > 0 ? widget.args.arrivalMeters : 150.0;
  double get _routeMoveThresholdMeters => widget.args.routeMoveThresholdMeters > 0 ? widget.args.routeMoveThresholdMeters : 25.0;
  List<LatLng> get _allTargets => [...widget.args.dropOffs, widget.args.destination];
  List<String> get _allTargetTexts => [...widget.args.dropOffTexts, widget.args.destinationText];
  LatLng get _effectivePickupLL => (widget.args.enableLivePickupTracking && _riderLL != null) ? _riderLL! : widget.args.pickup;

  LatLng get _currentTarget {
    if (_phase == TripNavPhase.driverToPickup || _phase == TripNavPhase.waitingPickup) return _effectivePickupLL;
    if (_allTargets.isEmpty) return widget.args.destination;
    return _allTargets[_activeStopIndex.clamp(0, _allTargets.length - 1)];
  }

  String get _currentTargetText {
    if (_phase == TripNavPhase.driverToPickup || _phase == TripNavPhase.waitingPickup) return widget.args.originText;
    if (_allTargetTexts.isEmpty) return widget.args.destinationText;
    return _allTargetTexts[_activeStopIndex.clamp(0, _allTargetTexts.length - 1)];
  }

  LatLng? get _enRouteOrigin {
    if (_phase != TripNavPhase.enRoute && _phase != TripNavPhase.arrivedDestination) return _displayDriverLL;
    if (widget.args.role == TripNavigationRole.rider && _riderLL != null && _displayDriverLL != null) {
      if (_haversine(_riderLL!, _displayDriverLL!) <= 120.0) return _riderLL!;
    }
    return _displayDriverLL ?? _riderLL;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _rawDriverLL = widget.args.initialDriverLocation;
    _displayDriverLL = _rawDriverLL;
    _riderLL = widget.args.initialRiderLocation ?? widget.args.pickup;
    _phase = widget.args.initialPhase;
    _isFollowCameraEnabled = widget.args.autoFollowCamera;

    if (_rawDriverLL != null) {
      _latKalman = _Kalman1D(x: _rawDriverLL!.latitude);
      _lngKalman = _Kalman1D(x: _rawDriverLL!.longitude);
      _carIconHeading = _bearingBetween(_rawDriverLL!, _currentTarget);
      _cameraBearingEMA = _carIconHeading;
    }

    _glideController = AnimationController(vsync: this, duration: _tickEvery);
    _glideCurve = CurvedAnimation(parent: _glideController!, curve: Curves.easeInOutCubic);
    _glideCurve!.addListener(_onGlideTick);

    _bootstrap();
  }

  void _pushMapState() {
    _markersNotifier.value = {..._staticMarkers, ..._dynamicMarkers};
    _polylinesNotifier.value = _polylines;
  }

  void _onGlideTick() {
    if (_animStartLL != null && _animTargetLL != null) {
      final double t = _glideCurve!.value;
      final double lat = _animStartLL!.latitude + (_animTargetLL!.latitude - _animStartLL!.latitude) * t;
      final double lng = _animStartLL!.longitude + (_animTargetLL!.longitude - _animStartLL!.longitude) * t;

      _displayDriverLL = LatLng(lat, lng);

      _updateDynamicMarkers();
      _pushMapState();

      if (_isFollowCameraEnabled && _viewMode == NavigationViewMode.navigation) {
        _followCamera();
      }
    }
  }

  Future<void> _bootstrap() async {
    if (mounted) setState(() => _booting = true);
    await _preloadIcons();
    _prebuildStaticMarkers();
    _pushMapState();

    _listenBooking();
    _startHardwareCompass();

    _tickTimer = Timer.periodic(_tickEvery, (_) => _tick());
    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted) return;
    _recomputePermissions();
    setState(() => _booting = false);
    _tick(force: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bookingSub?.cancel();
    _compassSub?.cancel();
    _tickTimer?.cancel();
    _compassThrottleTimer?.cancel();
    _glideController?.dispose();
    _glideCurve?.dispose();
    _markersNotifier.dispose();
    _polylinesNotifier.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _tick(force: true);
  }

  void _startHardwareCompass() {
    _compassSub?.cancel();
    _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
      if (event.heading == null) return;
      _localHardwareHeading = (event.heading! % 360.0 + 360.0) % 360.0;

      if (_compassThrottleTimer?.isActive ?? false) return;
      _compassThrottleTimer = Timer(const Duration(milliseconds: 33), () {
        if (!mounted || _userIsPanning) return;
        if (_viewMode == NavigationViewMode.navigation && _isFollowCameraEnabled) {
          _followCamera();
        }
      });
    });
  }

  Future<void> _preloadIcons() async {
    try { await Future.wait([_loadDriverIcon(), _loadPointIcons()]); } catch (_) {}
  }

  Future<void> _loadDriverIcon() async {
    if (_driverIcon != null) return;
    try {
      final ByteData bd = await rootBundle.load('assets/images/open_top_view_car.png');
      final ui.Codec codec = await ui.instantiateImageCodec(bd.buffer.asUint8List(), targetWidth: 96);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ByteData? png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (png != null) _driverIcon = BitmapDescriptor.fromBytes(png.buffer.asUint8List());
    } catch (_) {
      _driverIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet);
    }
  }

  Future<void> _loadPointIcons() async {
    _pickupIcon ??= await _buildRingDotMarker(const Color(0xFF1A73E8));
    _dropIcon ??= await _buildRingDotMarker(const Color(0xFF00A651));
    _riderIcon ??= await _buildRingDotMarker(const Color(0xFFE91E63));
    _waypointIcon ??= await _buildRingDotMarker(const Color(0xFFFF9800));
  }

  Future<BitmapDescriptor> _buildRingDotMarker(Color color) async {
    const double size = 56.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = const Offset(size / 2, size / 2);

    canvas.drawCircle(center + const Offset(0, 3), 14, Paint()..color = Colors.black.withOpacity(0.3)..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 5));
    canvas.drawCircle(center, 14, Paint()..color = Colors.white);
    canvas.drawCircle(center, 14, Paint()..style = PaintingStyle.stroke..strokeWidth = 4..color = color);
    canvas.drawCircle(center, 5.0, Paint()..color = color);

    final img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  void _prebuildStaticMarkers() {
    _staticMarkers = {
      if (!(widget.args.enableLivePickupTracking && _riderLL != null))
        Marker(markerId: const MarkerId('pickup'), position: widget.args.pickup, icon: _pickupIcon!, anchor: const Offset(0.5, 0.5), zIndex: 35),
      Marker(markerId: const MarkerId('destination'), position: widget.args.destination, icon: _dropIcon!, anchor: const Offset(0.5, 0.5), zIndex: 35),
      for (int i = 0; i < widget.args.dropOffs.length; i++)
        Marker(markerId: MarkerId('drop_$i'), position: widget.args.dropOffs[i], icon: _waypointIcon!, anchor: const Offset(0.5, 0.5), zIndex: 34)
    };
  }

  void _updateDynamicMarkers() {
    _dynamicMarkers = {
      if (_displayDriverLL != null)
        Marker(
            markerId: const MarkerId('driver'), position: _displayDriverLL!, icon: _driverIcon!,
            anchor: const Offset(0.5, 0.5), flat: true, rotation: _smoothCarRotation(), zIndex: 50
        ),
      if (_riderLL != null)
        Marker(markerId: const MarkerId('rider_live'), position: _riderLL!, icon: _riderIcon!, anchor: const Offset(0.5, 0.5), zIndex: 45)
    };
  }

  void _listenBooking() {
    if (widget.args.bookingUpdates == null) return;
    _bookingSub?.cancel();
    _bookingSub = widget.args.bookingUpdates!.listen((event) => _applyIncoming(event, trustPhase: true), cancelOnError: false);
  }

  Future<void> _tick({bool force = false}) async {
    if (!mounted || _busyTick || _booting) return;
    _busyTick = true;
    _uiNeedsRebuild = false;

    try {
      await _applyLiveSnapshot();
      _recomputePermissions();
      _updateDynamicMarkers();
      await _rebuildRoute(force: force);

      if (!_userIsPanning && !_glideController!.isAnimating) _followCamera();

      _pushMapState();

      if (_uiNeedsRebuild && mounted) setState(() {});
    } finally {
      _busyTick = false;
    }
  }

  Future<void> _applyLiveSnapshot() async {
    if (widget.args.liveSnapshotProvider == null) return;
    try {
      final snap = await widget.args.liveSnapshotProvider!.call();
      if (snap != null && snap.isNotEmpty) _applyIncoming(snap, trustPhase: false);
    } catch (_) {}
  }

  void _applyIncoming(dynamic event, {bool trustPhase = true}) {
    final payload = _eventMap(event);
    if (payload.isEmpty) return;

    if (event is BookingUpdate && event.status == BookingStatus.failed) {
      _emitError(event.displayMessage.isNotEmpty ? event.displayMessage : 'Trip issue.');
      return;
    }

    final rawNew = _coerceDriverLL(payload, event);
    final now = DateTime.now();

    if (rawNew != null) {
      if (_rawDriverLL == null) {
        _rawDriverLL = rawNew;
        _latKalman = _Kalman1D(x: rawNew.latitude);
        _lngKalman = _Kalman1D(x: rawNew.longitude);
      } else {
        double distMeters = _haversine(_rawDriverLL!, rawNew);
        double timeSecs = now.difference(_lastLocationTime).inMilliseconds / 1000.0;
        if (timeSecs > 0 && (distMeters / timeSecs) > 70.0) {
          // Reject impossible speeds
        } else {
          double fLat = _latKalman!.update(rawNew.latitude);
          double fLng = _lngKalman!.update(rawNew.longitude);
          LatLng filtered = LatLng(fLat, fLng);

          _recentPositions.add(filtered);
          if (_recentPositions.length > 3) _recentPositions.removeAt(0);

          if (_recentPositions.length == 3 && _isStationary(_recentPositions, 5.0)) {
            _stationaryAnchor ??= filtered;
            filtered = _stationaryAnchor!;
          } else {
            _stationaryAnchor = null;
          }

          if (filtered != _rawDriverLL) {
            _animStartLL = _displayDriverLL ?? _rawDriverLL;
            _animTargetLL = filtered;
            _rawDriverLL = filtered;
            _glideController?.forward(from: 0.0);
          }
        }
      }
      _lastLocationTime = now;
    }

    final rider = _coerceRiderLL(payload, event);
    if (rider != null) _riderLL = rider;

    final heading = _coerceHeading(payload, event);
    if (heading != null) _backendDriverHeading = heading;

    TripNavPhase? nextPhase = _coercePhase(payload, event);
    if (nextPhase != null && nextPhase != _phase) {
      if (!trustPhase && _optimisticPhase != null && _optimisticPhaseSetAt != null &&
          now.difference(_optimisticPhaseSetAt!) < const Duration(seconds: 4)) {
        nextPhase = _phase;
      } else {
        _optimisticPhase = null;
        _optimisticPhaseSetAt = null;
      }
    }

    if (nextPhase != null && nextPhase != _phase) {
      _phase = nextPhase;
      _didInitialFit = false;
      _lastDriverRouteLL = null;
      _uiNeedsRebuild = true;
    }

    final stopIndex = _coerceStopIndex(payload, event);
    if (stopIndex != null && _allTargets.isNotEmpty && _activeStopIndex != stopIndex) {
      _activeStopIndex = stopIndex.clamp(0, _allTargets.length - 1);
      _uiNeedsRebuild = true;
    }

    _prebuildStaticMarkers();
  }

  bool _isStationary(List<LatLng> positions, double threshold) {
    for (int i = 0; i < positions.length - 1; i++) {
      if (_haversine(positions[i], positions[i + 1]) > threshold) return false;
    }
    return true;
  }

  void _emitError(String message) {
    if (_lastErrorText != message) {
      _lastErrorText = message;
      _uiNeedsRebuild = true;
    }
  }

  void _recomputePermissions() {
    if (_displayDriverLL == null) return;

    final safeArrival = math.max(_arrivalMeters, 150.0);
    bool cAP = _phase == TripNavPhase.driverToPickup && _haversine(_displayDriverLL!, _effectivePickupLL) <= safeArrival;
    bool cST = _phase == TripNavPhase.waitingPickup && _haversine(_displayDriverLL!, _effectivePickupLL) <= safeArrival;
    bool cAD = _phase == TripNavPhase.enRoute && _haversine(_displayDriverLL!, _currentTarget) <= safeArrival;
    bool cCR = _phase == TripNavPhase.arrivedDestination && _haversine(_displayDriverLL!, _currentTarget) <= math.max(_arrivalMeters + 50.0, 200.0);

    if (_canArrivePickup != cAP || _canStartTrip != cST || _canArriveDestination != cAD || _canCompleteRide != cCR) {
      _canArrivePickup = cAP; _canStartTrip = cST; _canArriveDestination = cAD; _canCompleteRide = cCR;
      _uiNeedsRebuild = true;
    }
  }

  double _smoothCarRotation() {
    if (_displayDriverLL == null) return _carIconHeading;
    double target = (_backendDriverHeading > 0) ? _backendDriverHeading :
    (_animStartLL != null && _animTargetLL != null && _haversine(_animStartLL!, _animTargetLL!) > 1.5)
        ? _bearingBetween(_animStartLL!, _animTargetLL!) : _carIconHeading;

    double diff = target - _carIconHeading;
    while (diff < -180.0) diff += 360.0;
    while (diff > 180.0) diff -= 360.0;
    _carIconHeading += diff * 0.22;
    return _carIconHeading;
  }

  Future<void> _rebuildRoute({bool force = false}) async {
    if (_busyRoute || _phase == TripNavPhase.completed || _phase == TripNavPhase.cancelled) return;
    final from = (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? _enRouteOrigin : _displayDriverLL;
    final to = (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? _currentTarget : _effectivePickupLL;
    if (from == null || to == null) return;

    if (!force && DateTime.now().difference(_lastRouteAt) < _routeMinGap) {
      if (_lastDriverRouteLL != null && _haversine(_lastDriverRouteLL!, from) < _routeMoveThresholdMeters) return;
    }

    _busyRoute = true;
    _lastRouteAt = DateTime.now();
    _lastDriverRouteLL = from;

    try {
      final route = await _computeRoute(from, to);
      if (route == null || route.points.isEmpty) return;

      final dist = _fmtDistance(route.distanceMeters);
      final dur = _fmtDuration(route.durationSeconds);
      if (_distanceText != dist || _durationText != dur) {
        _distanceText = dist;
        _durationText = dur;
        _uiNeedsRebuild = true;
      }

      final isDark = Theme.of(context).brightness == Brightness.dark;
      _polylines = {
        Polyline(polylineId: const PolylineId('halo'), points: [from, ...route.points, to], color: isDark ? Colors.white.withOpacity(0.9) : Colors.black.withOpacity(0.85), width: 10, jointType: JointType.round, startCap: Cap.roundCap, endCap: Cap.roundCap),
        Polyline(polylineId: const PolylineId('main'), points: [from, ...route.points, to], color: AppColors.primary, width: 5, jointType: JointType.round, startCap: Cap.roundCap, endCap: Cap.roundCap)
      };

      _pushMapState();

      if (!_didInitialFit) {
        _didInitialFit = true;
        if (!_isFollowCameraEnabled) {
          _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_boundsFrom([from, to]), 90.0));
        } else {
          _followCamera();
        }
      }
    } finally {
      _busyRoute = false;
    }
  }

  Future<_RouteResult?> _computeRoute(LatLng origin, LatLng destination) async {
    final url = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');
    final body = {
      'origin': {'location': {'latLng': {'latitude': origin.latitude, 'longitude': origin.longitude}}},
      'destination': {'location': {'latLng': {'latitude': destination.latitude, 'longitude': destination.longitude}}},
      'travelMode': 'DRIVE', 'routingPreference': 'TRAFFIC_AWARE_OPTIMAL', 'units': 'METRIC', 'polylineQuality': 'HIGH_QUALITY',
    };
    final headers = {'Content-Type': 'application/json', 'X-Goog-Api-Key': ApiConstants.kGoogleApiKey, 'X-Goog-FieldMask': 'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline'};

    try {
      final res = await http.post(url, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      final route = data['routes']?[0];
      if (route == null || route['polyline']?['encodedPolyline'] == null) return null;
      return _RouteResult(
        points: _decodePolyline(route['polyline']['encodedPolyline']),
        distanceMeters: route['distanceMeters'] ?? 0,
        durationSeconds: int.tryParse(route['duration']?.replaceAll('s', '') ?? '0') ?? 0,
      );
    } catch (_) { return null; }
  }

  void _followCamera() {
    if (_phase == TripNavPhase.completed || _phase == TripNavPhase.cancelled || !_isFollowCameraEnabled || _viewMode != NavigationViewMode.navigation) return;
    final target = (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? _enRouteOrigin : _displayDriverLL;
    if (target == null) return;

    double targetBearing = _localHardwareHeading ?? _carIconHeading;
    double diff = targetBearing - _cameraBearingEMA;
    while (diff < -180.0) diff += 360.0;
    while (diff > 180.0) diff -= 360.0;
    _cameraBearingEMA += diff * 0.18;

    _isProgrammaticCameraMove = true;
    _mapController?.moveCamera(
        CameraUpdate.newCameraPosition(CameraPosition(target: target, zoom: (_phase == TripNavPhase.enRoute) ? 18.5 : 17.5, tilt: 75.0, bearing: _cameraBearingEMA))
    );
    Future.delayed(const Duration(milliseconds: 50), () => _isProgrammaticCameraMove = false);
  }

  Future<void> _activateOverviewMode() async {
    HapticFeedback.mediumImpact();
    setState(() { _viewMode = NavigationViewMode.atAGlance; _isFollowCameraEnabled = false; });
    final pts = <LatLng>[if (_displayDriverLL != null) _displayDriverLL!, _effectivePickupLL, ...widget.args.dropOffs, widget.args.destination];
    if (pts.isNotEmpty) {
      _isProgrammaticCameraMove = true;
      _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_boundsFrom(pts), 92.0));
      Future.delayed(const Duration(milliseconds: 250), () => _isProgrammaticCameraMove = false);
    }
  }

  Future<void> _recenterMap() async {
    HapticFeedback.selectionClick();
    setState(() { _isFollowCameraEnabled = true; _viewMode = NavigationViewMode.navigation; });

    if (_displayDriverLL != null) {
      _isProgrammaticCameraMove = true;
      double headingToUse = _localHardwareHeading ?? _carIconHeading;
      _cameraBearingEMA = headingToUse;

      _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(CameraPosition(target: _displayDriverLL!, zoom: 18.5, tilt: 75.0, bearing: headingToUse))
      );
      Future.delayed(const Duration(milliseconds: 250), () => _isProgrammaticCameraMove = false);
    }
  }

  void _onCameraMoveStarted() {
    if (_isFollowCameraEnabled && !_isProgrammaticCameraMove) {
      setState(() { _isFollowCameraEnabled = false; _viewMode = NavigationViewMode.atAGlance; });
    }
  }

  Future<void> _handlePrimaryAction() async {
    if (_busyPrimaryAction) return;

    Future<void> Function()? callback;
    TripNavPhase? nextOpt;

    if (widget.args.role == TripNavigationRole.driver) {
      if (_phase == TripNavPhase.driverToPickup) { callback = widget.args.onArrivedPickup; nextOpt = TripNavPhase.waitingPickup; }
      else if (_phase == TripNavPhase.waitingPickup) { callback = widget.args.onStartTrip; nextOpt = TripNavPhase.enRoute; }
      else if (_phase == TripNavPhase.enRoute) { callback = widget.args.onArrivedDestination; nextOpt = TripNavPhase.arrivedDestination; }
      else if (_phase == TripNavPhase.arrivedDestination) { callback = widget.args.onCompleteTrip; nextOpt = TripNavPhase.completed; }
    }

    if (callback == null) return;
    setState(() => _busyPrimaryAction = true);

    try {
      await callback();
      if (nextOpt != null) {
        _phase = nextOpt;
        _optimisticPhase = nextOpt;
        _optimisticPhaseSetAt = DateTime.now();
        _didInitialFit = false;
        _lastDriverRouteLL = null;
        _uiNeedsRebuild = true;
      }
      await _tick(force: true);
      if (_phase == TripNavPhase.enRoute && widget.args.role == TripNavigationRole.driver) _recenterMap();
    } catch (e) {
      _emitError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busyPrimaryAction = false);
    }
  }

  Future<void> _cancelTripPressed() async {
    if (_busyCancel) return;
    if (_phase == TripNavPhase.completed || _phase == TripNavPhase.cancelled) { Navigator.of(context).maybePop(); return; }
    setState(() => _busyCancel = true);
    try {
      if (widget.args.onCancelTrip != null) await widget.args.onCancelTrip!();
      if (!mounted) return;
      setState(() => _phase = TripNavPhase.cancelled);
      if (widget.args.autoCloseOnCancel) Navigator.of(context).maybePop();
    } catch (e) { _emitError(e.toString().replaceFirst('Exception: ', '')); }
    finally { if (mounted) setState(() => _busyCancel = false); }
  }

  Map<String, dynamic> _eventMap(dynamic event) {
    if (event is BookingUpdate) return {'booking_status': event.status.toString(), ...event.data};
    if (event is Map<String, dynamic>) return event;
    if (event is Map) return event.cast<String, dynamic>();
    try { final data = event.data; if (data is Map<String, dynamic>) return data; if (data is Map) return data.cast<String, dynamic>(); } catch (_) {}
    return {};
  }

  TripNavPhase? _coercePhase(Map<String, dynamic> payload, dynamic rawEvent) {
    if (rawEvent is BookingUpdate) {
      switch (rawEvent.status) {
        case BookingStatus.searching: case BookingStatus.driverAssigned: case BookingStatus.driverArriving: return TripNavPhase.driverToPickup;
        case BookingStatus.onTrip: return TripNavPhase.enRoute;
        case BookingStatus.completed: return TripNavPhase.completed;
        case BookingStatus.cancelled: return TripNavPhase.cancelled;
        case BookingStatus.failed: return null;
      }
    }
    final raw = (payload['phase'] ?? payload['status'] ?? payload['state'] ?? (payload['ride'] is Map ? payload['ride']['status'] : null))?.toString().toLowerCase() ?? '';
    switch (raw) {
      case 'searching': case 'accepted': case 'driver_assigned': case 'driver_arriving': case 'arriving': case 'enroute_pickup': return TripNavPhase.driverToPickup;
      case 'arrived_pickup': return TripNavPhase.waitingPickup;
      case 'in_ride': case 'on_trip': case 'in_progress': case 'started': return TripNavPhase.enRoute;
      case 'arrived_destination': return TripNavPhase.arrivedDestination;
      case 'completed': case 'done': case 'finished': return TripNavPhase.completed;
      case 'cancelled': case 'canceled': return TripNavPhase.cancelled;
      default: return null;
    }
  }

  int? _coerceStopIndex(Map<String, dynamic> payload, dynamic rawEvent) {
    final top = payload['stop_index'] ?? payload['waypoint_index'] ?? payload['active_stop_index'];
    if (top != null) return int.tryParse(top.toString());
    try { return int.tryParse((rawEvent.stopIndex ?? rawEvent.waypointIndex ?? rawEvent.activeStopIndex).toString()); } catch (_) { return null; }
  }

  LatLng? _coerceDriverLL(Map<String, dynamic> payload, dynamic rawEvent) {
    final lat = double.tryParse((payload['driver_lat'] ?? payload['driverLat'] ?? payload['lat'] ?? payload['latitude'])?.toString() ?? '');
    final lng = double.tryParse((payload['driver_lng'] ?? payload['driverLng'] ?? payload['lng'] ?? payload['longitude'])?.toString() ?? '');
    if (lat != null && lng != null) return LatLng(lat, lng);
    try {
      final la = double.tryParse((rawEvent.driverLat ?? rawEvent.lat ?? rawEvent.latitude)?.toString() ?? '');
      final lo = double.tryParse((rawEvent.driverLng ?? rawEvent.lng ?? rawEvent.longitude)?.toString() ?? '');
      if (la != null && lo != null) return LatLng(la, lo);
    } catch (_) {}
    return null;
  }

  LatLng? _coerceRiderLL(Map<String, dynamic> payload, dynamic rawEvent) {
    final lat = double.tryParse((payload['rider_lat'] ?? payload['riderLat'] ?? payload['user_lat'] ?? payload['pickup_lat'])?.toString() ?? '');
    final lng = double.tryParse((payload['rider_lng'] ?? payload['riderLng'] ?? payload['user_lng'] ?? payload['pickup_lng'])?.toString() ?? '');
    if (lat != null && lng != null) return LatLng(lat, lng);
    return null;
  }

  double? _coerceHeading(Map<String, dynamic> payload, dynamic rawEvent) {
    final top = double.tryParse((payload['driver_heading'] ?? payload['driverHeading'] ?? payload['heading'] ?? payload['bearing'])?.toString() ?? '');
    if (top != null) return top;
    try { return double.tryParse((rawEvent.heading ?? rawEvent.bearing ?? rawEvent.driverHeading)?.toString() ?? ''); } catch (_) { return null; }
  }

  List<LatLng> _decodePolyline(String enc) {
    final out = <LatLng>[]; int idx = 0, lat = 0, lng = 0;
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

  LatLngBounds _boundsFrom(List<LatLng> pts) {
    double minLat = pts.first.latitude, maxLat = pts.first.latitude, minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final p in pts) {
      minLat = math.min(minLat, p.latitude); maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude); maxLng = math.max(maxLng, p.longitude);
    }
    return LatLngBounds(southwest: LatLng(minLat - 0.0001, minLng - 0.0001), northeast: LatLng(maxLat + 0.0001, maxLng + 0.0001));
  }

  double _haversine(LatLng a, LatLng b) {
    double d2r(double d) => d * (math.pi / 180.0);
    final h = math.sin(d2r(b.latitude - a.latitude) / 2) * math.sin(d2r(b.latitude - a.latitude) / 2) +
        math.cos(d2r(a.latitude)) * math.cos(d2r(b.latitude)) * math.sin(d2r(b.longitude - a.longitude) / 2) * math.sin(d2r(b.longitude - a.longitude) / 2);
    return 2 * 6371000.0 * math.asin(math.min(1.0, math.sqrt(h)));
  }

  double _bearingBetween(LatLng a, LatLng b) {
    double d2r(double d) => d * (math.pi / 180.0);
    final y = math.sin(d2r(b.longitude - a.longitude)) * math.cos(d2r(b.latitude));
    final x = math.cos(d2r(a.latitude)) * math.sin(d2r(b.latitude)) - math.sin(d2r(a.latitude)) * math.cos(d2r(b.latitude)) * math.cos(d2r(b.longitude - a.longitude));
    return (math.atan2(y, x) * (180.0 / math.pi) + 360.0) % 360.0;
  }

  String _fmtDistance(int m) => m < 1000 ? '$m m' : '${(m / 1000).toStringAsFixed(1)} km';
  String _fmtDuration(int s) { final mins = (s / 60).round(); return mins < 60 ? '${mins}m' : '${mins ~/ 60}h ${mins % 60}m'; }

  String _phaseLabel() {
    if (widget.args.role == TripNavigationRole.driver) {
      switch (_phase) {
        case TripNavPhase.driverToPickup: return 'TO PICKUP';
        case TripNavPhase.waitingPickup: return 'AT PICKUP';
        case TripNavPhase.enRoute: return 'TO DESTINATION';
        case TripNavPhase.arrivedDestination: return 'AT DESTINATION';
        case TripNavPhase.completed: return 'COMPLETED';
        case TripNavPhase.cancelled: return 'CANCELLED';
      }
    } else {
      switch (_phase) {
        case TripNavPhase.driverToPickup: return 'DRIVER ARRIVING';
        case TripNavPhase.waitingPickup: return 'PICKUP READY';
        case TripNavPhase.enRoute: return 'ON TRIP';
        case TripNavPhase.arrivedDestination: return 'ARRIVED';
        case TripNavPhase.completed: return 'COMPLETED';
        case TripNavPhase.cancelled: return 'CANCELLED';
      }
    }
  }

  EdgeInsets _calcMapPadding(MediaQueryData mq, UIScale ui) {
    final bool showLandscapePanel = ui.landscape;
    final double landscapePanelWidth = showLandscapePanel ? (mq.size.width * 0.35).clamp(320.0, 400.0) : 0;
    return EdgeInsets.only(
      top: mq.padding.top + ui.gap(70),
      left: showLandscapePanel ? landscapePanelWidth + ui.inset(16) : 0,
      right: ui.landscape ? ui.inset(16) : 0,
      bottom: showLandscapePanel ? ui.inset(16) : (_viewMode == NavigationViewMode.navigation ? ui.gap(120) : ui.gap(200)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final mq = MediaQuery.of(context);
    final ui = UIScale.of(context);

    final bool showLandscapePanel = ui.landscape;
    final double landscapePanelWidth = showLandscapePanel ? (mq.size.width * 0.35).clamp(320.0, 400.0) : 0;

    String? primaryLabel;
    if (widget.args.role == TripNavigationRole.driver) {
      if (_phase == TripNavPhase.driverToPickup && widget.args.showArrivedPickupButton) primaryLabel = 'AT PICKUP';
      else if (_phase == TripNavPhase.waitingPickup && widget.args.showStartTripButton) primaryLabel = 'START TRIP';
      else if (_phase == TripNavPhase.enRoute && widget.args.showArrivedDestinationButton) primaryLabel = 'AT DESTINATION';
      else if (_phase == TripNavPhase.arrivedDestination && widget.args.showCompleteTripButton) primaryLabel = 'COMPLETE RIDE';
    }

    final double sheetInitialSize = ui.landscape ? 1.0 : (ui.tiny ? 0.40 : (ui.compact ? 0.38 : 0.35));
    final double sheetMaxSize = ui.landscape ? 1.0 : (ui.tiny ? 0.70 : 0.60);

    return WillPopScope(
      onWillPop: () async => true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: Container(
                color: theme.scaffoldBackgroundColor,
                child: _booting ? const SizedBox.shrink() : _OptimizedMapLayer(
                  markersNotifier: _markersNotifier,
                  polylinesNotifier: _polylinesNotifier,
                  initialTarget: _displayDriverLL ?? _effectivePickupLL,
                  isDark: isDark,
                  padding: _calcMapPadding(mq, ui),
                  onCameraMoveStarted: _onCameraMoveStarted,
                  onMapCreated: (controller) {
                    _mapController = controller;
                    if (!_didInitialFit && _polylinesNotifier.value.isNotEmpty) {
                      _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_boundsFrom([_enRouteOrigin ?? _displayDriverLL ?? _effectivePickupLL, _currentTarget]), 90.0));
                      _didInitialFit = true;
                    }
                  },
                ),
              ),
            ),

            if (!_booting) ...[
              Positioned(
                top: 0, left: 0, right: 0, height: ui.gap(140),
                child: IgnorePointer(
                  child: Container(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withOpacity(0.7), Colors.transparent]))),
                ),
              ),

              Positioned(
                top: mq.padding.top + ui.gap(12), left: ui.inset(10), right: ui.inset(10),
                child: _SolidHeader(ui: ui, phaseLabel: _phaseLabel(), distanceText: _distanceText ?? '—', durationText: _durationText ?? '—', onBack: () => Navigator.of(context).maybePop()),
              ),

              Positioned(
                top: mq.padding.top + ui.gap(76), right: ui.inset(10),
                child: _PillActionRail(ui: ui, isFollowCameraEnabled: _isFollowCameraEnabled, onOverviewMode: _activateOverviewMode, onRecenter: _recenterMap),
              ),

              if (showLandscapePanel)
                Positioned(
                  top: mq.padding.top + ui.gap(76), left: ui.inset(10), bottom: ui.inset(10), width: landscapePanelWidth,
                  child: SafeArea(top: false, child: _SolidPanelContainer(ui: ui, child: _buildSheetContent(ui, primaryLabel))),
                )
              else
                Positioned(
                  left: ui.inset(10), right: ui.inset(10), bottom: ui.inset(10),
                  height: math.min(mq.size.height * 0.75, mq.size.height - (mq.padding.top + ui.gap(100))),
                  child: SafeArea(
                    top: false,
                    child: DraggableScrollableSheet(
                      expand: true, initialChildSize: sheetInitialSize, minChildSize: 0.15, maxChildSize: sheetMaxSize,
                      builder: (ctx, controller) => _SolidPanelContainer(ui: ui, child: _buildSheetContent(ui, primaryLabel, controller: controller)),
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
      controller: controller, ui: ui, role: widget.args.role, phaseLabel: _phaseLabel(),
      rideType: widget.args.rideType, onSOSTap: widget.args.onSOSTap,
      driverName: widget.args.driverName ?? 'Driver', vehicleType: widget.args.vehicleType ?? 'Car', carPlate: widget.args.carPlate ?? '',
      rating: widget.args.rating ?? 0.0, from: widget.args.originText, to: widget.args.destinationText, currentTarget: _currentTargetText,
      distanceText: _distanceText ?? '--', durationText: _durationText ?? '--',
      activeStopIndex: _activeStopIndex, showPrimaryAction: primaryLabel != null, primaryLabel: primaryLabel,
      showCancelButton: widget.args.showCancelButton && (widget.args.role == TripNavigationRole.driver || (_phase == TripNavPhase.driverToPickup || _phase == TripNavPhase.waitingPickup)),
      busyPrimary: _busyPrimaryAction, busyCancel: _busyCancel,
      primaryEnabled: (_phase == TripNavPhase.driverToPickup && _canArrivePickup) || (_phase == TripNavPhase.waitingPickup && _canStartTrip) || (_phase == TripNavPhase.enRoute && _canArriveDestination) || (_phase == TripNavPhase.arrivedDestination && _canCompleteRide),
      onPrimaryAction: _handlePrimaryAction, onCancelTrip: _cancelTripPressed, errorText: _lastErrorText,
    );
  }
}

// --- ISOLATED MAP LAYER WIDGET (Using ValueNotifier) ---
class _OptimizedMapLayer extends StatelessWidget {
  final ValueNotifier<Set<Marker>> markersNotifier;
  final ValueNotifier<Set<Polyline>> polylinesNotifier;
  final LatLng initialTarget;
  final bool isDark;
  final EdgeInsets padding;
  final VoidCallback onCameraMoveStarted;
  final void Function(GoogleMapController) onMapCreated;

  const _OptimizedMapLayer({
    required this.markersNotifier, required this.polylinesNotifier, required this.initialTarget,
    required this.isDark, required this.padding, required this.onCameraMoveStarted, required this.onMapCreated,
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
              return GoogleMap(
                initialCameraPosition: CameraPosition(target: initialTarget, zoom: 17.5, tilt: 65),
                myLocationEnabled: false, myLocationButtonEnabled: false, zoomControlsEnabled: false,
                compassEnabled: false, mapToolbarEnabled: false, buildingsEnabled: false,
                indoorViewEnabled: false, trafficEnabled: false, rotateGesturesEnabled: true,
                tiltGesturesEnabled: true, padding: padding, markers: markers, polylines: polylines,
                onCameraMoveStarted: onCameraMoveStarted,
                onMapCreated: (c) {
                  if (isDark) c.setMapStyle(_getMapStyle());
                  onMapCreated(c);
                },
              );
            },
          );
        },
      ),
    );
  }
}

// --- PREMIUM UI WIDGETS ---
class _PremiumDashboardSheet extends StatelessWidget {
  final ScrollController? controller; final UIScale ui; final TripNavigationRole role; final String phaseLabel;
  final String rideType; final VoidCallback? onSOSTap;
  final String driverName, vehicleType, carPlate; final double rating; final String from, to, currentTarget;
  final String distanceText, durationText;
  final int activeStopIndex; final bool showPrimaryAction; final String? primaryLabel;
  final bool showCancelButton, busyPrimary, busyCancel, primaryEnabled;
  final VoidCallback onPrimaryAction, onCancelTrip; final String? errorText;

  const _PremiumDashboardSheet({
    required this.controller, required this.ui, required this.role, required this.phaseLabel,
    required this.rideType, this.onSOSTap,
    required this.driverName, required this.vehicleType, required this.carPlate, required this.rating, required this.from, required this.to, required this.currentTarget, required this.distanceText, required this.durationText, required this.activeStopIndex, required this.showPrimaryAction, required this.primaryLabel, required this.showCancelButton, required this.busyPrimary, required this.busyCancel, required this.primaryEnabled, required this.onPrimaryAction, required this.onCancelTrip, required this.errorText
  });

  @override
  Widget build(BuildContext context) {
    final Color os = Theme.of(context).colorScheme.onSurface;
    final String modeLabel = role == TripNavigationRole.driver ? "DRIVER COMMAND" : "RIDER MODE";
    final String profileTitle = role == TripNavigationRole.driver ? "YOUR RIDER" : "YOUR DRIVER";

    final List<Widget> content = [
      if (controller != null) ...[SizedBox(height: ui.gap(10)), Center(child: Container(width: 40, height: 5, decoration: BoxDecoration(color: os.withOpacity(0.2), borderRadius: BorderRadius.circular(10)))), SizedBox(height: ui.gap(16))] else SizedBox(height: ui.gap(16)),

      // Dynamic Context Header + SOS Button
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: ui.inset(10), vertical: ui.inset(6)),
            decoration: BoxDecoration(color: AppColors.primary.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
            child: Text("$modeLabel • ${rideType.toUpperCase()}", style: TextStyle(color: AppColors.primary, fontSize: ui.font(10), fontWeight: FontWeight.w900, letterSpacing: 1.0)),
          ),

          // Highly visible SOS button
          GestureDetector(
            onTap: onSOSTap ?? () {},
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: ui.inset(12), vertical: ui.inset(6)),
              decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), border: Border.all(color: Colors.red.withOpacity(0.5), width: 1.5), borderRadius: BorderRadius.circular(20)),
              child: Row(
                children: [
                  Icon(Icons.emergency_share_rounded, color: Colors.red, size: ui.icon(16)),
                  SizedBox(width: ui.gap(4)),
                  Text("SOS", style: TextStyle(color: Colors.red, fontSize: ui.font(12), fontWeight: FontWeight.w900, letterSpacing: 1.0)),
                ],
              ),
            ),
          )
        ],
      ),
      SizedBox(height: ui.gap(16)),

      Text(profileTitle, style: TextStyle(color: os.withOpacity(0.5), fontSize: ui.font(10), fontWeight: FontWeight.w800, letterSpacing: 1.0)),
      SizedBox(height: ui.gap(8)),

      // Driver/Rider Profile Row
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CircleAvatar(radius: ui.font(24), backgroundColor: AppColors.primary.withOpacity(0.15), child: Icon(Icons.person, color: AppColors.primary, size: ui.icon(24))),
          SizedBox(width: ui.gap(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(driverName.toUpperCase(), style: TextStyle(color: os, fontSize: ui.font(16), fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                SizedBox(height: ui.gap(4)),
                Text(vehicleType, style: TextStyle(color: os.withOpacity(0.6), fontSize: ui.font(12), fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (rating > 0) Container(padding: EdgeInsets.symmetric(horizontal: ui.inset(8), vertical: ui.inset(4)), decoration: BoxDecoration(color: Colors.amber.withOpacity(0.15), borderRadius: BorderRadius.circular(12)), child: Row(children: [Icon(Icons.star_rounded, color: Colors.amber, size: ui.icon(14)), SizedBox(width: ui.gap(4)), Text(rating.toStringAsFixed(1), style: TextStyle(color: Colors.amber, fontWeight: FontWeight.w800, fontSize: ui.font(12)))])),
              if (rating > 0) SizedBox(height: ui.gap(8)),
              if (carPlate.isNotEmpty) Container(padding: EdgeInsets.symmetric(horizontal: ui.inset(8), vertical: ui.inset(4)), decoration: BoxDecoration(color: const Color(0xFFFACC15), borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.black87, width: 1.5)), child: Text(carPlate.toUpperCase(), style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: ui.font(12), letterSpacing: 1.2))),
            ],
          )
        ],
      ),

      SizedBox(height: ui.gap(20)),

      // The "Meta" Status Card
      Container(
        padding: EdgeInsets.all(ui.inset(16)),
        decoration: BoxDecoration(gradient: LinearGradient(colors: [AppColors.primary, AppColors.primary.withOpacity(0.8)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(ui.radius(16)), boxShadow: [BoxShadow(color: AppColors.primary.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 6))]),
        child: Row(
          children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('CURRENT TARGET', style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: ui.font(10), fontWeight: FontWeight.w800, letterSpacing: 1.0)), SizedBox(height: ui.gap(4)), Text(currentTarget, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: ui.font(15), fontWeight: FontWeight.w800))])),
            Container(width: 1, height: 30, color: Colors.white.withOpacity(0.3), margin: EdgeInsets.symmetric(horizontal: ui.inset(12))),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(durationText, style: TextStyle(color: Colors.white, fontSize: ui.font(18), fontWeight: FontWeight.w900, height: 1.0)), Text(distanceText, style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: ui.font(11), fontWeight: FontWeight.w700))]),
          ],
        ),
      ),

      SizedBox(height: ui.gap(24)),

      // Visual Timeline Tracker
      Text('TRIP ROUTE', style: TextStyle(color: os.withOpacity(0.5), fontSize: ui.font(10), fontWeight: FontWeight.w800, letterSpacing: 1.0)),
      SizedBox(height: ui.gap(12)),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Icon(Icons.radio_button_checked, color: AppColors.primary, size: ui.icon(18)),
              Container(width: 2, height: ui.gap(24), color: os.withOpacity(0.15)),
              Icon(Icons.location_on, color: Colors.green, size: ui.icon(18)),
            ],
          ),
          SizedBox(width: ui.gap(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(from, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: os, fontSize: ui.font(13), fontWeight: FontWeight.w700)),
                SizedBox(height: ui.gap(22)),
                Text(to, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: os, fontSize: ui.font(13), fontWeight: FontWeight.w700)),
              ],
            ),
          )
        ],
      ),

      if (errorText != null && errorText!.trim().isNotEmpty) ...[SizedBox(height: ui.gap(20)), Container(padding: EdgeInsets.all(ui.inset(12)), decoration: BoxDecoration(color: AppColors.error.withOpacity(0.1), borderRadius: BorderRadius.circular(ui.radius(12)), border: Border.all(color: AppColors.error.withOpacity(0.3))), child: Row(children: [Icon(Icons.error_outline_rounded, color: AppColors.error, size: ui.icon(18)), SizedBox(width: ui.gap(8)), Expanded(child: Text(errorText!, style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w800, fontSize: ui.font(12))))]))],

      SizedBox(height: ui.gap(24)),

      // Action Buttons
      Row(
        children: [
          if (showPrimaryAction) Expanded(flex: 2, child: _PremiumButton(label: primaryLabel ?? 'ACTION', isLoading: busyPrimary, isDisabled: !primaryEnabled, isPrimary: true, onTap: onPrimaryAction, ui: ui)),
          if (showPrimaryAction && showCancelButton) SizedBox(width: ui.gap(12)),
          if (showCancelButton) Expanded(flex: 1, child: _PremiumButton(label: 'CANCEL', isLoading: busyCancel, isDisabled: false, isPrimary: false, onTap: onCancelTrip, ui: ui))
        ],
      ),
      SizedBox(height: ui.gap(20)),
    ];
    return controller != null ? ListView(controller: controller, padding: EdgeInsets.symmetric(horizontal: ui.inset(20)), children: content) : SingleChildScrollView(padding: EdgeInsets.symmetric(horizontal: ui.inset(20)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: content));
  }
}

class _PremiumButton extends StatelessWidget {
  final String label; final bool isLoading, isDisabled, isPrimary; final VoidCallback onTap; final UIScale ui;
  const _PremiumButton({required this.label, required this.isLoading, this.isDisabled = false, required this.isPrimary, required this.onTap, required this.ui});
  @override
  Widget build(BuildContext context) {
    final os = Theme.of(context).colorScheme.onSurface; final bool disabled = isLoading || isDisabled;
    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: Container(
        height: ui.gap(56), alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: isPrimary ? LinearGradient(colors: [disabled ? AppColors.primary.withOpacity(0.4) : AppColors.primary, disabled ? AppColors.primary.withOpacity(0.4) : AppColors.primary.withRed(100)]) : null,
          color: !isPrimary ? Colors.transparent : null,
          borderRadius: BorderRadius.circular(ui.radius(16)),
          border: Border.all(color: isPrimary ? Colors.transparent : os.withOpacity(0.2), width: 1.5),
          boxShadow: isPrimary && !disabled ? [BoxShadow(color: AppColors.primary.withOpacity(0.4), blurRadius: 16, offset: const Offset(0, 8))] : [],
        ),
        child: isLoading ? SizedBox(width: ui.gap(20), height: ui.gap(20), child: CircularProgressIndicator(strokeWidth: 2.5, color: isPrimary ? Colors.white : os)) : Text(label, style: TextStyle(color: isPrimary ? Colors.white.withOpacity(disabled ? 0.7 : 1.0) : os.withOpacity(disabled ? 0.5 : 0.9), fontSize: ui.font(14), fontWeight: FontWeight.w900, letterSpacing: 1.0)),
      ),
    );
  }
}

class _SolidPanelContainer extends StatelessWidget {
  final Widget child; final UIScale ui;
  const _SolidPanelContainer({required this.child, required this.ui});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark ? cs.surface.withOpacity(0.98) : Colors.white.withOpacity(0.98),
        borderRadius: BorderRadius.circular(ui.radius(24)), border: Border.all(color: cs.onSurface.withOpacity(0.05)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(ui.radius(24)), child: child),
    );
  }
}

class _SolidHeader extends StatelessWidget {
  final UIScale ui; final String phaseLabel, distanceText, durationText; final VoidCallback onBack;
  const _SolidHeader({required this.ui, required this.phaseLabel, required this.distanceText, required this.durationText, required this.onBack});
  @override
  Widget build(BuildContext context) {
    return Container(
      height: ui.gap(52), padding: EdgeInsets.symmetric(horizontal: ui.inset(12)),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.85), borderRadius: BorderRadius.circular(ui.radius(20)), border: Border.all(color: Colors.white.withOpacity(0.15)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 6))]),
      child: Row(
        children: [
          IconButton(onPressed: onBack, padding: EdgeInsets.zero, constraints: const BoxConstraints(), icon: Icon(Icons.close_rounded, color: Colors.white, size: ui.icon(20))),
          SizedBox(width: ui.gap(12)), Container(width: 1, height: ui.gap(24), color: Colors.white.withOpacity(0.2)), SizedBox(width: ui.gap(12)),
          Icon(Icons.directions_car_rounded, color: AppColors.primary, size: ui.icon(18)), SizedBox(width: ui.gap(8)),
          Expanded(child: Text(phaseLabel, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: ui.font(13), letterSpacing: 0.5))),
          Container(width: 1, height: ui.gap(24), color: Colors.white.withOpacity(0.2)), SizedBox(width: ui.gap(12)),
          Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [Text(durationText, style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w900, fontSize: ui.font(16), height: 1.1)), Text(distanceText, style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, fontSize: ui.font(11), height: 1.1))]),
        ],
      ),
    );
  }
}

class _PillActionRail extends StatelessWidget {
  final bool isFollowCameraEnabled; final VoidCallback onOverviewMode, onRecenter; final UIScale ui;
  const _PillActionRail({required this.isFollowCameraEnabled, required this.onOverviewMode, required this.onRecenter, required this.ui});
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _ActionPill(icon: Icons.map_rounded, label: 'Overview', isActive: !isFollowCameraEnabled, onTap: onOverviewMode, ui: ui),
        if (!isFollowCameraEnabled) ...[SizedBox(height: ui.gap(12)), _ActionPill(icon: Icons.my_location_rounded, label: 'Re-center', isActive: true, onTap: onRecenter, ui: ui)]
      ],
    );
  }
}

class _ActionPill extends StatelessWidget {
  final IconData icon; final String label; final bool isActive; final VoidCallback onTap; final UIScale ui;
  const _ActionPill({required this.icon, required this.label, required this.isActive, required this.onTap, required this.ui});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.inset(12)),
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.85), borderRadius: BorderRadius.circular(ui.radius(24)), border: Border.all(color: isActive ? AppColors.primary.withOpacity(0.8) : Colors.white.withOpacity(0.15)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 5))]),
        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, color: isActive ? AppColors.primary : Colors.white70, size: ui.icon(18)), SizedBox(width: ui.gap(10)), Text(label, style: TextStyle(color: isActive ? Colors.white : Colors.white70, fontSize: ui.font(14), fontWeight: FontWeight.w900, letterSpacing: 0.5))]),
      ),
    );
  }
}

class _RouteResult { final List<LatLng> points; final int distanceMeters, durationSeconds; const _RouteResult({required this.points, required this.distanceMeters, required this.durationSeconds}); }