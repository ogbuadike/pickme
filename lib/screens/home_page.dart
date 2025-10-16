// lib/screens/home_page.dart
//
// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║ PICK ME — LIVE NAV (Follow/Overview, Ultra-Low-Latency Heading)          ║
// ║ • Realtime follow: socket-smooth (compass + GPS heading fusion)           ║
// ║ • Auto overview: fits pickup+destination w/ smart padding                 ║
// ║ • Route snapping + re-route                                               ║
// ║ • Traffic-colored polyline + ETA/min bubbles                              ║
// ║ • Offline-tolerant cache, request retry, full resource hygiene            ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

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

import '../api/api_client.dart';
import '../api/url.dart';
import '../routes/routes.dart';
import '../themes/app_theme.dart';
import '../utility/notification.dart';

import '../widgets/app_menu_drawer.dart';
import '../widgets/bottom_navigation_bar.dart';
import '../widgets/fund_account_sheet.dart';

import 'state/home_models.dart';

import '../services/autocomplete_service.dart';
import '../widgets/auto_overlay.dart';
import '../widgets/header_bar.dart';
import '../widgets/locate_fab.dart';
import '../widgets/route_sheet.dart';

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
  _NetworkRequest(this.id, this.executor) : completer = Completer<http.Response>(), retries = 0;
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
  static const Duration kGpsUpdateInterval = Duration(milliseconds: 200); // fast (≈5 Hz)
  static const Duration kHeadingTickMin = Duration(milliseconds: 33);     // ~30 FPS
  static const double kVehicleSpeedThreshold = 1.5; // m/s
  static const double kPedestrianSpeedThreshold = 0.5; // m/s
  static const Duration kStationaryTimeout = Duration(minutes: 2);

  // Follow tuning
  static const double kCenterSnapMeters = 6; // recentre only if movement > 6m
  static const Duration kCamMoveMin = Duration(milliseconds: 60);

  // Bearing smoothing (very snappy)
  static const double kBearingDeadbandDeg = 0.5;
  static const double kMaxBearingVel = 320.0;   // deg/s
  static const double kMaxBearingAccel = 1200.0; // deg/s^2

  // Route logic
  static const double kRouteDeviationThreshold = 50.0; // meters
  static const double kTurnAngleThreshold = 35.0; // deg
  static const double kTurnPrepMeters = 120.0;

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

  // Icons
  BitmapDescriptor? _userPinIcon, _pickupIcon, _dropIcon, _etaBubbleIcon, _minsBubbleIcon;
  bool _iconsPreloaded = false;

  final Set<Marker> _markers = {};
  final Set<Polyline> _lines = {};
  final Set<Circle> _circles = {};

  static const MarkerId _userMarkerId = MarkerId('user_location');
  static const MarkerId _etaMarkerId = MarkerId('eta_label');
  static const MarkerId _minsMarkerId = MarkerId('mins_label');

  // Camera + heading
  _CamMode _camMode = _CamMode.follow;
  bool _rotateWithHeading = true; // map rotates with heading in follow mode
  bool _useForwardAnchor = true;  // forward-biased target when moving

  bool _isAnimatingCamera = false;
  LatLng? _lastCamTarget;
  DateTime _lastCamMove = DateTime.fromMillisecondsSinceEpoch(0);

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

  // ===== Utils & logging =====
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

  void _log(String msg, [Object? data]) {
    final d = data == null ? '' : ' → $data';
    debugPrint('[Home] $msg$d');
  }

  void _apiLog({required String tag, required Uri url, Map<String, String>? headers, Object? body, http.Response? res}) {
    final h = Map.of(headers ?? {});
    if (h.containsKey('X-Goog-Api-Key')) h['X-Goog-Api-Key'] = '***';
    _log('$tag URL', url.toString());
    if (body != null) _log('$tag Body', body);
    if (res != null) _log('$tag HTTP ${res.statusCode}');
  }

  // ===== Lifecycle =====
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _api = ApiClient(http.Client(), context);
    _auto = AutocompleteService(logger: _log);

    _overlayAnimController = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
    _overlayFadeAnim = CurvedAnimation(parent: _overlayAnimController, curve: Curves.easeOutCubic);

    _initPoints();
    _bootstrap();
    _startCompass();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _gpsSub?.cancel();
    _gpsThrottleTimer?.cancel();
    _routeRefreshTimer?.cancel();
    _compassSub?.cancel();
    _stationaryTimer?.cancel();
    _overlayAnimController.dispose();
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
      _log('App paused - GPS paused');
    } else if (state == AppLifecycleState.resumed) {
      _gpsSub?.resume();
      _refreshUserPosition();
      _log('App resumed - GPS resumed');
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
            () => _api.request(ApiConstants.userInfoEndpoint, method: 'POST', data: {'user': uid}).timeout(kApiTimeout),
      );

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body['error'] == false) {
          setState(() => _user = body['user']);
          await _createUserPinIcon();
        }
      }
      setState(() => _isConnected = true);
    } catch (e) {
      _log('User fetch error', e);
      setState(() => _isConnected = false);
    } finally {
      if (mounted) setState(() => _busyProfile = false);
    }
  }

  // ===== Network retry =====
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
          final delayMs = 400 * math.pow(2, request.retries - 1);
          _log('Retry $id (${request.retries}/$kMaxRetries) after ${delayMs}ms');
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
      await Future.wait([_ensurePointIcons(), _createUserPinIcon()]);
      _iconsPreloaded = true;
    } catch (e) {
      _log('Icon preload error', e);
    }
  }

  Future<void> _createUserPinIcon() async {
    try {
      final avatarUrl = _safeAvatarUrl(_user?['user_logo'] as String?);
      _userPinIcon = await _buildAvatarPinIcon(avatarUrl);
      if (!mounted) return;
      setState(() {});
      if (_curPos != null) {
        _updateUserMarker(LatLng(_curPos!.latitude, _curPos!.longitude), rotation: _userMarkerRotation);
      }
    } catch (e) {
      _log('User pin build error', e);
    }
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
      ..quadraticBezierTo(center.dx + (avatarRadius + 18), center.dy - 8, center.dx, center.dy + (avatarRadius + 18))
      ..quadraticBezierTo(center.dx - (avatarRadius + 18), center.dy - 8, center.dx, center.dy - (avatarRadius + 10))
      ..close();
    canvas.drawPath(pinPath, Paint()..color = Colors.white.withOpacity(0.98));

    canvas.drawCircle(center, avatarRadius + 4, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..color = Colors.white);

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
    final grad = ui.Gradient.linear(c - Offset(r, r), c + Offset(r, r), [AppColors.primary, AppColors.accentColor]);
    canvas.drawCircle(c, r, Paint()..shader = grad);
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.person.codePoint),
        style: TextStyle(fontSize: r * 1.6, fontFamily: Icons.person.fontFamily, color: Colors.white),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  Future<void> _ensurePointIcons() async {
    if (_pickupIcon != null && _dropIcon != null) return;
    final results = await Future.wait([
      _buildPointIcon(label: 'Pickup', color: const Color(0xFF1A73E8)),
      _buildPointIcon(label: 'Drop', color: const Color(0xFFE53935)),
    ]);
    _pickupIcon = results[0];
    _dropIcon = results[1];
  }

  Future<BitmapDescriptor> _buildPointIcon({required String label, required Color color}) async {
    const w = 150.0, h = 72.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);

    final r = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h - 10), const Radius.circular(18));
    c.drawRRect(r, Paint()..color = Colors.white);
    c.drawRRect(r, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5..color = color.withOpacity(.4));

    final p = Path()
      ..moveTo(w / 2 - 9, h - 10)
      ..lineTo(w / 2, h)
      ..lineTo(w / 2 + 9, h - 10)
      ..close();
    c.drawPath(p, Paint()..color = Colors.white);
    c.drawPath(p, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5..color = color.withOpacity(.4));

    c.drawCircle(const Offset(18, (h - 10) / 2), 7, Paint()..color = color);

    final tp = TextPainter(
      text: TextSpan(text: label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.black)),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: w - 40);
    tp.paint(c, Offset(34, ((h - 10) - tp.height) / 2));

    final picture = rec.endRecording();
    final img = await picture.toImage(w.toInt(), h.toInt());
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  // ===== Markers =====
  void _updateUserMarker(LatLng pos, {double? rotation}) {
    if (_userPinIcon == null) return;
    if (rotation != null) _userMarkerRotation = rotation;
    setState(() {
      _markers.removeWhere((m) => m.markerId == _userMarkerId);
      _markers.add(Marker(
        markerId: _userMarkerId,
        position: pos,
        icon: _userPinIcon!,
        anchor: const Offset(0.5, 1.0),
        flat: true,
        rotation: _userMarkerRotation,
        zIndex: 999,
      ));
    });
  }

  // ===== Compass & heading =====
  void _startCompass() {
    _compassSub?.cancel();
    _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
      final h = event.heading;
      if (h == null) return;

      // normalize
      _compassDeg = _normalizeDeg(h);

      // super-fast tick: limit to ~30fps to avoid jank
      final now = DateTime.now();
      if (now.difference(_lastHeadingTick) < kHeadingTickMin) return;
      _lastHeadingTick = now;

      // Apply heading live:
      _applyHeadingTick();
    });
  }

  void _applyHeadingTick() {
    // If GPS heading valid while moving, prefer it. Else use compass.
    double? heading;
    final sp = _curPos?.speed ?? 0.0;
    if (sp >= kPedestrianSpeedThreshold && _curPos != null && _curPos!.heading.isFinite && _curPos!.heading >= 0) {
      heading = _curPos!.heading;
      _lastBearingSource = BearingSource.gps;
    } else if (_compassDeg != null) {
      heading = _compassDeg;
      _lastBearingSource = BearingSource.compass;
    }
    if (heading == null) return;

    final smooth = _smoothBearingWithJerkLimit(heading);
    final pos = _curPos != null ? LatLng(_curPos!.latitude, _curPos!.longitude) : null;

    // Always rotate the marker instantly
    if (pos != null) _updateUserMarker(pos, rotation: smooth);

    // In follow mode, also rotate the map & keep it live
    if (_camMode == _CamMode.follow && _rotateWithHeading && _map != null && pos != null) {
      _moveCameraRealtime(
        target: _forwardBiasTarget(user: pos, bearingDeg: smooth),
        bearing: smooth,
        // dynamic zoom/tilt by mode
        zoom: (sp >= kVehicleSpeedThreshold) ? 17.5 : (sp >= kPedestrianSpeedThreshold ? 17.0 : 16.5),
        tilt: (sp >= kVehicleSpeedThreshold) ? 55.0 : 45.0,
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

    final desiredVel = (err * 3.0).clamp(-kMaxBearingVel, kMaxBearingVel); // snappier
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
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) + math.cos(la1) * math.cos(la2) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * _earth * math.asin(math.min(1, math.sqrt(h)));
  }

  LatLng _offsetLatLng(LatLng origin, double meters, double bearingDeg) {
    final br = _deg2rad(bearingDeg);
    final lat1 = _deg2rad(origin.latitude);
    final lon1 = _deg2rad(origin.longitude);
    final d = meters / _earth;

    final lat2 = math.asin(math.sin(lat1) * math.cos(d) + math.cos(lat1) * math.sin(d) * math.cos(br));
    final lon2 = lon1 + math.atan2(math.sin(br) * math.sin(d) * math.cos(lat1), math.cos(d) - math.sin(lat1) * math.sin(lat2));

    return LatLng(_rad2deg(lat2), _rad2deg(lon2));
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
    // meters ahead based on speed
    final sp = _curPos?.speed ?? 0.0;
    final metersAhead = (_camMode == _CamMode.follow && sp > 0)
        ? (sp * 3.5).clamp(30.0, 180.0)
        : 0.0;
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
    if (now.difference(_lastCamMove) < kCamMoveMin) return;
    _lastCamMove = now;

    _isAnimatingCamera = true;
    try {
      await _map!.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: target, zoom: zoom, tilt: tilt, bearing: bearing),
        ),
      );
      _lastCamTarget = target;
    } finally {
      _isAnimatingCamera = false;
    }
  }

  Future<void> _enterOverview({bool fitWholeRoute = false}) async {
    if (_map == null) return;
    // If we have a computed route and want whole route, use all points; otherwise fit pickup+destination.
    List<LatLng> pts;
    if (fitWholeRoute && _routePts.isNotEmpty) {
      pts = _routePts;
    } else {
      if (!(_pts.length >= 2 && _pts.first.latLng != null && _pts.last.latLng != null)) return;
      pts = [_pts.first.latLng!, _pts.last.latLng!];
    }
    // Compute bounds
    double minLat = pts.first.latitude, maxLat = pts.first.latitude, minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final p in pts) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    // Smart padding: top header + bottom sheet + a bit of air
    final double pad = math.max(_mapPadding.top + _mapPadding.bottom + 40.0, 120.0);

    _camMode = _CamMode.overview;
    _rotateWithHeading = false; // keep map stable in overview

    try {
      // small delay helps right after map creation on iOS
      await Future.delayed(const Duration(milliseconds: 16));
      await _map!.animateCamera(CameraUpdate.newLatLngBounds(bounds, pad));
    } catch (e) {
      // Fallback: center midpoint if bounds throws
      final mid = LatLng((minLat + maxLat) / 2.0, (minLng + maxLng) / 2.0);
      await _map!.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: mid, zoom: 13.5, tilt: 0, bearing: 0)));
    }
  }

  void _enterFollowMode() {
    _camMode = _CamMode.follow;
    _rotateWithHeading = true;
    _useForwardAnchor = true;
  }

  // ===== Location =====
  LocationSettings _platformLocationSettings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: kGpsUpdateInterval,
        forceLocationManager: false,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Pick Me',
          notificationText: 'Tracking location…',
          enableWakeLock: false,
        ),
      );
    } else if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: false,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0);
  }

  Future<void> _initLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        _toast('Location Required', 'Please enable location services');
        return;
      }

      _curPos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 10),
      );

      if (_curPos != null) {
        final ll = LatLng(_curPos!.latitude, _curPos!.longitude);
        await _map?.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: ll, zoom: 16, tilt: 45, bearing: 0)));
        await _useCurrentAsPickup();
        _updateUserMarker(ll, rotation: 0);
        _lastCamTarget = ll;
      }

      _gpsSub?.cancel();
      _gpsSub = Geolocator.getPositionStream(locationSettings: _platformLocationSettings()).listen(
        _onGpsUpdate,
        onError: (e) => _log('GPS stream error', e),
        cancelOnError: false,
      );
    } catch (e) {
      _log('Location init error', e);
      _toast('Location Error', 'Failed to initialize GPS');
    }
  }

  void _onGpsUpdate(Position pos) {
    if (_gpsThrottleTimer?.isActive ?? false) return;

    _gpsThrottleTimer = Timer(kGpsUpdateInterval, () {
      if (!mounted) return;

      _prevPos = _curPos;
      _curPos = pos;
      final ll = LatLng(pos.latitude, pos.longitude);

      // activity
      if (pos.speed >= kPedestrianSpeedThreshold) {
        if (!_gpsActive) {
          _gpsActive = true;
          _stationaryTimer?.cancel();
        }
      } else {
        _checkStationaryTimeout();
      }

      // rotate marker immediately (gps heading if valid)
      final rot = (pos.heading.isFinite && pos.heading >= 0) ? pos.heading : _userMarkerRotation;
      _updateUserMarker(ll, rotation: rot);

      // Follow camera stays live & low-latency
      if (_camMode == _CamMode.follow) {
        // bearing priority: route > gps > compass
        double? bearing = _routeAwareBearing(ll);
        if (bearing == null && pos.heading.isFinite && pos.heading >= 0 && pos.speed >= kPedestrianSpeedThreshold) {
          bearing = pos.heading;
        }
        bearing ??= _compassDeg;

        if (bearing != null) {
          final smoothed = _smoothBearingWithJerkLimit(bearing);
          _moveCameraRealtime(
            target: _forwardBiasTarget(user: ll, bearingDeg: smoothed),
            bearing: _rotateWithHeading ? smoothed : 0,
            zoom: (pos.speed >= kVehicleSpeedThreshold) ? 17.5 : (pos.speed >= kPedestrianSpeedThreshold ? 17.0 : 16.5),
            tilt: (pos.speed >= kVehicleSpeedThreshold) ? 55.0 : 45.0,
          );
        } else {
          // no bearing → just keep user centered gently
          final now = DateTime.now();
          if (now.difference(_lastCamMove) > kCamMoveMin) {
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
    } catch (e) {
      _log('Position refresh error', e);
    }
  }

  // ===== Circles =====
  void _putLocationCircle(LatLng c, {double accuracy = 50}) {
    setState(() {
      _circles
        ..clear()
        ..add(Circle(
          circleId: const CircleId('accuracy'),
          center: c,
          radius: accuracy.clamp(8, 100),
          fillColor: AppColors.primary.withOpacity(0.10),
          strokeColor: AppColors.primary.withOpacity(0.32),
          strokeWidth: 2,
        ));
    });
  }

  // ===== Routes + cache =====
  bool _hasRoute() => _pts.length >= 2 && _pts.first.latLng != null && _pts.last.latLng != null && _lines.isNotEmpty;

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
      // overview after applying cache too
      await _enterOverview(fitWholeRoute: false); // show both pins at a glance
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
      for (int i = 1; i < _pts.length - 1; i++) if (_pts[i].latLng != null) _pts[i].latLng!,
    ];

    try {
      final v2 = await _computeRoutesV2(origin, destination, stops);
      if (v2 != null) {
        _lastRouteHash = routeHash;
        _cachedRoute = _RouteCache(v2, DateTime.now());
        _applyRouteFromCache(v2);

        // immediately show both pickup + destination
        await _enterOverview(fitWholeRoute: false);

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
      // overview even on legacy
      await _enterOverview(fitWholeRoute: false);
    } catch (e) {
      _routeUiError = 'Route calculation failed';
      _toast('Route Error', 'Unable to calculate route');
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
    _updateRouteBubbles(origin: _pts.first.latLng!, destination: _pts.last.latLng!, secs: durationSeconds);
  }

  Future<_V2Route?> _computeRoutesV2(LatLng origin, LatLng destination, List<LatLng> stops) async {
    final url = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');

    final body = <String, dynamic>{
      'origin': {'location': {'latLng': {'latitude': origin.latitude, 'longitude': origin.longitude}}},
      'destination': {'location': {'latLng': {'latitude': destination.latitude, 'longitude': destination.longitude}}},
      if (stops.isNotEmpty)
        'intermediates': [
          for (final s in stops) {'location': {'latLng': {'latitude': s.latitude, 'longitude': s.longitude}}}
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
      'X-Goog-FieldMask': 'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline,routes.travelAdvisory.speedReadingIntervals',
    };

    http.Response res;
    try {
      res = await _executeWithRetry('routes_v2', () => http.post(url, headers: headers, body: jsonEncode(body)).timeout(kApiTimeout));
    } catch (e) {
      _log('v2 computeRoutes error', e);
      return null;
    }

    _apiLog(tag: 'v2 computeRoutes', url: url, headers: headers, body: body, res: res);

    if (res.statusCode != 200) {
      _routeUiError = 'Routes v2 HTTP ${res.statusCode}';
      return null;
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final routes = (json['routes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (routes.isEmpty) return null;

    final route = routes.first;
    final encoded = (route['polyline']?['encodedPolyline'] ?? '') as String;
    if (encoded.isEmpty) return null;

    final pts = _decodePolyline(encoded);
    final dist = (route['distanceMeters'] ?? 0) as int;
    final durS = _parseDurationSeconds(route['duration']?.toString() ?? '0s');

    final siRaw = (route['travelAdvisory']?['speedReadingIntervals'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
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
    _lines.add(Polyline(
      polylineId: const PolylineId('route_halo'),
      points: decPts,
      color: Colors.white.withOpacity(0.92),
      width: 11,
      startCap: Cap.roundCap,
      endCap: Cap.roundCap,
      jointType: JointType.round,
      geodesic: true,
    ));

    if (intervals.isEmpty) {
      _lines.add(Polyline(
        polylineId: const PolylineId('route_main'),
        points: decPts,
        color: AppColors.primary,
        width: 7,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        geodesic: true,
      ));
      setState(() {});
      return;
    }

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

    for (var i = 0; i < intervals.length; i++) {
      final it = intervals[i];
      final start = it.start.clamp(0, decPts.length - 1);
      final end = it.end.clamp(start + 1, decPts.length);
      final seg = decPts.sublist(start, end);
      _lines.add(Polyline(
        polylineId: PolylineId('route_seg_$i'),
        points: seg,
        color: colorFor(it.speed),
        width: 7,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        geodesic: true,
      ));
    }
    setState(() {});
  }

  Future<void> _buildRouteLegacy(LatLng o, LatLng d, List<LatLng> stops) async {
    final wp = stops.isNotEmpty ? '&waypoints=optimize:true|${stops.map((w) => '${w.latitude},${w.longitude}').join('|')}' : '';
    final url = Uri.parse('https://maps.googleapis.com/maps/api/directions/json?origin=${o.latitude},${o.longitude}&destination=${d.latitude},${d.longitude}$wp&key=${ApiConstants.kGoogleApiKey}');

    http.Response r;
    try {
      r = await _executeWithRetry('directions_v1', () => http.get(url).timeout(kApiTimeout));
    } catch (e) {
      _routeUiError = 'Directions v1 error';
      setState(() {});
      return;
    }

    _apiLog(tag: 'Directions v1', url: url, res: r);

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
  }

  Future<void> _updateRouteBubbles({required LatLng origin, required LatLng destination, required int secs}) async {
    final minsText = '${(secs / 60).round()} min';
    final etaText = 'Arrive by ${DateFormat('h:mm a').format(DateTime.now().add(Duration(seconds: secs)))}';

    _minsBubbleIcon = await _buildMinutesBubble(minsText);
    _etaBubbleIcon = await _buildEtaBubble(etaText);

    if (!mounted) return;
    setState(() {
      _markers.removeWhere((m) => m.markerId == _etaMarkerId || m.markerId == _minsMarkerId);
      _markers.add(Marker(markerId: _etaMarkerId, position: origin, icon: _etaBubbleIcon!, anchor: const Offset(0.5, 1.0), consumeTapEvents: false, zIndex: 998));
      _markers.add(Marker(markerId: _minsMarkerId, position: destination, icon: _minsBubbleIcon!, anchor: const Offset(0.5, 1.0), consumeTapEvents: false, zIndex: 998));
    });
  }

  Future<BitmapDescriptor> _buildMinutesBubble(String text) async {
    const w = 140.0, h = 64.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h - 10), const Radius.circular(24));
    c.drawRRect(r, Paint()..color = const Color(0xFF00A651));
    final p = Path()
      ..moveTo(w / 2 - 10, h - 10)
      ..lineTo(w / 2, h)
      ..lineTo(w / 2 + 10, h - 10)
      ..close();
    c.drawPath(p, Paint()..color = const Color(0xFF00A651));
    final tp = TextPainter(
      text: TextSpan(text: text, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset((w - tp.width) / 2, (h - 10 - tp.height) / 2));
    final picture = rec.endRecording();
    final img = await picture.toImage(w.toInt(), h.toInt());
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  Future<BitmapDescriptor> _buildEtaBubble(String text) async {
    const w = 236.0, h = 64.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h - 10), const Radius.circular(24));
    c.drawRRect(r, Paint()..color = const Color(0xFF1A73E8));
    final p = Path()
      ..moveTo(w / 2 - 10, h - 10)
      ..lineTo(w / 2, h)
      ..lineTo(w / 2 + 10, h - 10)
      ..close();
    c.drawPath(p, Paint()..color = const Color(0xFF1A73E8));
    final tp = TextPainter(
      text: TextSpan(text: text, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: w - 24);
    tp.paint(c, Offset((w - tp.width) / 2, (h - 10 - tp.height) / 2));
    final picture = rec.endRecording();
    final img = await picture.toImage(w.toInt(), h.toInt());
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
    } catch (e) {
      _log('Load recents error', e);
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
      RoutePoint(type: PointType.pickup, controller: pickupCtl, focus: pickupFocus, hint: 'Pickup location'),
      RoutePoint(type: PointType.destination, controller: destCtl, focus: destFocus, hint: 'Where to?'),
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
      _toast('Limit Reached', 'Maximum 4 stops allowed');
      return;
    }
    final idx = _pts.length - 1;
    final stopFocus = FocusNode();
    final stopCtl = TextEditingController();
    stopFocus.addListener(() {
      if (stopFocus.hasFocus) _onFocused(idx);
    });
    final s = RoutePoint(type: PointType.stop, controller: stopCtl, focus: stopFocus, hint: 'Add stop ${_pts.length - 1}');
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
    _debounce = Timer(const Duration(milliseconds: 220), () => _fetchSugs(q.trim()));
  }

  void _ensureSession() {
    if (_placesSession.isEmpty) {
      _placesSession = _uuid.v4();
      _log('New Places session', _placesSession);
    }
    ;
  }

  Future<void> _fetchSugs(String input) async {
    if (_activeRequests >= kMaxConcurrentRequests) {
      _log('Autocomplete throttled', _activeRequests);
      return;
    }
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
          sugs = await _auto.findPlaceText(input: input, apiKey: ApiConstants.kGoogleApiKey, origin: origin).timeout(kApiTimeout);
          _autoStatus = _autoStatus ?? 'FALLBACK_FIND_PLACE';
        }
      }

      setState(() {
        _sugs = sugs;
        _isTyping = false;
        _isConnected = true;
      });
    } catch (e) {
      if (!mounted || myQueryId != _lastQueryId) return;
      _log('Autocomplete exception', e);
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
      final det = await _auto.placeDetails(placeId: s.placeId, sessionToken: _placesSession, apiKey: ApiConstants.kGoogleApiKey).timeout(kApiTimeout);
      if (det.latLng == null) {
        _log('Details latLng null', s.placeId);
        return;
      }
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
      await _map?.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: det.latLng!, zoom: 16, tilt: 45)));
      _focusNextUnfilled();
      if (_pts.first.latLng != null && _pts.last.latLng != null) {
        _cachedRoute = null;
        await _buildRoute(); // _enterOverview() runs inside
      } else if (_pts.first.latLng != null) {
        // if just pickup is set, go follow
        _enterFollowMode();
      }
    } catch (e) {
      _log('Place details error', e);
      _toast('Error', 'Failed to load place details');
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
        ? (_dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed))
        : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);

    setState(() {
      _markers.removeWhere((m) => m.markerId == id);
      _markers.add(Marker(
        markerId: id,
        position: pos,
        icon: icon,
        anchor: const Offset(0.5, 1.0),
        infoWindow: InfoWindow(title: p.type.label, snippet: title),
        consumeTapEvents: false,
      ));
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => FundAccountSheet(account: _user, balance: balance, currency: currency),
    );
  }

  void _goRideOptions() {
    HapticFeedback.mediumImpact();
    if (!(_pts.length >= 2 && _pts.first.latLng != null && _pts.last.latLng != null)) {
      _toast('Missing Information', 'Please select pickup and destination');
      return;
    }
    Navigator.pushNamed(context, AppRoutes.rideOptions, arguments: {
      'pickup': _pts.first.latLng,
      'destination': _pts.last.latLng,
      'stops': _pts.sublist(1, _pts.length - 1).where((p) => p.latLng != null).map((p) => p.latLng).toList(),
      'pickupText': _pts.first.controller.text,
      'destinationText': _pts.last.controller.text,
      'distance': _distanceText,
      'duration': _durationText,
      'fare': _fare,
    });
  }

  void _toast(String title, String msg) {
    if (!mounted) return;
    showToastNotification(context: context, title: title, message: msg, isSuccess: false);
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
              rotateGesturesEnabled: false, // keep programmatic rotation only
              tiltGesturesEnabled: false,

              markers: _markers,
              polylines: _lines,
              circles: _circles,
              onMapCreated: (c) {
                _map = c;
                _scheduleMapPaddingUpdate();
                _lastCamTarget = _initialCam.target;
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
                      Text('Connection issue. Retrying...', style: TextStyle(color: Colors.white, fontSize: (12 * s).clamp(11.0, 14.0), fontWeight: FontWeight.w700)),
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
                    colors: [Colors.black.withOpacity(.60), Colors.black.withOpacity(.25), Colors.transparent],
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
                    border: Border.all(color: AppColors.mintBgLight.withOpacity(.38), width: 1.2),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(.15), blurRadius: 12, offset: const Offset(0, 6))],
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.schedule_rounded, size: 17), const SizedBox(width: 6), Text(_durationText!, style: const TextStyle(fontWeight: FontWeight.w800))]),
                      Container(height: 16, width: 1, color: AppColors.mintBgLight.withOpacity(.5)),
                      Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.straighten_rounded, size: 17), const SizedBox(width: 6), Text(_distanceText!, style: const TextStyle(fontWeight: FontWeight.w800))]),
                      if (_arrivalTime != null) ...[
                        Container(height: 16, width: 1, color: AppColors.mintBgLight.withOpacity(.5)),
                        Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.flag_rounded, size: 17), const SizedBox(width: 6), Text('Arrive ${DateFormat('h:mm a').format(_arrivalTime!)}', style: const TextStyle(fontWeight: FontWeight.w800))]),
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
                  // Trigger instant tick so camera jumps back to follow immediately
                  _applyHeadingTick();
                  await _map?.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: ll, zoom: 17, tilt: 45)));
                } else {
                  await _initLocation();
                }
              },
            ),
          ),

          // Bottom sheet (search & recents)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: KeyedSubtree(
              key: _sheetKey,
              child: RouteSheet(
                key: ValueKey('route_sheet_$_expanded'),
                bottomNavHeight: kBottomNavH,
                recentDestinations: _recents,
                onSearchTap: () {
                  setState(() {
                    _activeIdx = _pts.length - 1;
                    _expanded = true;
                    _pts.last.focus.requestFocus();
                  });
                  _scheduleMapPaddingUpdate();
                },
                onRecentTap: (sug) async => _selectSug(sug),
              ),
            ),
          ),

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
                onSearchRides: _goRideOptions,
                fmtDistance: _fmtDistance,
                onAddStop: _addStop,
                onRemoveStop: _removeStop,
                onSwap: _swap,
                onClose: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  _collapse();
                  Future.delayed(const Duration(milliseconds: 50), () {
                    if (mounted) setState(() {});
                  });
                },
              ),
            ),
        ],
      ),
      bottomNavigationBar: CustomBottomNavBar(
        currentIndex: _currentIndex,
        onTap: (i) {
          HapticFeedback.selectionClick();
          setState(() => _currentIndex = i);
          if (i == 1) Navigator.pushNamed(context, AppRoutes.rideHistory);
          if (i == 2) Navigator.pushNamed(context, AppRoutes.profile);
        },
      ),
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
