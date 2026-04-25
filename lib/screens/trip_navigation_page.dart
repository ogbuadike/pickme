// lib/screens/trip_navigation_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

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

enum TripNavPhase {
  driverToPickup,
  waitingPickup,
  enRoute,
  arrivedDestination,
  completed,
  cancelled,
}

enum NavigationViewMode { navigation, atAGlance }

class TripNavigationArgs {
  final String userId;
  final String driverId;
  final String tripId;
  final LatLng pickup;
  final LatLng destination;
  final List<LatLng> dropOffs;
  final String originText;
  final String destinationText;
  final List<String> dropOffTexts;
  final String? driverName;
  final String? vehicleType;
  final String? carPlate;
  final double? rating;
  final LatLng? initialDriverLocation;
  final LatLng? initialRiderLocation;
  final TripNavPhase initialPhase;
  final Stream<dynamic>? bookingUpdates;
  final Future<Map<String, dynamic>?> Function()? liveSnapshotProvider;
  final Future<void> Function()? onStartTrip;
  final Future<void> Function()? onCancelTrip;
  final Future<void> Function()? onArrivedPickup;
  final Future<void> Function()? onArrivedDestination;
  final Future<void> Function()? onCompleteTrip;
  final TripNavigationRole role;
  final Duration tickEvery;
  final Duration routeMinGap;
  final double arrivalMeters;
  final double routeMoveThresholdMeters;
  final bool autoFollowCamera;
  final bool showStartTripButton;
  final bool showCancelButton;
  final bool showMetaCard;
  final bool showDebugPanel;
  final bool enableLivePickupTracking;
  final bool preserveStopOrder;
  final bool autoCloseOnCancel;
  final bool showArrivedPickupButton;
  final bool showArrivedDestinationButton;
  final bool showCompleteTripButton;

  const TripNavigationArgs({
    required this.userId,
    required this.driverId,
    required this.tripId,
    required this.pickup,
    required this.destination,
    this.dropOffs = const <LatLng>[],
    required this.originText,
    required this.destinationText,
    this.dropOffTexts = const <String>[],
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

// Added TickerProviderStateMixin to power the 60FPS Glide Engine
class TripNavigationPage extends StatefulWidget {
  final TripNavigationArgs args;
  const TripNavigationPage({super.key, required this.args});

  @override
  State<TripNavigationPage> createState() => _TripNavigationPageState();
}

class _TripNavigationPageState extends State<TripNavigationPage> with TickerProviderStateMixin, WidgetsBindingObserver {
  GoogleMapController? _map;
  StreamSubscription<dynamic>? _bookingSub;
  StreamSubscription<CompassEvent>? _compassSub;
  Timer? _tickTimer;
  Timer? _compassThrottleTimer;

  final Set<Marker> _markers = <Marker>{};
  final Set<Polyline> _polylines = <Polyline>{};

  BitmapDescriptor? _driverIcon;
  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _dropIcon;
  BitmapDescriptor? _riderIcon;
  BitmapDescriptor? _waypointIcon;

  // --- ENTERPRISE GLIDE ENGINE STATE ---
  AnimationController? _glideController;
  LatLng? _driverLL; // Raw database position
  LatLng? _animStartLL;
  LatLng? _animTargetLL;
  LatLng? _displayDriverLL; // The actively interpolated, moving 60FPS position

  LatLng? _lastDriverLL;
  LatLng? _riderLL;

  double _backendDriverHeading = 0.0;
  double? _localHardwareHeading;

  double _emaHeading = 0.0;
  double _emaCameraBearing = 0.0;
  static const double _smoothingFactor = 0.25;

  TripNavPhase _phase = TripNavPhase.driverToPickup;
  int _activeStopIndex = 0;

  // Smart Camera Engine State
  NavigationViewMode _viewMode = NavigationViewMode.navigation;
  bool _isFollowCameraEnabled = true;
  bool _isProgrammaticCameraMove = false; // Protects against pan-detection misfires
  bool _userIsPanning = false; // <--- ADD THIS LINE BACK IN

  // STAGGERED LOAD STATE
  bool _booting = true;

  String? _distanceText;
  String? _durationText;
  String? _lastErrorText;

  bool _busyRoute = false;
  bool _busyTick = false;
  bool _busyPrimaryAction = false;
  bool _busyCancel = false;
  bool _didInitialFit = false;

  bool _canArrivePickup = false;
  bool _canStartTrip = false;
  bool _canArriveDestination = false;
  bool _canCompleteRide = false;

  DateTime _lastRouteAt = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _lastDriverRouteLL;
  List<LatLng> _latestRoutePoints = <LatLng>[];

  Duration get _tickEvery => widget.args.tickEvery;
  Duration get _routeMinGap => widget.args.routeMinGap;
  double get _arrivalMeters => widget.args.arrivalMeters > 0 ? widget.args.arrivalMeters : 150.0;
  double get _routeMoveThresholdMeters => widget.args.routeMoveThresholdMeters > 0 ? widget.args.routeMoveThresholdMeters : 25.0;

  List<LatLng> get _allTargets => <LatLng>[...widget.args.dropOffs, widget.args.destination];
  List<String> get _allTargetTexts => <String>[...widget.args.dropOffTexts, widget.args.destinationText];

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

  String? _getMapStyle(bool isDark) {
    if (!isDark) return null;
    return '''[
      {"elementType":"geometry","stylers":[{"color":"#212121"}]},
      {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
      {"elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
      {"elementType":"labels.text.stroke","stylers":[{"color":"#212121"}]},
      {"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#757575"}]},
      {"featureType":"administrative.country","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]},
      {"featureType":"administrative.land_parcel","stylers":[{"visibility":"off"}]},
      {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#bdbdbd"}]},
      {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
      {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#181818"}]},
      {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
      {"featureType":"poi.park","elementType":"labels.text.stroke","stylers":[{"color":"#1b1b1b"}]},
      {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#2c2c2c"}]},
      {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#8a8a8a"}]},
      {"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#373737"}]},
      {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3c3c3c"}]},
      {"featureType":"road.highway.controlled_access","elementType":"geometry","stylers":[{"color":"#4e4e4e"}]},
      {"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
      {"featureType":"transit","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
      {"featureType":"water","elementType":"geometry","stylers":[{"color":"#000000"}]},
      {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#3d3d3d"}]}
    ]''';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _driverLL = widget.args.initialDriverLocation;
    _displayDriverLL = _driverLL; // Start display at true origin
    _riderLL = widget.args.initialRiderLocation ?? widget.args.pickup;
    _phase = widget.args.initialPhase;

    // ENFORCING NAVIGATION DEFAULT
    _isFollowCameraEnabled = widget.args.autoFollowCamera;
    _viewMode = NavigationViewMode.navigation;

    // Setup Glide Animation Controller
    _glideController = AnimationController(vsync: this, duration: widget.args.tickEvery);
    _glideController!.addListener(_onGlideTick);

    if (_driverLL != null) {
      _emaHeading = _bearingBetween(_driverLL!, _currentTarget);
      _emaCameraBearing = _emaHeading;
    }

    _bootstrap();
  }

  // Animates the car frame-by-frame instead of teleporting
  void _onGlideTick() {
    if (_animStartLL != null && _animTargetLL != null) {
      final double t = _glideController!.value;
      final double lat = _animStartLL!.latitude + (_animTargetLL!.latitude - _animStartLL!.latitude) * t;
      final double lng = _animStartLL!.longitude + (_animTargetLL!.longitude - _animStartLL!.longitude) * t;

      _displayDriverLL = LatLng(lat, lng);

      if (_viewMode == NavigationViewMode.navigation && _isFollowCameraEnabled) {
        _followCamera();
      }
      _syncMarkers();
      setState(() {});
    }
  }

  Future<void> _bootstrap() async {
    if (mounted) setState(() => _booting = true);

    await _preloadIcons();
    _listenBooking();
    _startHardwareCompass();

    _tickTimer = Timer.periodic(_tickEvery, (_) => _tick());

    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted) return;

    _syncMarkers();
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
    try { _map?.dispose(); } catch (_) {}
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _tick(force: true);
    }
  }

  void _startHardwareCompass() {
    _compassSub?.cancel();
    _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
      if (event.heading == null) return;
      _localHardwareHeading = _normalizeDeg(event.heading!);

      if (_compassThrottleTimer?.isActive ?? false) return;
      _compassThrottleTimer = Timer(const Duration(milliseconds: 33), () {
        if (!mounted || _userIsPanning) return;
        if (_viewMode == NavigationViewMode.navigation && _isFollowCameraEnabled) {
          _followCamera();
          if (widget.args.role == TripNavigationRole.driver) {
            _syncMarkers();
            setState(() {});
          }
        }
      });
    });
  }

  double _normalizeDeg(double d) {
    double res = d % 360.0;
    if (res < 0) res += 360.0;
    return res;
  }

  Future<void> _preloadIcons() async {
    try {
      await Future.wait<void>([_loadDriverIcon(), _loadPointIcons()]);
    } catch (_) {}
  }

  Future<void> _loadDriverIcon() async {
    if (_driverIcon != null) return;
    try {
      final ByteData bd = await rootBundle.load('assets/images/open_top_view_car.png');
      final Uint8List bytes = bd.buffer.asUint8List();
      final ui.Codec codec = await ui.instantiateImageCodec(bytes, targetWidth: 96);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ByteData? png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (png != null) {
        _driverIcon = BitmapDescriptor.fromBytes(png.buffer.asUint8List());
        return;
      }
    } catch (_) {}
    _driverIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet);
  }

  Future<void> _loadPointIcons() async {
    if (_pickupIcon != null && _dropIcon != null && _riderIcon != null && _waypointIcon != null) return;
    _pickupIcon = await _buildRingDotMarker(color: const Color(0xFF1A73E8));
    _dropIcon = await _buildRingDotMarker(color: const Color(0xFF00A651));
    _riderIcon = await _buildRingDotMarker(color: const Color(0xFFE91E63));
    _waypointIcon = await _buildRingDotMarker(color: const Color(0xFFFF9800));
  }

  Future<BitmapDescriptor> _buildRingDotMarker({required Color color}) async {
    const double size = 56.0;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final Offset center = const Offset(size / 2, size / 2);

    canvas.drawCircle(
      center + const Offset(0, 3),
      14,
      Paint()
        ..color = Colors.black.withOpacity(0.3)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 5),
    );
    canvas.drawCircle(center, 14, Paint()..color = Colors.white);
    canvas.drawCircle(center, 14, Paint()..style = PaintingStyle.stroke..strokeWidth = 4..color = color);
    canvas.drawCircle(center, 5.0, Paint()..color = color);

    final ui.Image img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final ByteData? bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
    return BitmapDescriptor.fromBytes(bytes.buffer.asUint8List());
  }

  void _listenBooking() {
    final Stream<dynamic>? stream = widget.args.bookingUpdates;
    if (stream == null) return;
    _bookingSub?.cancel();
    _bookingSub = stream.listen(
          (dynamic event) => _applyIncoming(event),
      cancelOnError: false,
    );
  }

  Future<void> _tick({bool force = false}) async {
    if (!mounted || _busyTick || _booting) return;
    _busyTick = true;
    try {
      await _applyLiveSnapshot();
      _recomputePermissions();
      _syncMarkers();
      await _rebuildRoute(force: force);

      // Camera is handled by glide engine if moving, but force it if stationary
      if (!_userIsPanning && !_glideController!.isAnimating) await _followCamera();

      if (mounted) setState(() {});
    } finally {
      _busyTick = false;
    }
  }

  Future<void> _applyLiveSnapshot() async {
    final provider = widget.args.liveSnapshotProvider;
    if (provider == null) return;
    try {
      final Map<String, dynamic>? snap = await provider.call();
      if (snap == null || snap.isEmpty) return;
      _applyIncoming(snap);
    } catch (_) {}
  }

  void _applyIncoming(dynamic event) {
    final Map<String, dynamic> payload = _eventMap(event);
    if (payload.isEmpty) return;

    if (event is BookingUpdate && event.status == BookingStatus.failed) {
      _emitError(event.displayMessage.isNotEmpty ? event.displayMessage : 'Trip issue.');
      return;
    }

    final LatLng? newDriverLL = _coerceDriverLL(payload, event);
    if (newDriverLL != null && newDriverLL != _driverLL) {
      _lastDriverLL = _driverLL;
      _driverLL = newDriverLL;

      // TRIGGER THE GLIDE ENGINE
      if (_displayDriverLL != null) {
        _animStartLL = _displayDriverLL;
        _animTargetLL = newDriverLL;
        _glideController?.forward(from: 0.0);
      } else {
        _displayDriverLL = newDriverLL;
      }
    }

    final LatLng? rider = _coerceRiderLL(payload, event);
    if (rider != null) _riderLL = rider;

    final double? heading = _coerceHeading(payload, event);
    if (heading != null) _backendDriverHeading = heading;

    final TripNavPhase? nextPhase = _coercePhase(payload, event);
    if (nextPhase != null && nextPhase != _phase) {
      if (widget.args.role == TripNavigationRole.rider && nextPhase == TripNavPhase.arrivedDestination) {
        _triggerRiderArrivalNotification();
      }

      _phase = nextPhase;
      _didInitialFit = false;
      _lastDriverRouteLL = null;
    }

    final int? stopIndex = _coerceStopIndex(payload, event);
    if (stopIndex != null && _allTargets.isNotEmpty) {
      _activeStopIndex = stopIndex.clamp(0, _allTargets.length - 1);
    }
  }

  void _triggerRiderArrivalNotification() {
    HapticFeedback.heavyImpact();
    try {
      showToastNotification(
        context: context,
        title: 'You have arrived!',
        message: 'Please gather your belongings and ensure you have all your items before exiting the vehicle.',
        isSuccess: true,
      );
    } catch (_) {}
  }

  void _emitError(String message) {
    if (_lastErrorText != message && mounted) {
      setState(() => _lastErrorText = message);
    }
  }

  void _recomputePermissions() {
    if (_displayDriverLL == null) return;

    final double pickupGap = _haversine(_displayDriverLL!, _effectivePickupLL);
    final double destGap = _haversine(_displayDriverLL!, _currentTarget);

    final double safeArrivalMeters = math.max(_arrivalMeters, 150.0);
    final double safeCompletionMeters = math.max(_arrivalMeters + 50.0, 200.0);

    _canArrivePickup = _phase == TripNavPhase.driverToPickup && pickupGap <= safeArrivalMeters;
    _canStartTrip = _phase == TripNavPhase.waitingPickup && pickupGap <= safeArrivalMeters;
    _canArriveDestination = _phase == TripNavPhase.enRoute && destGap <= safeArrivalMeters;
    _canCompleteRide = _phase == TripNavPhase.arrivedDestination && destGap <= safeCompletionMeters;
  }

  double _smoothDriverRotation() {
    if (_displayDriverLL == null) return _emaHeading;

    double targetHeading = _emaHeading;

    if (widget.args.role == TripNavigationRole.driver && _localHardwareHeading != null) {
      targetHeading = _localHardwareHeading!;
    }
    else {
      if (_backendDriverHeading > 0) {
        targetHeading = _backendDriverHeading;
      } else if (_lastDriverLL != null) {
        final double dist = _haversine(_lastDriverLL!, _driverLL!);
        if (dist > 2.0) {
          targetHeading = _bearingBetween(_lastDriverLL!, _driverLL!);
        }
      }
    }

    double diff = targetHeading - _emaHeading;
    while (diff < -180.0) diff += 360.0;
    while (diff > 180.0) diff -= 360.0;

    _emaHeading += diff * _smoothingFactor;
    return _emaHeading;
  }

  void _syncMarkers() {
    final bool showSeparatePickupMarker = !(widget.args.enableLivePickupTracking && _riderLL != null);
    final Set<Marker> next = <Marker>{
      if (showSeparatePickupMarker)
        Marker(
          markerId: const MarkerId('pickup'),
          position: _effectivePickupLL,
          icon: _pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          anchor: const Offset(0.5, 0.5),
          zIndex: 35,
        ),
      Marker(
        markerId: const MarkerId('destination'),
        position: widget.args.destination,
        icon: _dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        anchor: const Offset(0.5, 0.5),
        zIndex: 35,
      ),
    };

    if (_riderLL != null) {
      next.add(Marker(
        markerId: const MarkerId('rider_live'),
        position: _riderLL!,
        icon: _riderIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose),
        anchor: const Offset(0.5, 0.5),
        zIndex: 45,
      ));
    }

    for (int i = 0; i < widget.args.dropOffs.length; i++) {
      next.add(Marker(
        markerId: MarkerId('drop_$i'),
        position: widget.args.dropOffs[i],
        icon: _waypointIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        anchor: const Offset(0.5, 0.5),
        zIndex: 34,
      ));
    }

    if (_displayDriverLL != null) {
      next.add(Marker(
        markerId: const MarkerId('driver'),
        position: _displayDriverLL!, // Animated position!
        icon: _driverIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
        anchor: const Offset(0.5, 0.5),
        flat: true,
        rotation: _smoothDriverRotation(),
        zIndex: 50,
      ));
    }

    _markers..clear()..addAll(next);
  }

  Future<void> _rebuildRoute({bool force = false}) async {
    final DateTime now = DateTime.now();
    if (_busyRoute) return;
    if (_phase == TripNavPhase.completed || _phase == TripNavPhase.cancelled) return;

    final LatLng? from = (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? _enRouteOrigin : _displayDriverLL;
    final LatLng? to = (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? _currentTarget : _effectivePickupLL;

    if (from == null || to == null) return;

    if (!force && now.difference(_lastRouteAt) < _routeMinGap) {
      if (_lastDriverRouteLL != null && _haversine(_lastDriverRouteLL!, from) < _routeMoveThresholdMeters) {
        return;
      }
    }

    _busyRoute = true;
    _lastRouteAt = now;
    _lastDriverRouteLL = from;

    try {
      final _RouteResult? route = await _computeRoute(from, to);
      if (route == null || route.points.isEmpty) return;

      _distanceText = _fmtDistance(route.distanceMeters);
      _durationText = _fmtDuration(route.durationSeconds);

      final List<LatLng> precisionPoints = <LatLng>[from, ...route.points, to];
      _latestRoutePoints = precisionPoints;

      final isDark = Theme.of(context).brightness == Brightness.dark;

      _polylines
        ..clear()
        ..add(Polyline(
          polylineId: const PolylineId('nav_halo'),
          points: precisionPoints,
          color: isDark ? Colors.white.withOpacity(0.9) : Colors.black.withOpacity(0.85),
          width: 10,
          geodesic: true,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ))
        ..add(Polyline(
          polylineId: const PolylineId('nav_main'),
          points: precisionPoints,
          color: AppColors.primary,
          width: 5,
          geodesic: true,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ));

      // --- ENTERPRISE FIX: RESPECT NAVIGATION DEFAULT ---
      if (_map != null && !_didInitialFit) {
        _didInitialFit = true;
        // ONLY zoom out to overview bounds if the user explicitly turned off follow camera.
        // Otherwise, it skips the zoom-out and locks immediately into 3D navigation mode.
        if (!_isFollowCameraEnabled) {
          final LatLngBounds bounds = _boundsFrom(<LatLng>[from, to]);
          try { await _map!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 90)); } catch (_) {}
        } else {
          _followCamera(); // Force immediate 3D lock on boot
        }
      }
    } finally {
      _busyRoute = false;
    }
  }

  Future<_RouteResult?> _computeRoute(LatLng origin, LatLng destination) async {
    final Uri url = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');
    final Map<String, dynamic> body = <String, dynamic>{
      'origin': {'location': {'latLng': {'latitude': origin.latitude, 'longitude': origin.longitude}}},
      'destination': {'location': {'latLng': {'latitude': destination.latitude, 'longitude': destination.longitude}}},
      'travelMode': 'DRIVE',
      'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
      'units': 'METRIC',
      'polylineQuality': 'HIGH_QUALITY',
    };
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': ApiConstants.kGoogleApiKey,
      'X-Goog-FieldMask': 'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline',
    };

    try {
      final http.Response res = await http.post(url, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final Map<String, dynamic> decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final List<Map<String, dynamic>> routes = (decoded['routes'] as List?)?.whereType<Map>().map((Map e) => e.cast<String, dynamic>()).toList() ?? const <Map<String, dynamic>>[];
      if (routes.isEmpty) return null;
      final Map<String, dynamic> route = routes.first;
      final String encoded = route['polyline']?['encodedPolyline']?.toString() ?? '';
      if (encoded.isEmpty) return null;

      return _RouteResult(
        points: _decodePolyline(encoded),
        distanceMeters: _toInt(route['distanceMeters']) ?? 0,
        durationSeconds: _parseDurationSeconds(route['duration']?.toString() ?? '0s'),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _followCamera() async {
    if (_map == null) return;
    if (_phase == TripNavPhase.completed || _phase == TripNavPhase.cancelled) return;

    if (!_isFollowCameraEnabled || _viewMode != NavigationViewMode.navigation) return;

    final LatLng? target = (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? _enRouteOrigin : _displayDriverLL;
    if (target == null) return;

    double targetCameraBearing = _localHardwareHeading ?? _emaHeading;

    double diff = targetCameraBearing - _emaCameraBearing;
    while (diff < -180.0) diff += 360.0;
    while (diff > 180.0) diff -= 360.0;
    _emaCameraBearing += diff * _smoothingFactor;

    final double targetTilt = (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? 75.0 : 65.0;
    final double targetZoom = (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? 18.5 : 17.5;

    try {
      _isProgrammaticCameraMove = true;
      await _map!.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: target,
            zoom: targetZoom,
            tilt: targetTilt,
            bearing: _emaCameraBearing,
          ),
        ),
      );
      // Unlock panning detection right after auto-move
      Future.delayed(const Duration(milliseconds: 50), () => _isProgrammaticCameraMove = false);
    } catch (_) {}
  }

  Future<void> _fitOverview() async {
    if (_map == null) return;
    final List<LatLng> pts = <LatLng>[
      if (_displayDriverLL != null) _displayDriverLL!,
      if (_riderLL != null) _riderLL!,
      _effectivePickupLL,
      ...widget.args.dropOffs,
      widget.args.destination,
      ..._latestRoutePoints,
    ];
    if (pts.isEmpty) return;
    try {
      final LatLngBounds bounds = _boundsFrom(pts);
      _isProgrammaticCameraMove = true;
      await _map!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 92.0));
      Future.delayed(const Duration(milliseconds: 250), () => _isProgrammaticCameraMove = false);
    } catch (_) {}
  }

  Future<void> _activateOverviewMode() async {
    HapticFeedback.mediumImpact();
    if (!mounted) return;
    setState(() {
      _viewMode = NavigationViewMode.atAGlance;
      _isFollowCameraEnabled = false;
    });
    await _fitOverview();
  }

  Future<void> _activateNavigationMode() async {
    HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() {
      _viewMode = NavigationViewMode.navigation;
      _isFollowCameraEnabled = true;
    });
    if (_displayDriverLL != null) {
      _isProgrammaticCameraMove = true;
      await _map!.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(
        target: _displayDriverLL!, zoom: 18.5, tilt: 75.0, bearing: _localHardwareHeading ?? _emaHeading,
      )));
      Future.delayed(const Duration(milliseconds: 250), () => _isProgrammaticCameraMove = false);
    }
  }

  void _onCameraMoveStarted() {
    if (_isFollowCameraEnabled && !_isProgrammaticCameraMove) {
      // Screen physically touched by user - Break Follow Mode
      setState(() {
        _isFollowCameraEnabled = false;
        _viewMode = NavigationViewMode.atAGlance;
      });
    }
  }

  Future<void> _recenterMap() async {
    HapticFeedback.selectionClick();
    if (!mounted) return;

    setState(() {
      _isFollowCameraEnabled = true;
      _viewMode = NavigationViewMode.navigation;
    });

    if (_displayDriverLL != null) {
      _isProgrammaticCameraMove = true;
      await _map!.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(
        target: _displayDriverLL!, zoom: 18.5, tilt: 75.0, bearing: _localHardwareHeading ?? _emaHeading,
      )));
      Future.delayed(const Duration(milliseconds: 250), () => _isProgrammaticCameraMove = false);
    }
  }

  bool get _canRiderCancel => widget.args.role == TripNavigationRole.rider &&
      (_phase == TripNavPhase.driverToPickup || _phase == TripNavPhase.waitingPickup);

  bool get _showCancelButton => widget.args.showCancelButton &&
      (widget.args.role == TripNavigationRole.driver || _canRiderCancel);

  String? _resolvePrimaryActionLabel() {
    if (widget.args.role == TripNavigationRole.driver) {
      if (_phase == TripNavPhase.driverToPickup && widget.args.showArrivedPickupButton) return 'AT PICKUP';
      if (_phase == TripNavPhase.waitingPickup && widget.args.showStartTripButton) return 'START TRIP';
      if (_phase == TripNavPhase.enRoute && widget.args.showArrivedDestinationButton) return 'AT DESTINATION';
      if (_phase == TripNavPhase.arrivedDestination && widget.args.showCompleteTripButton) return 'COMPLETE RIDE';
    }
    return null;
  }

  bool _isPrimaryActionEnabled() {
    if (widget.args.role == TripNavigationRole.driver) {
      if (_phase == TripNavPhase.driverToPickup) return _canArrivePickup;
      if (_phase == TripNavPhase.waitingPickup) return _canStartTrip;
      if (_phase == TripNavPhase.enRoute) return _canArriveDestination;
      if (_phase == TripNavPhase.arrivedDestination) return _canCompleteRide;
    }
    return false;
  }

  Future<void> _handlePrimaryAction() async {
    if (_busyPrimaryAction) return;

    Future<void> Function()? callback;
    if (widget.args.role == TripNavigationRole.driver) {
      if (_phase == TripNavPhase.driverToPickup) callback = widget.args.onArrivedPickup;
      else if (_phase == TripNavPhase.waitingPickup) callback = widget.args.onStartTrip;
      else if (_phase == TripNavPhase.enRoute) callback = widget.args.onArrivedDestination;
      else if (_phase == TripNavPhase.arrivedDestination) callback = widget.args.onCompleteTrip;
    }

    if (callback == null) return;

    setState(() => _busyPrimaryAction = true);
    try {
      await callback.call();
      await _tick(force: true);
      if (_phase == TripNavPhase.waitingPickup && widget.args.role == TripNavigationRole.driver) {
        await _recenterMap();
      }
    } catch (e) {
      _emitError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busyPrimaryAction = false);
    }
  }

  Future<void> _cancelTripPressed() async {
    if (_busyCancel) return;
    if (_phase == TripNavPhase.completed || _phase == TripNavPhase.cancelled) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _busyCancel = true);
    try {
      if (widget.args.onCancelTrip != null) await widget.args.onCancelTrip!.call();
      if (!mounted) return;
      setState(() => _phase = TripNavPhase.cancelled);
      if (widget.args.autoCloseOnCancel) Navigator.of(context).maybePop();
    } catch (e) {
      _emitError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busyCancel = false);
    }
  }

  Map<String, dynamic> _eventMap(dynamic event) {
    if (event is BookingUpdate) return <String, dynamic>{'booking_status': event.status.toString(), ...event.data};
    if (event is Map<String, dynamic>) return event;
    if (event is Map) return event.cast<String, dynamic>();
    try {
      final dynamic data = event.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return data.cast<String, dynamic>();
    } catch (_) {}
    return <String, dynamic>{};
  }

  TripNavPhase? _coercePhase(Map<String, dynamic> payload, dynamic rawEvent) {
    if (rawEvent is BookingUpdate) {
      switch (rawEvent.status) {
        case BookingStatus.searching:
        case BookingStatus.driverAssigned:
        case BookingStatus.driverArriving: return TripNavPhase.driverToPickup;
        case BookingStatus.onTrip: return TripNavPhase.enRoute;
        case BookingStatus.completed: return TripNavPhase.completed;
        case BookingStatus.cancelled: return TripNavPhase.cancelled;
        case BookingStatus.failed: return null;
      }
    }
    final String raw = _string(payload['phase'] ?? payload['status'] ?? payload['state'] ?? (payload['ride'] is Map ? (payload['ride'] as Map)['status'] : null)).toLowerCase();
    switch (raw) {
      case 'searching':
      case 'accepted':
      case 'driver_assigned':
      case 'driver_arriving':
      case 'arriving':
      case 'enroute_pickup': return TripNavPhase.driverToPickup;
      case 'arrived_pickup': return TripNavPhase.waitingPickup;
      case 'in_ride':
      case 'on_trip':
      case 'in_progress':
      case 'started': return TripNavPhase.enRoute;
      case 'arrived_destination': return TripNavPhase.arrivedDestination;
      case 'completed':
      case 'done':
      case 'finished': return TripNavPhase.completed;
      case 'cancelled':
      case 'canceled': return TripNavPhase.cancelled;
      default: return null;
    }
  }

  int? _coerceStopIndex(Map<String, dynamic> payload, dynamic rawEvent) {
    final dynamic top = payload['stop_index'] ?? payload['waypoint_index'] ?? payload['active_stop_index'];
    if (_toInt(top) != null) return _toInt(top);
    try { return _toInt(rawEvent.stopIndex ?? rawEvent.waypointIndex ?? rawEvent.activeStopIndex); } catch (_) { return null; }
  }

  LatLng? _coerceDriverLL(Map<String, dynamic> payload, dynamic rawEvent) {
    final double? flatLat = _toDouble(payload['driver_lat'] ?? payload['driverLat'] ?? payload['lat'] ?? payload['latitude']);
    final double? flatLng = _toDouble(payload['driver_lng'] ?? payload['driverLng'] ?? payload['lng'] ?? payload['longitude']);
    if (flatLat != null && flatLng != null) return LatLng(flatLat, flatLng);
    try {
      final double? la = _toDouble(rawEvent.driverLat ?? rawEvent.lat ?? rawEvent.latitude);
      final double? lo = _toDouble(rawEvent.driverLng ?? rawEvent.lng ?? rawEvent.longitude);
      if (la != null && lo != null) return LatLng(la, lo);
    } catch (_) {}
    return null;
  }

  LatLng? _coerceRiderLL(Map<String, dynamic> payload, dynamic rawEvent) {
    final double? flatLat = _toDouble(payload['rider_lat'] ?? payload['riderLat'] ?? payload['user_lat'] ?? payload['pickup_lat']);
    final double? flatLng = _toDouble(payload['rider_lng'] ?? payload['riderLng'] ?? payload['user_lng'] ?? payload['pickup_lng']);
    if (flatLat != null && flatLng != null) return LatLng(flatLat, flatLng);
    return null;
  }

  double? _coerceHeading(Map<String, dynamic> payload, dynamic rawEvent) {
    final double? top = _toDouble(payload['driver_heading'] ?? payload['driverHeading'] ?? payload['heading'] ?? payload['bearing']);
    if (top != null) return top;
    try { return _toDouble(rawEvent.heading ?? rawEvent.bearing ?? rawEvent.driverHeading); } catch (_) { return null; }
  }

  String _string(dynamic v, [String fallback = '']) {
    if (v == null) return fallback;
    final String s = v.toString().trim();
    return s.isEmpty ? fallback : s;
  }
  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim());
  }
  int? _toInt(v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString().trim());
  }

  int _parseDurationSeconds(String v) {
    if (!v.endsWith('s')) return 0;
    return double.tryParse(v.substring(0, v.length - 1))?.round() ?? 0;
  }

  List<LatLng> _decodePolyline(String enc) {
    final List<LatLng> out = <LatLng>[];
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

  LatLngBounds _boundsFrom(List<LatLng> pts) {
    double minLat = pts.first.latitude, maxLat = pts.first.latitude, minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final LatLng p in pts) {
      minLat = math.min(minLat, p.latitude); maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude); maxLng = math.max(maxLng, p.longitude);
    }
    if (minLat == maxLat) { minLat -= 0.0001; maxLat += 0.0001; }
    if (minLng == maxLng) { minLng -= 0.0001; maxLng += 0.0001; }
    return LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
  }

  double _haversine(LatLng a, LatLng b) {
    const double earth = 6371000.0;
    double d2r(double d) => d * (math.pi / 180.0);
    final double h = math.sin(d2r(b.latitude - a.latitude) / 2) * math.sin(d2r(b.latitude - a.latitude) / 2) +
        math.cos(d2r(a.latitude)) * math.cos(d2r(b.latitude)) * math.sin(d2r(b.longitude - a.longitude) / 2) * math.sin(d2r(b.longitude - a.longitude) / 2);
    return 2 * earth * math.asin(math.min(1.0, math.sqrt(h)));
  }

  double _bearingBetween(LatLng a, LatLng b) {
    double d2r(double d) => d * (math.pi / 180.0);
    double r2d(double r) => r * (180.0 / math.pi);
    final double y = math.sin(d2r(b.longitude - a.longitude)) * math.cos(d2r(b.latitude));
    final double x = math.cos(d2r(a.latitude)) * math.sin(d2r(b.latitude)) -
        math.sin(d2r(a.latitude)) * math.cos(d2r(b.latitude)) * math.cos(d2r(b.longitude - a.longitude));
    return (r2d(math.atan2(y, x)) + 360.0) % 360.0;
  }

  String _fmtDistance(int m) => m < 1000 ? '$m m' : '${(m / 1000).toStringAsFixed(1)} km';
  String _fmtDuration(int s) {
    final int mins = (s / 60).round();
    if (mins < 60) return '${mins}m';
    return '${mins ~/ 60}h ${mins % 60}m';
  }

  String _phaseLabel() {
    switch (_phase) {
      case TripNavPhase.driverToPickup: return widget.args.role == TripNavigationRole.driver ? 'TO PICKUP' : 'DRIVER ARRIVING';
      case TripNavPhase.waitingPickup: return widget.args.role == TripNavigationRole.driver ? 'AT PICKUP' : 'PICKUP READY';
      case TripNavPhase.enRoute: return widget.args.role == TripNavigationRole.driver ? 'TO DESTINATION' : 'ON TRIP';
      case TripNavPhase.arrivedDestination: return widget.args.role == TripNavigationRole.driver ? 'AT DESTINATION' : 'ARRIVED';
      case TripNavPhase.completed: return 'COMPLETED';
      case TripNavPhase.cancelled: return 'CANCELLED';
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

    if (_map != null) _map!.setMapStyle(_getMapStyle(isDark));

    final bool showLandscapePanel = ui.landscape;
    final double landscapePanelWidth = showLandscapePanel ? (mq.size.width * 0.35).clamp(320.0, 400.0) : 0;
    final String? primaryLabel = _resolvePrimaryActionLabel();
    final bool showPrimaryAction = primaryLabel != null;

    final double sheetInitialSize = ui.landscape ? 1.0 : (ui.tiny ? 0.35 : (ui.compact ? 0.32 : 0.28));
    final double sheetMinSize = 0.15;
    final double sheetMaxSize = ui.landscape ? 1.0 : (ui.tiny ? 0.65 : 0.55);

    return WillPopScope(
      onWillPop: () async => true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: <Widget>[
            Positioned.fill(
              child: Container(
                color: theme.scaffoldBackgroundColor,
                child: _booting ? const SizedBox.shrink() : GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _displayDriverLL ?? _effectivePickupLL,
                    zoom: 17.5,
                    tilt: 65,
                  ),
                  myLocationEnabled: false,
                  myLocationButtonEnabled: false,
                  zoomControlsEnabled: false,
                  compassEnabled: false,
                  mapToolbarEnabled: false,
                  buildingsEnabled: true,
                  trafficEnabled: true,
                  rotateGesturesEnabled: true,
                  tiltGesturesEnabled: true,
                  padding: _calcMapPadding(mq, ui),
                  markers: _markers,
                  polylines: _polylines,
                  onCameraMoveStarted: _onCameraMoveStarted,
                  onMapCreated: (GoogleMapController c) {
                    _map = c;
                    if (isDark) _map!.setMapStyle(_getMapStyle(isDark));
                  },
                ),
              ),
            ),

            if (!_booting)
              Stack(
                children: [
                  Positioned(
                    top: 0, left: 0, right: 0, height: ui.gap(140),
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.black.withOpacity(0.7), Colors.transparent],
                          ),
                        ),
                      ),
                    ),
                  ),

                  Positioned(
                    top: mq.padding.top + ui.gap(12),
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

                  Positioned(
                    top: mq.padding.top + ui.gap(76),
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
                      top: mq.padding.top + ui.gap(76),
                      left: ui.inset(10),
                      bottom: ui.inset(10),
                      width: landscapePanelWidth,
                      child: SafeArea(
                        top: false,
                        child: _SolidPanelContainer(
                          ui: ui,
                          child: _buildSheetContent(ui, primaryLabel, showPrimaryAction),
                        ),
                      ),
                    )
                  else
                    Positioned(
                      left: ui.inset(10),
                      right: ui.inset(10),
                      bottom: ui.inset(10),
                      height: math.min(
                        mq.size.height * 0.68,
                        mq.size.height - (mq.padding.top + ui.gap(100)),
                      ),
                      child: SafeArea(
                        top: false,
                        child: DraggableScrollableSheet(
                          expand: true,
                          initialChildSize: sheetInitialSize,
                          minChildSize: sheetMinSize,
                          maxChildSize: sheetMaxSize,
                          builder: (BuildContext ctx, ScrollController controller) {
                            return _SolidPanelContainer(
                              ui: ui,
                              child: _buildSheetContent(ui, primaryLabel, showPrimaryAction, controller: controller),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSheetContent(UIScale ui, String? primaryLabel, bool showPrimaryAction, {ScrollController? controller}) {
    return _SheetContent(
      controller: controller,
      ui: ui,
      role: widget.args.role,
      phaseLabel: _phaseLabel(),
      driverName: widget.args.driverName ?? 'Driver',
      vehicleType: widget.args.vehicleType ?? 'Car',
      carPlate: widget.args.carPlate ?? '',
      rating: widget.args.rating ?? 0,
      from: widget.args.originText,
      to: widget.args.destinationText,
      currentTarget: _currentTargetText,
      dropOffTexts: widget.args.dropOffTexts,
      activeStopIndex: _activeStopIndex,
      showPrimaryAction: showPrimaryAction,
      primaryLabel: primaryLabel,
      showCancelButton: _showCancelButton,
      busyPrimary: _busyPrimaryAction,
      busyCancel: _busyCancel,
      primaryEnabled: _isPrimaryActionEnabled(),
      onPrimaryAction: _handlePrimaryAction,
      onCancelTrip: _cancelTripPressed,
      showMetaCard: widget.args.showMetaCard,
      errorText: _lastErrorText,
    );
  }
}

class _SolidPanelContainer extends StatelessWidget {
  final Widget child;
  final UIScale ui;
  const _SolidPanelContainer({required this.child, required this.ui});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? cs.surface.withOpacity(0.95) : Colors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(ui.radius(20)),
        border: Border.all(color: cs.onSurface.withOpacity(0.08), width: 1.0),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 16, offset: const Offset(0, 8))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ui.radius(20)),
        child: child,
      ),
    );
  }
}

class _SolidHeader extends StatelessWidget {
  final UIScale ui;
  final String phaseLabel;
  final String distanceText;
  final String durationText;
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
      height: ui.gap(48),
      padding: EdgeInsets.symmetric(horizontal: ui.inset(8)),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.85),
        borderRadius: BorderRadius.circular(ui.radius(18)),
        border: Border.all(color: Colors.white.withOpacity(0.18), width: 1.0),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: onBack,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(Icons.close_rounded, color: Colors.white, size: ui.icon(18)),
          ),
          SizedBox(width: ui.gap(8)),
          Container(width: 1, height: ui.gap(24), color: Colors.white.withOpacity(0.2)),
          SizedBox(width: ui.gap(8)),
          Icon(Icons.directions_car_rounded, color: AppColors.primary, size: ui.icon(16)),
          SizedBox(width: ui.gap(6)),
          Expanded(
            child: Text(
              phaseLabel,
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: ui.font(13), letterSpacing: 0.3),
            ),
          ),
          Container(width: 1, height: ui.gap(24), color: Colors.white.withOpacity(0.2)),
          SizedBox(width: ui.gap(10)),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(durationText, style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w900, fontSize: ui.font(15), height: 1.1)),
              Text(distanceText, style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: ui.font(10.5), height: 1.1)),
            ],
          ),
          SizedBox(width: ui.gap(8)),
        ],
      ),
    );
  }
}

// ENTERPRISE ACTION RAIL (PILLS)
class _PillActionRail extends StatelessWidget {
  final bool isFollowCameraEnabled;
  final VoidCallback onOverviewMode;
  final VoidCallback onRecenter;
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
      children: <Widget>[
        _ActionPill(
          icon: Icons.map_rounded,
          label: 'Overview',
          isActive: !isFollowCameraEnabled,
          onTap: onOverviewMode,
          ui: ui,
        ),

        if (!isFollowCameraEnabled) ...[
          SizedBox(height: ui.gap(12)),
          _ActionPill(
            icon: Icons.my_location_rounded,
            label: 'Re-center',
            isActive: true,
            onTap: onRecenter,
            ui: ui,
          ),
        ]
      ],
    );
  }
}

class _ActionPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
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
    final Color textColor = isActive ? Colors.white : Colors.white70;
    final Color iconColor = isActive ? AppColors.primary : Colors.white70;
    final Color bgColor = Colors.black.withOpacity(0.85);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: ui.inset(14), vertical: ui.inset(10)),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(ui.radius(24)),
          border: Border.all(color: isActive ? AppColors.primary.withOpacity(0.5) : Colors.white.withOpacity(0.18), width: 1.0),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 8, offset: const Offset(0, 4))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: iconColor, size: ui.icon(16)),
            SizedBox(width: ui.gap(8)),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: ui.font(13.5),
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetContent extends StatelessWidget {
  final ScrollController? controller;
  final UIScale ui;
  final TripNavigationRole role;
  final String phaseLabel;
  final String driverName;
  final String vehicleType;
  final String carPlate;
  final double rating;
  final String from;
  final String to;
  final String currentTarget;
  final List<String> dropOffTexts;
  final int activeStopIndex;
  final bool showPrimaryAction;
  final String? primaryLabel;
  final bool showCancelButton;
  final bool busyPrimary;
  final bool busyCancel;
  final bool primaryEnabled;
  final VoidCallback onPrimaryAction;
  final VoidCallback onCancelTrip;
  final bool showMetaCard;
  final String? errorText;

  const _SheetContent({
    required this.controller,
    required this.ui,
    required this.role,
    required this.phaseLabel,
    required this.driverName,
    required this.vehicleType,
    required this.carPlate,
    required this.rating,
    required this.from,
    required this.to,
    required this.currentTarget,
    required this.dropOffTexts,
    required this.activeStopIndex,
    required this.showPrimaryAction,
    required this.primaryLabel,
    required this.showCancelButton,
    required this.busyPrimary,
    required this.busyCancel,
    required this.primaryEnabled,
    required this.onPrimaryAction,
    required this.onCancelTrip,
    required this.showMetaCard,
    required this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    final List<Widget> children = <Widget>[
      if (controller != null) ...<Widget>[
        SizedBox(height: ui.gap(8)),
        Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(color: onSurface.withOpacity(0.2), borderRadius: BorderRadius.circular(10)),
          ),
        ),
        SizedBox(height: ui.gap(10)),
      ] else SizedBox(height: ui.gap(12)),

      Text(
        role == TripNavigationRole.driver ? 'DRIVER COMMAND VIEW' : 'RIDER LIVE VIEW',
        style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: ui.font(10), fontWeight: FontWeight.w800, letterSpacing: 0.5),
      ),
      SizedBox(height: ui.gap(8)),

      _DataRowDense(label1: role == TripNavigationRole.driver ? 'RIDER' : 'DRIVER', value1: driverName, label2: 'VEHICLE', value2: vehicleType, ui: ui),
      SizedBox(height: ui.gap(8)),
      _DataRowDense(label1: 'PLATE', value1: carPlate.isEmpty ? '—' : carPlate, label2: 'RATING', value2: rating > 0 ? '★ ${rating.toStringAsFixed(1)}' : '—', ui: ui),

      SizedBox(height: ui.gap(12)),
      Divider(color: onSurface.withOpacity(0.1), height: 1, thickness: 1),
      SizedBox(height: ui.gap(12)),

      if (showMetaCard)
        Container(
          padding: EdgeInsets.all(ui.inset(10)),
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(ui.radius(12)),
            border: Border.all(color: AppColors.primary.withOpacity(0.2)),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.assistant_navigation, color: AppColors.primary, size: ui.icon(16)),
              SizedBox(width: ui.gap(8)),
              Expanded(
                child: Text(
                  'TARGET: $currentTarget',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: ui.font(12)),
                ),
              ),
            ],
          ),
        ),
      if (showMetaCard) SizedBox(height: ui.gap(12)),

      Text('TRIP ROUTE', style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: ui.font(10), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      SizedBox(height: ui.gap(8)),
      _PathLine(label: 'FROM', value: from, isHighlight: true, ui: ui),
      if (dropOffTexts.isNotEmpty)
        for (int i = 0; i < dropOffTexts.length; i++) ...<Widget>[
          SizedBox(height: ui.gap(6)),
          _PathLine(label: 'STOP ${i + 1}', value: dropOffTexts[i], isHighlight: activeStopIndex == i && phaseLabel.contains('DESTINATION'), ui: ui),
        ],
      SizedBox(height: ui.gap(6)),
      _PathLine(label: 'TO', value: to, isHighlight: phaseLabel.contains('DESTINATION') || phaseLabel == 'COMPLETED', ui: ui),

      if (errorText != null && errorText!.trim().isNotEmpty) ...<Widget>[
        SizedBox(height: ui.gap(12)),
        Container(
          padding: EdgeInsets.all(ui.inset(10)),
          decoration: BoxDecoration(
            color: AppColors.error.withOpacity(0.08),
            borderRadius: BorderRadius.circular(ui.radius(12)),
            border: Border.all(color: AppColors.error.withOpacity(0.2)),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.error_outline_rounded, color: AppColors.error, size: ui.icon(16)),
              SizedBox(width: ui.gap(8)),
              Expanded(
                child: Text(errorText!, style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w700, fontSize: ui.font(12))),
              ),
            ],
          ),
        ),
      ],

      SizedBox(height: ui.gap(16)),
      _ActionRow(
        ui: ui,
        showPrimaryAction: showPrimaryAction,
        primaryLabel: primaryLabel,
        showCancelButton: showCancelButton,
        busyPrimary: busyPrimary,
        busyCancel: busyCancel,
        primaryEnabled: primaryEnabled,
        onPrimaryAction: onPrimaryAction,
        onCancelTrip: onCancelTrip,
      ),
      SizedBox(height: ui.gap(12)),
    ];

    if (controller != null) {
      return ListView(
        controller: controller,
        padding: EdgeInsets.symmetric(horizontal: ui.inset(12)),
        children: children,
      );
    }
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}

class _DataRowDense extends StatelessWidget {
  final String label1, value1, label2, value2;
  final UIScale ui;

  const _DataRowDense({required this.label1, required this.value1, required this.label2, required this.value2, required this.ui});

  @override
  Widget build(BuildContext context) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label1, style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: ui.font(10), fontWeight: FontWeight.w800)),
              SizedBox(height: ui.gap(2)),
              Text(value1, style: TextStyle(color: onSurface, fontSize: ui.font(13.5), fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label2, style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: ui.font(10), fontWeight: FontWeight.w800)),
              SizedBox(height: ui.gap(2)),
              Text(value2, style: TextStyle(color: onSurface, fontSize: ui.font(13.5), fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ],
    );
  }
}

class _PathLine extends StatelessWidget {
  final String label;
  final String value;
  final bool isHighlight;
  final UIScale ui;

  const _PathLine({required this.label, required this.value, required this.isHighlight, required this.ui});

  @override
  Widget build(BuildContext context) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: ui.gap(52),
          child: Text(label, style: TextStyle(color: isHighlight ? AppColors.primary : onSurface.withOpacity(0.5), fontSize: ui.font(10), fontWeight: FontWeight.w800)),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: isHighlight ? onSurface : onSurface.withOpacity(0.72), fontSize: ui.font(12.5), fontWeight: isHighlight ? FontWeight.w800 : FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  final UIScale ui;
  final bool showPrimaryAction;
  final String? primaryLabel;
  final bool showCancelButton;
  final bool busyPrimary;
  final bool busyCancel;
  final bool primaryEnabled;
  final VoidCallback onPrimaryAction;
  final VoidCallback onCancelTrip;

  const _ActionRow({
    required this.ui,
    required this.showPrimaryAction,
    required this.primaryLabel,
    required this.showCancelButton,
    required this.busyPrimary,
    required this.busyCancel,
    required this.primaryEnabled,
    required this.onPrimaryAction,
    required this.onCancelTrip,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        if (showPrimaryAction)
          Expanded(
            flex: 2,
            child: _ActionButton(
              label: primaryLabel ?? 'ACTION',
              isLoading: busyPrimary,
              isDisabled: !primaryEnabled,
              isPrimary: true,
              onTap: onPrimaryAction,
              ui: ui,
            ),
          ),
        if (showPrimaryAction && showCancelButton) SizedBox(width: ui.gap(10)),
        if (showCancelButton)
          Expanded(
            flex: 1,
            child: _ActionButton(
              label: 'CANCEL',
              isLoading: busyCancel,
              isDisabled: false,
              isPrimary: false,
              onTap: onCancelTrip,
              ui: ui,
            ),
          ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final bool isLoading;
  final bool isDisabled;
  final bool isPrimary;
  final VoidCallback onTap;
  final UIScale ui;

  const _ActionButton({
    required this.label,
    required this.isLoading,
    this.isDisabled = false,
    required this.isPrimary,
    required this.onTap,
    required this.ui,
  });

  @override
  Widget build(BuildContext context) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    final bool disabled = isLoading || isDisabled;

    final Color bgColor = isPrimary
        ? (disabled ? AppColors.primary.withOpacity(0.4) : AppColors.primary)
        : Colors.transparent;
    final Color borderColor = isPrimary
        ? Colors.transparent
        : onSurface.withOpacity(disabled ? 0.1 : 0.25);
    final Color textColor = isPrimary
        ? Colors.white.withOpacity(disabled ? 0.7 : 1.0)
        : onSurface.withOpacity(disabled ? 0.5 : 0.9);

    final height = math.max(40.0, ui.landscape ? ui.gap(42) : ui.gap(46));

    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(ui.radius(12)),
          border: Border.all(color: borderColor, width: 1.2),
        ),
        child: isLoading
            ? SizedBox(width: ui.gap(16), height: ui.gap(16), child: CircularProgressIndicator(strokeWidth: 2.0, color: textColor))
            : Text(label, style: TextStyle(color: textColor, fontSize: ui.font(13), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      ),
    );
  }
}

class _RouteResult {
  final List<LatLng> points;
  final int distanceMeters;
  final int durationSeconds;

  const _RouteResult({required this.points, required this.distanceMeters, required this.durationSeconds});
}