// lib/screens/home_page.dart
//
// Home map + routes + marketplace + booking
// - Full polyline overview (not just pins)
// - Bottom sheets constrained to finite height (fixes RenderPhysicalShape crash)
// - Heavy camera/heading work paused while search overlay is open
// - Ride marketplace streams drivers + offers via ApiClient-backed service
// - On offer select -> BookingController -> live status + driver→pickup polyline (purple)
//
// PERF + UX PATCH (requested):
// - Route auto-fits to visible map viewport (header + bottom sheet padding respected)
//   so user never needs to zoom out manually (like screenshot)
// - Screenshot-style markers:
//    * Pickup = blue ring + dot
//    * Destination = green ring + dot
//    * "11 min" = green circular badge + pin dot
//    * "Arrive by ..." = blue pill badge
// - Reduced release-mode overhead by guarding debug logs in asserts

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// App
import '../api/api_client.dart';
import '../api/url.dart';
import '../routes/routes.dart';
import '../themes/app_theme.dart';
import '../utility/notification.dart';

// Widgets
import '../widgets/app_menu_drawer.dart';
import '../widgets/bottom_navigation_bar.dart';
import '../widgets/fund_account_sheet.dart';
import '../widgets/auto_overlay.dart';
import '../widgets/header_bar.dart';
import '../widgets/locate_fab.dart';
import '../widgets/route_sheet.dart';
import '../widgets/ride_market_sheet.dart';

// State & services
import 'state/home_models.dart';
import '../services/autocomplete_service.dart';
import '../services/perf_profile.dart';
import '../services/ride_market_service.dart';
import '../services/booking_controller.dart';

enum MovementMode { stationary, pedestrian, vehicle }
enum BearingSource { route, gps, compass }
enum _CamMode { follow, overview }

class _SpeedInterval {
  final int start, end;
  final String speed;
  const _SpeedInterval(this.start, this.end, this.speed);
}

class _V2Route {
  final List<LatLng> points;
  final int distanceMeters, durationSeconds;
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
  _NetworkRequest(this.id, this.executor)
      : completer = Completer<http.Response>(),
        retries = 0;
}

class _SpatialNode {
  final LatLng point;
  final int index;
  final double lat, lng;
  _SpatialNode(this.point, this.index)
      : lat = point.latitude,
        lng = point.longitude;
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver, TickerProviderStateMixin {
  // ===== Tuned constants =====
  static const double kBottomNavH = 74;
  static const double kHeaderVisualH = 88;

  static const int kMaxConcurrentRequests = 5;
  static const Duration kApiTimeout = Duration(seconds: 15);
  static const int kMaxRetries = 3;

  // Location/heading
  static const Duration kGpsUpdateInterval = Duration(milliseconds: 200); // ≈5 Hz
  static const Duration kHeadingTickMin = Duration(milliseconds: 33); // ~30 FPS
  static const double kVehicleSpeedThreshold = 1.5; // m/s
  static const double kPedestrianSpeedThreshold = 0.5; // m/s
  static const Duration kStationaryTimeout = Duration(minutes: 2);

  // Follow tuning
  static const double kCenterSnapMeters = 6;

  // Bearing smoothing
  static const double kBearingDeadbandDeg = 0.5;
  static const double kMaxBearingVel = 320.0; // deg/s
  static const double kMaxBearingAccel = 1200.0; // deg/s^2

  // Route logic
  static const double kRouteDeviationThreshold = 50.0; // meters

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _sheetKey = GlobalKey();

  // Layout
  double _sheetHeight = 0;
  EdgeInsets _mapPadding = EdgeInsets.zero;

  // Infra
  late SharedPreferences _prefs;
  late ApiClient _api;
  Map<String, dynamic>? _user;
  bool _busyProfile = false;
  int _currentIndex = 0;

  // Map & GPS
  GoogleMapController? _map;
  final CameraPosition _initialCam = const CameraPosition(target: LatLng(6.458985, 7.548266), zoom: 15);

  Position? _curPos, _prevPos;
  StreamSubscription<Position>? _gpsSub;
  Timer? _gpsThrottleTimer, _stationaryTimer;
  MovementMode _movementMode = MovementMode.stationary;
  bool _gpsActive = true;

  // Enhanced GPS lifecycle
  bool _isInitializingLocation = false;
  int _gpsInitAttempt = 0;
  int _gpsStreamErrorCount = 0;
  Timer? _gpsWatchdog;
  DateTime? _lastStreamUpdate;

  // NEW: single-flight guard + service status listener
  Completer<void>? _locInitCompleter;
  StreamSubscription<ServiceStatus>? _svcStatusSub;

  // Icons
  BitmapDescriptor? _userPinIcon, _pickupIcon, _dropIcon, _etaBubbleIcon, _minsBubbleIcon;
  bool _iconsPreloaded = false;

  // Drivers (market)
  BitmapDescriptor? _driverIcon;
  final Set<Marker> _driverMarkers = {};

  final Set<Marker> _markers = {};
  final Set<Polyline> _lines = {};
  final Set<Circle> _circles = {};

  static const MarkerId _userMarkerId = MarkerId('user_location');
  static const MarkerId _etaMarkerId = MarkerId('eta_label');
  static const MarkerId _minsMarkerId = MarkerId('mins_label');

  // Booking visuals
  static const MarkerId _driverSelectedId = MarkerId('driver_selected');
  final Set<Polyline> _driverLines = {};
  RideOffer? _selectedOffer;

  // IMPORTANT: make tolerant to controller API differences
  dynamic _booking; // BookingController? but dynamic for adapter

  // Camera + heading
  _CamMode _camMode = _CamMode.follow;
  bool _rotateWithHeading = true;
  bool _useForwardAnchor = true;

  LatLng? _lastCamTarget;
  DateTime _lastCamMove = DateTime.fromMillisecondsSinceEpoch(0);

  // Throttle driver→pickup recompute (replaces shouldRecomputeRoute())
  DateTime _lastDriverLegRouteAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Compass
  StreamSubscription<CompassEvent>? _compassSub;
  double? _compassDeg, _lastBearingDeg;
  double _bearingEma = 0;
  BearingSource _lastBearingSource = BearingSource.compass;
  double _userMarkerRotation = 0;
  double _lastBearingVel = 0;
  DateTime _lastBearingTime = DateTime.now();
  DateTime _lastHeadingTick = DateTime.fromMillisecondsSinceEpoch(0);

  // Route
  final List<RoutePoint> _pts = [];
  int _activeIdx = 0;

  String? _distanceText, _durationText;
  double? _fare;
  DateTime? _arrivalTime;
  Timer? _routeRefreshTimer;
  String? _routeUiError;
  _RouteCache? _cachedRoute;
  String? _lastRouteHash;
  List<LatLng> _routePts = [];
  List<_SpatialNode> _spatialIndex = [];
  int _lastSnapIndex = -1;
  DateTime _lastRerouteCheck = DateTime.now();
  bool _isRerouting = false;

  // Autocomplete
  final _uuid = const Uuid();
  String _placesSession = '';
  Timer? _debounce;
  late final AutocompleteService _auto;
  List<Suggestion> _sugs = [], _recents = [];
  bool _isTyping = false;
  int _lastQueryId = 0;
  final Map<String, _NetworkRequest> _requestQueue = {};
  int _activeRequests = 0;
  String? _autoStatus, _autoError;

  // UI
  bool _expanded = false, _isConnected = true;
  Orientation? _lastOrientation;
  late final AnimationController _overlayAnimController;
  late final Animation<double> _overlayFadeAnim;

  // Ride marketplace & live drivers
  RideMarketService? _market;
  StreamSubscription<RideMarketSnapshot>? _marketSub;
  bool _marketOpen = false;
  bool _offersLoading = false;
  List<RideOffer> _offers = const [];
  final Map<String, DriverCar> _drivers = {};

  // NEW: debounce camera-fit when padding changes (prevents repeated fits during sheet animation)
  Timer? _fitBoundsDebounce;

  // ===== Debug (zero overhead in release) =====
  void _dbg(String msg, [Object? data]) {
    assert(() {
      final d = data == null ? '' : ' → $data';
      debugPrint('[Home] $msg$d');
      return true;
    }());
  }

  void _log(String msg, [Object? data]) => _dbg(msg, data);

  void _apiLog({
    required String tag,
    required Uri url,
    Map<String, String>? headers,
    Object? body,
    http.Response? res,
  }) {
    assert(() {
      final h = Map.of(headers ?? {});
      if (h.containsKey('X-Goog-Api-Key')) h['X-Goog-Api-Key'] = '***';
      _dbg('$tag URL', url.toString());
      if (body != null) _dbg('$tag Body', body);
      if (res != null) _dbg('$tag HTTP ${res.statusCode}');
      return true;
    }());
  }

  void _logLocationDiagnostic(String message) => _dbg('[GPS-DIAGNOSTICS] $message');

  late final RideMarketService _rideMarketService;

  // ===== Utils =====
  double _s(BuildContext c) {
    final mq = MediaQuery.of(c);
    final size = mq.size;
    final shortest = math.min(size.width, size.height);
    final longest = math.max(size.width, size.height);
    final aspect = longest / shortest;
    double scale = (shortest / 390.0).clamp(0.65, 1.20);
    if (aspect > 2.0) scale *= 0.90;
    if (aspect < 1.5) scale *= 1.08;
    return scale;
  }

  // ===== Lifecycle =====
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = ApiClient(http.Client(), context);
    _auto = AutocompleteService(logger: _log);

    _dbg('[HomePage] Initializing RideMarketService...');
    _rideMarketService = RideMarketService(api: _api, debug: true);

    _overlayAnimController = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    _overlayFadeAnim = CurvedAnimation(parent: _overlayAnimController, curve: Curves.easeOutCubic);

    _initPoints();
    _bootstrap();
    _startCompass();

    // Monitor OS-level location service toggles and recover quickly
    _svcStatusSub?.cancel();
    _svcStatusSub = Geolocator.getServiceStatusStream().listen((status) {
      _logLocationDiagnostic('Service status: $status');
      if (status == ServiceStatus.enabled) {
        _restartLocationStreamWithBackoff();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _rideMarketService.dispose();

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
    _market?.dispose();

    _booking?.dispose();

    _fitBoundsDebounce?.cancel();

    for (final p in _pts) {
      p.controller.dispose();
      p.focus.dispose();
    }

    _map?.dispose();
    _requestQueue.clear();
    _routePts.clear();
    _spatialIndex.clear();
    _cachedRoute = null;

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _gpsSub?.pause();
    } else if (state == AppLifecycleState.resumed) {
      _gpsSub?.resume();
      // Refresh or re-init when coming back to foreground
      if (_curPos == null) {
        _initLocation();
      } else {
        _refreshUserPosition();
      }
    }
  }

  Future<void> _bootstrap() async {
    _prefs = await SharedPreferences.getInstance();
    await Future.wait([_fetchUser(), _loadRecents(), _preloadAllIcons()]);
    await _initLocation();
    _scheduleMapPaddingUpdate();
  }

  Future<void> _fetchUser() async {
    setState(() => _busyProfile = true);
    try {
      final uid = _prefs.getString('user_id') ?? '';
      if (uid.isEmpty) return;

      final res = await _executeWithRetry(
        'fetch_user',
            () => _api
            .request(
          ApiConstants.userInfoEndpoint,
          method: 'POST',
          data: {'user': uid},
        )
            .timeout(kApiTimeout),
      );

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body['error'] == false) {
          setState(() => _user = body['user']);
          await _createUserPinIcon();
        }
      }
      setState(() => _isConnected = true);
    } catch (_) {
      setState(() => _isConnected = false);
    } finally {
      if (mounted) setState(() => _busyProfile = false);
    }
  }

  // ===== Network retry =====
  Future<http.Response> _executeWithRetry(String id, Future<http.Response> Function() executor) async {
    if (_requestQueue.containsKey(id)) {
      return _requestQueue[id]!.completer.future;
    }
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
          final delayMs = 400 * math.pow(2, request.retries - 1);
          await Future.delayed(Duration(milliseconds: delayMs.toInt()));
        }
      }
      throw Exception('Max retries exceeded');
    } finally {
      _requestQueue.remove(id);
    }
  }

  // ===== Icons =====
  Future<void> _preloadAllIcons() async {
    if (_iconsPreloaded) return;
    try {
      await Future.wait([_ensurePointIcons(), _createUserPinIcon(), _createDriverIcon()]);
      _iconsPreloaded = true;
    } catch (_) {}
  }

  Future<void> _createUserPinIcon() async {
    try {
      final avatarUrl = _safeAvatarUrl(_user?['user_logo'] as String?);
      _userPinIcon = await _buildAvatarPinIcon(avatarUrl);
      if (!mounted) return;
      setState(() {});
      if (_curPos != null) {
        _updateUserMarker(
          LatLng(_curPos!.latitude, _curPos!.longitude),
          rotation: _userMarkerRotation,
        );
      }
    } catch (_) {}
  }

  String? _safeAvatarUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.toLowerCase().contains('icon-library.com')) return null;
    return url.startsWith('http') ? url : null;
  }

  Future<BitmapDescriptor> _buildAvatarPinIcon(String? avatarUrl) async {
    const size = 84.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(size / 2, size / 2 - 6);
    final avatarRadius = size * 0.28;

    final shadow = Paint()
      ..color = Colors.black.withOpacity(0.22)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 8);
    canvas.drawCircle(center + const Offset(0, 14), avatarRadius + 14, shadow);

    final pinPath = Path()
      ..moveTo(center.dx, center.dy - (avatarRadius + 10))
      ..quadraticBezierTo(
        center.dx + (avatarRadius + 18),
        center.dy - 8,
        center.dx,
        center.dy + (avatarRadius + 18),
      )
      ..quadraticBezierTo(
        center.dx - (avatarRadius + 18),
        center.dy - 8,
        center.dx,
        center.dy - (avatarRadius + 10),
      )
      ..close();
    canvas.drawPath(pinPath, Paint()..color = Colors.white.withOpacity(0.98));

    canvas.drawCircle(
      center,
      avatarRadius + 4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..color = Colors.white,
    );

    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: avatarRadius)));

    if (avatarUrl != null) {
      try {
        final resp = await http.get(Uri.parse(avatarUrl)).timeout(const Duration(seconds: 5));
        if (resp.statusCode == 200) {
          final codec = await ui.instantiateImageCodec(resp.bodyBytes);
          final frame = await codec.getNextFrame();
          final src = Rect.fromLTWH(0, 0, frame.image.width.toDouble(), frame.image.height.toDouble());
          final dst = Rect.fromCircle(center: center, radius: avatarRadius);
          canvas.drawImageRect(frame.image, src, dst, Paint());
        } else {
          _drawFallbackAvatar(canvas, center, avatarRadius);
        }
      } catch (_) {
        _drawFallbackAvatar(canvas, center, avatarRadius);
      }
    } else {
      _drawFallbackAvatar(canvas, center, avatarRadius);
    }
    canvas.restore();

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  void _drawFallbackAvatar(Canvas canvas, Offset c, double r) {
    final grad = ui.Gradient.linear(
      c - Offset(r, r),
      c + Offset(r, r),
      [AppColors.primary, AppColors.accentColor],
    );
    canvas.drawCircle(c, r, Paint()..shader = grad);
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.person.codePoint),
        style: TextStyle(
          fontSize: r * 1.6,
          fontFamily: Icons.person.fontFamily,
          color: Colors.white,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  // ===== Screenshot-style point markers (ring + dot) =====
  Future<void> _ensurePointIcons() async {
    if (_pickupIcon != null && _dropIcon != null) return;

    final results = await Future.wait([
      _buildRingDotMarker(color: const Color(0xFF1A73E8)), // pickup blue
      _buildRingDotMarker(color: const Color(0xFF00A651)), // destination green
    ]);

    _pickupIcon = results[0];
    _dropIcon = results[1];
  }

  Future<BitmapDescriptor> _buildRingDotMarker({required Color color}) async {
    const double size = 64;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final center = const Offset(size / 2, size / 2);

    // subtle shadow
    c.drawCircle(
      center + const Offset(0, 2),
      18,
      Paint()
        ..color = Colors.black.withOpacity(0.20)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 6),
    );

    // white base
    c.drawCircle(center, 18, Paint()..color = Colors.white);

    // colored ring
    c.drawCircle(
      center,
      18,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = color,
    );

    // center dot
    c.drawCircle(center, 5.5, Paint()..color = color);

    final img = await rec.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  Future<void> _createDriverIcon() async {
    if (_driverIcon != null) return;
    const w = 72.0, h = 72.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);

    final body = Path()
      ..moveTo(18, 44)
      ..quadraticBezierTo(20, 30, 26, 26)
      ..quadraticBezierTo(36, 20, 46, 26)
      ..quadraticBezierTo(52, 30, 54, 44)
      ..close();

    c.drawShadow(body, Colors.black.withOpacity(.35), 6, false);
    c.drawPath(body, Paint()..color = Colors.white);
    c.drawCircle(const Offset(26, 44), 5, Paint()..color = Colors.black87);
    c.drawCircle(const Offset(46, 44), 5, Paint()..color = Colors.black87);

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    _driverIcon = BitmapDescriptor.fromBytes(bytes);
  }

  // ===== Markers =====
  void _updateUserMarker(LatLng pos, {double? rotation}) {
    if (_userPinIcon == null) return;
    if (rotation != null) _userMarkerRotation = rotation;
    setState(() {
      _markers.removeWhere((m) => m.markerId == _userMarkerId);
      _markers.add(
        Marker(
          markerId: _userMarkerId,
          position: pos,
          icon: _userPinIcon!,
          anchor: const Offset(0.5, 1.0),
          flat: true,
          rotation: _userMarkerRotation,
          zIndex: 999,
        ),
      );
    });
  }

  // ===== Compass & heading =====
  void _startCompass() {
    _compassSub?.cancel();
    _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
      final h = event.heading;
      if (h == null) return;

      _compassDeg = _normalizeDeg(h);

      final now = DateTime.now();
      if (now.difference(_lastHeadingTick) < kHeadingTickMin) return;
      _lastHeadingTick = now;

      _applyHeadingTick();
    });
  }

  void _applyHeadingTick() {
    if (_expanded) return; // pause heading-driven rotations while overlay open

    double? heading;
    final sp = _curPos?.speed ?? 0.0;
    if (sp >= kPedestrianSpeedThreshold &&
        _curPos != null &&
        _curPos!.heading.isFinite &&
        _curPos!.heading >= 0) {
      heading = _curPos!.heading;
      _lastBearingSource = BearingSource.gps;
    } else if (_compassDeg != null) {
      heading = _compassDeg;
      _lastBearingSource = BearingSource.compass;
    }
    if (heading == null) return;

    final smooth = _smoothBearingWithJerkLimit(heading);
    final pos = _curPos != null ? LatLng(_curPos!.latitude, _curPos!.longitude) : null;

    if (pos != null) _updateUserMarker(pos, rotation: smooth);

    if (_camMode == _CamMode.follow && _rotateWithHeading && _map != null && pos != null) {
      _moveCameraRealtime(
        target: _forwardBiasTarget(user: pos, bearingDeg: smooth),
        bearing: smooth,
        zoom: (sp >= kVehicleSpeedThreshold)
            ? 17.5
            : (sp >= kPedestrianSpeedThreshold ? 17.0 : 16.5),
        tilt: Perf.I.tiltFor(sp),
      );
    }
  }

  double _normalizeDeg(double d) {
    var x = d % 360.0;
    if (x < 0) x += 360.0;
    return x;
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

    _bearingEma = _normalizeDeg(_bearingEma + _lastBearingVel * dt);
    return _bearingEma;
  }

  // ===== Geo utils =====
  static const double _earth = 6371000.0;
  double _deg2rad(double d) => d * (math.pi / 180.0);
  double _rad2deg(double r) => r * (180.0 / math.pi);

  double _bearingBetween(LatLng a, LatLng b) {
    final lat1 = _deg2rad(a.latitude), lat2 = _deg2rad(b.latitude);
    final dLon = _deg2rad(b.longitude - a.longitude);
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return _normalizeDeg(_rad2deg(math.atan2(y, x)));
  }

  double _haversine(LatLng a, LatLng b) {
    final dLat = _deg2rad(b.latitude - a.latitude);
    final dLon = _deg2rad(b.longitude - a.longitude);
    final la1 = _deg2rad(a.latitude);
    final la2 = _deg2rad(b.latitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(la1) * math.cos(la2) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * _earth * math.asin(math.min(1, math.sqrt(h)));
  }

  LatLng _offsetLatLng(LatLng origin, double meters, double bearingDeg) {
    final br = _deg2rad(bearingDeg);
    final lat1 = _deg2rad(origin.latitude);
    final lon1 = _deg2rad(origin.longitude);
    final d = meters / _earth;

    final lat2 = math.asin(
      math.sin(lat1) * math.cos(d) + math.cos(lat1) * math.sin(d) * math.cos(br),
    );
    final lon2 = lon1 +
        math.atan2(
          math.sin(br) * math.sin(d) * math.cos(lat1),
          math.cos(d) - math.sin(lat1) * math.sin(lat2),
        );

    return LatLng(_rad2deg(lat2), _rad2deg(lon2));
  }

  // ======= VIEWPORT FIT (like screenshot) =======
  LatLngBounds _boundsFromPoints(List<LatLng> pts) {
    double minLat = pts.first.latitude, maxLat = pts.first.latitude;
    double minLng = pts.first.longitude, maxLng = pts.first.longitude;

    for (final p in pts) {
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

  Future<void> _animateBoundsSafe(LatLngBounds bounds, {double padding = 70}) async {
    if (_map == null) return;

    _camMode = _CamMode.overview;
    _rotateWithHeading = false;

    try {
      await _map!.animateCamera(CameraUpdate.newLatLngBounds(bounds, padding));
      return;
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 60));
    if (_map == null) return;

    try {
      await _map!.animateCamera(CameraUpdate.newLatLngBounds(bounds, padding));
    } catch (_) {
      final c = LatLng(
        (bounds.northeast.latitude + bounds.southwest.latitude) / 2,
        (bounds.northeast.longitude + bounds.southwest.longitude) / 2,
      );
      await _map!.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(target: c, zoom: 13.5, tilt: 0, bearing: 0)),
      );
    }
  }

  Future<void> _fitCurrentRouteToViewport() async {
    if (_map == null) return;

    final pts = _routePts.isNotEmpty
        ? _routePts
        : <LatLng>[
      if (_pts.isNotEmpty && _pts.first.latLng != null) _pts.first.latLng!,
      if (_pts.isNotEmpty && _pts.last.latLng != null) _pts.last.latLng!,
    ];

    if (pts.length < 2) return;

    // ensure padding is updated first (header + bottom sheet)
    _scheduleMapPaddingUpdate();
    await Future.delayed(const Duration(milliseconds: 24));

    final bounds = _boundsFromPoints(pts);

    // map already has padding; this is just a margin like the screenshot
    await _animateBoundsSafe(bounds, padding: 70);
  }

  // ===== Spatial index for route snapping =====
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
      final d = _haversine(p, node.point);
      if (d < bestDist) {
        bestDist = d;
        bestIdx = node.index;
      }
    }
    if (bestIdx >= 0) {
      final start = math.max(0, bestIdx - 20);
      final end = math.min(_spatialIndex.length - 1, bestIdx + 20);
      for (int i = start; i <= end; i++) {
        final node = _spatialIndex[i];
        final d = _haversine(p, node.point);
        if (d < bestDist) {
          bestDist = d;
          bestIdx = node.index;
        }
      }
    }
    return bestIdx;
  }

  double? _routeAwareBearing(LatLng user) {
    if (_spatialIndex.isEmpty) return null;
    final idx = _nearestRouteIndex(user);
    if (idx < 0) return null;
    final near = _routePts[idx];
    final distToRoute = _haversine(user, near);
    if (distToRoute > kRouteDeviationThreshold) {
      _checkReroute(distToRoute);
      return null;
    }
    final speed = _curPos?.speed ?? 0.0;
    final lookAheadPoints = speed > kVehicleSpeedThreshold ? 10 : 5;
    final aheadIdx = (idx + lookAheadPoints).clamp(idx, _routePts.length - 1);
    if (idx == aheadIdx) return null;
    _lastSnapIndex = idx;
    return _bearingBetween(near, _routePts[aheadIdx]);
  }

  void _checkReroute(double deviation) {
    if (_isRerouting) return;
    final now = DateTime.now();
    if (now.difference(_lastRerouteCheck) < const Duration(seconds: 10)) return;
    _lastRerouteCheck = now;
    _isRerouting = true;
    _cachedRoute = null;
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted && _pts.first.latLng != null && _pts.last.latLng != null) {
        _buildRoute();
      }
      _isRerouting = false;
    });
  }

  // ===== Follow/Overview Camera =====
  LatLng _forwardBiasTarget({required LatLng user, required double bearingDeg}) {
    if (!_useForwardAnchor) return user;
    final sp = _curPos?.speed ?? 0.0;
    final metersAhead = (_camMode == _CamMode.follow && sp > 0) ? (sp * 3.5).clamp(30.0, 180.0) : 0.0;
    return _offsetLatLng(user, metersAhead, bearingDeg);
  }

  Future<void> _moveCameraRealtime({
    required LatLng target,
    required double bearing,
    required double zoom,
    required double tilt,
  }) async {
    if (_map == null) return;
    final now = DateTime.now();
    final minGap = Perf.I.camMoveMin;
    if (now.difference(_lastCamMove) < minGap) return;
    _lastCamMove = now;

    await _map!.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: target, zoom: zoom, tilt: tilt, bearing: bearing),
      ),
    );
    _lastCamTarget = target;
  }

  Future<void> _enterOverview({bool fitWholeRoute = true}) async {
    if (_map == null) return;

    late final List<LatLng> pts;
    if (fitWholeRoute && _routePts.isNotEmpty) {
      pts = _routePts;
    } else {
      if (!(_pts.length >= 2 && _pts.first.latLng != null && _pts.last.latLng != null)) return;
      pts = [_pts.first.latLng!, _pts.last.latLng!];
    }

    if (pts.length < 2) return;

    _scheduleMapPaddingUpdate();
    await Future.delayed(const Duration(milliseconds: 16));

    final bounds = _boundsFromPoints(pts);
    await _animateBoundsSafe(bounds, padding: 70);
  }

  void _enterFollowMode() {
    _camMode = _CamMode.follow;
    _rotateWithHeading = true;
    _useForwardAnchor = true;
  }

  // ===== Location settings (dynamic) =====
  LocationSettings _platformLocationSettings({required bool moving}) {
    final gp = Perf.I.gpsProfile(moving: moving);
    final accuracy = moving ? gp.accuracy : LocationAccuracy.high;

    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: moving ? gp.distanceFilterM : math.max(12, gp.distanceFilterM),
        intervalDuration: Duration(milliseconds: gp.intervalMs),
        forceLocationManager: false,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Pick Me',
          notificationText: 'Tracking location…',
          enableWakeLock: false,
        ),
      );
    } else if (Platform.isIOS) {
      return AppleSettings(
        accuracy: accuracy,
        distanceFilter: moving ? gp.distanceFilterM : math.max(12, gp.distanceFilterM),
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: true,
        showBackgroundLocationIndicator: false,
      );
    }
    return LocationSettings(
      accuracy: accuracy,
      distanceFilter: moving ? gp.distanceFilterM : math.max(12, gp.distanceFilterM),
    );
  }

  // ============================================================================
  // Robust acquisition helpers
  // ============================================================================
  bool _isGoodFix(Position p, double maxAccM) {
    if (!p.latitude.isFinite || !p.longitude.isFinite) return false;
    if (p.latitude == 0 && p.longitude == 0) return false;
    if (p.accuracy <= 0 || p.accuracy > 50000) return false;
    return p.accuracy <= maxAccM;
  }

  Future<Position?> _firstStreamFix({
    required Duration deadline,
    required bool moving,
    double maxAccM = 200,
  }) async {
    StreamSubscription<Position>? sub;
    final completer = Completer<Position?>();

    void finish(Position? p) {
      if (!completer.isCompleted) completer.complete(p);
    }

    sub = Geolocator.getPositionStream(
      locationSettings: _platformLocationSettings(moving: moving),
    ).listen((p) {
      if (_isGoodFix(p, maxAccM)) {
        finish(p);
        sub?.cancel();
      }
    }, onError: (_) {});

    Future.delayed(deadline).then((_) async {
      await sub?.cancel();
      finish(null);
    });

    return completer.future;
  }

  Future<void> _awaitOrCreateInitFlight(Future<void> Function() action) async {
    if (_locInitCompleter != null) {
      _logLocationDiagnostic('Init join: waiting on in-flight initialization');
      try {
        await _locInitCompleter!.future;
      } catch (_) {}
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

  Future<bool> _ensureServicesEnabled({required bool userTriggered}) async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (serviceEnabled) return true;

    _logLocationDiagnostic('Location services OFF');
    await _showLocationPromptModal(
      title: 'Turn On Location',
      message: 'To find drivers and show accurate pickups, please turn on your device location.',
      isServiceIssue: true,
    );
    _toast('Location Services Off', 'Please turn on GPS / location services.');
    return false;
  }

  Future<LocationPermission> _ensurePermission({required bool userTriggered}) async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever ||
        perm == LocationPermission.unableToDetermine) {
      _logLocationDiagnostic('Permission denied: $perm');
      await _showLocationPromptModal(
        title: 'Allow Location Access',
        message:
        'We use your location to match you with nearby drivers and calculate accurate ETAs. '
            'Please allow location access in your device settings.',
        isServiceIssue: false,
      );
      _toast('Location Required', 'Please grant location access in Settings.');
    }
    return perm;
  }

  Future<Position?> _acquirePositionRobust() async {
    const maxAcceptableAcc = 200.0;
    const tries = 3;

    // Use fresh last-known to seed fast if available
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null &&
          last.timestamp != null &&
          DateTime.now().difference(last.timestamp!).inMinutes < 2 &&
          _isGoodFix(last, 400)) {
        _logLocationDiagnostic('Using fresh last-known to seed UI: acc=${last.accuracy}');
        return last;
      }
    } catch (_) {}

    for (var attempt = 1; attempt <= tries; attempt++) {
      try {
        _logLocationDiagnostic('Acquisition attempt $attempt/$tries (bestForNavigation)');
        final p = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.bestForNavigation,
          timeLimit: const Duration(seconds: 10),
        );
        if (_isGoodFix(p, maxAcceptableAcc)) return p;
        _logLocationDiagnostic('Fix too coarse (acc=${p.accuracy.toStringAsFixed(1)}m) — trying stream…');
      } on TimeoutException {
        _logLocationDiagnostic('GPS timeout on attempt $attempt/$tries');
      } on LocationServiceDisabledException {
        _logLocationDiagnostic('Services disabled during acquisition');
        return null;
      } on PermissionDeniedException {
        _logLocationDiagnostic('Permission denied during acquisition');
        return null;
      } catch (e) {
        _logLocationDiagnostic('Acquisition error attempt $attempt: $e');
      }

      final sample = await _firstStreamFix(
        deadline: Duration(milliseconds: 1200 + (attempt * 600)),
        moving: true,
        maxAccM: maxAcceptableAcc * (attempt == tries ? 2 : 1),
      );
      if (sample != null) return sample;
    }

    try {
      _logLocationDiagnostic('Attempting high accuracy fallback (8s)');
      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 8),
      );
      if (_isGoodFix(p, 400)) return p;
    } catch (e) {
      _logLocationDiagnostic('High accuracy fallback failed: $e');
    }

    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return last;
    } catch (_) {}

    return null;
  }

  Future<void> _startGpsStream(Position seed) async {
    await _gpsSub?.cancel();
    _gpsStreamErrorCount = 0;

    _lastStreamUpdate = DateTime.now();
    _curPos = seed;
    _onGpsUpdate(seed); // seed UI immediately

    _gpsSub = Geolocator.getPositionStream(
      locationSettings: _platformLocationSettings(moving: true),
    ).listen((p) {
      try {
        _lastStreamUpdate = DateTime.now();
        _gpsStreamErrorCount = 0;

        if (!_isGoodFix(p, 10000)) {
          _logLocationDiagnostic('Discarded suspicious stream update (acc=${p.accuracy})');
          return;
        }
        _onGpsUpdate(p);
      } catch (e) {
        _logLocationDiagnostic('Error processing stream update: $e');
      }
    }, onError: (err) {
      _gpsStreamErrorCount++;
      _logLocationDiagnostic('[GPS] stream error #$_gpsStreamErrorCount: $err');
      if (_gpsStreamErrorCount >= 5) {
        _logLocationDiagnostic('[GPS] Max stream errors; scheduling restart');
        _gpsSub?.cancel();
        _gpsStreamErrorCount = 0;
        _restartLocationStreamWithBackoff();
      }
    }, cancelOnError: false);

    _gpsWatchdog?.cancel();
    _gpsWatchdog = Timer.periodic(const Duration(seconds: 27), (_) {
      if (_lastStreamUpdate == null) return;
      final gap = DateTime.now().difference(_lastStreamUpdate!);
      if (gap.inSeconds > 40) {
        _logLocationDiagnostic('[GPS] Watchdog: stalled ${gap.inSeconds}s — restarting');
        _gpsSub?.cancel();
        _restartLocationStreamWithBackoff();
      }
    });
  }

  // ============================================================================
  // INIT LOCATION — single-flight robust version
  // ============================================================================
  Future<void> _initLocation({bool userTriggered = false}) async {
    if (!mounted) return;

    await _awaitOrCreateInitFlight(() async {
      _gpsWatchdog?.cancel();

      final servicesOk = await _ensureServicesEnabled(userTriggered: userTriggered);
      if (!servicesOk) return;

      final perm = await _ensurePermission(userTriggered: userTriggered);
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever ||
          perm == LocationPermission.unableToDetermine) {
        return;
      }

      final pos = await _acquirePositionRobust();

      if (pos == null) {
        _logLocationDiagnostic('Final position is null after all strategies + fallback');
        if (userTriggered) {
          await _showLocationPromptModal(
            title: 'Location Unavailable',
            message: 'We could not determine your current position. Move to open space, toggle GPS, then try again.',
            isServiceIssue: true,
          );
        }
        _toast('Location Unavailable', 'Unable to get your current position.');
        return;
      }

      _curPos = pos;
      final ll = LatLng(pos.latitude, pos.longitude);
      _lastStreamUpdate = DateTime.now();

      _logLocationDiagnostic(
        'Acquired: lat=${pos.latitude}, lon=${pos.longitude}, '
            'acc=${pos.accuracy.toStringAsFixed(1)}m, heading=${pos.heading}',
      );

      if (_map != null) {
        try {
          await _map!.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(
                target: ll,
                zoom: 16.5,
                tilt: 45,
                bearing: pos.heading.isFinite && pos.heading >= 0 ? pos.heading : 0,
              ),
            ),
          );
        } catch (e) {
          _logLocationDiagnostic('Camera animation failed: $e');
        }
      }

      try {
        await _useCurrentAsPickup();
        _updateUserMarker(ll, rotation: pos.heading >= 0 ? pos.heading : 0);
        _lastCamTarget = ll;
      } catch (e) {
        _logLocationDiagnostic('Marker/pickup update failed: $e');
      }

      await _startGpsStream(pos);
    });
  }

  // ============================================================================
  // Stream restart with exponential backoff + jitter
  // ============================================================================
  Future<void> _restartLocationStreamWithBackoff() async {
    if (!mounted) return;

    if (_locInitCompleter != null) {
      _logLocationDiagnostic('Restart join: init already in progress');
      await _locInitCompleter!.future;
      return;
    }

    _gpsInitAttempt = (_gpsInitAttempt + 1).clamp(1, 5);
    final secs = 2 * _gpsInitAttempt;
    final jitterMs = (300 * (math.Random().nextDouble())).round();
    final delay = Duration(seconds: secs, milliseconds: jitterMs);

    _logLocationDiagnostic(
      '[GPS] Re-init in ${delay.inSeconds}.${(delay.inMilliseconds % 1000) ~/ 100}s (attempt $_gpsInitAttempt)',
    );

    await Future.delayed(delay);
    if (!mounted) return;
    await _initLocation(userTriggered: false);
  }

  // ============================================================================
  // PREMIUM LOCATION PROMPT MODAL (BOTTOM SHEET)
  // ============================================================================
  Future<void> _showLocationPromptModal({
    required String title,
    required String message,
    required bool isServiceIssue,
  }) async {
    if (!mounted) return;

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(isDark ? 0.60 : 0.40),
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        final bottomInset = media.viewInsets.bottom;

        final surface = cs.surface;
        final onSurface = theme.textTheme.bodyMedium?.color ?? cs.onSurface;
        final divider = theme.dividerColor.withOpacity(isDark ? 0.28 : 0.18);

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 12 + bottomInset),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    color: surface,
                    border: Border.all(color: divider, width: 0.8),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(isDark ? 0.40 : 0.18),
                        blurRadius: 26,
                        offset: const Offset(0, 16),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Grabber
                        Container(
                          width: 52,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            color: divider,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        // Leading badge
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                cs.primary.withOpacity(0.95),
                                cs.primary.withOpacity(0.65),
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: cs.primary.withOpacity(0.22),
                                blurRadius: 16,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Icon(
                            isServiceIssue ? Icons.gps_off_rounded : Icons.my_location_rounded,
                            color: cs.onPrimary,
                            size: 28,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          message,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: onSurface.withOpacity(0.88),
                            height: 1.36,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                style: TextButton.styleFrom(
                                  foregroundColor: onSurface.withOpacity(0.92),
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                child: const Text('Not now'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () async {
                                  Navigator.of(ctx).pop();
                                  if (isServiceIssue) {
                                    await Geolocator.openLocationSettings();
                                  } else {
                                    await Geolocator.openAppSettings();
                                  }
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: cs.primary,
                                  foregroundColor: cs.onPrimary,
                                  elevation: 0,
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                child: const Text('Enable location'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ===== GPS stream → app pipeline =====
  void _onGpsUpdate(Position pos) {
    if (_gpsThrottleTimer?.isActive ?? false) return;
    if (!_isGoodFix(pos, 10000)) return;

    _gpsThrottleTimer = Timer(kGpsUpdateInterval, () {
      if (!mounted) return;

      final now = DateTime.now();
      _prevPos = _curPos;
      _curPos = pos;
      final ll = LatLng(pos.latitude, pos.longitude);

      // Movement state & mode
      final sp = pos.speed;
      if (sp >= kVehicleSpeedThreshold) {
        _movementMode = MovementMode.vehicle;
      } else if (sp >= kPedestrianSpeedThreshold) {
        _movementMode = MovementMode.pedestrian;
      } else {
        _movementMode = MovementMode.stationary;
      }

      if (sp >= kPedestrianSpeedThreshold) {
        if (!_gpsActive) {
          _gpsActive = true;
          _stationaryTimer?.cancel();
        }
      } else {
        _checkStationaryTimeout();
      }

      // Rotate cheap marker
      final rot = (pos.heading.isFinite && pos.heading >= 0) ? pos.heading : _userMarkerRotation;
      _updateUserMarker(ll, rotation: rot);

      // Camera work: skip while overlay open to avoid jank
      if (!_expanded && _camMode == _CamMode.follow) {
        double? bearing = _routeAwareBearing(ll);
        if (bearing == null &&
            pos.heading.isFinite &&
            pos.heading >= 0 &&
            pos.speed >= kPedestrianSpeedThreshold) {
          bearing = pos.heading;
        }
        bearing ??= _compassDeg;

        if (bearing != null) {
          final smoothed = _smoothBearingWithJerkLimit(bearing);
          _moveCameraRealtime(
            target: _forwardBiasTarget(user: ll, bearingDeg: smoothed),
            bearing: _rotateWithHeading ? smoothed : 0,
            zoom: (pos.speed >= kVehicleSpeedThreshold)
                ? 17.5
                : (pos.speed >= kPedestrianSpeedThreshold ? 17.0 : 16.5),
            tilt: Perf.I.tiltFor(pos.speed),
          );
        } else {
          if (now.difference(_lastCamMove) > Perf.I.camMoveMin) {
            final moved = (_lastCamTarget == null) ? double.infinity : _haversine(_lastCamTarget!, ll);
            if (moved > kCenterSnapMeters) {
              _map?.moveCamera(CameraUpdate.newLatLng(ll));
              _lastCamTarget = ll;
              _lastCamMove = now;
            }
          }
        }
      }

      if (_pts.isNotEmpty && _pts.first.isCurrent) _updatePickupFromGps();
      _putLocationCircle(ll, accuracy: pos.accuracy);
    });
  }

  void _checkStationaryTimeout() {
    _stationaryTimer?.cancel();
    _stationaryTimer = Timer(kStationaryTimeout, () {
      if (_movementMode == MovementMode.stationary && _gpsActive) {
        _gpsActive = false;
      }
    });
  }

  Future<void> _refreshUserPosition() async {
    if (_curPos == null) {
      await _initLocation();
      return;
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 5),
      );
      _onGpsUpdate(pos);
    } catch (_) {}
  }

  // ===== Circles =====
  void _putLocationCircle(LatLng c, {double accuracy = 50}) {
    setState(() {
      _circles
        ..clear()
        ..add(
          Circle(
            circleId: const CircleId('accuracy'),
            center: c,
            radius: accuracy.clamp(8, 100),
            fillColor: AppColors.primary.withOpacity(0.10),
            strokeColor: AppColors.primary.withOpacity(0.32),
            strokeWidth: 2,
          ),
        );
    });
  }

  // ===== Routes + cache =====
  bool _hasRoute() =>
      _pts.length >= 2 && _pts.first.latLng != null && _pts.last.latLng != null && _lines.isNotEmpty;

  bool get _hasPickupAndDropoff =>
      _pts.length >= 2 && _pts.first.latLng != null && _pts.last.latLng != null;

  String _computeRouteHash() {
    final parts = <String>[];
    for (final p in _pts) {
      if (p.latLng != null) {
        parts.add('${p.latLng!.latitude.toStringAsFixed(6)},${p.latLng!.longitude.toStringAsFixed(6)}');
      }
    }
    return parts.join('|');
  }

  Future<void> _buildRoute() async {
    if (!(_pts.length >= 2 && _pts.first.latLng != null && _pts.last.latLng != null)) return;

    final routeHash = _computeRouteHash();

    if (_cachedRoute != null && _lastRouteHash == routeHash && !_cachedRoute!.isStale) {
      _applyRouteFromCache(_cachedRoute!.route);
      await _enterOverview(fitWholeRoute: true); // viewport fit
      return;
    }

    setState(() {
      _lines.clear();
      _distanceText = null;
      _durationText = null;
      _fare = null;
      _arrivalTime = null;
      _routeUiError = null;
      _markers.removeWhere((m) => m.markerId == _etaMarkerId || m.markerId == _minsMarkerId);
      _routePts.clear();
      _spatialIndex.clear();
      _lastSnapIndex = -1;
    });

    final origin = _pts.first.latLng!;
    final destination = _pts.last.latLng!;
    final stops = <LatLng>[
      for (int i = 1; i < _pts.length - 1; i++)
        if (_pts[i].latLng != null) _pts[i].latLng!,
    ];

    try {
      final v2 = await _computeRoutesV2(origin, destination, stops);
      if (v2 != null) {
        _lastRouteHash = routeHash;
        _cachedRoute = _RouteCache(v2, DateTime.now());
        _applyRouteFromCache(v2);
        await _enterOverview(fitWholeRoute: true);

        _routeRefreshTimer?.cancel();
        _routeRefreshTimer = Timer.periodic(const Duration(minutes: 3), (_) {
          if (_pts.first.latLng != null && _pts.last.latLng != null && !_expanded) {
            _cachedRoute = null;
            _buildRoute();
          }
        });
        return;
      }

      await _buildRouteLegacy(origin, destination, stops);
      await _enterOverview(fitWholeRoute: true);
    } catch (_) {
      _routeUiError = 'Route calculation failed';
      _toast('Route Error', 'Unable to calculate route.');
      setState(() => _isConnected = false);
    }
  }

  void _applyRouteFromCache(_V2Route route) {
    final points = route.points;
    final distanceMeters = route.distanceMeters;
    final durationSeconds = route.durationSeconds;

    if (points.isEmpty) return;

    _arrivalTime = DateTime.now().add(Duration(seconds: durationSeconds));
    setState(() {
      _distanceText = _fmtDistance(distanceMeters);
      _durationText = _fmtDuration(durationSeconds);
      _fare = _calcFare(distanceMeters);
      _isConnected = true;
    });

    _routePts = points;
    _buildSpatialIndex();
    _buildSpeedColoredPolylines(points, route.speedIntervals);

    // screenshot-style badges
    _updateRouteBubbles(
      origin: _pts.first.latLng!,
      destination: _pts.last.latLng!,
      secs: durationSeconds,
    ).then((_) => _fitCurrentRouteToViewport());
  }

  Future<_V2Route?> _computeRoutesV2(LatLng origin, LatLng destination, List<LatLng> stops) async {
    final url = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');

    final body = <String, dynamic>{
      'origin': {
        'location': {
          'latLng': {'latitude': origin.latitude, 'longitude': origin.longitude}
        }
      },
      'destination': {
        'location': {
          'latLng': {'latitude': destination.latitude, 'longitude': destination.longitude}
        }
      },
      if (stops.isNotEmpty)
        'intermediates': [
          for (final s in stops)
            {
              'location': {
                'latLng': {'latitude': s.latitude, 'longitude': s.longitude}
              }
            }
        ],
      'travelMode': 'DRIVE',
      'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
      'computeAlternativeRoutes': false,
      'optimizeWaypointOrder': stops.isNotEmpty,
      'units': 'METRIC',
      'polylineQuality': 'HIGH',
    };

    final headers = {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': ApiConstants.kGoogleApiKey,
      'X-Goog-FieldMask':
      'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline,'
          'routes.travelAdvisory.speedReadingIntervals',
    };

    http.Response res;
    try {
      res = await _executeWithRetry(
        'routes_v2_${DateTime.now().millisecondsSinceEpoch}',
            () => http.post(url, headers: headers, body: jsonEncode(body)).timeout(kApiTimeout),
      );
    } catch (_) {
      return null;
    }

    if (res.statusCode != 200) return null;

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final routes = (json['routes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (routes.isEmpty) return null;

    final route = routes.first;
    final encoded = (route['polyline']?['encodedPolyline'] ?? '') as String;
    if (encoded.isEmpty) return null;

    final pts = _decodePolyline(encoded);
    final dist = (route['distanceMeters'] ?? 0) as int;
    final durS = _parseDurationSeconds(route['duration']?.toString() ?? '0s');

    final siRaw =
        (route['travelAdvisory']?['speedReadingIntervals'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final intervals = <_SpeedInterval>[];
    for (final m in siRaw) {
      final s = (m['startPolylinePointIndex'] ?? 0) as int;
      final e = (m['endPolylinePointIndex'] ?? 0) as int;
      final sp = (m['speed'] ?? 'NORMAL') as String;
      intervals.add(_SpeedInterval(s, e, sp));
    }

    return _V2Route(pts, dist, durS, intervals);
  }

  int _parseDurationSeconds(String v) {
    if (!v.endsWith('s')) return 0;
    final n = v.substring(0, v.length - 1);
    return double.tryParse(n)?.round() ?? 0;
  }

  void _buildSpeedColoredPolylines(List<LatLng> decPts, List<_SpeedInterval> intervals) {
    _lines.add(
      Polyline(
        polylineId: const PolylineId('route_halo'),
        points: decPts,
        color: Colors.white.withOpacity(0.92),
        width: 11,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        geodesic: true,
      ),
    );

    Color colorFor(String speed) {
      switch (speed) {
        case 'TRAFFIC_JAM':
          return const Color(0xFFE53935);
        case 'SLOW':
          return const Color(0xFFFF8F00);
        default:
          return const Color(0xFF2E7D32);
      }
    }

    if (intervals.isEmpty) {
      _lines.add(
        Polyline(
          polylineId: const PolylineId('route_main'),
          points: decPts,
          color: AppColors.primary,
          width: 7,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
          geodesic: true,
        ),
      );
      setState(() {});
      return;
    }

    for (var i = 0; i < intervals.length; i++) {
      final it = intervals[i];
      final start = it.start.clamp(0, decPts.length - 1);
      final end = it.end.clamp(start + 1, decPts.length);
      final seg = decPts.sublist(start, end);
      _lines.add(
        Polyline(
          polylineId: PolylineId('route_seg_$i'),
          points: seg,
          color: colorFor(it.speed),
          width: 7,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
          geodesic: true,
        ),
      );
    }
    setState(() {});
  }

  Future<void> _buildRouteLegacy(LatLng o, LatLng d, List<LatLng> stops) async {
    final wp = stops.isNotEmpty
        ? '&waypoints=optimize:true|${stops.map((w) => '${w.latitude},${w.longitude}').join('|')}'
        : '';
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json?origin=${o.latitude},${o.longitude}'
          '&destination=${d.latitude},${d.longitude}$wp&key=${ApiConstants.kGoogleApiKey}',
    );

    http.Response r;
    try {
      r = await _executeWithRetry(
        'directions_v1_${DateTime.now().millisecondsSinceEpoch}',
            () => http.get(url).timeout(kApiTimeout),
      );
    } catch (_) {
      _routeUiError = 'Directions v1 error';
      setState(() {});
      return;
    }

    final j = jsonDecode(r.body);
    if (r.statusCode != 200 || (j['status']?.toString() ?? 'UNKNOWN') != 'OK') {
      _routeUiError = 'Directions v1 failed';
      setState(() {});
      return;
    }

    final routes = (j['routes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (routes.isEmpty) return;

    final route = routes.first;
    final legs = (route['legs'] as List).cast<Map<String, dynamic>>();

    int dMeters = 0, dSecs = 0;
    for (final l in legs) {
      dMeters += (l['distance']?['value'] ?? 0) as int;
      dSecs += (l['duration']?['value'] ?? 0) as int;
    }

    final poly = (route['overview_polyline']?['points'] ?? '') as String;
    if (poly.isEmpty) return;

    final pts = _decodePolyline(poly);

    _arrivalTime = DateTime.now().add(Duration(seconds: dSecs));
    setState(() {
      _distanceText = _fmtDistance(dMeters);
      _durationText = _fmtDuration(dSecs);
      _fare = _calcFare(dMeters);
      _isConnected = true;
    });

    _routePts = pts;
    _buildSpatialIndex();
    _buildSpeedColoredPolylines(pts, const []);

    await _updateRouteBubbles(origin: o, destination: d, secs: dSecs);
    await _fitCurrentRouteToViewport();
  }

  // ===== Screenshot-style route badges =====
  Future<void> _updateRouteBubbles({
    required LatLng origin, // pickup
    required LatLng destination, // destination
    required int secs,
  }) async {
    final minutes = math.max(1, (secs / 60).round());
    final arrive = 'Arrive by ${DateFormat('h:mm a').format(DateTime.now().add(Duration(seconds: secs)))}';

    _minsBubbleIcon = await _buildMinutesCircleBadge(minutes);
    _etaBubbleIcon = await _buildArrivePillBadge(arrive);

    if (!mounted) return;

    setState(() {
      _markers.removeWhere((m) => m.markerId == _etaMarkerId || m.markerId == _minsMarkerId);

      // destination badge (green)
      _markers.add(
        Marker(
          markerId: _minsMarkerId,
          position: destination,
          icon: _minsBubbleIcon!,
          anchor: const Offset(0.5, 1.0),
          consumeTapEvents: false,
          zIndex: 998,
        ),
      );

      // pickup badge (blue pill)
      _markers.add(
        Marker(
          markerId: _etaMarkerId,
          position: origin,
          icon: _etaBubbleIcon!,
          anchor: const Offset(0.5, 1.0),
          consumeTapEvents: false,
          zIndex: 998,
        ),
      );
    });
  }

  Future<BitmapDescriptor> _buildMinutesCircleBadge(int minutes) async {
    // green circle badge + bottom pinned dot (like screenshot)
    const w = 140.0, h = 160.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);

    final center = const Offset(w / 2, 62);
    const badgeR = 44.0;

    // shadow
    c.drawCircle(
      center + const Offset(0, 6),
      badgeR,
      Paint()
        ..color = Colors.black.withOpacity(0.18)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 10),
    );

    // badge
    c.drawCircle(center, badgeR, Paint()..color = const Color(0xFF00A651));

    // "11" + "min"
    final numTp = TextPainter(
      text: TextSpan(
        text: '$minutes',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 34,
          fontWeight: FontWeight.w900,
          height: 1.0,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final minTp = TextPainter(
      text: const TextSpan(
        text: 'min',
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w800,
          height: 1.0,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    numTp.paint(c, Offset(center.dx - numTp.width / 2, center.dy - 30));
    minTp.paint(c, Offset(center.dx - minTp.width / 2, center.dy + 6));

    // connector
    final linePaint = Paint()
      ..color = const Color(0xFF00A651)
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;

    c.drawLine(const Offset(w / 2, 110), const Offset(w / 2, 132), linePaint);

    // pinned dot
    const dotCenter = Offset(w / 2, 144);
    c.drawCircle(dotCenter, 12, Paint()..color = Colors.white);
    c.drawCircle(
      dotCenter,
      12,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..color = const Color(0xFF00A651),
    );
    c.drawCircle(dotCenter, 4.5, Paint()..color = const Color(0xFF00A651));

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  Future<BitmapDescriptor> _buildArrivePillBadge(String text) async {
    const double h = 64;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final w = (tp.width + 46).clamp(210.0, 360.0);

    final rec = ui.PictureRecorder();
    final c = Canvas(rec);

    final pill = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, w, h - 10),
      const Radius.circular(22),
    );

    // shadow
    c.drawRRect(
      pill.shift(const Offset(0, 6)),
      Paint()
        ..color = Colors.black.withOpacity(0.18)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 10),
    );

    // fill
    c.drawRRect(pill, Paint()..color = const Color(0xFF1A73E8));

    // pointer
    final p = Path()
      ..moveTo(w / 2 - 10, h - 10)
      ..lineTo(w / 2, h)
      ..lineTo(w / 2 + 10, h - 10)
      ..close();
    c.drawPath(p, Paint()..color = const Color(0xFF1A73E8));

    tp.paint(c, Offset((w - tp.width) / 2, ((h - 10) - tp.height) / 2));

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  double _calcFare(int meters) => 500.0 + (meters / 1000.0) * 120.0;

  String _fmtDistance(int m) => (m < 1000) ? '$m m' : '${(m / 1000.0).toStringAsFixed(1)} km';

  String _fmtDuration(int s) {
    final mins = (s / 60).round();
    if (mins < 60) return '$mins min';
    final h = mins ~/ 60, mm = mins % 60;
    return '${h}h ${mm}m';
  }

  List<LatLng> _decodePolyline(String enc) {
    final out = <LatLng>[];
    int idx = 0, lat = 0, lng = 0;
    while (idx < enc.length) {
      int b, shift = 0, res = 0;
      do {
        b = enc.codeUnitAt(idx++) - 63;
        res |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlat = (res & 1) != 0 ? ~(res >> 1) : (res >> 1);
      lat += dlat;

      shift = 0;
      res = 0;
      do {
        b = enc.codeUnitAt(idx++) - 63;
        res |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlng = (res & 1) != 0 ? ~(res >> 1) : (res >> 1);
      lng += dlng;

      out.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return out;
  }

  // ===== Recents =====
  static const _kRecentsKey = 'recent_places_v5';
  static const int _maxRecents = 30;

  Future<void> _loadRecents() async {
    final raw = _prefs.getString(_kRecentsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      setState(() {
        _recents = list.map(Suggestion.fromJson).toList().take(_maxRecents).toList();
        _sugs = _recents;
      });
    } catch (_) {
      await _prefs.remove(_kRecentsKey);
    }
  }

  void _saveRecent(Suggestion s) {
    final up = List<Suggestion>.from(_recents);
    up.removeWhere((e) => e.placeId == s.placeId);
    up.insert(0, s);
    final cap = up.take(_maxRecents).toList();
    _prefs.setString(_kRecentsKey, jsonEncode(cap.map((e) => e.toJson()).toList()));
    setState(() => _recents = cap);
  }

  // ===== Points =====
  void _initPoints() {
    final pickupFocus = FocusNode();
    final pickupCtl = TextEditingController();
    pickupFocus.addListener(() {
      if (pickupFocus.hasFocus) _onFocused(0);
    });

    final destFocus = FocusNode();
    final destCtl = TextEditingController();
    destFocus.addListener(() {
      if (destFocus.hasFocus) _onFocused(1);
    });

    _pts.addAll([
      RoutePoint(
        type: PointType.pickup,
        controller: pickupCtl,
        focus: pickupFocus,
        hint: 'Pickup location',
      ),
      RoutePoint(
        type: PointType.destination,
        controller: destCtl,
        focus: destFocus,
        hint: 'Where to?',
      ),
    ]);
  }

  void _onFocused(int index) {
    setState(() {
      _activeIdx = index;
      _sugs = _recents;
      _autoStatus = null;
      _autoError = null;
    });
    _expand();
  }

  void _addStop() {
    HapticFeedback.mediumImpact();
    if (_pts.length >= 6) {
      _toast('Limit Reached', 'Maximum 4 stops allowed.');
      return;
    }
    final idx = _pts.length - 1;
    final stopFocus = FocusNode();
    final stopCtl = TextEditingController();
    stopFocus.addListener(() {
      if (stopFocus.hasFocus) _onFocused(idx);
    });
    final s = RoutePoint(
      type: PointType.stop,
      controller: stopCtl,
      focus: stopFocus,
      hint: 'Add stop ${_pts.length - 1}',
    );
    setState(() => _pts.insert(idx, s));
    Future.delayed(const Duration(milliseconds: 80), () => s.focus.requestFocus());
  }

  void _removeStop(int idx) {
    HapticFeedback.lightImpact();
    if (idx <= 0 || idx >= _pts.length - 1) return;
    setState(() {
      final p = _pts.removeAt(idx);
      p.controller.dispose();
      p.focus.dispose();
      _markers.removeWhere((m) => m.markerId.value == 'p_$idx');
    });
    if (_pts.first.latLng != null && _pts.last.latLng != null) {
      _cachedRoute = null;
      _buildRoute();
    }
  }

  void _swap() {
    HapticFeedback.mediumImpact();
    if (_pts.length < 2) return;
    setState(() {
      final a = _pts.first, b = _pts.last;
      final ll = a.latLng, id = a.placeId, txt = a.controller.text, cur = a.isCurrent;
      a
        ..latLng = b.latLng
        ..placeId = b.placeId
        ..controller.text = b.controller.text
        ..isCurrent = false;
      b
        ..latLng = ll
        ..placeId = id
        ..controller.text = txt
        ..isCurrent = cur;
      if (a.latLng != null) _putMarker(0, a.latLng!, a.controller.text);
      if (b.latLng != null) _putMarker(_pts.length - 1, b.latLng!, b.controller.text);
    });
    if (_pts.first.latLng != null && _pts.last.latLng != null) {
      _cachedRoute = null;
      _buildRoute();
    }
  }

  // ===== Autocomplete =====
  void _onTyping(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() {
        _sugs = _recents;
        _isTyping = false;
      });
      return;
    }
    if (!_expanded) _expand();
    setState(() => _isTyping = true);
    _debounce = Timer(const Duration(milliseconds: 260), () => _fetchSugs(q.trim()));
  }

  void _ensureSession() {
    if (_placesSession.isEmpty) {
      _placesSession = _uuid.v4();
    }
  }

  Future<void> _fetchSugs(String input) async {
    if (_activeRequests >= kMaxConcurrentRequests) return;
    _ensureSession();
    _activeRequests++;
    final origin = _curPos == null ? null : LatLng(_curPos!.latitude, _curPos!.longitude);
    final int myQueryId = ++_lastQueryId;

    try {
      var result = await _auto
          .autocomplete(
        input: input,
        sessionToken: _placesSession,
        apiKey: ApiConstants.kGoogleApiKey,
        country: 'ng',
        origin: origin,
      )
          .timeout(kApiTimeout);

      if (!mounted || myQueryId != _lastQueryId) return;

      _autoStatus = result.status;
      _autoError = result.errorMessage;
      var sugs = result.predictions;

      if (sugs.isEmpty) {
        result = await _auto
            .autocomplete(
          input: input,
          sessionToken: _placesSession,
          apiKey: ApiConstants.kGoogleApiKey,
          country: 'ng',
          origin: origin,
          relaxedTypes: true,
        )
            .timeout(kApiTimeout);
        _autoStatus = result.status;
        _autoError = result.errorMessage;
        sugs = result.predictions;

        if (sugs.isEmpty) {
          sugs = await _auto
              .findPlaceText(
            input: input,
            apiKey: ApiConstants.kGoogleApiKey,
            origin: origin,
          )
              .timeout(kApiTimeout);
          _autoStatus = _autoStatus ?? 'FALLBACK_FIND_PLACE';
        }
      }

      setState(() {
        _sugs = sugs;
        _isTyping = false;
        _isConnected = true;
      });
    } catch (_) {
      if (!mounted || myQueryId != _lastQueryId) return;
      setState(() {
        _isTyping = false;
        _isConnected = false;
      });
    } finally {
      _activeRequests = (_activeRequests - 1).clamp(0, 9999);
    }
  }

  Future<void> _selectSug(Suggestion s) async {
    HapticFeedback.mediumImpact();
    try {
      final det = await _auto
          .placeDetails(
        placeId: s.placeId,
        sessionToken: _placesSession,
        apiKey: ApiConstants.kGoogleApiKey,
      )
          .timeout(kApiTimeout);
      if (det.latLng == null) return;

      setState(() {
        final p = _pts[_activeIdx];
        p
          ..latLng = det.latLng
          ..placeId = s.placeId
          ..controller.text = s.mainText.isNotEmpty ? s.mainText : s.description
          ..isCurrent = false;
      });
      _putMarker(_activeIdx, det.latLng!, s.description);
      _saveRecent(s);
      _placesSession = '';

      await _map?.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(target: det.latLng!, zoom: 16, tilt: 45)),
      );
      _focusNextUnfilled();

      if (_pts.first.latLng != null && _pts.last.latLng != null) {
        _cachedRoute = null;
        await _buildRoute();
        await _enterOverview(); // now fits like screenshot
        _collapse();
        _startRideMarket();
      } else if (_pts.first.latLng != null) {
        _enterFollowMode();
      }
    } catch (_) {
      _toast('Error', 'Failed to load place details.');
    }
  }

  void _focusNextUnfilled() {
    for (int i = 0; i < _pts.length; i++) {
      if (_pts[i].latLng == null) {
        Future.delayed(const Duration(milliseconds: 120), () => _pts[i].focus.requestFocus());
        return;
      }
    }
    Future.delayed(const Duration(milliseconds: 120), () {
      FocusScope.of(context).unfocus();
      _collapse();
    });
  }

  // ===== Point markers =====
  void _putMarker(int idx, LatLng pos, String title) {
    final p = _pts[idx];
    final id = MarkerId('p_$idx');
    final icon = p.type == PointType.pickup
        ? (_pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure))
        : p.type == PointType.destination
        ? (_dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen))
        : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);

    setState(() {
      _markers.removeWhere((m) => m.markerId == id);
      _markers.add(
        Marker(
          markerId: id,
          position: pos,
          icon: icon,
          anchor: const Offset(0.5, 0.5),
          infoWindow: InfoWindow(title: p.type.label, snippet: title),
          consumeTapEvents: false,
        ),
      );
    });
  }

  // ===== Sheet & padding =====
  void _expand() {
    setState(() => _expanded = true);
    _overlayAnimController.forward();
    _scheduleMapPaddingUpdate();
  }

  void _collapse() {
    FocusScope.of(context).unfocus();
    setState(() => _expanded = false);
    _overlayAnimController.reverse();
    _scheduleMapPaddingUpdate();
  }

  void _scheduleMapPaddingUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _sheetKey.currentContext;
      double newHeight = 0;
      if (ctx != null) {
        final box = ctx.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) newHeight = box.size.height;
      }
      if (_sheetHeight != newHeight) {
        _sheetHeight = newHeight;
        _applyMapPadding();

        // debounce-fit route when padding changes (so polyline stays visible)
        if (_routePts.isNotEmpty && !_expanded) {
          _fitBoundsDebounce?.cancel();
          _fitBoundsDebounce = Timer(const Duration(milliseconds: 180), () {
            if (!mounted) return;
            if (_camMode == _CamMode.overview) {
              _fitCurrentRouteToViewport();
            }
          });
        }
      }
    });
  }

  void _applyMapPadding() {
    if (!mounted) return;
    final mq = MediaQuery.of(context);
    final topPad = mq.padding.top + kHeaderVisualH;
    final bottomPad = _sheetHeight + kBottomNavH + 12;
    setState(() {
      _mapPadding = EdgeInsets.fromLTRB(0, topPad, 0, bottomPad);
    });
  }

  // ===== UI helpers =====
  void _openWallet() {
    final balance = _user != null ? double.tryParse(_user!['user_bal']?.toString() ?? '0.0') ?? 0.0 : null;
    final currency = _user?['user_currency']?.toString() ?? 'NGN';
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FundAccountSheet(account: _user, balance: balance, currency: currency),
    );
  }

  void _toast(String title, String msg) {
    if (!mounted) return;
    showToastNotification(
      context: context,
      title: title,
      message: msg,
      isSuccess: false,
    );
  }

  // ===== Ride marketplace control =====
  Future<void> _startRideMarket() async {
    if (!_hasPickupAndDropoff) return;
    _marketSub?.cancel();
    _market?.dispose();

    _market = RideMarketService(api: _api, searchRadiusKm: 50);
    setState(() {
      _offersLoading = true;
      _marketOpen = true;
    });

    _marketSub = _market!.stream(origin: _pts.first.latLng!, destination: _pts.last.latLng!).listen((snap) {
      _offers = snap.offers;
      _drivers
        ..clear()
        ..addEntries(snap.drivers.map((d) => MapEntry(d.id, d)));
      _refreshDriverMarkers();
      if (mounted) setState(() => _offersLoading = false);
    }, onError: (_) {
      if (mounted) setState(() => _offersLoading = false);
    });
  }

  void _stopRideMarket() {
    _marketSub?.cancel();
    _market?.dispose();
    _marketSub = null;
    _market = null;
    setState(() {
      _marketOpen = false;
      _offers = const [];
      _drivers.clear();
    });
    _refreshDriverMarkers();
  }

  void _refreshDriverMarkers() {
    if (_driverIcon == null) return;
    final next = <Marker>{};
    for (final d in _drivers.values) {
      next.add(
        Marker(
          markerId: MarkerId('driver_${d.id}'),
          position: d.ll,
          icon: _driverIcon!,
          flat: true,
          rotation: d.heading,
          anchor: const Offset(0.5, 0.6),
          zIndex: 5,
        ),
      );
    }
    setState(() {
      _driverMarkers
        ..clear()
        ..addAll(next);
    });
  }

  // ===== Booking adapter helpers (tolerant to different controller APIs) ====
  Future<String?> _startBooking({
    required String riderId,
    required RideOffer offer,
    required LatLng pickup,
    required LatLng destination,
  }) async {
    if (_booking == null) return null;
    String? id;

    // Named param candidates
    try {
      id = await _booking.bookRide(
        riderId: riderId,
        offer: offer,
        pickup: pickup,
        destination: destination,
      );
    } catch (_) {}
    if (id != null) return id;

    try {
      id = await _booking.startBooking(
        riderId: riderId,
        offer: offer,
        pickup: pickup,
        destination: destination,
      );
    } catch (_) {}
    if (id != null) return id;

    try {
      id = await _booking.createRide(
        riderId: riderId,
        offer: offer,
        pickup: pickup,
        destination: destination,
      );
    } catch (_) {}
    if (id != null) return id;

    // Positional fallbacks
    try {
      id = await _booking.bookRide(riderId, offer, pickup, destination);
    } catch (_) {}
    if (id != null) return id;

    try {
      id = await _booking.startBooking(riderId, offer, pickup, destination);
    } catch (_) {}
    if (id != null) return id;

    try {
      id = await _booking.createRide(riderId, offer, pickup, destination);
    } catch (_) {}
    if (id != null) return id;

    // Generic
    try {
      id = await _booking.start(
        riderId: riderId,
        offer: offer,
        pickup: pickup,
        destination: destination,
      );
    } catch (_) {}
    if (id != null) return id;

    try {
      id = await _booking.start(riderId, offer, pickup, destination);
    } catch (_) {}

    return id;
  }

  Stream<dynamic>? _bookingUpdatesStream() {
    final b = _booking;
    if (b == null) return null;
    try {
      final s = b.updates;
      if (s is Stream) return s as Stream;
    } catch (_) {}
    try {
      final s = b.stream;
      if (s is Stream) return s as Stream;
    } catch (_) {}
    try {
      final s = b.events;
      if (s is Stream) return s as Stream;
    } catch (_) {}
    return null;
  }

  LatLng? _coerceDriverLL(dynamic u) {
    try {
      if (u.driverLL is LatLng) return u.driverLL as LatLng;

      final d = (u.driver ?? u.car ?? u.vehicle ?? u.location ?? u.driverLocation);
      double? lat, lng;
      if (d != null) {
        try {
          lat = (d.lat ?? d.latitude ?? d['lat'] ?? d['latitude'])?.toDouble();
        } catch (_) {}
        try {
          lng = (d.lng ?? d.longitude ?? d['lng'] ?? d['longitude'])?.toDouble();
        } catch (_) {}
        if (lat != null && lng != null) return LatLng(lat!, lng!);
      }

      try {
        final flatLat = (u.driverLat ?? u.lat ?? u.latitude ?? u['driverLat'] ?? u['lat'] ?? u['latitude'])?.toDouble();
        final flatLng = (u.driverLng ?? u.lng ?? u.longitude ?? u['driverLng'] ?? u['lng'] ?? u['longitude'])?.toDouble();
        if (flatLat != null && flatLng != null) return LatLng(flatLat, flatLng);
      } catch (_) {}
    } catch (_) {}
    return null;
  }

  double _coerceHeading(dynamic u) {
    try {
      final h = (u.heading ?? u.bearing ?? u.driverHeading ?? u['heading'] ?? u['bearing']);
      if (h is num) return h.toDouble();
      if (h is String) {
        final v = double.tryParse(h);
        if (v != null) return v;
      }
    } catch (_) {}
    return 0.0;
  }

  String _coercePhase(dynamic u) {
    try {
      final p = (u.phase ?? u.status ?? u.state ?? u['phase'] ?? u['status'] ?? u['state']);
      if (p == null) return '';
      return p.toString().toLowerCase().replaceAll(' ', '_');
    } catch (_) {
      return '';
    }
  }

  bool _phaseIs(String phase, List<String> candidates) {
    if (phase.isEmpty) return false;
    for (final c in candidates) {
      if (phase.contains(c)) return true;
    }
    return false;
  }

  bool _isAssignedOrEnroute(String p) => _phaseIs(p, [
    'driver_assigned',
    'assigned',
    'confirmed',
    'accepted',
    'enroute_pickup',
    'enroute',
    'towards_pickup',
    'to_pickup'
  ]);

  bool _isArrived(String p) => _phaseIs(p, ['arrived_pickup', 'arrived', 'reach_pickup']);
  bool _isInRide(String p) => _phaseIs(p, ['in_ride', 'on_trip', 'in_progress', 'riding']);
  bool _isCompleted(String p) => _phaseIs(p, ['completed', 'done', 'finished', 'ended', 'settled']);
  bool _isCanceled(String p) => _phaseIs(p, ['canceled', 'cancelled', 'declined', 'aborted']);

  // ===== Booking helpers =====
  Future<void> _buildRouteFromDriverToPickup(LatLng driverLL) async {
    if (_pts.isEmpty || _pts.first.latLng == null) return;
    if (!mounted) return;

    final now = DateTime.now();
    if (now.difference(_lastDriverLegRouteAt) < const Duration(seconds: 5)) return;
    _lastDriverLegRouteAt = now;

    final pickup = _pts.first.latLng!;
    final v2 = await _computeRoutesV2(driverLL, pickup, const []);
    if (v2 == null) return;

    setState(() {
      _driverLines
        ..clear()
        ..add(
          Polyline(
            polylineId: const PolylineId('driver_halo'),
            points: v2.points,
            color: Colors.white.withOpacity(0.92),
            width: 10,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
            geodesic: true,
          ),
        )
        ..add(
          Polyline(
            polylineId: const PolylineId('driver_path'),
            points: v2.points,
            color: const Color(0xFF7B1FA2), // purple
            width: 6,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
            geodesic: true,
          ),
        );
    });

    if (_camMode != _CamMode.follow && !_expanded) {
      await _enterOverview(fitWholeRoute: false);
    }
  }

  void _clearBookingVisuals() {
    _booking?.dispose();
    _booking = null;
    _selectedOffer = null;
    setState(() {
      _driverLines.clear();
      _markers.removeWhere((m) => m.markerId == _driverSelectedId);
    });
  }

  // ===== Build =====
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final s = _s(context);
    final safeTop = mq.padding.top;
    final orientation = mq.orientation;

    if (_lastOrientation != orientation) {
      _lastOrientation = orientation;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleMapPaddingUpdate());
    }

    final double fabBottom = (_sheetHeight + kBottomNavH + 16).clamp(96.0, 520.0);
    final hasSummary = _distanceText != null && _durationText != null;
    final bottomSheetMaxH = mq.size.height * 0.60; // finite -> fixes crash

    return Scaffold(
      key: _scaffoldKey,
      drawer: AppMenuDrawer(user: _user),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: _initialCam,
              padding: _mapPadding,
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
              mapToolbarEnabled: false,
              rotateGesturesEnabled: false,
              tiltGesturesEnabled: false,
              markers: {..._markers, ..._driverMarkers},
              polylines: {..._lines, ..._driverLines},
              circles: _circles,
              onMapCreated: (c) {
                _map = c;
                _scheduleMapPaddingUpdate();
                _lastCamTarget = _initialCam.target;

                // if route already exists, refit once map is ready
                if (_routePts.isNotEmpty) {
                  Future.delayed(const Duration(milliseconds: 60), () => _fitCurrentRouteToViewport());
                }
              },
              onCameraMove: (pos) => _lastCamTarget = pos.target,
              onTap: (_) => _collapse(),
            ),
          ),

          if (!_isConnected)
            Positioned(
              top: safeTop + (kHeaderVisualH * s) + 8,
              left: 12 * s,
              right: 12 * s,
              child: Material(
                color: Colors.orange.shade700,
                borderRadius: BorderRadius.circular(8 * s),
                elevation: 6,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 8 * s),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi_off, size: 16 * s, color: Colors.white),
                      SizedBox(width: 8 * s),
                      Text(
                        'Connection issue. Retrying...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: (12 * s).clamp(11.0, 14.0),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Top gradient
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
                    colors: [
                      Colors.black.withOpacity(.60),
                      Colors.black.withOpacity(.25),
                      Colors.transparent
                    ],
                    stops: const [0.0, 0.65, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // Header
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

          // Compact trip summary
          if (hasSummary)
            Positioned(
              top: safeTop + (kHeaderVisualH * s) + 6,
              left: 12,
              right: 12,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor.withOpacity(0.97),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppColors.mintBgLight.withOpacity(.38),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(.15),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      )
                    ],
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.schedule_rounded, size: 17),
                          SizedBox(width: 6),
                        ],
                      ),
                      Text(_durationText!, style: const TextStyle(fontWeight: FontWeight.w800)),
                      Container(height: 16, width: 1, color: AppColors.mintBgLight.withOpacity(.5)),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.straighten_rounded, size: 17),
                          SizedBox(width: 6),
                        ],
                      ),
                      Text(_distanceText!, style: const TextStyle(fontWeight: FontWeight.w800)),
                      if (_arrivalTime != null) ...[
                        Container(height: 16, width: 1, color: AppColors.mintBgLight.withOpacity(.5)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.flag_rounded, size: 17),
                            const SizedBox(width: 6),
                            Text(
                              'Arrive ${DateFormat('h:mm a').format(_arrivalTime!)}',
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),

          // Locate / Follow FAB
          Positioned(
            right: 14 * s,
            bottom: fabBottom,
            child: LocateFab(
              onTap: () async {
                HapticFeedback.selectionClick();
                _enterFollowMode();
                if (_curPos != null) {
                  final ll = LatLng(_curPos!.latitude, _curPos!.longitude);
                  _applyHeadingTick();
                  await _map?.animateCamera(
                    CameraUpdate.newCameraPosition(CameraPosition(target: ll, zoom: 17, tilt: 45)),
                  );
                } else {
                  await _initLocation(userTriggered: true);
                }
              },
            ),
          ),

          // Bottom sheet area — RouteSheet OR RideMarketSheet (finite height)
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
                  key: ValueKey('route_sheet_${_expanded}_$_marketOpen'),
                  bottomNavHeight: kBottomNavH,
                  recentDestinations: _recents,
                  onSearchTap: () {
                    _dbg("[RouteSheet] onSearchTap triggered");
                    setState(() {
                      _activeIdx = _pts.length - 1;
                      _expanded = true;
                      _pts.last.focus.requestFocus();
                    });
                    _scheduleMapPaddingUpdate();
                  },
                  onRecentTap: (sug) async {
                    _dbg("[RouteSheet] onRecentTap", sug);
                    await _selectSug(sug);
                  },
                )
                    : StreamBuilder<RideMarketSnapshot>(
                  stream: _rideMarketService.stream(
                    origin: _pts.first.latLng!,
                    destination: _pts.last.latLng!,
                    simulateOnFailure: false,
                  ),
                  builder: (context, snapshot) {
                    _dbg("[RideMarketSheet] StreamBuilder rebuild, hasData=${snapshot.hasData}");
                    List<RideOffer> offers = [];
                    List<DriverCar> drivers = [];

                    if (snapshot.hasError) {
                      _dbg("[RideMarketSheet] Stream error", snapshot.error ?? '');
                    }

                    if (snapshot.hasData) {
                      offers = snapshot.data!.offers;
                      drivers = snapshot.data!.drivers;
                    }

                    return RideMarketSheet(
                      bottomNavHeight: kBottomNavH,
                      originText: _pts.first.controller.text,
                      destinationText: _pts.last.controller.text,
                      distanceText: _distanceText,
                      durationText: _durationText,
                      offers: offers,
                      loading: !snapshot.hasData,
                      onRefresh: () {
                        _dbg("[RideMarketSheet] onRefresh triggered");
                        _startRideMarket();
                      },
                      onCancel: () {
                        _dbg("[RideMarketSheet] onCancel triggered");
                        _stopRideMarket();
                        _clearBookingVisuals();
                        setState(() {
                          _pts.last
                            ..latLng = null
                            ..controller.text = '';
                          _marketOpen = false;
                        });
                      },
                      onSelect: (offer) async {
                        _dbg("[RideMarketSheet] onSelect offer", offer.id);
                        _stopRideMarket();
                        _selectedOffer = offer;

                        final riderId = _prefs.getString('user_id') ?? 'guest';
                        _booking?.dispose();
                        _booking = BookingController(_api);

                        final rideId = await _startBooking(
                          riderId: riderId,
                          offer: offer,
                          pickup: _pts.first.latLng!,
                          destination: _pts.last.latLng!,
                        );

                        if (rideId == null) {
                          _dbg("[RideMarketSheet] Booking failed for offer", offer.id);
                          _toast('Booking failed', 'Could not book this driver.');
                          _startRideMarket();
                          return;
                        }

                        _dbg("[RideMarketSheet] Booking successful, rideId", rideId);

                        final stream = _bookingUpdatesStream();
                        if (stream == null) {
                          _dbg("[RideMarketSheet] Booking update stream is null!");
                          _toast('Booking error', 'No update stream from controller.');
                          return;
                        }

                        stream.listen((u) async {
                          if (!mounted) return;

                          final drvLL = _coerceDriverLL(u);
                          if (drvLL != null) {
                            final head = _coerceHeading(u);
                            setState(() {
                              _markers.removeWhere((m) => m.markerId == _driverSelectedId);
                              _markers.add(
                                Marker(
                                  markerId: _driverSelectedId,
                                  position: drvLL,
                                  icon: _driverIcon ??
                                      BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
                                  flat: true,
                                  rotation: head,
                                  anchor: const Offset(0.5, 0.6),
                                  zIndex: 50,
                                ),
                              );
                            });
                            _dbg("[BookingStream] Driver moved to", '${drvLL.latitude},${drvLL.longitude}');

                            // Optional: if you want driver→pickup route visible, uncomment:
                            // await _buildRouteFromDriverToPickup(drvLL);
                          }

                          final ph = _coercePhase(u);
                          _dbg("[BookingStream] Ride phase", ph);

                          if (_isArrived(ph)) _toast('Driver arrived', 'Please meet your driver.');
                          if (_isInRide(ph)) setState(() => _driverLines.clear());
                          if (_isCompleted(ph)) _clearBookingVisuals();
                          if (_isCanceled(ph)) _clearBookingVisuals();
                        });

                        setState(() => _marketOpen = false);
                      },
                    );
                  },
                ),
              ),
            ),
          ),

          // Full-screen overlay for search/autocomplete
          if (_expanded)
            FadeTransition(
              opacity: _overlayFadeAnim,
              child: AutoOverlay(
                safeTop: safeTop,
                bottomPadding: kBottomNavH + 12,
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
                  Future.delayed(const Duration(milliseconds: 50), () {
                    if (mounted) setState(() {});
                  });
                },
                onSwap: _swap,
              ),
            ),
        ],
      ),
      bottomNavigationBar: !_marketOpen
          ? CustomBottomNavBar(
        currentIndex: _currentIndex,
        onTap: (i) {
          HapticFeedback.selectionClick();
          setState(() => _currentIndex = i);
          if (i == 1) Navigator.pushNamed(context, AppRoutes.rideHistory);
          if (i == 2) Navigator.pushNamed(context, AppRoutes.profile);
        },
      )
          : null,
    );
  }

  // ===== Pickup helpers =====
  Future<void> _useCurrentAsPickup() async {
    if (_curPos == null || _pts.isEmpty) return;
    try {
      final marks = await geo.placemarkFromCoordinates(_curPos!.latitude, _curPos!.longitude);
      final place = marks.isNotEmpty ? marks.first : null;
      final addr = _fmtPlacemark(place);
      final ll = LatLng(_curPos!.latitude, _curPos!.longitude);
      setState(() {
        _pts.first
          ..latLng = ll
          ..placeId = null
          ..controller.text = addr
          ..isCurrent = true;
      });
      _putMarker(0, ll, addr);
      _putLocationCircle(ll, accuracy: _curPos!.accuracy);
    } catch (_) {
      final ll = LatLng(_curPos!.latitude, _curPos!.longitude);
      setState(() {
        _pts.first
          ..latLng = ll
          ..controller.text = 'Current location'
          ..isCurrent = true;
      });
      _putMarker(0, ll, 'Current location');
    }
  }

  void _updatePickupFromGps() {
    if (_curPos == null) return;
    final ll = LatLng(_curPos!.latitude, _curPos!.longitude);
    setState(() => _pts.first.latLng = ll);
    _putMarker(0, ll, _pts.first.controller.text);
  }

  String _fmtPlacemark(geo.Placemark? p) {
    if (p == null) return 'Current location';
    final parts = <String>[];
    if ((p.name ?? '').isNotEmpty) parts.add(p.name!);
    if ((p.street ?? '').isNotEmpty && p.street != p.name) parts.add(p.street!);
    if ((p.locality ?? '').isNotEmpty) parts.add(p.locality!);
    return parts.isEmpty ? 'Current location' : parts.join(', ');
  }
}
