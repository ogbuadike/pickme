// lib/screens/home/home_page.dart
//
// ╔═══════════════════════════════════════════════════════════════════════════╗
/* ║ PICK ME — ULTRA PREMIUM HOME PAGE (v2 Routes, speed-colored polylines)   ║
   ║                                                                           ║
   ║ ✓ Real-time GPS tracking with compact avatar pin (no default blue dot)    ║
   ║ ✓ Best-route drawing via Routes v2 (POST + FieldMask) + v1 fallback       ║
   ║ ✓ Speed heatmap on route (green/orange/red) + white halo for contrast     ║
   ║ ✓ ETA & distance HUD + map bubbles (“Arrive by…”, “NN min”)               ║
   ║ ✓ Custom pickup/drop markers (no default pins)                            ║
   ║ ✓ Massive-scale friendly: debounced autocomplete, throttled GPS, etc.     ║
   ║ ✓ Very loud logs + friendly toasts for every API failure                  ║ */
// ╚═══════════════════════════════════════════════════════════════════════════╝

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../routes/routes.dart';
import '../../themes/app_theme.dart';
import '../../utility/notification.dart';

import '../../widgets/app_menu_drawer.dart';
import '../../widgets/bottom_navigation_bar.dart';
import '../../widgets/fund_account_sheet.dart';

import 'state/home_models.dart';
import '../services/autocomplete_service.dart';
import '../widgets/auto_overlay.dart';
import '../widgets/header_bar.dart';
import '../widgets/locate_fab.dart';
import '../widgets/route_sheet.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// Top-level helper models (must NOT be inside a class)
/// ─────────────────────────────────────────────────────────────────────────

class _SpeedInterval {
  final int start; // polyline point index
  final int end; // exclusive
  final String speed; // "SLOW" | "NORMAL" | "TRAFFIC_JAM"
  const _SpeedInterval(this.start, this.end, this.speed);
}

class _V2Route {
  final List<LatLng> points;
  final int distanceMeters;
  final int durationSeconds;
  final List<_SpeedInterval> speedIntervals;
  const _V2Route(this.points, this.distanceMeters, this.durationSeconds, this.speedIntervals);
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  // ───────────────────────────────── LAYOUT / PERFORMANCE CONSTANTS
  static const double kBottomNavH = 74;
  static const double kHeaderVisualH = 88;

  static const int kMaxConcurrentRequests = 3;
  static const Duration kGpsUpdateInterval = Duration(milliseconds: 600);
  static const Duration kDebounceDelay = Duration(milliseconds: 260);
  static const Duration kApiTimeout = Duration(seconds: 20);

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _sheetKey = GlobalKey();

  double _sheetHeight = 0;
  EdgeInsets _mapPadding = EdgeInsets.zero;

  // ───────────────────────────────── INFRA
  late SharedPreferences _prefs;
  late ApiClient _api;
  Map<String, dynamic>? _user;
  bool _busyProfile = false;
  int _currentIndex = 0;

  // ───────────────────────────────── MAP / GPS
  GoogleMapController? _map;
  final CameraPosition _initialCam = const CameraPosition(
    target: LatLng(6.458985, 7.548266), // Onitsha fallback
    zoom: 15,
  );

  Position? _curPos;
  Position? _prevPos;
  StreamSubscription<Position>? _gpsSub;
  Timer? _gpsThrottleTimer;

  // markers / overlays
  BitmapDescriptor? _userPinIcon; // compact avatar pin (current location)
  BitmapDescriptor? _pickupIcon;  // custom pickup chip
  BitmapDescriptor? _dropIcon;    // custom drop chip

  BitmapDescriptor? _etaBubbleIcon;  // “Arrive by …”
  BitmapDescriptor? _minsBubbleIcon; // “NN min”
  final Set<Marker> _markers = {};
  final Set<Polyline> _lines = {};
  final Set<Circle> _circles = {};

  // ids for programmatic markers
  static const MarkerId _userMarkerId = MarkerId('user_location');
  static const MarkerId _etaMarkerId  = MarkerId('eta_label');
  static const MarkerId _minsMarkerId = MarkerId('mins_label');

  bool _isAnimatingCamera = false;
  bool _userInteractedWithMap = false;
  bool _routeActive = false; // >>> disables auto-follow when true
  Timer? _userInteractionTimer;

  // ───────────────────────────────── ROUTE POINTS / TRIP
  final List<RoutePoint> _pts = [];
  int _activeIdx = 0;

  String? _distanceText;
  String? _durationText;
  double? _fare;
  DateTime? _arrivalTime; // for HUD + bubble
  Timer? _routeRefreshTimer;

  // ───────────────────────────────── AUTOCOMPLETE
  final _uuid = const Uuid();
  String _placesSession = '';
  Timer? _debounce;
  late final AutocompleteService _auto;
  List<Suggestion> _sugs = [];
  List<Suggestion> _recents = [];
  bool _isTyping = false;
  int _lastQueryId = 0;
  int _activeRequests = 0;
  String? _autoStatus;
  String? _autoError;

  // ───────────────────────────────── UI STATE / RESPONSIVE
  bool _expanded = false;
  bool _isConnected = true;
  Orientation? _lastOrientation;

  // ───────────────────────────────── UTIL
  double _s(BuildContext c) {
    final mq = MediaQuery.of(c);
    final size = mq.size;
    final shortest = math.min(size.width, size.height);
    final longest = math.max(size.width, size.height);
    final aspectRatio = longest / shortest;

    double scale = (shortest / 390.0).clamp(0.70, 1.15);
    if (aspectRatio > 2.0) scale *= 0.92; // ultra-wide/foldables
    if (aspectRatio < 1.5) scale *= 1.05; // square-ish tablets
    return scale;
  }

  void _log(String msg, [Object? data]) {
    final d = data == null ? '' : '  -> $data';
    debugPrint('[Home] $msg$d');
  }

  // ───────────────────────────────── LIFECYCLE
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api  = ApiClient(http.Client(), context);
    _auto = AutocompleteService(logger: _log);
    _initPoints();
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _gpsSub?.cancel();
    _gpsThrottleTimer?.cancel();
    _routeRefreshTimer?.cancel();
    _userInteractionTimer?.cancel();
    for (final p in _pts) {
      p.controller.dispose();
      p.focus.dispose();
    }
    _map?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _gpsSub?.pause();
    } else if (state == AppLifecycleState.resumed) {
      _gpsSub?.resume();
      _refreshUserPosition();
    }
  }

  // ───────────────────────────────── BOOTSTRAP
  Future<void> _bootstrap() async {
    _prefs = await SharedPreferences.getInstance();
    await Future.wait([
      _fetchUser(),
      _loadRecents(),
      _createUserPinIcon(), // prebuild avatar pin
      _ensurePointIcons(),  // prebuild pickup/drop chips
    ]);
    await _initLocation();
    _scheduleMapPaddingUpdate();

    // Quick sanity check of key – avoids silent fails.
    if ((ApiConstants.kGoogleApiKey).isEmpty) {
      _toast('API Key Missing', 'Set ApiConstants.kGoogleApiKey');
      _log('CONFIG', 'ApiConstants.kGoogleApiKey is empty');
    }
  }

  Future<void> _fetchUser() async {
    setState(() => _busyProfile = true);
    try {
      final uid = _prefs.getString('user_id') ?? '';
      if (uid.isEmpty) {
        _log('User fetch', 'No user_id in SharedPreferences');
        return;
      }

      final res = await _api
          .request(ApiConstants.userInfoEndpoint, method: 'POST', data: {'user': uid})
          .timeout(kApiTimeout);

      _log('User fetch response code', res.statusCode);
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        _log('User fetch body', body);
        if (body['error'] == false) {
          setState(() => _user = body['user']);
          await _createUserPinIcon(); // refresh pin if avatar changed
        } else {
          _log('User fetch error flag', body);
        }
      } else {
        _log('User fetch HTTP error', res.body);
      }
      setState(() => _isConnected = true);
    } catch (e) {
      _log('User fetch exception', e);
      setState(() => _isConnected = false);
    } finally {
      if (mounted) setState(() => _busyProfile = false);
    }
  }

  // ───────────────────────────────── CUSTOM MARKERS
  Future<void> _createUserPinIcon() async {
    try {
      final avatarUrl = _safeAvatarUrl(_user?['user_logo'] as String?);
      _userPinIcon = await _buildAvatarPinIcon(avatarUrl);
      if (!mounted) return;
      setState(() {});
      if (_curPos != null) {
        _updateUserMarker(LatLng(_curPos!.latitude, _curPos!.longitude));
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

  /// Compact pin with avatar circle (pointer tip sits on location)
  Future<BitmapDescriptor> _buildAvatarPinIcon(String? avatarUrl) async {
    const size = 84.0; // small footprint
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(size / 2, size / 2 - 6);
    final avatarRadius = size * 0.28;

    // drop shadow of the pin base
    final shadow = Paint()
      ..color = Colors.black.withOpacity(0.18)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 6);
    canvas.drawCircle(center + const Offset(0, 12), avatarRadius + 12, shadow);

    // pin body (rounded diamond)
    final pinPath = Path()
      ..moveTo(center.dx, center.dy - (avatarRadius + 10))
      ..quadraticBezierTo(center.dx + (avatarRadius + 18), center.dy - 8,
          center.dx, center.dy + (avatarRadius + 18))
      ..quadraticBezierTo(center.dx - (avatarRadius + 18), center.dy - 8,
          center.dx, center.dy - (avatarRadius + 10))
      ..close();
    canvas.drawPath(pinPath, Paint()..color = Colors.white.withOpacity(0.98));

    // inner circle border
    canvas.drawCircle(
      center,
      avatarRadius + 4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );

    // avatar circle (clipped)
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: avatarRadius)));
    if (avatarUrl != null) {
      try {
        final resp = await http.get(Uri.parse(avatarUrl)).timeout(const Duration(seconds: 6));
        if (resp.statusCode == 200) {
          final codec = await ui.instantiateImageCodec(resp.bodyBytes);
          final frame = await codec.getNextFrame();
          final src = Rect.fromLTWH(
            0, 0, frame.image.width.toDouble(), frame.image.height.toDouble(),
          );
          final dst = Rect.fromCircle(center: center, radius: avatarRadius);
          canvas.drawImageRect(frame.image, src, dst, Paint());
        } else {
          _log('Avatar fetch HTTP', resp.statusCode);
          _drawFallbackAvatar(canvas, center, avatarRadius);
        }
      } catch (e) {
        _log('Avatar fetch exception', e);
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

  Future<void> _ensurePointIcons() async {
    if (_pickupIcon != null && _dropIcon != null) return;
    _pickupIcon = await _buildPointIcon(label: 'Pickup', color: const Color(0xFF1A73E8));
    _dropIcon   = await _buildPointIcon(label: 'Drop',   color: const Color(0xFFE53935));
  }

  Future<BitmapDescriptor> _buildPointIcon({
    required String label,
    required Color color,
  }) async {
    const w = 150.0, h = 72.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);

    final r = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h - 10), const Radius.circular(18));
    c.drawRRect(r, Paint()..color = Colors.white);
    c.drawRRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withOpacity(.35),
    );

    final p = Path()
      ..moveTo(w / 2 - 9, h - 10)
      ..lineTo(w / 2, h)
      ..lineTo(w / 2 + 9, h - 10)
      ..close();
    c.drawPath(p, Paint()..color = Colors.white);
    c.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withOpacity(.35),
    );

    c.drawCircle(const Offset(18, (h - 10) / 2), 7, Paint()..color = color);

    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.black),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: w - 40);
    tp.paint(c, Offset(34, ((h - 10) - tp.height) / 2));

    final picture = rec.endRecording();
    final img = await picture.toImage(w.toInt(), h.toInt());
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  /// Bubble markers
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
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
      ),
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
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: w - 24);
    tp.paint(c, Offset((w - tp.width) / 2, (h - 10 - tp.height) / 2));
    final picture = rec.endRecording();
    final img = await picture.toImage(w.toInt(), h.toInt());
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  void _updateUserMarker(LatLng pos) {
    if (_userPinIcon == null) return;
    setState(() {
      _markers.removeWhere((m) => m.markerId == _userMarkerId);
      _markers.add(Marker(
        markerId: _userMarkerId,
        position: pos,
        icon: _userPinIcon!,
        anchor: const Offset(0.5, 1.0), // pointer tip on location
        flat: false,
        zIndex: 999,
      ));
    });
  }

  // ───────────────────────────────── LOCATION
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
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
  }

  Future<void> _initLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
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
        await _animate(ll, zoom: 16, tilt: 45);
        await _useCurrentAsPickup();
        _updateUserMarker(ll);
      }

      _gpsSub?.cancel();
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: _platformLocationSettings(),
      ).listen(
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

      _updateUserMarker(ll);

      // DO NOT auto-follow if a route is active (so user sees full overview)
      if (!_routeActive && !_userInteractedWithMap && !_isAnimatingCamera) {
        _smoothFollowUser(ll);
      }

      if (_pts.isNotEmpty && _pts.first.isCurrent) {
        _updatePickupFromGps();
      }

      _putLocationCircle(ll, accuracy: pos.accuracy);
    });
  }

  Future<void> _smoothFollowUser(LatLng target) async {
    if (_map == null || _isAnimatingCamera) return;
    _isAnimatingCamera = true;
    try {
      await _map!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: target, zoom: 17, tilt: 45),
        ),
      );
    } finally {
      _isAnimatingCamera = false;
    }
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

  Future<void> _animate(LatLng t, {double zoom = 15, double tilt = 0, double bearing = 0}) async {
    if (_map == null) return;
    _isAnimatingCamera = true;
    try {
      await _map!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: t, zoom: zoom, tilt: tilt, bearing: bearing),
        ),
      );
    } finally {
      _isAnimatingCamera = false;
    }
  }

  void _putLocationCircle(LatLng c, {double accuracy = 50}) {
    setState(() {
      _circles
        ..clear()
        ..add(Circle(
          circleId: const CircleId('accuracy'),
          center: c,
          radius: accuracy.clamp(10, 100),
          fillColor: AppColors.primary.withOpacity(0.12),
          strokeColor: AppColors.primary.withOpacity(0.35),
          strokeWidth: 2,
        ));
    });
  }

  // ───────────────────────────────── ROUTES (v2 + fallback)
  bool _hasRoute() =>
      _pts.length >= 2 && _pts.first.latLng != null && _pts.last.latLng != null;

  Future<void> _buildRoute() async {
    if (!_hasRoute()) return;

    setState(() {
      _routeActive = false;
      _lines.clear();
      _distanceText = null;
      _durationText = null;
      _fare = null;
      _arrivalTime = null;
      _markers.removeWhere((m) => m.markerId == _etaMarkerId || m.markerId == _minsMarkerId);
    });

    final origin      = _pts.first.latLng!;
    final destination = _pts.last.latLng!;
    final stops = <LatLng>[
      for (int i = 1; i < _pts.length - 1; i++)
        if (_pts[i].latLng != null) _pts[i].latLng!,
    ];

    try {
      final v2 = await _computeRoutesV2(origin, destination, stops);
      if (v2 != null) {
        final points = v2.points;
        final distanceMeters = v2.distanceMeters;
        final durationSeconds = v2.durationSeconds;

        _arrivalTime = DateTime.now().add(Duration(seconds: durationSeconds));
        setState(() {
          _distanceText = _fmtDistance(distanceMeters);
          _durationText = _fmtDuration(durationSeconds);
          _fare = _calcFare(distanceMeters);
          _isConnected = true;
        });

        _buildSpeedColoredPolylines(points, v2.speedIntervals);
        await _updateRouteBubbles(origin: origin, destination: destination, secs: durationSeconds);
        _fitBounds(points);
        setState(() => _routeActive = true);

        _routeRefreshTimer?.cancel();
        _routeRefreshTimer = Timer.periodic(const Duration(minutes: 2), (_) {
          if (_hasRoute() && !_expanded) _buildRoute();
        });
        return;
      }

      _log('v2 computeRoutes returned null — falling back to legacy v1');
      await _buildRouteLegacy(origin, destination, stops);
      setState(() => _routeActive = true);
    } catch (e) {
      _log('Directions error (outer)', e);
      _toast('Route Error', 'Failed to calculate route');
      setState(() => _isConnected = false);
    }
  }

  Future<_V2Route?> _computeRoutesV2(
      LatLng origin,
      LatLng destination,
      List<LatLng> stops,
      ) async {
    final url = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');

    final body = <String, dynamic>{
      'origin': {
        'location': {'latLng': {'latitude': origin.latitude, 'longitude': origin.longitude}}
      },
      'destination': {
        'location': {'latLng': {'latitude': destination.latitude, 'longitude': destination.longitude}}
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
      'routes.duration,routes.distanceMeters,'
          'routes.polyline.encodedPolyline,'
          'routes.travelAdvisory.speedReadingIntervals',
    };

    _log('ROUTES v2 request', {'url': url.toString(), 'body': body});
    late http.Response res;
    try {
      res = await http.post(url, headers: headers, body: jsonEncode(body)).timeout(kApiTimeout);
    } catch (e) {
      _log('ROUTES v2 network/timeout', e);
      _toast('Network', 'Routes v2 request failed (timeout/offline)');
      return null;
    }

    _log('ROUTES v2 status', res.statusCode);
    if (res.statusCode != 200) {
      // Very loud diagnostics so we can see errors like API key invalid / billing not enabled / not allowed by restrictions
      _log('ROUTES v2 error body', res.body);
      _toast('Routes v2',
          'HTTP ${res.statusCode}. Ensure Routes API is enabled & billing is ON (see logs).');
      return null;
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final routes = (json['routes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (routes.isEmpty) {
      _log('ROUTES v2', 'No routes returned');
      return null;
    }

    final route = routes.first;
    final encoded = (route['polyline']?['encodedPolyline'] ?? '') as String;
    if (encoded.isEmpty) {
      _log('ROUTES v2', 'encodedPolyline empty');
      return null;
    }

    final pts = _decodePolyline(encoded);
    final dist = (route['distanceMeters'] ?? 0) as int;

    final durRaw = route['duration']?.toString() ?? '0s';
    final durS = _parseDurationSeconds(durRaw);

    final siRaw = (route['travelAdvisory']?['speedReadingIntervals'] as List?)
        ?.cast<Map<String, dynamic>>() ??
        const [];
    final intervals = <_SpeedInterval>[];
    for (final m in siRaw) {
      final s = (m['startPolylinePointIndex'] ?? 0) as int;
      final e = (m['endPolylinePointIndex'] ?? 0) as int;
      final sp = (m['speed'] ?? 'NORMAL') as String;
      intervals.add(_SpeedInterval(s, e, sp));
    }

    _log('ROUTES v2 ok', {
      'points': pts.length,
      'distanceMeters': dist,
      'durationSeconds': durS,
      'intervals': intervals.length,
    });

    return _V2Route(pts, dist, durS, intervals);
  }

  int _parseDurationSeconds(String v) {
    // e.g. "1234s" or "123.4s"
    final s = v.trim().toLowerCase();
    if (!s.endsWith('s')) return 0;
    final n = s.substring(0, s.length - 1);
    return double.tryParse(n)?.round() ?? 0;
  }

  void _buildSpeedColoredPolylines(
      List<LatLng> decPts,
      List<_SpeedInterval> intervals,
      ) {
    // White halo for crisp visibility beneath colored segments
    _lines.add(Polyline(
      polylineId: const PolylineId('route_halo'),
      points: decPts,
      color: Colors.white.withOpacity(0.9),
      width: 10,
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
        width: 6,
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
          return const Color(0xFFE53935); // red
        case 'SLOW':
          return const Color(0xFFFF8F00); // orange
        default:
          return const Color(0xFF2E7D32); // green
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

  Future<void> _buildRouteLegacy(
      LatLng o,
      LatLng d,
      List<LatLng> stops,
      ) async {
    final wp = stops.isNotEmpty
        ? '&waypoints=optimize:true|${stops.map((w) => '${w.latitude},${w.longitude}').join('|')}'
        : '';

    final url =
        'https://maps.googleapis.com/maps/api/directions/json?origin=${o.latitude},${o.longitude}'
        '&destination=${d.latitude},${d.longitude}$wp'
        '&key=${ApiConstants.kGoogleApiKey}';

    _log('LEGACY v1 GET', url);
    late http.Response r;
    try {
      r = await http.get(Uri.parse(url)).timeout(kApiTimeout);
    } catch (e) {
      _log('LEGACY v1 network/timeout', e);
      _toast('Network', 'Directions v1 failed (timeout/offline)');
      return;
    }

    _log('LEGACY v1 status', r.statusCode);
    if (r.statusCode != 200) {
      _log('LEGACY v1 error body', r.body);
      _toast('Directions v1', 'HTTP ${r.statusCode}. Check API enablement & billing.');
      return;
    }

    final j = jsonDecode(r.body);
    final routes = (j['routes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (routes.isEmpty) {
      _log('LEGACY v1', 'No routes found');
      _toast('Directions v1', 'No routes found for this query');
      return;
    }

    final route = routes.first;
    final legs = (route['legs'] as List).cast<Map<String, dynamic>>();

    int dMeters = 0, dSecs = 0;
    for (final l in legs) {
      dMeters += (l['distance']?['value'] ?? 0) as int;
      dSecs += (l['duration']?['value'] ?? 0) as int;
    }

    final poly = (route['overview_polyline']?['points'] ?? '') as String;
    if (poly.isEmpty) {
      _log('LEGACY v1', 'overview_polyline empty');
      _toast('Directions v1', 'Polyline not returned');
      return;
    }

    final pts = _decodePolyline(poly);

    _arrivalTime = DateTime.now().add(Duration(seconds: dSecs));
    setState(() {
      _distanceText = _fmtDistance(dMeters);
      _durationText = _fmtDuration(dSecs);
      _fare = _calcFare(dMeters);
      _isConnected = true;
    });

    _buildSpeedColoredPolylines(pts, const []);
    await _updateRouteBubbles(origin: o, destination: d, secs: dSecs);
    _fitBounds(pts);
  }

  Future<void> _updateRouteBubbles({
    required LatLng origin,
    required LatLng destination,
    required int secs,
  }) async {
    final minsText = '${(secs / 60).round()} min';
    final etaText =
        'Arrive by ${DateFormat('h:mm a').format(DateTime.now().add(Duration(seconds: secs)))}';

    _minsBubbleIcon = await _buildMinutesBubble(minsText);
    _etaBubbleIcon  = await _buildEtaBubble(etaText);

    if (!mounted) return;
    setState(() {
      _markers.removeWhere((m) => m.markerId == _etaMarkerId || m.markerId == _minsMarkerId);

      _markers.add(Marker(
        markerId: _etaMarkerId,
        position: origin,
        icon: _etaBubbleIcon!,
        anchor: const Offset(0.5, 1.0),
        consumeTapEvents: false,
        zIndex: 998,
      ));

      _markers.add(Marker(
        markerId: _minsMarkerId,
        position: destination,
        icon: _minsBubbleIcon!,
        anchor: const Offset(0.5, 1.0),
        consumeTapEvents: false,
        zIndex: 998,
      ));
    });
  }

  double _calcFare(int meters) {
    const base = 500.0;
    const perKm = 120.0;
    return base + (meters / 1000.0) * perKm;
  }

  String _fmtDistance(int m) =>
      (m < 1000) ? '$m m' : '${(m / 1000.0).toStringAsFixed(1)} km';

  String _fmtDuration(int s) {
    final mins = (s / 60).round();
    if (mins < 60) return '$mins min';
    final h = mins ~/ 60, mm = mins % 60;
    return '${h}h ${mm}m';
  }

  void _fitBounds(List<LatLng> pts) async {
    if (_map == null || pts.isEmpty) return;
    double minLat = pts.first.latitude,
        maxLat = pts.first.latitude,
        minLng = pts.first.longitude,
        maxLng = pts.first.longitude;
    for (final p in pts) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    final b = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
    _log('Camera fitBounds', b.toString());
    await _map!.animateCamera(CameraUpdate.newLatLngBounds(b, 80));
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

  // ───────────────────────────────── RECENTS
  static const _kRecentsKey = 'recent_places_v4';
  static const int _maxRecents = 24;

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

  // ───────────────────────────────── POINTS
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
      _toast('Limit Reached', 'Maximum 4 stops allowed');
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
    if (_hasRoute()) _buildRoute();
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
    if (_hasRoute()) _buildRoute();
  }

  // ───────────────────────────────── AUTOCOMPLETE
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
    _debounce = Timer(kDebounceDelay, () => _fetchSugs(q.trim()));
  }

  void _ensureSession() {
    if (_placesSession.isEmpty) {
      _placesSession = _uuid.v4();
      _log('New Places session', _placesSession);
    }
  }

  Future<void> _fetchSugs(String input) async {
    if (_activeRequests >= kMaxConcurrentRequests) {
      _log('Places request throttled', _activeRequests);
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

      if ((_autoStatus != null && _autoStatus != 'OK') || sugs.isEmpty) {
        if (_autoError != null && _autoError!.isNotEmpty) {
          _toast('Places API', _autoError!);
        }
        _log('Places status/error', {'status': _autoStatus, 'error': _autoError});
      }
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
      final det = await _auto
          .placeDetails(
        placeId: s.placeId,
        sessionToken: _placesSession,
        apiKey: ApiConstants.kGoogleApiKey,
      )
          .timeout(kApiTimeout);

      if (det.latLng == null) {
        _log('Place details latLng null', s.placeId);
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
      await _animate(det.latLng!, zoom: 16, tilt: 45);
      _focusNextUnfilled();
      if (_hasRoute()) await _buildRoute();
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

  // ───────────────────────────────── MARKERS (pickup/dest/stops)
  void _putMarker(int idx, LatLng pos, String title) async {
    await _ensurePointIcons();
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

  // ───────────────────────────────── SHEET / PADDING
  void _expand() {
    setState(() => _expanded = true);
    _scheduleMapPaddingUpdate();
  }

  void _collapse() {
    FocusScope.of(context).unfocus();
    setState(() => _expanded = false);
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

  // ───────────────────────────────── UI HELPERS
  void _openWallet() {
    final balance =
    _user != null ? double.tryParse(_user!['user_bal']?.toString() ?? '0.0') ?? 0.0 : null;
    final currency = _user?['user_currency']?.toString() ?? 'NGN';

    showModalBottomSheet(
      context: context,
      isScrollControlled: false,
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

  void _goRideOptions() {
    HapticFeedback.mediumImpact();
    if (!_hasRoute()) {
      _toast('Missing Information', 'Please select pickup and destination');
      return;
    }
    Navigator.pushNamed(
      context,
      AppRoutes.rideOptions,
      arguments: {
        'pickup': _pts.first.latLng,
        'destination': _pts.last.latLng,
        'stops': _pts
            .sublist(1, _pts.length - 1)
            .where((p) => p.latLng != null)
            .map((p) => p.latLng)
            .toList(),
        'pickupText': _pts.first.controller.text,
        'destinationText': _pts.last.controller.text,
        'distance': _distanceText,
        'duration': _durationText,
        'fare': _fare,
      },
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

  // ───────────────────────────────── BUILD (RESPONSIVE)
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final s = _s(context);
    final safeTop = mq.padding.top;
    final orientation = mq.orientation;

    if (_lastOrientation != orientation) {
      _lastOrientation = orientation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduleMapPaddingUpdate();
      });
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
          // MAP
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: _initialCam,
              padding: _mapPadding,
              myLocationEnabled: false, // we render our own avatar pin
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
              mapToolbarEnabled: false,
              rotateGesturesEnabled: true,
              tiltGesturesEnabled: true,
              markers: _markers,
              polylines: _lines,
              circles: _circles,
              onMapCreated: (c) {
                _map = c;
                _scheduleMapPaddingUpdate();
              },
              onCameraMove: (_) {
                _userInteractedWithMap = true;
                _userInteractionTimer?.cancel();
                _userInteractionTimer =
                    Timer(const Duration(seconds: 5), () => _userInteractedWithMap = false);
              },
              onTap: (_) => _collapse(),
            ),
          ),

          // Connection banner
          if (!_isConnected)
            Positioned(
              top: safeTop + (kHeaderVisualH * s) + 8,
              left: 12 * s,
              right: 12 * s,
              child: Material(
                color: Colors.orange.shade700,
                borderRadius: BorderRadius.circular(8 * s),
                elevation: 4,
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

          // Gradient under header
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
                      Colors.black.withOpacity(0.55),
                      Colors.black.withOpacity(0.20),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.6, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // HEADER
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

          // ROUTE HUD (ETA + Distance) — sits under header
          if (hasSummary)
            Positioned(
              top: safeTop + (kHeaderVisualH * s) + 6,
              left: 12,
              right: 12,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor.withOpacity(0.96),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.mintBgLight.withOpacity(.35), width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(.12),
                        blurRadius: 10,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    children: [
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.schedule_rounded, size: 16),
                        const SizedBox(width: 6),
                        Text(_durationText!, style: const TextStyle(fontWeight: FontWeight.w800)),
                      ]),
                      Container(height: 14, width: 1, color: AppColors.mintBgLight.withOpacity(.4)),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.straighten_rounded, size: 16),
                        const SizedBox(width: 6),
                        Text(_distanceText!, style: const TextStyle(fontWeight: FontWeight.w800)),
                      ]),
                      if (_arrivalTime != null) ...[
                        Container(height: 14, width: 1, color: AppColors.mintBgLight.withOpacity(.4)),
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.flag_rounded, size: 16),
                          const SizedBox(width: 6),
                          Text('Arrive ${DateFormat('h:mm a').format(_arrivalTime!)}',
                              style: const TextStyle(fontWeight: FontWeight.w800)),
                        ]),
                      ],
                    ],
                  ),
                ),
              ),
            ),

          // Locate FAB
          Positioned(
            right: 14 * s,
            bottom: fabBottom,
            child: LocateFab(
              onTap: () async {
                HapticFeedback.selectionClick();
                // If route is active, do NOT jump to user (keeps overview)
                if (_curPos != null && !_routeActive) {
                  _userInteractedWithMap = false;
                  await _animate(
                    LatLng(_curPos!.latitude, _curPos!.longitude),
                    zoom: 17,
                    tilt: 45,
                  );
                } else if (_curPos == null) {
                  await _initLocation();
                }
              },
            ),
          ),

          // Route Sheet (measured for map padding)
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
                onRecentTap: (sug) async {
                  await _selectSug(sug);
                },
              ),
            ),
          ),

          // Autocomplete overlay
          if (_expanded)
            AutoOverlay(
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

  // ───────────────────────────────── PICKUP HELPERS
  Future<void> _useCurrentAsPickup() async {
    if (_curPos == null || _pts.isEmpty) return;
    try {
      final marks = await geo.placemarkFromCoordinates(
        _curPos!.latitude,
        _curPos!.longitude,
      );
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
    } catch (e) {
      _log('Reverse-geocode error', e);
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


