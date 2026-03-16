import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../api/url.dart';
import '../services/booking_controller.dart';
import '../themes/app_theme.dart';

// ============================================================================
// ENUMERATIONS & DATA CLASSES
// ============================================================================

enum TripNavigationRole { rider, driver }

enum TripNavPhase {
  driverToPickup,
  waitingPickup,
  enRoute,
  completed,
  cancelled,
}

enum NavigationViewMode {
  navigation,
  atAGlance,
}

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
    this.role = TripNavigationRole.rider,
    this.tickEvery = const Duration(seconds: 2),
    this.routeMinGap = const Duration(seconds: 2),
    this.arrivalMeters = 35.0,
    this.routeMoveThresholdMeters = 8.0,
    this.autoFollowCamera = true,
    this.showStartTripButton = true,
    this.showCancelButton = true,
    this.showMetaCard = true,
    this.showDebugPanel = false,
    this.enableLivePickupTracking = false,
    this.preserveStopOrder = true,
    this.autoCloseOnCancel = true,
  });
}

// ============================================================================
// LASER-THIN METRICS SYSTEM
// ============================================================================

class _ScreenMetrics {
  final BuildContext context;
  _ScreenMetrics(this.context);

  MediaQueryData get _mq => MediaQuery.of(context);
  double get screenWidth => _mq.size.width;
  double get screenHeight => _mq.size.height;
  double get topPadding => _mq.padding.top;
  double get bottomPadding => _mq.padding.bottom;

  bool get isPortrait => _mq.orientation == Orientation.portrait;
  bool get isLandscape => _mq.orientation == Orientation.landscape;
  bool get isSmallScreen => screenWidth < 360.0;
  bool get isCompactHeight => screenHeight < 600.0;

  double get scale => (screenWidth / 360.0).clamp(0.75, 1.15);

  double get spacing4 => 4.0 * scale;
  double get spacing6 => 6.0 * scale;
  double get spacing8 => 8.0 * scale;
  double get spacing10 => 10.0 * scale;
  double get spacing12 => 12.0 * scale;
  double get spacing14 => 14.0 * scale;
  double get spacing16 => 16.0 * scale;

  double get radiusSmall => 4.0 * scale;
  double get radiusMedium => 8.0 * scale;
  double get radiusLarge => 12.0 * scale;

  double get buttonHeight => isLandscape ? 36.0 : 42.0;

  double get fontSizeTiny => 9.0 * scale;
  double get fontSizeSmall => 10.0 * scale;
  double get fontSizeBase => 11.5 * scale;
  double get fontSizeMedium => 13.0 * scale;
  double get fontSizeLarge => 15.0 * scale;

  double get bottomSheetInitialSize {
    if (isLandscape) return 1.0;
    if (isCompactHeight) return 0.28;
    return 0.30;
  }

  double get bottomSheetMinSize {
    if (isLandscape) return 1.0;
    return 0.15;
  }

  double get bottomSheetMaxSize {
    if (isLandscape) return 1.0;
    return 0.60;
  }

  double get landscapePanelWidth => (screenWidth * 0.35).clamp(280.0, 360.0).toDouble();

  EdgeInsets mapPaddingFor({
    required bool showLandscapePanel,
    required double landscapePanelWidth,
    required bool navigationMode,
  }) {
    final double topPad = topPadding + 60.0;
    final double bottomPad = showLandscapePanel
        ? 12.0
        : (navigationMode ? (isLandscape ? 12.0 : 120.0) : (isLandscape ? 12.0 : 200.0));
    final double leftPad = showLandscapePanel ? (landscapePanelWidth + 10.0) : 0.0;
    final double rightPad = isLandscape ? 60.0 : 0.0;

    return EdgeInsets.only(
      top: topPad,
      bottom: bottomPad,
      left: leftPad,
      right: rightPad,
    );
  }
}

// ============================================================================
// MAIN TRIP NAVIGATION PAGE
// ============================================================================

class TripNavigationPage extends StatefulWidget {
  final TripNavigationArgs args;
  const TripNavigationPage({super.key, required this.args});

  @override
  State<TripNavigationPage> createState() => _TripNavigationPageState();
}

class _TripNavigationPageState extends State<TripNavigationPage> with WidgetsBindingObserver {
  GoogleMapController? _map;
  StreamSubscription<dynamic>? _bookingSub;
  Timer? _tickTimer;

  final Set<Marker> _markers = <Marker>{};
  final Set<Polyline> _polylines = <Polyline>{};
  final List<String> _debugLines = <String>[];

  BitmapDescriptor? _driverIcon;
  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _dropIcon;
  BitmapDescriptor? _riderIcon;

  LatLng? _driverLL;
  LatLng? _lastDriverLL;
  LatLng? _riderLL;
  double _driverHeading = 0.0;

  TripNavPhase _phase = TripNavPhase.driverToPickup;
  int _activeStopIndex = 0;
  NavigationViewMode _viewMode = NavigationViewMode.navigation;
  bool _isFollowCameraEnabled = true;

  String? _distanceText;
  String? _durationText;
  String? _lastErrorText;

  bool _busyRoute = false;
  bool _busyStart = false;
  bool _busyCancel = false;
  bool _busyTick = false;
  bool _didInitialFit = false;
  bool _canStartTrip = false;

  DateTime _lastRouteAt = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _lastDriverRouteLL;
  int _tickCount = 0;
  List<LatLng> _latestRoutePoints = <LatLng>[];

  Duration get _tickEvery => widget.args.tickEvery;
  Duration get _routeMinGap => widget.args.routeMinGap;
  double get _arrivalMeters => widget.args.arrivalMeters > 0 ? widget.args.arrivalMeters : 35.0;
  double get _routeMoveThresholdMeters => widget.args.routeMoveThresholdMeters > 0 ? widget.args.routeMoveThresholdMeters : 8.0;

  List<LatLng> get _allTargets => <LatLng>[...widget.args.dropOffs, widget.args.destination];
  List<String> get _allTargetTexts => <String>[...widget.args.dropOffTexts, widget.args.destinationText];

  LatLng get _effectivePickupLL {
    if (widget.args.enableLivePickupTracking && _riderLL != null) {
      return _riderLL!;
    }
    return widget.args.pickup;
  }

  LatLng get _currentTarget {
    if (_phase == TripNavPhase.driverToPickup || _phase == TripNavPhase.waitingPickup) {
      return _effectivePickupLL;
    }
    if (_allTargets.isEmpty) return widget.args.destination;
    return _allTargets[_activeStopIndex.clamp(0, _allTargets.length - 1)];
  }

  String get _currentTargetText {
    if (_phase == TripNavPhase.driverToPickup || _phase == TripNavPhase.waitingPickup) {
      return widget.args.originText;
    }
    if (_allTargetTexts.isEmpty) return widget.args.destinationText;
    return _allTargetTexts[_activeStopIndex.clamp(0, _allTargetTexts.length - 1)];
  }

  LatLng? get _enRouteOrigin {
    if (_phase != TripNavPhase.enRoute) return _driverLL;
    if (widget.args.role == TripNavigationRole.rider && _riderLL != null && _driverLL != null) {
      final double gap = _haversine(_riderLL!, _driverLL!);
      if (gap <= 120.0) return _riderLL!;
    }
    return _driverLL ?? _riderLL;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _driverLL = widget.args.initialDriverLocation;
    _riderLL = widget.args.initialRiderLocation ?? widget.args.pickup;
    _phase = widget.args.initialPhase;
    _isFollowCameraEnabled = widget.args.autoFollowCamera;

    _preloadIcons();
    _listenBooking();

    _tickTimer = Timer.periodic(_tickEvery, (_) => _tick());

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncMarkers();
      setState(() {});
      _tick(force: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bookingSub?.cancel();
    _tickTimer?.cancel();
    try { _map?.dispose(); } catch (_) {}
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _tick(force: true);
    }
  }

  void _log(String tag, [Object? data]) {
    final String stamp = DateTime.now().toIso8601String();
    final String line = data == null ? '[TripNav][$tag] $stamp' : '[TripNav][$tag] $stamp ${_safeJson(data)}';
    debugPrint(line);
    _debugLines.add(line);
    if (_debugLines.length > 80) _debugLines.removeRange(0, _debugLines.length - 80);
    if (mounted && widget.args.showDebugPanel) setState(() {});
  }

  String _safeJson(Object? data) {
    try { return jsonEncode(data); } catch (_) { return data.toString(); }
  }

  Future<void> _preloadIcons() async {
    try {
      await Future.wait<void>([_loadDriverIcon(), _loadPointIcons()]);
      if (!mounted) return;
      _syncMarkers();
      setState(() {});
    } catch (e) {
      _log('ICON_ERROR', e.toString());
    }
  }

  Future<void> _loadDriverIcon() async {
    if (_driverIcon != null) return;
    try {
      final ByteData bd = await rootBundle.load('assets/images/open_top_view_car.png');
      final Uint8List bytes = bd.buffer.asUint8List();
      final ui.Codec codec = await ui.instantiateImageCodec(bytes, targetWidth: 84);
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
    if (_pickupIcon != null && _dropIcon != null && _riderIcon != null) return;
    _pickupIcon = await _buildRingDotMarker(color: const Color(0xFF1A73E8));
    _dropIcon = await _buildRingDotMarker(color: const Color(0xFF00A651));
    _riderIcon = await _buildRingDotMarker(color: const Color(0xFFE91E63));
  }

  Future<BitmapDescriptor> _buildRingDotMarker({required Color color}) async {
    const double size = 48.0;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final Offset center = const Offset(size / 2, size / 2);

    canvas.drawCircle(center, 12, Paint()..color = Colors.white);
    canvas.drawCircle(center, 12, Paint()..style = PaintingStyle.stroke..strokeWidth = 4..color = color);
    canvas.drawCircle(center, 4, Paint()..color = color);

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
          (dynamic event) => _applyIncoming(event, fromStream: true),
      onError: (Object e) { _log('LIVE_STREAM_ERROR', e.toString()); },
      cancelOnError: false,
    );
  }

  Future<void> _tick({bool force = false}) async {
    if (!mounted || _busyTick) return;
    _busyTick = true;
    _tickCount += 1;

    try {
      await _applyLiveSnapshot();

      if (_driverLL == null && _riderLL == null) {
        _recomputeStartPermission();
        if (mounted) setState(() {});
        return;
      }

      if (_driverLL != null) {
        if (_phase == TripNavPhase.driverToPickup) {
          final double meters = _haversine(_driverLL!, _effectivePickupLL);
          if (meters <= _arrivalMeters) {
            _phase = TripNavPhase.waitingPickup;
            _didInitialFit = false;
          }
        } else if (_phase == TripNavPhase.enRoute) {
          final LatLng? movingOrigin = _enRouteOrigin;
          if (movingOrigin != null && _haversine(movingOrigin, _currentTarget) <= _arrivalMeters) {
            if (_activeStopIndex < _allTargets.length - 1) {
              _activeStopIndex += 1;
            } else {
              _phase = TripNavPhase.completed;
            }
            _didInitialFit = false;
          }
        }
      }

      _recomputeStartPermission();
      _syncMarkers();
      await _rebuildRoute(force: force);
      await _followCamera();

      if (!mounted) return;
      setState(() {});
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
      _applyIncoming(snap, fromStream: false);
    } catch (e) {
      _log('LIVE_SNAPSHOT_ERROR', e.toString());
    }
  }

  void _applyIncoming(dynamic event, {required bool fromStream}) {
    final Map<String, dynamic> payload = _eventMap(event);
    if (payload.isEmpty) return;

    if (event is BookingUpdate && event.status == BookingStatus.failed) {
      _emitError(event.displayMessage.isNotEmpty ? event.displayMessage : 'Booking issue.');
      return;
    }

    final String serverMessage = _string(
      payload['displayMessage'] ?? payload['message'] ?? payload['error_message'],
    );

    final bool hasServerError = payload['error'] == true ||
        payload['error_kind'] != null ||
        _string(payload['booking_status']).toLowerCase().contains('failed');

    if (hasServerError && serverMessage.isNotEmpty) {
      _emitError(serverMessage);
    }

    final LatLng? driver = _coerceDriverLL(payload, event);
    if (driver != null) {
      _lastDriverLL = _driverLL;
      _driverLL = driver;
    }

    final LatLng? rider = _coerceRiderLL(payload, event);
    if (rider != null) {
      _riderLL = rider;
    }

    final double? heading = _coerceHeading(payload, event);
    if (heading != null) _driverHeading = heading;

    final TripNavPhase? nextPhase = _coercePhase(payload, event);
    if (nextPhase != null) {
      if (nextPhase != _phase) {
        _didInitialFit = false;
        _lastDriverRouteLL = null;
      }
      _phase = nextPhase;
    }

    final int? stopIndex = _coerceStopIndex(payload, event);
    if (stopIndex != null && _allTargets.isNotEmpty) {
      _activeStopIndex = stopIndex.clamp(0, _allTargets.length - 1);
    }

    _recomputeStartPermission();
    _syncMarkers();
    if (mounted) setState(() {});
  }

  void _emitError(String message) {
    _lastErrorText = message;
    _log('ERROR_SILENT', message);
    if (mounted) setState(() {});
  }

  void _recomputeStartPermission() {
    if (_phase == TripNavPhase.waitingPickup) {
      _canStartTrip = true;
    } else if (_phase == TripNavPhase.driverToPickup && _driverLL != null) {
      _canStartTrip = _haversine(_driverLL!, _effectivePickupLL) <= _arrivalMeters;
    } else {
      _canStartTrip = false;
    }
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
        ),
      Marker(
        markerId: const MarkerId('destination'),
        position: widget.args.destination,
        icon: _dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        anchor: const Offset(0.5, 0.5),
      ),
    };

    if (_riderLL != null) {
      next.add(
        Marker(
          markerId: const MarkerId('rider_live'),
          position: _riderLL!,
          icon: _riderIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          anchor: const Offset(0.5, 0.5),
          zIndex: 45,
        ),
      );
    }

    for (int i = 0; i < widget.args.dropOffs.length; i++) {
      next.add(
        Marker(
          markerId: MarkerId('drop_$i'),
          position: widget.args.dropOffs[i],
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          anchor: const Offset(0.5, 0.5),
        ),
      );
    }

    if (_driverLL != null) {
      next.add(
        Marker(
          markerId: const MarkerId('driver'),
          position: _driverLL!,
          icon: _driverIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
          anchor: const Offset(0.5, 0.5),
          flat: true,
          rotation: _driverRotation(),
          zIndex: 50,
        ),
      );
    }

    _markers
      ..clear()
      ..addAll(next);
  }

  Future<void> _rebuildRoute({bool force = false}) async {
    final DateTime now = DateTime.now();

    if (_busyRoute) return;
    if (_phase == TripNavPhase.completed || _phase == TripNavPhase.cancelled) return;

    final LatLng? from = _phase == TripNavPhase.enRoute ? _enRouteOrigin : _driverLL;
    final LatLng? to = _phase == TripNavPhase.enRoute ? _currentTarget : _effectivePickupLL;

    if (from == null || to == null) return;
    if (!force && now.difference(_lastRouteAt) < _routeMinGap) return;
    if (!force && _lastDriverRouteLL != null) {
      final double moved = _haversine(_lastDriverRouteLL!, from);
      if (moved < _routeMoveThresholdMeters) return;
    }

    _busyRoute = true;
    _lastRouteAt = now;
    _lastDriverRouteLL = from;

    try {
      final _RouteResult? route = await _computeRoute(from, to);
      if (route == null || route.points.isEmpty) return;

      _distanceText = _fmtDistance(route.distanceMeters);
      _durationText = _fmtDuration(route.durationSeconds);

      final List<LatLng> precisionPoints = [
        from,
        ...route.points,
        to
      ];

      _latestRoutePoints = precisionPoints;

      _polylines
        ..clear()
        ..add(
          Polyline(
            polylineId: const PolylineId('nav_halo'),
            points: precisionPoints,
            color: Colors.white.withOpacity(0.92),
            width: 10,
            geodesic: true,
            jointType: JointType.round,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ),
        )
        ..add(
          Polyline(
            polylineId: const PolylineId('nav_main'),
            points: precisionPoints,
            color: AppColors.primary,
            width: 6,
            geodesic: true,
            jointType: JointType.round,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ),
        );

      if (_map != null && !_didInitialFit) {
        _didInitialFit = true;
        final LatLngBounds bounds = _boundsFrom(<LatLng>[from, to]);
        try {
          await _map!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 90));
        } catch (_) {}
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
    } catch (e) {
      return null;
    }
  }

  Future<void> _followCamera({bool force = false}) async {
    if (_map == null) return;
    if (_phase == TripNavPhase.completed || _phase == TripNavPhase.cancelled) return;

    if (!force) {
      if (_viewMode != NavigationViewMode.navigation) return;
      if (!_isFollowCameraEnabled) return;
      if (!widget.args.autoFollowCamera) return;
    }

    final LatLng? target = _phase == TripNavPhase.enRoute ? _enRouteOrigin : _driverLL;
    if (target == null) return;

    try {
      if (_viewMode == NavigationViewMode.navigation) {
        await _map!.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: target,
              zoom: _phase == TripNavPhase.enRoute ? 18.0 : 17.5,
              tilt: _phase == TripNavPhase.enRoute ? 60.0 : 45.0,
              bearing: _driverRotation(),
            ),
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _fitOverview() async {
    if (_map == null) return;
    final List<LatLng> pts = <LatLng>[
      if (_driverLL != null) _driverLL!,
      if (_riderLL != null) _riderLL!,
      _effectivePickupLL,
      ...widget.args.dropOffs,
      widget.args.destination,
      ..._latestRoutePoints,
    ];

    if (pts.isEmpty) return;

    try {
      final LatLngBounds bounds = _boundsFrom(pts);
      await _map!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 92.0));
    } catch (_) {}
  }

  Future<void> _activateOverviewMode() async {
    HapticFeedback.selectionClick();
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
    await _followCamera(force: true);
  }

  Future<void> _recenterMap() async {
    HapticFeedback.selectionClick();
    if (_viewMode == NavigationViewMode.navigation) {
      if (!mounted) return;
      setState(() => _isFollowCameraEnabled = true);
      await _followCamera(force: true);
    } else {
      await _fitOverview();
    }
  }

  double _driverRotation() {
    if (_driverHeading > 0) return _driverHeading;
    if (_driverLL == null) return 0.0;
    if (_lastDriverLL != null && _haversine(_lastDriverLL!, _driverLL!) > 2.0) {
      return _bearingBetween(_lastDriverLL!, _driverLL!);
    }
    return _bearingBetween(_driverLL!, _currentTarget);
  }

  Future<void> _startTripPressed() async {
    if (_busyStart || !_canStartTrip) return;
    setState(() => _busyStart = true);
    try {
      if (widget.args.onStartTrip != null) await widget.args.onStartTrip!.call();
      if (!mounted) return;
      setState(() {
        _phase = TripNavPhase.enRoute;
        _didInitialFit = false;
        _lastDriverRouteLL = null;
      });
      await _tick(force: true);
      await _activateNavigationMode();
    } catch (e) {
      _emitError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (!mounted) return;
      setState(() => _busyStart = false);
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
      if (!mounted) return;
      setState(() => _busyCancel = false);
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
      case 'searching': case 'driver_assigned': case 'driver_arriving': case 'arriving': case 'enroute_pickup': return TripNavPhase.driverToPickup;
      case 'arrived_pickup': return TripNavPhase.waitingPickup;
      case 'in_ride': case 'on_trip': case 'in_progress': case 'started': return TripNavPhase.enRoute;
      case 'completed': case 'done': case 'finished': return TripNavPhase.completed;
      case 'cancelled': case 'canceled': return TripNavPhase.cancelled;
      default: return null;
    }
  }

  int? _coerceStopIndex(Map<String, dynamic> payload, dynamic rawEvent) {
    final dynamic top = payload['stop_index'] ?? payload['waypoint_index'] ?? payload['active_stop_index'];
    if (_toInt(top) != null) return _toInt(top);
    if (payload['ride'] is Map) {
      final int? nested = _toInt((payload['ride'] as Map)['stop_index'] ?? (payload['ride'] as Map)['waypoint_index'] ?? (payload['ride'] as Map)['active_stop_index']);
      if (nested != null) return nested;
    }
    try { return _toInt(rawEvent.stopIndex ?? rawEvent.waypointIndex ?? rawEvent.activeStopIndex); } catch (_) {}
    return null;
  }

  LatLng? _coerceDriverLL(Map<String, dynamic> payload, dynamic rawEvent) {
    final double? flatLat = _toDouble(payload['driver_lat'] ?? payload['driverLat'] ?? payload['lat'] ?? payload['latitude']);
    final double? flatLng = _toDouble(payload['driver_lng'] ?? payload['driverLng'] ?? payload['lng'] ?? payload['longitude']);
    if (flatLat != null && flatLng != null) return LatLng(flatLat, flatLng);
    final dynamic driver = payload['driver'] ?? payload['location'];
    if (driver is Map) {
      final double? la = _toDouble(driver['lat'] ?? driver['latitude']);
      final double? lo = _toDouble(driver['lng'] ?? driver['longitude']);
      if (la != null && lo != null) return LatLng(la, lo);
    }
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
    final dynamic ride = payload['ride'];
    if (ride is Map) {
      final dynamic pickup = ride['pickup'];
      if (pickup is Map) {
        final double? la = _toDouble(pickup['lat'] ?? pickup['latitude']);
        final double? lo = _toDouble(pickup['lng'] ?? pickup['longitude']);
        if (la != null && lo != null) return LatLng(la, lo);
      }
    }
    try {
      final double? la = _toDouble(rawEvent.riderLat ?? rawEvent.userLat ?? rawEvent.pickupLat);
      final double? lo = _toDouble(rawEvent.riderLng ?? rawEvent.userLng ?? rawEvent.pickupLng);
      if (la != null && lo != null) return LatLng(la, lo);
    } catch (_) {}
    return null;
  }

  double? _coerceHeading(Map<String, dynamic> payload, dynamic rawEvent) {
    final double? top = _toDouble(payload['driver_heading'] ?? payload['driverHeading'] ?? payload['heading'] ?? payload['bearing']);
    if (top != null) return top;
    final dynamic driver = payload['driver'];
    if (driver is Map) {
      final double? nested = _toDouble(driver['heading'] ?? driver['bearing']);
      if (nested != null) return nested;
    }
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
    final double h = math.sin(d2r(b.latitude - a.latitude) / 2) * math.sin(d2r(b.latitude - a.latitude) / 2) + math.cos(d2r(a.latitude)) * math.cos(d2r(b.latitude)) * math.sin(d2r(b.longitude - a.longitude) / 2) * math.sin(d2r(b.longitude - a.longitude) / 2);
    return 2 * earth * math.asin(math.min(1.0, math.sqrt(h)));
  }
  double _bearingBetween(LatLng a, LatLng b) {
    double d2r(double d) => d * (math.pi / 180.0);
    double r2d(double r) => r * (180.0 / math.pi);
    final double y = math.sin(d2r(b.longitude - a.longitude)) * math.cos(d2r(b.latitude));
    final double x = math.cos(d2r(a.latitude)) * math.sin(d2r(b.latitude)) - math.sin(d2r(a.latitude)) * math.cos(d2r(b.latitude)) * math.cos(d2r(b.longitude - a.longitude));
    return (r2d(math.atan2(y, x)) + 360.0) % 360.0;
  }

  String _fmtDistance(int m) => m < 1000 ? '$m m' : '${(m / 1000).toStringAsFixed(1)} km';
  String _fmtDuration(int s) {
    final int mins = (s / 60).round();
    if (mins < 60) return '${mins}m';
    return '${mins ~/ 60}h ${mins % 60}m';
  }
  String _fmtLL(LatLng ll) => '${ll.latitude.toStringAsFixed(5)},${ll.longitude.toStringAsFixed(5)}';
  String? _fmtLLOrNull(LatLng? ll) => ll == null ? null : _fmtLL(ll);
  Map<String, dynamic> _llMap(LatLng ll) => <String, dynamic>{'lat': ll.latitude, 'lng': ll.longitude};

  // ========================================================================
  // MAIN BUILD METHOD
  // ========================================================================

  @override
  Widget build(BuildContext context) {
    final _ScreenMetrics metrics = _ScreenMetrics(context);
    final bool showLandscapePanel = metrics.isLandscape;
    final double landscapePanelWidth = showLandscapePanel ? metrics.landscapePanelWidth : 0.0;
    final bool showStartButton = widget.args.showStartTripButton && (_phase == TripNavPhase.driverToPickup || _phase == TripNavPhase.waitingPickup);

    return WillPopScope(
      onWillPop: () async => true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: <Widget>[
            // Base Google Map
            Positioned.fill(
              child: GoogleMap(
                initialCameraPosition: CameraPosition(target: _driverLL ?? _effectivePickupLL, zoom: 16.2),
                myLocationEnabled: false,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                compassEnabled: false,
                mapToolbarEnabled: false,
                buildingsEnabled: true,
                trafficEnabled: true,
                rotateGesturesEnabled: true,
                tiltGesturesEnabled: true,
                padding: metrics.mapPaddingFor(
                  showLandscapePanel: showLandscapePanel,
                  landscapePanelWidth: landscapePanelWidth,
                  navigationMode: _viewMode == NavigationViewMode.navigation,
                ),
                markers: _markers,
                polylines: _polylines,
                onMapCreated: (GoogleMapController c) {
                  _map = c;
                  _tick(force: true);
                },
              ),
            ),

            // Original App Theme Gradient Layer
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        Colors.black.withOpacity(0.58),
                        Colors.black.withOpacity(0.16),
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black.withOpacity(0.10),
                        Colors.black.withOpacity(0.44),
                      ],
                      stops: const <double>[0.0, 0.16, 0.34, 0.56, 0.78, 1.0],
                    ),
                  ),
                ),
              ),
            ),

            // Top Header Strip
            Positioned(
              top: metrics.topPadding + 10, left: metrics.spacing10, right: metrics.spacing10,
              child: _ThinHeader(
                metrics: metrics,
                phase: _phase,
                distanceText: _distanceText ?? '—',
                durationText: _durationText ?? '—',
                onBack: () => Navigator.of(context).maybePop(),
              ),
            ),

            // Right Action Rail
            Positioned(
              top: metrics.topPadding + 70, right: metrics.spacing10,
              child: _ActionRail(
                isNavigationMode: _viewMode == NavigationViewMode.navigation,
                isFollowCameraEnabled: _isFollowCameraEnabled,
                onNavigationMode: _activateNavigationMode,
                onOverviewMode: _activateOverviewMode,
                onRecenter: _recenterMap,
                metrics: metrics,
              ),
            ),

            // Bottom Sheet / Side Panel
            if (showLandscapePanel)
              Positioned(
                top: metrics.topPadding + 70.0, left: metrics.spacing10, bottom: metrics.spacing10, width: landscapePanelWidth,
                child: SafeArea(
                  top: false,
                  child: _PanelContainer(
                    metrics: metrics,
                    child: _DenseSheetContent(
                      controller: null, metrics: metrics, phase: _phase,
                      driverName: widget.args.driverName ?? 'Driver', vehicleType: widget.args.vehicleType ?? 'Car', carPlate: widget.args.carPlate ?? '', rating: widget.args.rating ?? 0,
                      from: widget.args.originText, to: widget.args.destinationText, currentTarget: _currentTargetText, dropOffTexts: widget.args.dropOffTexts, activeStopIndex: _activeStopIndex,
                      showStartButton: showStartButton, showCancelButton: widget.args.showCancelButton, busyStart: _busyStart, busyCancel: _busyCancel,
                      canStartTrip: _canStartTrip,
                      onStartTrip: _startTripPressed, onCancelTrip: _cancelTripPressed,
                    ),
                  ),
                ),
              )
            else
              Positioned(
                left: metrics.spacing10, right: metrics.spacing10, bottom: metrics.spacing10,
                height: math.min(MediaQuery.of(context).size.height * 0.65, MediaQuery.of(context).size.height - (metrics.topPadding + 120.0)),
                child: SafeArea(
                  top: false,
                  child: DraggableScrollableSheet(
                    expand: true,
                    initialChildSize: metrics.bottomSheetInitialSize,
                    minChildSize: metrics.bottomSheetMinSize,
                    maxChildSize: metrics.bottomSheetMaxSize,
                    builder: (BuildContext ctx, ScrollController controller) {
                      return _PanelContainer(
                        metrics: metrics,
                        child: _DenseSheetContent(
                          controller: controller, metrics: metrics, phase: _phase,
                          driverName: widget.args.driverName ?? 'Driver', vehicleType: widget.args.vehicleType ?? 'Car', carPlate: widget.args.carPlate ?? '', rating: widget.args.rating ?? 0,
                          from: widget.args.originText, to: widget.args.destinationText, currentTarget: _currentTargetText, dropOffTexts: widget.args.dropOffTexts, activeStopIndex: _activeStopIndex,
                          showStartButton: showStartButton, showCancelButton: widget.args.showCancelButton, busyStart: _busyStart, busyCancel: _busyCancel,
                          canStartTrip: _canStartTrip,
                          onStartTrip: _startTripPressed, onCancelTrip: _cancelTripPressed,
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// THEMED UI COMPONENTS
// ============================================================================

class _PanelContainer extends StatelessWidget {
  final Widget child;
  final _ScreenMetrics metrics;

  const _PanelContainer({required this.child, required this.metrics});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(metrics.radiusLarge),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor.withOpacity(0.95),
            borderRadius: BorderRadius.circular(metrics.radiusLarge),
            border: Border.all(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.08), width: 0.8),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, 8))],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _ThinHeader extends StatelessWidget {
  final _ScreenMetrics metrics;
  final TripNavPhase phase;
  final String distanceText;
  final String durationText;
  final VoidCallback onBack;

  const _ThinHeader({required this.metrics, required this.phase, required this.distanceText, required this.durationText, required this.onBack});

  @override
  Widget build(BuildContext context) {
    Color tone;
    switch (phase) {
      case TripNavPhase.driverToPickup: tone = const Color(0xFFFF9800); break;
      case TripNavPhase.waitingPickup: tone = const Color(0xFF2196F3); break;
      case TripNavPhase.enRoute: tone = AppColors.primary; break;
      case TripNavPhase.completed: tone = const Color(0xFF00897B); break;
      case TripNavPhase.cancelled: tone = const Color(0xFFB00020); break;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(metrics.radiusLarge),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          height: 48 * metrics.scale,
          padding: EdgeInsets.symmetric(horizontal: metrics.spacing8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            borderRadius: BorderRadius.circular(metrics.radiusLarge),
            border: Border.all(color: Colors.white.withOpacity(0.15), width: 0.8),
          ),
          child: Row(
            children: [
              IconButton(onPressed: onBack, icon: Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18 * metrics.scale), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
              SizedBox(width: metrics.spacing10),
              Container(width: 1, height: 24 * metrics.scale, color: Colors.white.withOpacity(0.15)),
              SizedBox(width: metrics.spacing10),
              Icon(Icons.trip_origin_rounded, color: tone, size: 14 * metrics.scale),
              SizedBox(width: metrics.spacing6),
              Text(
                phase == TripNavPhase.enRoute ? "ON TRIP" : "EN ROUTE",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: metrics.fontSizeBase, letterSpacing: 0.5),
              ),
              const Spacer(),
              Container(width: 1, height: 24 * metrics.scale, color: Colors.white.withOpacity(0.15)),
              SizedBox(width: metrics.spacing10),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(durationText, style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w900, fontSize: metrics.fontSizeMedium, height: 1.1)),
                  Text(distanceText, style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: metrics.fontSizeTiny, height: 1.1)),
                ],
              ),
              SizedBox(width: metrics.spacing6),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionRail extends StatelessWidget {
  final bool isNavigationMode;
  final bool isFollowCameraEnabled;
  final VoidCallback onNavigationMode;
  final VoidCallback onOverviewMode;
  final VoidCallback onRecenter;
  final _ScreenMetrics metrics;

  const _ActionRail({required this.isNavigationMode, required this.isFollowCameraEnabled, required this.onNavigationMode, required this.onOverviewMode, required this.onRecenter, required this.metrics});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(metrics.radiusLarge),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: 48 * metrics.scale,
          padding: EdgeInsets.symmetric(vertical: metrics.spacing8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            borderRadius: BorderRadius.circular(metrics.radiusLarge),
            border: Border.all(color: Colors.white.withOpacity(0.15), width: 0.8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ThinIconButton(icon: Icons.navigation_rounded, isActive: isNavigationMode, onTap: onNavigationMode, metrics: metrics),
              SizedBox(height: metrics.spacing10),
              _ThinIconButton(icon: Icons.map_rounded, isActive: !isNavigationMode, onTap: onOverviewMode, metrics: metrics),
              SizedBox(height: metrics.spacing10),
              Container(height: 1, width: 24 * metrics.scale, color: Colors.white.withOpacity(0.15)),
              SizedBox(height: metrics.spacing10),
              _ThinIconButton(icon: Icons.gps_fixed_rounded, isActive: isFollowCameraEnabled, onTap: onRecenter, metrics: metrics),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThinIconButton extends StatelessWidget {
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;
  final _ScreenMetrics metrics;

  const _ThinIconButton({required this.icon, required this.isActive, required this.onTap, required this.metrics});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32 * metrics.scale, height: 32 * metrics.scale,
        decoration: BoxDecoration(
          color: isActive ? AppColors.primary.withOpacity(0.2) : Colors.transparent,
          shape: BoxShape.circle,
          border: Border.all(color: isActive ? AppColors.primary : Colors.transparent, width: 0.8),
        ),
        child: Icon(icon, color: isActive ? AppColors.primary : Colors.white70, size: 16 * metrics.scale),
      ),
    );
  }
}

class _DenseSheetContent extends StatelessWidget {
  final ScrollController? controller;
  final _ScreenMetrics metrics;
  final TripNavPhase phase;
  final String driverName;
  final String vehicleType;
  final String carPlate;
  final double rating;
  final String from;
  final String to;
  final String currentTarget;
  final List<String> dropOffTexts;
  final int activeStopIndex;
  final bool showStartButton;
  final bool showCancelButton;
  final bool busyStart;
  final bool busyCancel;
  final bool canStartTrip; // CRITICAL: Receive permission
  final VoidCallback onStartTrip;
  final VoidCallback onCancelTrip;

  const _DenseSheetContent({required this.controller, required this.metrics, required this.phase, required this.driverName, required this.vehicleType, required this.carPlate, required this.rating, required this.from, required this.to, required this.currentTarget, required this.dropOffTexts, required this.activeStopIndex, required this.showStartButton, required this.showCancelButton, required this.busyStart, required this.busyCancel, required this.canStartTrip, required this.onStartTrip, required this.onCancelTrip});

  @override
  Widget build(BuildContext context) {
    final List<Widget> content = [
      if (controller != null) ...[
        SizedBox(height: metrics.spacing8),
        Center(child: Container(width: 32, height: 4, decoration: BoxDecoration(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.2), borderRadius: BorderRadius.circular(10)))),
        SizedBox(height: metrics.spacing10),
      ] else SizedBox(height: metrics.spacing16),

      _DataRowDense(label1: 'DRIVER', value1: driverName, label2: 'VEHICLE', value2: vehicleType, metrics: metrics),
      SizedBox(height: metrics.spacing8),
      _DataRowDense(label1: 'PLATE', value1: carPlate.isEmpty ? '—' : carPlate, label2: 'RATING', value2: rating > 0 ? '★ ${rating.toStringAsFixed(1)}' : '—', metrics: metrics),

      SizedBox(height: metrics.spacing12),
      Divider(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.1), height: 1, thickness: 0.8),
      SizedBox(height: metrics.spacing12),

      Text('TRIP ROUTE', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5), fontSize: metrics.fontSizeTiny, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      SizedBox(height: metrics.spacing8),
      _PathLine(label: 'FROM', value: from, isHighlight: true, metrics: metrics),
      if (dropOffTexts.isNotEmpty) for (int i = 0; i < dropOffTexts.length; i++) ...[
        SizedBox(height: metrics.spacing6),
        _PathLine(label: 'STOP ${i + 1}', value: dropOffTexts[i], isHighlight: phase == TripNavPhase.enRoute && i == activeStopIndex, metrics: metrics),
      ],
      SizedBox(height: metrics.spacing6),
      _PathLine(label: 'TO', value: to, isHighlight: phase != TripNavPhase.driverToPickup, metrics: metrics),

      SizedBox(height: metrics.spacing12),
      Container(
        padding: EdgeInsets.symmetric(horizontal: metrics.spacing10, vertical: metrics.spacing8),
        decoration: BoxDecoration(color: AppColors.primary.withOpacity(0.08), borderRadius: BorderRadius.circular(metrics.radiusSmall), border: Border.all(color: AppColors.primary.withOpacity(0.2), width: 0.5)),
        child: Row(
          children: [
            Icon(Icons.near_me_rounded, color: AppColors.primary, size: 14 * metrics.scale),
            SizedBox(width: metrics.spacing8),
            Expanded(child: Text('TARGET: $currentTarget', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: metrics.fontSizeSmall))),
          ],
        ),
      ),

      SizedBox(height: metrics.spacing16),
      // Pass canStartTrip down
      _ActionRow(metrics: metrics, showStartButton: showStartButton, showCancelButton: showCancelButton, phase: phase, busyStart: busyStart, busyCancel: busyCancel, canStartTrip: canStartTrip, onStartTrip: onStartTrip, onCancelTrip: onCancelTrip),
      SizedBox(height: metrics.spacing16),
    ];

    if (controller != null) return ListView(controller: controller, padding: EdgeInsets.symmetric(horizontal: metrics.spacing12), children: content);
    return SingleChildScrollView(padding: EdgeInsets.symmetric(horizontal: metrics.spacing12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: content));
  }
}

class _DataRowDense extends StatelessWidget {
  final String label1, value1, label2, value2;
  final _ScreenMetrics metrics;
  const _DataRowDense({required this.label1, required this.value1, required this.label2, required this.value2, required this.metrics});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label1, style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: metrics.fontSizeTiny, fontWeight: FontWeight.w800)), const SizedBox(height: 2), Text(value1, style: TextStyle(color: onSurface, fontSize: metrics.fontSizeBase, fontWeight: FontWeight.w600))])),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label2, style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: metrics.fontSizeTiny, fontWeight: FontWeight.w800)), const SizedBox(height: 2), Text(value2, style: TextStyle(color: onSurface, fontSize: metrics.fontSizeBase, fontWeight: FontWeight.w600))])),
      ],
    );
  }
}

class _PathLine extends StatelessWidget {
  final String label;
  final String value;
  final bool isHighlight;
  final _ScreenMetrics metrics;

  const _PathLine({required this.label, required this.value, required this.isHighlight, required this.metrics});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        SizedBox(width: 45 * metrics.scale, child: Text(label, style: TextStyle(color: isHighlight ? AppColors.primary : onSurface.withOpacity(0.5), fontSize: metrics.fontSizeTiny, fontWeight: FontWeight.w800))),
        Expanded(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: isHighlight ? onSurface : onSurface.withOpacity(0.7), fontSize: metrics.fontSizeSmall, fontWeight: isHighlight ? FontWeight.w600 : FontWeight.w500))),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  final _ScreenMetrics metrics;
  final bool showStartButton, showCancelButton, busyStart, busyCancel;
  final TripNavPhase phase;
  final bool canStartTrip;
  final VoidCallback onStartTrip, onCancelTrip;

  const _ActionRow({required this.metrics, required this.showStartButton, required this.showCancelButton, required this.phase, required this.busyStart, required this.busyCancel, required this.canStartTrip, required this.onStartTrip, required this.onCancelTrip});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (showStartButton) Expanded(flex: 2, child: _ActionButton(
            label: canStartTrip ? 'START' : 'ARRIVING',
            isLoading: busyStart,
            isDisabled: !canStartTrip, // CRITICAL: Disable button if driver isn't here
            isPrimary: true,
            onTap: onStartTrip,
            metrics: metrics
        )),
        if (showStartButton && showCancelButton) SizedBox(width: metrics.spacing10),
        if (showCancelButton) Expanded(flex: 1, child: _ActionButton(
            label: 'CANCEL',
            isLoading: busyCancel,
            isDisabled: false,
            isPrimary: false,
            onTap: onCancelTrip,
            metrics: metrics
        )),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final bool isLoading;
  final bool isDisabled; // Controls visual & interactive state
  final bool isPrimary;
  final VoidCallback onTap;
  final _ScreenMetrics metrics;

  const _ActionButton({required this.label, required this.isLoading, this.isDisabled = false, required this.isPrimary, required this.onTap, required this.metrics});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final bool actuallyDisabled = isLoading || isDisabled;

    Color bgColor;
    Color borderColor;
    Color textColor;

    if (isPrimary) {
      bgColor = actuallyDisabled ? AppColors.primary.withOpacity(0.3) : AppColors.primary;
      borderColor = actuallyDisabled ? Colors.transparent : AppColors.primary;
      textColor = actuallyDisabled ? Colors.white.withOpacity(0.6) : Colors.white;
    } else {
      bgColor = Colors.transparent;
      borderColor = actuallyDisabled ? onSurface.withOpacity(0.1) : onSurface.withOpacity(0.2);
      textColor = actuallyDisabled ? onSurface.withOpacity(0.4) : onSurface.withOpacity(0.8);
    }

    return GestureDetector(
      onTap: actuallyDisabled ? null : onTap,
      child: Container(
        height: metrics.buttonHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(metrics.radiusSmall),
          border: Border.all(color: borderColor, width: 1.0),
        ),
        child: isLoading
            ? SizedBox(width: 14 * metrics.scale, height: 14 * metrics.scale, child: CircularProgressIndicator(strokeWidth: 1.5, color: textColor))
            : Text(label, style: TextStyle(color: textColor, fontSize: metrics.fontSizeBase, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      ),
    );
  }
}

// ============================================================================
// DATA CLASSES
// ============================================================================
class _RouteResult {
  final List<LatLng> points;
  final int distanceMeters;
  final int durationSeconds;

  const _RouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });
}