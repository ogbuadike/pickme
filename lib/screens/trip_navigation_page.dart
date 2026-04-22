// lib/screens/trip_navigation_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../api/url.dart';
import '../services/booking_controller.dart';
import '../themes/app_theme.dart';

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
    this.tickEvery = const Duration(seconds: 2),
    this.routeMinGap = const Duration(seconds: 2),
    this.arrivalMeters = 150.0,
    this.routeMoveThresholdMeters = 8.0,
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

class _ScreenMetrics {
  final BuildContext context;
  _ScreenMetrics(this.context);

  MediaQueryData get _mq => MediaQuery.of(context);
  double get screenWidth => _mq.size.width;
  double get screenHeight => _mq.size.height;
  double get topPadding => _mq.padding.top;
  bool get isLandscape => _mq.orientation == Orientation.landscape;
  bool get isCompactHeight => screenHeight < 620.0;
  double get scale => (screenWidth / 390.0).clamp(0.78, 1.12);

  double get spacing6 => 6.0 * scale;
  double get spacing8 => 8.0 * scale;
  double get spacing10 => 10.0 * scale;
  double get spacing12 => 12.0 * scale;
  double get spacing14 => 14.0 * scale;
  double get spacing16 => 16.0 * scale;
  double get radiusSmall => 8.0 * scale;
  double get radiusMedium => 12.0 * scale;
  double get radiusLarge => 18.0 * scale;
  double get buttonHeight => isLandscape ? 38.0 : 44.0;
  double get fontTiny => 10.0 * scale;
  double get fontSmall => 11.5 * scale;
  double get fontBase => 13.0 * scale;
  double get fontLarge => 15.5 * scale;

  double get bottomSheetInitialSize => isLandscape ? 1.0 : (isCompactHeight ? 0.32 : 0.36);
  double get bottomSheetMinSize => isLandscape ? 1.0 : 0.18;
  double get bottomSheetMaxSize => isLandscape ? 1.0 : 0.66;
  double get landscapePanelWidth => (screenWidth * 0.35).clamp(290.0, 380.0);

  EdgeInsets mapPaddingFor({required bool showLandscapePanel, required double landscapePanelWidth, required bool navigationMode}) {
    return EdgeInsets.only(
      top: topPadding + 70,
      left: showLandscapePanel ? landscapePanelWidth + 14 : 0,
      right: isLandscape ? 64 : 0,
      bottom: showLandscapePanel ? 16 : (navigationMode ? 170 : 230),
    );
  }
}

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
  BitmapDescriptor? _waypointIcon;

  LatLng? _driverLL;
  LatLng? _lastDriverLL;
  LatLng? _riderLL;
  double _driverHeading = 0;

  // FIXED: Keeps the car from spinning wildly due to GPS jitter
  double _lastComputedHeading = 0.0;

  TripNavPhase _phase = TripNavPhase.driverToPickup;
  int _activeStopIndex = 0;
  NavigationViewMode _viewMode = NavigationViewMode.navigation;
  bool _isFollowCameraEnabled = true;

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
    if (_phase != TripNavPhase.enRoute && _phase != TripNavPhase.arrivedDestination) return _driverLL;
    if (widget.args.role == TripNavigationRole.rider && _riderLL != null && _driverLL != null) {
      final double gap = _haversine(_riderLL!, _driverLL!);
      if (gap <= 120.0) return _riderLL!;
    }
    return _driverLL ?? _riderLL;
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
    _riderLL = widget.args.initialRiderLocation ?? widget.args.pickup;
    _phase = widget.args.initialPhase;
    _isFollowCameraEnabled = widget.args.autoFollowCamera;
    _preloadIcons();
    _listenBooking();
    _tickTimer = Timer.periodic(_tickEvery, (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncMarkers();
      _recomputePermissions();
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
    if (_debugLines.length > 80) {
      _debugLines.removeRange(0, _debugLines.length - 80);
    }
    if (mounted && widget.args.showDebugPanel) setState(() {});
  }

  String _safeJson(Object? data) {
    try {
      return jsonEncode(data);
    } catch (_) {
      return data.toString();
    }
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
      final ui.Codec codec = await ui.instantiateImageCodec(bytes, targetWidth: 92);
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
      center + const Offset(0, 2),
      14,
      Paint()
        ..color = Colors.black.withOpacity(0.22)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 5),
    );
    canvas.drawCircle(center, 14, Paint()..color = Colors.white);
    canvas.drawCircle(center, 14, Paint()..style = PaintingStyle.stroke..strokeWidth = 4..color = color);
    canvas.drawCircle(center, 4.8, Paint()..color = color);

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
      onError: (Object e) => _log('LIVE_STREAM_ERROR', e.toString()),
      cancelOnError: false,
    );
  }

  Future<void> _tick({bool force = false}) async {
    if (!mounted || _busyTick) return;
    _busyTick = true;
    try {
      await _applyLiveSnapshot();
      _recomputePermissions();
      _syncMarkers();
      await _rebuildRoute(force: force);
      await _followCamera();
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
    } catch (e) {
      _log('LIVE_SNAPSHOT_ERROR', e.toString());
    }
  }

  void _applyIncoming(dynamic event) {
    final Map<String, dynamic> payload = _eventMap(event);
    if (payload.isEmpty) return;

    if (event is BookingUpdate && event.status == BookingStatus.failed) {
      _emitError(event.displayMessage.isNotEmpty ? event.displayMessage : 'Trip issue.');
      return;
    }

    final String serverMessage = _string(payload['displayMessage'] ?? payload['message'] ?? payload['error_message']);
    final bool hasServerError = payload['error'] == true || payload['error_kind'] != null || _string(payload['booking_status']).toLowerCase().contains('failed');
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
    if (heading != null) {
      _driverHeading = heading;
    }

    final TripNavPhase? nextPhase = _coercePhase(payload, event);
    if (nextPhase != null && nextPhase != _phase) {
      _phase = nextPhase;
      _didInitialFit = false;
      _lastDriverRouteLL = null;
    }

    final int? stopIndex = _coerceStopIndex(payload, event);
    if (stopIndex != null && _allTargets.isNotEmpty) {
      _activeStopIndex = stopIndex.clamp(0, _allTargets.length - 1);
    }

    _recomputePermissions();
    _syncMarkers();
    if (mounted) setState(() {});
  }

  void _emitError(String message) {
    _lastErrorText = message;
    _log('ERROR', message);
    if (mounted) setState(() {});
  }

  void _recomputePermissions() {
    _canArrivePickup = false;
    _canStartTrip = false;
    _canArriveDestination = false;
    _canCompleteRide = false;

    if (_driverLL == null) return;

    final double pickupGap = _haversine(_driverLL!, _effectivePickupLL);
    final double destGap = _haversine(_driverLL!, _currentTarget);

    final double safeArrivalMeters = math.max(_arrivalMeters, 150.0);
    final double safeCompletionMeters = math.max(_arrivalMeters + 50.0, 200.0);

    if (_phase == TripNavPhase.driverToPickup) {
      _canArrivePickup = pickupGap <= safeArrivalMeters;
    } else if (_phase == TripNavPhase.waitingPickup) {
      _canStartTrip = pickupGap <= safeArrivalMeters;
    } else if (_phase == TripNavPhase.enRoute) {
      _canArriveDestination = destGap <= safeArrivalMeters;
    } else if (_phase == TripNavPhase.arrivedDestination) {
      _canCompleteRide = destGap <= safeCompletionMeters;
    }
  }

  // FIXED: Smooth driver rotation based on actual movement instead of jitter
  double _driverRotation() {
    if (_driverLL == null) return _lastComputedHeading;

    // Prefer actual GPS hardware heading if it is valid
    if (_driverHeading > 0) {
      _lastComputedHeading = _driverHeading;
      return _lastComputedHeading;
    }

    // Fallback: Compute bearing based on movement
    if (_lastDriverLL != null) {
      final double dist = _haversine(_lastDriverLL!, _driverLL!);
      // Ignore micro-jitters smaller than 2.5 meters so the car doesn't spin wildly
      if (dist > 2.5) {
        _lastComputedHeading = _bearingBetween(_lastDriverLL!, _driverLL!);
      }
    } else {
      // Initial startup heading points toward the current target
      _lastComputedHeading = _bearingBetween(_driverLL!, _currentTarget);
    }

    return _lastComputedHeading;
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
      next.add(
        Marker(
          markerId: const MarkerId('rider_live'),
          position: _riderLL!,
          icon: _riderIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose),
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
          icon: _waypointIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          anchor: const Offset(0.5, 0.5),
          zIndex: 34,
        ),
      );
    }

    if (_driverLL != null) {
      next.add(
        Marker(
          markerId: const MarkerId('driver'),
          position: _driverLL!,
          icon: _driverIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
          // Ensure anchor is center so the car rotates accurately around its middle
          anchor: const Offset(0.5, 0.5),
          flat: true, // Forces the marker to rotate with the map
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

    final LatLng? from = (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? _enRouteOrigin : _driverLL;
    final LatLng? to = (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? _currentTarget : _effectivePickupLL;
    if (from == null || to == null) return;
    if (!force && now.difference(_lastRouteAt) < _routeMinGap) return;
    if (!force && _lastDriverRouteLL != null && _haversine(_lastDriverRouteLL!, from) < _routeMoveThresholdMeters) return;

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
          color: isDark ? Colors.white.withOpacity(0.94) : Colors.black.withOpacity(0.8),
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
          width: 6,
          geodesic: true,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ));

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
      final List<Map<String, dynamic>> routes = (decoded['routes'] as List?)
          ?.whereType<Map>()
          .map((Map e) => e.cast<String, dynamic>())
          .toList() ??
          const <Map<String, dynamic>>[];
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

  Future<void> _followCamera({bool force = false}) async {
    if (_map == null) return;
    if (_phase == TripNavPhase.completed || _phase == TripNavPhase.cancelled) return;
    if (!force) {
      if (_viewMode != NavigationViewMode.navigation) return;
      if (!_isFollowCameraEnabled) return;
      if (!widget.args.autoFollowCamera) return;
    }

    final LatLng? target = (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? _enRouteOrigin : _driverLL;
    if (target == null) return;

    try {
      await _map!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: target,
            zoom: (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? 18.0 : 17.5,
            tilt: (_phase == TripNavPhase.enRoute || _phase == TripNavPhase.arrivedDestination) ? 60.0 : 45.0,
            bearing: _driverRotation(),
          ),
        ),
      );
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

  Future<void> _handlePrimaryAction() async {
    if (_busyPrimaryAction) return;
    Future<void> Function()? callback;
    if (_phase == TripNavPhase.driverToPickup &&
        widget.args.role == TripNavigationRole.driver &&
        widget.args.onArrivedPickup != null &&
        widget.args.showArrivedPickupButton) {
      callback = widget.args.onArrivedPickup;
    } else if (_phase == TripNavPhase.waitingPickup &&
        widget.args.role == TripNavigationRole.driver &&
        widget.args.onStartTrip != null &&
        widget.args.showStartTripButton) {
      callback = widget.args.onStartTrip;
    } else if (_phase == TripNavPhase.enRoute &&
        widget.args.role == TripNavigationRole.driver &&
        widget.args.onArrivedDestination != null &&
        widget.args.showArrivedDestinationButton) {
      callback = widget.args.onArrivedDestination;
    } else if (_phase == TripNavPhase.arrivedDestination &&
        widget.args.role == TripNavigationRole.driver &&
        widget.args.onCompleteTrip != null &&
        widget.args.showCompleteTripButton) {
      callback = widget.args.onCompleteTrip;
    } else if (_phase == TripNavPhase.waitingPickup &&
        widget.args.role == TripNavigationRole.rider &&
        widget.args.onStartTrip != null &&
        widget.args.showStartTripButton) {
      callback = widget.args.onStartTrip;
    }

    if (callback == null) return;
    setState(() => _busyPrimaryAction = true);
    try {
      await callback.call();
      await _tick(force: true);
      if (_phase == TripNavPhase.waitingPickup && widget.args.role == TripNavigationRole.driver) {
        await _activateNavigationMode();
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
      if (!mounted) return;
      setState(() => _busyCancel = false);
    }
  }

  Map<String, dynamic> _eventMap(dynamic event) {
    if (event is BookingUpdate) {
      return <String, dynamic>{'booking_status': event.status.toString(), ...event.data};
    }
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

    final String raw = _string(
      payload['phase'] ??
          payload['status'] ??
          payload['state'] ??
          (payload['ride'] is Map ? (payload['ride'] as Map)['status'] : null),
    ).toLowerCase();

    switch (raw) {
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

  int? _coerceStopIndex(Map<String, dynamic> payload, dynamic rawEvent) {
    final dynamic top = payload['stop_index'] ?? payload['waypoint_index'] ?? payload['active_stop_index'];
    if (_toInt(top) != null) return _toInt(top);
    if (payload['ride'] is Map) {
      final Map ride = payload['ride'] as Map;
      final int? nested = _toInt(ride['stop_index'] ?? ride['waypoint_index'] ?? ride['active_stop_index']);
      if (nested != null) return nested;
    }
    try {
      return _toInt(rawEvent.stopIndex ?? rawEvent.waypointIndex ?? rawEvent.activeStopIndex);
    } catch (_) {
      return null;
    }
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
    try {
      return _toDouble(rawEvent.heading ?? rawEvent.bearing ?? rawEvent.driverHeading);
    } catch (_) {
      return null;
    }
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

  int? _toInt(dynamic v) {
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
      do {
        b = enc.codeUnitAt(idx++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      shift = 0;
      result = 0;
      do {
        b = enc.codeUnitAt(idx++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      out.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return out;
  }

  LatLngBounds _boundsFrom(List<LatLng> pts) {
    double minLat = pts.first.latitude, maxLat = pts.first.latitude, minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final LatLng p in pts) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    if (minLat == maxLat) {
      minLat -= 0.0001;
      maxLat += 0.0001;
    }
    if (minLng == maxLng) {
      minLng -= 0.0001;
      maxLng += 0.0001;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  double _haversine(LatLng a, LatLng b) {
    const double earth = 6371000.0;
    double d2r(double d) => d * (math.pi / 180.0);
    final double h =
        math.sin(d2r(b.latitude - a.latitude) / 2) * math.sin(d2r(b.latitude - a.latitude) / 2) +
            math.cos(d2r(a.latitude)) *
                math.cos(d2r(b.latitude)) *
                math.sin(d2r(b.longitude - a.longitude) / 2) *
                math.sin(d2r(b.longitude - a.longitude) / 2);
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
      case TripNavPhase.driverToPickup:
        return widget.args.role == TripNavigationRole.driver ? 'TO PICKUP' : 'DRIVER ARRIVING';
      case TripNavPhase.waitingPickup:
        return widget.args.role == TripNavigationRole.driver ? 'AT PICKUP' : 'PICKUP READY';
      case TripNavPhase.enRoute:
        return widget.args.role == TripNavigationRole.driver ? 'TO DESTINATION' : 'ON TRIP';
      case TripNavPhase.arrivedDestination:
        return widget.args.role == TripNavigationRole.driver ? 'AT DESTINATION' : 'ARRIVED';
      case TripNavPhase.completed:
        return 'COMPLETED';
      case TripNavPhase.cancelled:
        return 'CANCELLED';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // FIXED: Forces map to switch styles immediately when theme changes
    if (_map != null) {
      _map!.setMapStyle(_getMapStyle(isDark));
    }

    final _ScreenMetrics metrics = _ScreenMetrics(context);
    final bool showLandscapePanel = metrics.isLandscape;
    final double landscapePanelWidth = showLandscapePanel ? metrics.landscapePanelWidth : 0;
    final bool showPrimaryAction = _resolvePrimaryActionLabel() != null;
    final String? primaryLabel = _resolvePrimaryActionLabel();

    return WillPopScope(
      onWillPop: () async => true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: <Widget>[
            Positioned.fill(
              child: GoogleMap(
                initialCameraPosition: CameraPosition(
                  target: _driverLL ?? _effectivePickupLL,
                  zoom: 16.2,
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
                padding: metrics.mapPaddingFor(
                  showLandscapePanel: showLandscapePanel,
                  landscapePanelWidth: landscapePanelWidth,
                  navigationMode: _viewMode == NavigationViewMode.navigation,
                ),
                markers: _markers,
                polylines: _polylines,
                onMapCreated: (GoogleMapController c) {
                  _map = c;
                  if (isDark) {
                    _map!.setMapStyle(_getMapStyle(isDark));
                  }
                  _tick(force: true);
                },
              ),
            ),
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
            Positioned(
              top: metrics.topPadding + 10,
              left: metrics.spacing10,
              right: metrics.spacing10,
              child: _ThinHeader(
                metrics: metrics,
                phaseLabel: _phaseLabel(),
                distanceText: _distanceText ?? '—',
                durationText: _durationText ?? '—',
                onBack: () => Navigator.of(context).maybePop(),
              ),
            ),
            Positioned(
              top: metrics.topPadding + 70,
              right: metrics.spacing10,
              child: _ActionRail(
                isNavigationMode: _viewMode == NavigationViewMode.navigation,
                isFollowCameraEnabled: _isFollowCameraEnabled,
                onNavigationMode: _activateNavigationMode,
                onOverviewMode: _activateOverviewMode,
                onRecenter: _recenterMap,
                metrics: metrics,
              ),
            ),
            if (showLandscapePanel)
              Positioned(
                top: metrics.topPadding + 70,
                left: metrics.spacing10,
                bottom: metrics.spacing10,
                width: landscapePanelWidth,
                child: SafeArea(
                  top: false,
                  child: _PanelContainer(
                    child: _SheetContent(
                      controller: null,
                      metrics: metrics,
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
                      showCancelButton: widget.args.showCancelButton,
                      busyPrimary: _busyPrimaryAction,
                      busyCancel: _busyCancel,
                      primaryEnabled: _isPrimaryActionEnabled(),
                      onPrimaryAction: _handlePrimaryAction,
                      onCancelTrip: _cancelTripPressed,
                      showMetaCard: widget.args.showMetaCard,
                      errorText: _lastErrorText,
                    ),
                  ),
                ),
              )
            else
              Positioned(
                left: metrics.spacing10,
                right: metrics.spacing10,
                bottom: metrics.spacing10,
                height: math.min(
                  MediaQuery.of(context).size.height * 0.68,
                  MediaQuery.of(context).size.height - (metrics.topPadding + 120),
                ),
                child: SafeArea(
                  top: false,
                  child: DraggableScrollableSheet(
                    expand: true,
                    initialChildSize: metrics.bottomSheetInitialSize,
                    minChildSize: metrics.bottomSheetMinSize,
                    maxChildSize: metrics.bottomSheetMaxSize,
                    builder: (BuildContext ctx, ScrollController controller) {
                      return _PanelContainer(
                        child: _SheetContent(
                          controller: controller,
                          metrics: metrics,
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
                          showCancelButton: widget.args.showCancelButton,
                          busyPrimary: _busyPrimaryAction,
                          busyCancel: _busyCancel,
                          primaryEnabled: _isPrimaryActionEnabled(),
                          onPrimaryAction: _handlePrimaryAction,
                          onCancelTrip: _cancelTripPressed,
                          showMetaCard: widget.args.showMetaCard,
                          errorText: _lastErrorText,
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

  String? _resolvePrimaryActionLabel() {
    if (widget.args.role == TripNavigationRole.driver) {
      if (_phase == TripNavPhase.driverToPickup &&
          widget.args.showArrivedPickupButton &&
          widget.args.onArrivedPickup != null) {
        return 'AT PICKUP';
      }
      if (_phase == TripNavPhase.waitingPickup &&
          widget.args.showStartTripButton &&
          widget.args.onStartTrip != null) {
        return 'START TRIP';
      }
      if (_phase == TripNavPhase.enRoute &&
          widget.args.showArrivedDestinationButton &&
          widget.args.onArrivedDestination != null) {
        return 'AT DESTINATION';
      }
      if (_phase == TripNavPhase.arrivedDestination &&
          widget.args.showCompleteTripButton &&
          widget.args.onCompleteTrip != null) {
        return 'COMPLETE RIDE';
      }
    } else {
      if (_phase == TripNavPhase.waitingPickup &&
          widget.args.showStartTripButton &&
          widget.args.onStartTrip != null) {
        return 'START TRIP';
      }
    }
    return null;
  }

  bool _isPrimaryActionEnabled() {
    if (widget.args.role == TripNavigationRole.driver) {
      if (_phase == TripNavPhase.driverToPickup) return _canArrivePickup;
      if (_phase == TripNavPhase.waitingPickup) return _canStartTrip;
      if (_phase == TripNavPhase.enRoute) return _canArriveDestination;
      if (_phase == TripNavPhase.arrivedDestination) return _canCompleteRide;
      return false;
    }
    if (_phase == TripNavPhase.waitingPickup) return _canStartTrip;
    return false;
  }
}

class _PanelContainer extends StatelessWidget {
  final Widget child;
  const _PanelContainer({required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? cs.surface.withOpacity(0.95) : Theme.of(context).cardColor.withOpacity(0.95),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cs.onSurface.withOpacity(0.08), width: 0.8),
            boxShadow: <BoxShadow>[
              BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, 8)),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _ThinHeader extends StatelessWidget {
  final _ScreenMetrics metrics;
  final String phaseLabel;
  final String distanceText;
  final String durationText;
  final VoidCallback onBack;

  const _ThinHeader({
    required this.metrics,
    required this.phaseLabel,
    required this.distanceText,
    required this.durationText,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(metrics.radiusLarge),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          height: 48 * metrics.scale,
          padding: EdgeInsets.symmetric(horizontal: metrics.spacing8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.42),
            borderRadius: BorderRadius.circular(metrics.radiusLarge),
            border: Border.all(color: Colors.white.withOpacity(0.15), width: 0.8),
          ),
          child: Row(
            children: <Widget>[
              IconButton(
                onPressed: onBack,
                icon: Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18 * metrics.scale),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              SizedBox(width: metrics.spacing10),
              Container(width: 1, height: 24 * metrics.scale, color: Colors.white.withOpacity(0.15)),
              SizedBox(width: metrics.spacing10),
              Icon(Icons.trip_origin_rounded, color: AppColors.primary, size: 14 * metrics.scale),
              SizedBox(width: metrics.spacing6),
              Expanded(
                child: Text(
                  phaseLabel,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: metrics.fontBase, letterSpacing: 0.5),
                ),
              ),
              Container(width: 1, height: 24 * metrics.scale, color: Colors.white.withOpacity(0.15)),
              SizedBox(width: metrics.spacing10),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(durationText, style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w900, fontSize: metrics.fontLarge, height: 1.1)),
                  Text(distanceText, style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: metrics.fontTiny, height: 1.1)),
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

  const _ActionRail({
    required this.isNavigationMode,
    required this.isFollowCameraEnabled,
    required this.onNavigationMode,
    required this.onOverviewMode,
    required this.onRecenter,
    required this.metrics,
  });

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
            children: <Widget>[
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

  const _ThinIconButton({
    required this.icon,
    required this.isActive,
    required this.onTap,
    required this.metrics,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32 * metrics.scale,
        height: 32 * metrics.scale,
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

class _SheetContent extends StatelessWidget {
  final ScrollController? controller;
  final _ScreenMetrics metrics;
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
    required this.metrics,
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
        SizedBox(height: metrics.spacing8),
        Center(
          child: Container(
            width: 34,
            height: 4,
            decoration: BoxDecoration(
              color: onSurface.withOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        SizedBox(height: metrics.spacing10),
      ] else SizedBox(height: metrics.spacing16),
      Text(
        role == TripNavigationRole.driver ? 'DRIVER COMMAND VIEW' : 'RIDER LIVE VIEW',
        style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: metrics.fontTiny, fontWeight: FontWeight.w800, letterSpacing: 0.6),
      ),
      SizedBox(height: metrics.spacing8),
      _DataRowDense(label1: role == TripNavigationRole.driver ? 'RIDER' : 'DRIVER', value1: driverName, label2: 'VEHICLE', value2: vehicleType, metrics: metrics),
      SizedBox(height: metrics.spacing8),
      _DataRowDense(label1: 'PLATE', value1: carPlate.isEmpty ? '—' : carPlate, label2: 'RATING', value2: rating > 0 ? '★ ${rating.toStringAsFixed(1)}' : '—', metrics: metrics),
      SizedBox(height: metrics.spacing12),
      Divider(color: onSurface.withOpacity(0.1), height: 1, thickness: 0.8),
      SizedBox(height: metrics.spacing12),
      if (showMetaCard)
        Container(
          padding: EdgeInsets.all(metrics.spacing10),
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(metrics.radiusMedium),
            border: Border.all(color: AppColors.primary.withOpacity(0.18)),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.near_me_rounded, color: AppColors.primary, size: 16 * metrics.scale),
              SizedBox(width: metrics.spacing8),
              Expanded(
                child: Text(
                  'TARGET: $currentTarget',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: metrics.fontSmall),
                ),
              ),
            ],
          ),
        ),
      if (showMetaCard) SizedBox(height: metrics.spacing12),
      Text('TRIP ROUTE', style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: metrics.fontTiny, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      SizedBox(height: metrics.spacing8),
      _PathLine(label: 'FROM', value: from, isHighlight: true, metrics: metrics),
      if (dropOffTexts.isNotEmpty)
        for (int i = 0; i < dropOffTexts.length; i++) ...<Widget>[
          SizedBox(height: metrics.spacing6),
          _PathLine(
            label: 'STOP ${i + 1}',
            value: dropOffTexts[i],
            isHighlight: activeStopIndex == i && phaseLabel.contains('DESTINATION'),
            metrics: metrics,
          ),
        ],
      SizedBox(height: metrics.spacing6),
      _PathLine(label: 'TO', value: to, isHighlight: phaseLabel.contains('DESTINATION') || phaseLabel == 'COMPLETED', metrics: metrics),
      if (errorText != null && errorText!.trim().isNotEmpty) ...<Widget>[
        SizedBox(height: metrics.spacing12),
        Container(
          padding: EdgeInsets.all(metrics.spacing10),
          decoration: BoxDecoration(
            color: AppColors.error.withOpacity(0.08),
            borderRadius: BorderRadius.circular(metrics.radiusMedium),
            border: Border.all(color: AppColors.error.withOpacity(0.18)),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.error_outline_rounded, color: AppColors.error, size: 16 * metrics.scale),
              SizedBox(width: metrics.spacing8),
              Expanded(
                child: Text(
                  errorText!,
                  style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w700, fontSize: metrics.fontSmall),
                ),
              ),
            ],
          ),
        ),
      ],
      SizedBox(height: metrics.spacing16),
      _ActionRow(
        metrics: metrics,
        showPrimaryAction: showPrimaryAction,
        primaryLabel: primaryLabel,
        showCancelButton: showCancelButton,
        busyPrimary: busyPrimary,
        busyCancel: busyCancel,
        primaryEnabled: primaryEnabled,
        onPrimaryAction: onPrimaryAction,
        onCancelTrip: onCancelTrip,
      ),
      SizedBox(height: metrics.spacing16),
    ];

    if (controller != null) {
      return ListView(
        controller: controller,
        padding: EdgeInsets.symmetric(horizontal: metrics.spacing12),
        children: children,
      );
    }
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: metrics.spacing12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _DataRowDense extends StatelessWidget {
  final String label1, value1, label2, value2;
  final _ScreenMetrics metrics;

  const _DataRowDense({
    required this.label1,
    required this.value1,
    required this.label2,
    required this.value2,
    required this.metrics,
  });

  @override
  Widget build(BuildContext context) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label1, style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: metrics.fontTiny, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(value1, style: TextStyle(color: onSurface, fontSize: metrics.fontBase, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label2, style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: metrics.fontTiny, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(value2, style: TextStyle(color: onSurface, fontSize: metrics.fontBase, fontWeight: FontWeight.w600)),
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
  final _ScreenMetrics metrics;

  const _PathLine({
    required this.label,
    required this.value,
    required this.isHighlight,
    required this.metrics,
  });

  @override
  Widget build(BuildContext context) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 52 * metrics.scale,
          child: Text(
            label,
            style: TextStyle(color: isHighlight ? AppColors.primary : onSurface.withOpacity(0.5), fontSize: metrics.fontTiny, fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: isHighlight ? onSurface : onSurface.withOpacity(0.72), fontSize: metrics.fontSmall, fontWeight: isHighlight ? FontWeight.w700 : FontWeight.w500),
          ),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  final _ScreenMetrics metrics;
  final bool showPrimaryAction;
  final String? primaryLabel;
  final bool showCancelButton;
  final bool busyPrimary;
  final bool busyCancel;
  final bool primaryEnabled;
  final VoidCallback onPrimaryAction;
  final VoidCallback onCancelTrip;

  const _ActionRow({
    required this.metrics,
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
              metrics: metrics,
            ),
          ),
        if (showPrimaryAction && showCancelButton) SizedBox(width: metrics.spacing10),
        if (showCancelButton)
          Expanded(
            flex: 1,
            child: _ActionButton(
              label: 'CANCEL',
              isLoading: busyCancel,
              isDisabled: false,
              isPrimary: false,
              onTap: onCancelTrip,
              metrics: metrics,
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
  final _ScreenMetrics metrics;

  const _ActionButton({
    required this.label,
    required this.isLoading,
    this.isDisabled = false,
    required this.isPrimary,
    required this.onTap,
    required this.metrics,
  });

  @override
  Widget build(BuildContext context) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    final bool disabled = isLoading || isDisabled;

    final Color bgColor = isPrimary
        ? (disabled ? AppColors.primary.withOpacity(0.32) : AppColors.primary)
        : Colors.transparent;
    final Color borderColor = isPrimary
        ? (disabled ? AppColors.primary.withOpacity(0.28) : AppColors.primary)
        : onSurface.withOpacity(disabled ? 0.1 : 0.2);
    final Color textColor = isPrimary
        ? Colors.white.withOpacity(disabled ? 0.68 : 1.0)
        : onSurface.withOpacity(disabled ? 0.4 : 0.82);

    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: Container(
        height: metrics.buttonHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(metrics.radiusSmall),
          border: Border.all(color: borderColor, width: 1.0),
        ),
        child: isLoading
            ? SizedBox(
          width: 14 * metrics.scale,
          height: 14 * metrics.scale,
          child: CircularProgressIndicator(strokeWidth: 1.6, color: textColor),
        )
            : Text(
          label,
          style: TextStyle(color: textColor, fontSize: metrics.fontBase, fontWeight: FontWeight.w800, letterSpacing: 0.4),
        ),
      ),
    );
  }
}

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