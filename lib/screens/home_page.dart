// lib/screens/home_page.dart
//
// Home map + routes + marketplace + booking
// ENHANCED VERSION: Responsive layout, smart polyline fitting, orientation handling
//
// Integrated flow in this version:
// 1) RideMarketSheet uses onBook(driver, offer) with edge-to-edge bottom sheet.
// 2) Nearby drivers render from polling and marketplace stream.
// 3) Booking hands off into TripNavigationPage.
// 4) Legacy in-page trip helpers are retained for compatibility/fallback.
// 5) Normal follow/compass camera is paused only when nav mode is active.
// 6) ENHANCED: Smart responsive padding, polyline auto-fit, orientation handling

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
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
import '../widgets/auto_overlay.dart';
import '../widgets/bottom_navigation_bar.dart';
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
import 'state/home_models.dart';
import '../models/geo_point.dart';

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

  const _V2Route(
      this.points,
      this.distanceMeters,
      this.durationSeconds,
      this.speedIntervals,
      );
}

class _RouteCache {
  final _V2Route route;
  final DateTime timestamp;

  const _RouteCache(this.route, this.timestamp);

  bool get isStale =>
      DateTime.now().difference(timestamp) > const Duration(hours: 24);
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
  final double lat;
  final double lng;

  _SpatialNode(this.point, this.index)
      : lat = point.latitude,
        lng = point.longitude;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const double kBottomNavH = 74;
  static const double kHeaderVisualH = 88;

  static const int kMaxConcurrentRequests = 5;
  static const Duration kApiTimeout = Duration(seconds: 15);
  static const int kMaxRetries = 3;

  static const Duration kGpsUpdateInterval = Duration(milliseconds: 200);
  static const Duration kHeadingTickMin = Duration(milliseconds: 33);
  static const double kVehicleSpeedThreshold = 1.5;
  static const double kPedestrianSpeedThreshold = 0.5;
  static const Duration kStationaryTimeout = Duration(minutes: 2);

  static const double kCenterSnapMeters = 6;

  static const double kBearingDeadbandDeg = 0.5;
  static const double kMaxBearingVel = 320.0;
  static const double kMaxBearingAccel = 1200.0;

  static const double kRouteDeviationThreshold = 50.0;

  static const Duration kDriversPollInterval = Duration(seconds: 2);
  static const int kMaxDriverMarkers = 80;

  static const CircleId _accuracyCircleId = CircleId('accuracy');
  static const CircleId _searchCircleId = CircleId('search_radius');
  static const double _searchCircleMinM = 220;
  static const double _searchCircleMaxM = 650;

  static const double _arriveMeters = 35.0;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _sheetKey = GlobalKey();

  double _sheetHeight = 0;
  EdgeInsets _mapPadding = EdgeInsets.zero;

  late SharedPreferences _prefs;
  late ApiClient _api;
  Map<String, dynamic>? _user;
  bool _busyProfile = false;
  int _currentIndex = 0;

  int _indexOfFocus(FocusNode focus) {
    for (int i = 0; i < _pts.length; i++) {
      if (identical(_pts[i].focus, focus)) return i;
    }
    return 0;
  }

  GoogleMapController? _map;
  final CameraPosition _initialCam = const CameraPosition(
    target: LatLng(6.458985, 7.548266),
    zoom: 15,
  );

  Position? _curPos;
  Position? _prevPos;
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
  final Set<Marker> _driverMarkers = <Marker>{};

  final Set<Marker> _markers = <Marker>{};
  final Set<Polyline> _lines = <Polyline>{};
  final Set<Circle> _circles = <Circle>{};

  static const MarkerId _userMarkerId = MarkerId('user_location');
  static const MarkerId _etaMarkerId = MarkerId('eta_label');
  static const MarkerId _minsMarkerId = MarkerId('mins_label');

  static const MarkerId _driverSelectedId = MarkerId('driver_selected');
  final Set<Polyline> _driverLines = <Polyline>{};
  RideOffer? _selectedOffer;

  BookingController? _booking;
  StreamSubscription<dynamic>? _bookingSub;
  String? _lastBookingError;

  _CamMode _camMode = _CamMode.follow;
  bool _rotateWithHeading = true;
  bool _useForwardAnchor = true;

  LatLng? _lastCamTarget;
  DateTime _lastCamMove = DateTime.fromMillisecondsSinceEpoch(0);

  DateTime _lastDriverLegRouteAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastTripLegRouteAt = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _lastDriverLegFrom;
  LatLng? _lastTripLegFrom;

  bool _didFitDriverLeg = false;
  bool _didFitTripLeg = false;

  StreamSubscription<CompassEvent>? _compassSub;
  double? _compassDeg;
  double? _lastBearingDeg;
  double _bearingEma = 0;
  BearingSource _lastBearingSource = BearingSource.compass;
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
  double? _fare;
  DateTime? _arrivalTime;
  Timer? _routeRefreshTimer;
  String? _routeUiError;
  _RouteCache? _cachedRoute;
  String? _lastRouteHash;
  List<LatLng> _routePts = <LatLng>[];
  List<_SpatialNode> _spatialIndex = <_SpatialNode>[];
  int _lastSnapIndex = -1;
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
  final Map<String, _NetworkRequest> _requestQueue =
  <String, _NetworkRequest>{};
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
  final Map<String, DriverCar> _drivers = <String, DriverCar>{};

  Timer? _nearbyDriversTimer;
  bool _nearbyDriversBusy = false;
  String? _nearbyDriversCursor;
  DateTime _lastNearbyTickAt = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, DateTime> _driverLastSeen = <String, DateTime>{};

  Timer? _fitBoundsDebounce;

  TripPhase _tripPhase = TripPhase.browsing;
  bool _navMode = false;
  String? _engagedDriverId;
  LatLng? _engagedDriverLL;
  Timer? _tripTickTimer;

  late final RideMarketService _rideMarketService;

  Future<void> _bookingStartTrip() async {
    final b = _booking;
    if (b == null) {
      _dbg('BOOKING_START_FAIL', 'BookingController is null');
      throw Exception('Booking controller is null.');
    }

    final bool ok = await b.startTrip();
    if (!ok) {
      final String msg = b.lastError?.message ?? 'Failed to start trip.';
      _dbg('BOOKING_START_FAIL', {
        'rideId': b.rideId,
        'riderId': b.riderId,
        'driverId': b.driverId,
        'error': msg,
        'lastError': b.lastError?.toString(),
      });
      throw Exception(msg);
    }

    _dbg('BOOKING_START_OK', {
      'rideId': b.rideId,
      'riderId': b.riderId,
      'driverId': b.driverId,
    });
  }

  Future<void> _bookingCancelTrip() async {
    final b = _booking;
    if (b == null) {
      _dbg('BOOKING_CANCEL_FAIL', 'BookingController is null');
      throw Exception('Booking controller is null.');
    }

    final bool ok = await b.cancelTrip();
    if (!ok) {
      final String msg = b.lastError?.message ?? 'Failed to cancel trip.';
      _dbg('BOOKING_CANCEL_FAIL', {
        'rideId': b.rideId,
        'riderId': b.riderId,
        'driverId': b.driverId,
        'error': msg,
        'lastError': b.lastError?.toString(),
      });
      throw Exception(msg);
    }

    _dbg('BOOKING_CANCEL_OK', {
      'rideId': b.rideId,
      'riderId': b.riderId,
      'driverId': b.driverId,
    });
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
      debugPrint('[Home] $msg$d');
      return true;
    }());
  }

  void _log(String msg, [Object? data]) => _dbg(msg, data);

  void _logLocationDiagnostic(String message) =>
      _dbg('[GPS-DIAGNOSTICS] $message');

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

  double _effectiveBottomNavH() {
    if (_marketOpen) return 0;
    if (_tripPhase != TripPhase.browsing) return 0;
    return kBottomNavH;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _api = ApiClient(http.Client(), context);
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
            _logLocationDiagnostic('Service status: $status');
            if (status == ServiceStatus.enabled) {
              _restartLocationStreamWithBackoff();
            }
          },
          onError: (_) {},
        );
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _stopNearbyDriversPolling();

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
    try {
      _booking?.dispose();
    } catch (_) {}

    _fitBoundsDebounce?.cancel();
    _tripTickTimer?.cancel();

    for (final p in _pts) {
      p.controller.dispose();
      p.focus.dispose();
    }

    try {
      _map?.dispose();
    } catch (_) {}

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
      _stopNearbyDriversPolling();
      _tripTickTimer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _gpsSub?.resume();
      if (_curPos == null) {
        _initLocation();
      } else {
        _refreshUserPosition();
        _startNearbyDriversPolling();
      }

      // Restore camera state after rotation
      if (_lastCamTarget != null && _map != null) {
        Future.delayed(const Duration(milliseconds: 80), () {
          if (_routePts.isNotEmpty && _camMode == _CamMode.overview) {
            _fitCurrentRouteToViewportV2(waitForLayout: false);
          }
        });
      }

      if (_tripPhase == TripPhase.driverToPickup ||
          _tripPhase == TripPhase.waitingPickup) {
        _startDriverToPickupTick();
      } else if (_tripPhase == TripPhase.enRoute) {
        _startTripNavTick();
      }
    }
  }

  Future<void> _primeNearbyDriversAsap() async {
    if (!mounted) return;
    if (_tripPhase != TripPhase.browsing) return;
    if (_marketOpen) return;

    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever ||
          perm == LocationPermission.unableToDetermine) {
        return;
      }

      final svc = await Geolocator.isLocationServiceEnabled();
      if (!svc) return;

      final last = await Geolocator.getLastKnownPosition();
      if (last == null) return;

      _curPos ??= last;
      _nearbyDriversCursor = null;

      _startNearbyDriversPolling(force: true);

      final ll = LatLng(last.latitude, last.longitude);
      _updateUserMarker(
        ll,
        rotation: (last.heading.isFinite && last.heading >= 0) ? last.heading : 0,
      );
    } catch (_) {}
  }

  Future<void> _bootstrap() async {
    _prefs = await SharedPreferences.getInstance();

    await _primeNearbyDriversAsap();

    final locFuture = _initLocation();
    final otherFuture = Future.wait<void>([
      _fetchUser(),
      _loadRecents(),
      _preloadAllIcons(),
    ]);

    await Future.wait<void>([locFuture, otherFuture]);

    _refreshDriverMarkers();
    _scheduleMapPaddingUpdate();
  }

  Future<void> _fetchUser() async {
    if (!mounted) return;
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
          data: <String, String>{'user': uid},
        )
            .timeout(kApiTimeout),
      );

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

  Future<http.Response> _executeWithRetry(
      String id,
      Future<http.Response> Function() executor,
      ) async {
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

  Future<void> _preloadAllIcons() async {
    if (_iconsPreloaded) return;
    try {
      await Future.wait<void>([
        _ensurePointIcons(),
        _createUserPinIcon(),
        _createDriverIcon(),
      ]);
      _iconsPreloaded = true;
      if (mounted) {
        _refreshDriverMarkers();
        setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _createUserPinIcon() async {
    try {
      final avatarUrl = _safeAvatarUrl(_user?['user_logo']?.toString());
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
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: avatarRadius)),
    );

    if (avatarUrl != null) {
      try {
        final resp = await http
            .get(Uri.parse(avatarUrl))
            .timeout(const Duration(seconds: 5));
        if (resp.statusCode == 200) {
          final codec = await ui.instantiateImageCodec(resp.bodyBytes);
          final frame = await codec.getNextFrame();
          final src = Rect.fromLTWH(
            0,
            0,
            frame.image.width.toDouble(),
            frame.image.height.toDouble(),
          );
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
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  void _drawFallbackAvatar(Canvas canvas, Offset c, double r) {
    final grad = ui.Gradient.linear(
      c - Offset(r, r),
      c + Offset(r, r),
      <Color>[AppColors.primary, AppColors.accentColor],
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
    final results = await Future.wait<BitmapDescriptor>([
      _buildRingDotMarker(color: const Color(0xFF1A73E8)),
      _buildRingDotMarker(color: const Color(0xFF00A651)),
    ]);
    _pickupIcon = results[0];
    _dropIcon = results[1];
  }

  Future<BitmapDescriptor> _buildRingDotMarker({required Color color}) async {
    const size = 64.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final center = const Offset(size / 2, size / 2);

    c.drawCircle(
      center + const Offset(0, 2),
      18,
      Paint()
        ..color = Colors.black.withOpacity(0.20)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 6),
    );
    c.drawCircle(center, 18, Paint()..color = Colors.white);
    c.drawCircle(
      center,
      18,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = color,
    );
    c.drawCircle(center, 5.5, Paint()..color = color);

    final img = await rec.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  Future<BitmapDescriptor> _bitmapDescriptorFromAsset(
      String assetPath, {
        int targetWidth = 96,
      }) async {
    final bd = await rootBundle.load(assetPath);
    final bytes = bd.buffer.asUint8List();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
    final frame = await codec.getNextFrame();
    final pngBytes = (await frame.image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    return BitmapDescriptor.fromBytes(pngBytes);
  }

  Future<void> _createDriverIcon() async {
    if (_driverIcon != null) return;
    try {
      _driverIcon = await _bitmapDescriptorFromAsset(
        'assets/images/open_top_view_car.png',
        targetWidth: 96,
      );
      if (mounted) {
        _refreshDriverMarkers();
        setState(() {});
      }
      return;
    } catch (_) {}

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
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    _driverIcon = BitmapDescriptor.fromBytes(bytes);

    if (mounted) {
      _refreshDriverMarkers();
      setState(() {});
    }
  }

  void _updateUserMarker(LatLng pos, {double? rotation}) {
    if (_userPinIcon == null) return;
    if (rotation != null) _userMarkerRotation = rotation;

    final last = _lastUserMarkerLL;
    final rotDiff = (_userMarkerRotation - _lastUserMarkerRot).abs();

    if (last != null) {
      final moved = _haversine(last, pos);
      if (moved < 0.9 && rotDiff < 0.9) return;
    }

    _lastUserMarkerLL = pos;
    _lastUserMarkerRot = _userMarkerRotation;

    if (!mounted) return;
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
    if (_expanded) return;
    if (_navMode) return;

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
    final pos =
    _curPos != null ? LatLng(_curPos!.latitude, _curPos!.longitude) : null;

    if (pos != null) _updateUserMarker(pos, rotation: smooth);

    if (_camMode == _CamMode.follow &&
        _rotateWithHeading &&
        _map != null &&
        pos != null) {
      _moveCameraRealtimeV2(
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
    final dt = (now.difference(_lastBearingTime).inMilliseconds / 1000.0)
        .clamp(1e-3, 1.0);
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
    final accel = ((desiredVel - _lastBearingVel) / dt)
        .clamp(-kMaxBearingAccel, kMaxBearingAccel);
    _lastBearingVel =
        (_lastBearingVel + accel * dt).clamp(-kMaxBearingVel, kMaxBearingVel);

    _bearingEma = _normalizeDeg(_bearingEma + _lastBearingVel * dt);
    return _bearingEma;
  }

  static const double _earth = 6371000.0;

  double _deg2rad(double d) => d * (math.pi / 180.0);

  double _rad2deg(double r) => r * (180.0 / math.pi);

  double _bearingBetween(LatLng a, LatLng b) {
    final lat1 = _deg2rad(a.latitude);
    final lat2 = _deg2rad(b.latitude);
    final dLon = _deg2rad(b.longitude - a.longitude);
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return _normalizeDeg(_rad2deg(math.atan2(y, x)));
  }

  double _haversine(LatLng a, LatLng b) {
    final dLat = _deg2rad(b.latitude - a.latitude);
    final dLon = _deg2rad(b.longitude - a.longitude);
    final la1 = _deg2rad(a.latitude);
    final la2 = _deg2rad(b.latitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(la1) *
            math.cos(la2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return 2 * _earth * math.asin(math.min(1, math.sqrt(h)));
  }

  LatLng _offsetLatLng(LatLng origin, double meters, double bearingDeg) {
    final br = _deg2rad(bearingDeg);
    final lat1 = _deg2rad(origin.latitude);
    final lon1 = _deg2rad(origin.longitude);
    final d = meters / _earth;
    final lat2 = math.asin(
      math.sin(lat1) * math.cos(d) +
          math.cos(lat1) * math.sin(d) * math.cos(br),
    );
    final lon2 = lon1 +
        math.atan2(
          math.sin(br) * math.sin(d) * math.cos(lat1),
          math.cos(d) - math.sin(lat1) * math.sin(lat2),
        );
    return LatLng(_rad2deg(lat2), _rad2deg(lon2));
  }

  // ============================================================================
  // ENHANCED RESPONSIVE LAYOUT METHODS - SECTION 1: Smart Bounds Calculation
  // ============================================================================

  /// Computes smart bounds with intelligent altitude buffer
  LatLngBounds _computeSmartBounds(List<LatLng> points) {
    if (points.isEmpty) return LatLngBounds(
      southwest: const LatLng(0, 0),
      northeast: const LatLng(0, 0),
    );

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final p in points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }

    // Add smart buffer based on span magnitude
    final latSpan = maxLat - minLat;
    final lngSpan = maxLng - minLng;
    final maxSpan = math.max(latSpan, lngSpan);

    // Altitude buffer: prevents over-zoom (10% of span, minimum 0.0018°)
    final altitudeBuffer = math.max(maxSpan * 0.10, 0.0018);

    minLat = math.max(minLat - altitudeBuffer, -90.0);
    maxLat = math.min(maxLat + altitudeBuffer, 90.0);
    minLng = math.max(minLng - altitudeBuffer, -180.0);
    maxLng = math.min(maxLng + altitudeBuffer, 180.0);

    // Ensure minimum dimensions for single-point routes
    if ((maxLat - minLat).abs() < 0.0001) {
      minLat -= 0.0008;
      maxLat += 0.0008;
    }
    if ((maxLng - minLng).abs() < 0.0001) {
      minLng -= 0.0008;
      maxLng += 0.0008;
    }

    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  /// Calculates optimal bounds padding based on screen geometry
  double _computeOptimalBoundsPadding(Size screenSize) {
    final aspect = screenSize.width / screenSize.height;
    final minDim = math.min(screenSize.width, screenSize.height);

    // Ultra-wide (landscape tablet): aggressive padding
    if (aspect > 1.6) {
      return (minDim * 0.18).clamp(60.0, 180.0);
    }

    // Standard landscape
    if (aspect > 1.3) {
      return (minDim * 0.22).clamp(70.0, 200.0);
    }

    // Portrait (standard)
    return (minDim * 0.16).clamp(80.0, 220.0);
  }

  /// Computes optimal zoom level from bounds
  double _computeZoomFromBounds(LatLngBounds bounds) {
    final latSpan = bounds.northeast.latitude - bounds.southwest.latitude;
    final lngSpan = bounds.northeast.longitude - bounds.southwest.longitude;
    final maxSpan = math.max(latSpan, lngSpan);

    if (maxSpan > 0.5) return 12.5;
    if (maxSpan > 0.2) return 13.5;
    if (maxSpan > 0.08) return 14.5;
    if (maxSpan > 0.03) return 15.5;
    if (maxSpan > 0.012) return 16.5;
    return 17.0;
  }

  // ============================================================================
  // ENHANCED RESPONSIVE LAYOUT METHODS - SECTION 2: Responsive Padding
  // ============================================================================

  /// Enhanced map padding calculation with orientation awareness
  void _applyMapPadding() {
    if (!mounted) return;

    final mq = MediaQuery.of(context);
    final size = mq.size;
    final orientation = mq.orientation;
    final safeArea = mq.padding;

    // Compute dynamic safe areas
    final topPad = safeArea.top + (kHeaderVisualH * _s(context));

    // Smart bottom padding based on orientation & sheet height
    final baseBottomPad = _sheetHeight + _effectiveBottomNavH();

    // Landscape: reduce vertical padding, increase horizontal awareness
    final bottomPad = orientation == Orientation.landscape
        ? (baseBottomPad * 0.72).clamp(12.0, 280.0)
        : (baseBottomPad + 12.0).clamp(24.0, 560.0);

    // Responsive horizontal padding (screen-aware)
    final minScreenDim = math.min(size.width, size.height);
    final hPad = minScreenDim < 400 ? 4.0 : (minScreenDim < 600 ? 6.0 : 8.0);

    if (!mounted) return;
    setState(() {
      _mapPadding = EdgeInsets.fromLTRB(
        hPad,
        topPad,
        hPad,
        bottomPad,
      );
    });
  }

  /// Enhanced effective bounds padding with context awareness
  double _effectiveBoundsPaddingV2(double basePad) {
    final mq = MediaQuery.of(context);
    final extraV = math.max(_mapPadding.top, _mapPadding.bottom);
    final extraH = math.max(_mapPadding.left, _mapPadding.right);
    final extra = math.max(extraV, extraH);

    // Add safe margin for UI elements
    final finalPad = (basePad + extra + 16.0).clamp(
      basePad,
      (math.min(mq.size.width, mq.size.height) * 0.35).clamp(basePad, 600.0),
    );

    return finalPad;
  }

  // ============================================================================
  // ENHANCED RESPONSIVE LAYOUT METHODS - SECTION 3: Camera Animation
  // ============================================================================

  /// Robust camera animation with multi-tier retry strategy
  Future<void> _animateBoundsSafeV2(
      LatLngBounds bounds, {
        double basePadding = 70,
      }) async {
    if (_map == null) return;

    _camMode = _CamMode.overview;
    _rotateWithHeading = false;

    final mq = MediaQuery.of(context);
    final pad = _effectiveBoundsPaddingV2(basePadding);

    // Multi-tier retry strategy with exponential backoff
    const maxAttempts = 3;
    const delayMs = [0, 80, 160];
    const cameraTilts = [0.0, 0.0, 30.0];

    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      if (!mounted || _map == null) return;

      try {
        await Future.delayed(Duration(milliseconds: delayMs[attempt]));

        await _map!.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, pad),
        );

        return; // Success
      } catch (_) {
        if (attempt == maxAttempts - 1) {
          // Final fallback: center on bounds with computed zoom
          try {
            final center = LatLng(
              (bounds.northeast.latitude + bounds.southwest.latitude) / 2,
              (bounds.northeast.longitude + bounds.southwest.longitude) / 2,
            );

            await _map!.animateCamera(
              CameraUpdate.newCameraPosition(
                CameraPosition(
                  target: center,
                  zoom: _computeZoomFromBounds(bounds),
                  tilt: cameraTilts[attempt],
                  bearing: 0,
                ),
              ),
            );
          } catch (_) {
            // Silent fail - UI remains functional
          }
          return;
        }
      }
    }
  }

  /// Responsive polyline auto-fit (main entry point)
  Future<void> _fitCurrentRouteToViewportV2({
    bool waitForLayout = true,
  }) async {
    if (!mounted) return;

    final pts = _routePts.isNotEmpty
        ? _routePts
        : <LatLng>[
      if (_pts.isNotEmpty && _pts.first.latLng != null)
        _pts.first.latLng!,
      if (_pts.isNotEmpty && _pts.last.latLng != null)
        _pts.last.latLng!,
    ];

    if (pts.length < 2) return;

    // Optional: wait for layout to stabilize
    if (waitForLayout) {
      _scheduleMapPaddingUpdate();
      await Future.delayed(const Duration(milliseconds: 32));
    }

    final bounds = _computeSmartBounds(pts);
    await _animateBoundsSafeV2(bounds, basePadding: 70);
  }

  /// Landscape-aware camera movement with adaptive timing
  Future<void> _moveCameraRealtimeV2({
    required LatLng target,
    required double bearing,
    required double zoom,
    required double tilt,
  }) async {
    if (_map == null) return;

    final now = DateTime.now();

    // Adaptive timing: slower on landscape (more content visible)
    final mq = MediaQuery.of(context);
    final isLandscape = mq.orientation == Orientation.landscape;
    final minMoveInterval = isLandscape
        ? Duration(milliseconds: (Perf.I.camMoveMin.inMilliseconds * 1.2).toInt())
        : Perf.I.camMoveMin;

    if (now.difference(_lastCamMove) < minMoveInterval) return;
    _lastCamMove = now;

    try {
      await _map!.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: target,
            zoom: zoom,
            tilt: tilt,
            bearing: bearing,
          ),
        ),
      );
      _lastCamTarget = target;
    } catch (_) {
      // Silent fail - preserves current camera state
    }
  }

  // ============================================================================
  // ENHANCED RESPONSIVE LAYOUT METHODS - SECTION 4: Schedule Updates
  // ============================================================================

  /// Enhanced schedule with auto-refit on layout changes
  void _scheduleMapPaddingUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final ctx = _sheetKey.currentContext;
      double newHeight = 0;

      if (ctx != null) {
        final box = ctx.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          newHeight = box.size.height;
        }
      }

      if (_sheetHeight != newHeight) {
        _sheetHeight = newHeight;
        _applyMapPadding();

        // Auto-fit route if visible
        if (_routePts.isNotEmpty && !_expanded && _map != null) {
          _fitBoundsDebounce?.cancel();
          _fitBoundsDebounce = Timer(
            const Duration(milliseconds: 120),
                () {
              if (!mounted) return;
              if (_camMode == _CamMode.overview) {
                _fitCurrentRouteToViewportV2(waitForLayout: false);
              }
            },
          );
        }
      }
    });
  }

  // ============================================================================
  // END ENHANCED RESPONSIVE LAYOUT METHODS
  // ============================================================================

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

    Future<void>.delayed(const Duration(milliseconds: 500), () async {
      if (mounted && _pts.first.latLng != null && _pts.last.latLng != null) {
        await _buildRoute();
      }
      _isRerouting = false;
    });
  }

  LatLng _forwardBiasTarget({
    required LatLng user,
    required double bearingDeg,
  }) {
    if (!_useForwardAnchor) return user;
    final sp = _curPos?.speed ?? 0.0;
    final metersAhead = (_camMode == _CamMode.follow && sp > 0)
        ? (sp * 3.5).clamp(30.0, 180.0)
        : 0.0;
    return _offsetLatLng(user, metersAhead, bearingDeg);
  }

  Future<void> _enterOverview({bool fitWholeRoute = true}) async {
    if (_map == null) return;

    late final List<LatLng> pts;
    if (fitWholeRoute && _routePts.isNotEmpty) {
      pts = _routePts;
    } else {
      if (!(_pts.length >= 2 &&
          _pts.first.latLng != null &&
          _pts.last.latLng != null)) return;
      pts = <LatLng>[_pts.first.latLng!, _pts.last.latLng!];
    }
    if (pts.length < 2) return;

    _scheduleMapPaddingUpdate();
    await Future.delayed(const Duration(milliseconds: 16));
    final bounds = _computeSmartBounds(pts);
    await _animateBoundsSafeV2(bounds, basePadding: 70);
  }

  void _enterFollowMode() {
    _camMode = _CamMode.follow;
    _rotateWithHeading = true;
    _useForwardAnchor = true;
  }

  LocationSettings _platformLocationSettings({required bool moving}) {
    final gp = Perf.I.gpsProfile(moving: moving);
    final accuracy = moving ? gp.accuracy : LocationAccuracy.high;
    final int distanceFilter =
    (moving ? gp.distanceFilterM : math.max(12, gp.distanceFilterM)).toInt();

    if (kIsWeb) {
      return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
    }

    final tp = defaultTargetPlatform;

    if (tp == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        intervalDuration: Duration(milliseconds: gp.intervalMs),
        forceLocationManager: false,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Pick Me',
          notificationText: 'Tracking location…',
          enableWakeLock: false,
        ),
      );
    } else if (tp == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: true,
        showBackgroundLocationIndicator: false,
      );
    }

    return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  }

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
    ).listen(
          (p) {
        if (_isGoodFix(p, maxAccM)) {
          finish(p);
          sub?.cancel();
        }
      },
      onError: (_) {},
    );

    Future<void>.delayed(deadline).then((_) async {
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
      message:
      'To find drivers and show accurate pickups, please turn on your device location.',
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
        'We use your location to match you with nearby drivers and calculate accurate ETAs. Please allow location access in your device settings.',
        isServiceIssue: false,
      );
      _toast('Location Required', 'Please grant location access in Settings.');
    }
    return perm;
  }

  Future<Position?> _acquirePositionRobust() async {
    const maxAcceptableAcc = 200.0;
    const tries = 3;

    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null &&
          last.timestamp != null &&
          DateTime.now().difference(last.timestamp!).inMinutes < 2 &&
          _isGoodFix(last, 400)) {
        _logLocationDiagnostic(
            'Using fresh last-known to seed UI: acc=${last.accuracy}');
        return last;
      }
    } catch (_) {}

    for (var attempt = 1; attempt <= tries; attempt++) {
      try {
        _logLocationDiagnostic(
            'Acquisition attempt $attempt/$tries (bestForNavigation)');
        final p = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.bestForNavigation,
          timeLimit: const Duration(seconds: 10),
        );
        if (_isGoodFix(p, maxAcceptableAcc)) return p;
        _logLocationDiagnostic(
            'Fix too coarse (acc=${p.accuracy.toStringAsFixed(1)}m) — trying stream…');
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
    _onGpsUpdate(seed);

    _gpsSub = Geolocator.getPositionStream(
      locationSettings: _platformLocationSettings(moving: true),
    ).listen(
          (p) {
        try {
          _lastStreamUpdate = DateTime.now();
          _gpsStreamErrorCount = 0;
          if (!_isGoodFix(p, 10000)) {
            _logLocationDiagnostic(
                'Discarded suspicious stream update (acc=${p.accuracy})');
            return;
          }
          _onGpsUpdate(p);
        } catch (e) {
          _logLocationDiagnostic('Error processing stream update: $e');
        }
      },
      onError: (err) {
        _gpsStreamErrorCount++;
        _logLocationDiagnostic('[GPS] stream error #$_gpsStreamErrorCount: $err');
        if (_gpsStreamErrorCount >= 5) {
          _logLocationDiagnostic('[GPS] Max stream errors; scheduling restart');
          _gpsSub?.cancel();
          _gpsStreamErrorCount = 0;
          _restartLocationStreamWithBackoff();
        }
      },
      cancelOnError: false,
    );

    _gpsWatchdog?.cancel();
    _gpsWatchdog = Timer.periodic(const Duration(seconds: 27), (_) {
      if (_lastStreamUpdate == null) return;
      final gap = DateTime.now().difference(_lastStreamUpdate!);
      if (gap.inSeconds > 40) {
        _logLocationDiagnostic(
            '[GPS] Watchdog: stalled ${gap.inSeconds}s — restarting');
        _gpsSub?.cancel();
        _restartLocationStreamWithBackoff();
      }
    });
  }

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
        _logLocationDiagnostic(
            'Final position is null after all strategies + fallback');
        if (userTriggered) {
          await _showLocationPromptModal(
            title: 'Location Unavailable',
            message:
            'We could not determine your current position. Move to open space, toggle GPS, then try again.',
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
                bearing: pos.heading.isFinite && pos.heading >= 0
                    ? pos.heading
                    : 0,
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
      _startNearbyDriversPolling();
    });
  }

  Future<void> _restartLocationStreamWithBackoff() async {
    if (!mounted) return;
    if (_locInitCompleter != null) {
      _logLocationDiagnostic('Restart join: init already in progress');
      try {
        await _locInitCompleter!.future;
      } catch (_) {}
      return;
    }

    _gpsInitAttempt = (_gpsInitAttempt + 1).clamp(1, 5);
    final secs = 2 * _gpsInitAttempt;
    final jitterMs = (300 * (math.Random().nextDouble())).round();
    final delay = Duration(seconds: secs, milliseconds: jitterMs);

    _logLocationDiagnostic(
      '[GPS] Re-init in ${delay.inSeconds}.${(delay.inMilliseconds % 1000) ~/ 100}s '
          '(attempt $_gpsInitAttempt)',
    );

    await Future.delayed(delay);
    if (!mounted) return;
    await _initLocation(userTriggered: false);
  }

  Future<void> _showLocationPromptModal({
    required String title,
    required String message,
    required bool isServiceIssue,
  }) async {
    if (!mounted) return;

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    await showModalBottomSheet<void>(
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
                        Container(
                          width: 52,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            color: divider,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
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
                            isServiceIssue
                                ? Icons.gps_off_rounded
                                : Icons.my_location_rounded,
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

  void _onGpsUpdate(Position pos) {
    if (_gpsThrottleTimer?.isActive ?? false) return;
    if (!_isGoodFix(pos, 10000)) return;

    _gpsThrottleTimer = Timer(kGpsUpdateInterval, () {
      if (!mounted) return;

      final now = DateTime.now();
      _prevPos = _curPos;
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
        if (!_gpsActive) {
          _gpsActive = true;
          _stationaryTimer?.cancel();
        }
      } else {
        _checkStationaryTimeout();
      }

      final rot =
      (pos.heading.isFinite && pos.heading >= 0) ? pos.heading : _userMarkerRotation;
      _updateUserMarker(ll, rotation: rot);

      if (!_navMode) {
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
            _moveCameraRealtimeV2(
              target: _forwardBiasTarget(user: ll, bearingDeg: smoothed),
              bearing: _rotateWithHeading ? smoothed : 0,
              zoom: (pos.speed >= kVehicleSpeedThreshold)
                  ? 17.5
                  : (pos.speed >= kPedestrianSpeedThreshold ? 17.0 : 16.5),
              tilt: Perf.I.tiltFor(pos.speed),
            );
          } else {
            if (now.difference(_lastCamMove) > Perf.I.camMoveMin) {
              final moved = (_lastCamTarget == null)
                  ? double.infinity
                  : _haversine(_lastCamTarget!, ll);
              if (moved > kCenterSnapMeters) {
                _map?.moveCamera(CameraUpdate.newLatLng(ll));
                _lastCamTarget = ll;
                _lastCamMove = now;
              }
            }
          }
        }
      }

      if (_pts.isNotEmpty && _pts.first.isCurrent) _updatePickupFromGps();

      _putLocationCircle(ll, accuracy: pos.accuracy);
      _syncSearchCircle();
      _maybeKickNearbyDrivers();
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

  void _putLocationCircle(LatLng c, {double accuracy = 50}) {
    final r = accuracy.clamp(8, 100).toDouble();
    if (_lastAccuracyLL != null) {
      final moved = _haversine(_lastAccuracyLL!, c);
      final dr = (r - _lastAccuracyRadius).abs();
      if (moved < 2.0 && dr < 2.0) return;
    }
    _lastAccuracyLL = c;
    _lastAccuracyRadius = r;

    if (!mounted) return;
    setState(() {
      _circles.removeWhere((x) => x.circleId == _accuracyCircleId);
      _circles.add(Circle(
        circleId: _accuracyCircleId,
        center: c,
        radius: r,
        fillColor: AppColors.primary.withOpacity(0.10),
        strokeColor: AppColors.primary.withOpacity(0.32),
        strokeWidth: 2,
      ));
    });
  }

  double _visualSearchRadiusMeters() {
    final km = _homeRadiusKm();
    final m = (km * 1000.0).clamp(_searchCircleMinM, _searchCircleMaxM);
    return m.toDouble();
  }

  LatLng? _searchCircleCenter() {
    final pick = _pts.isNotEmpty ? _pts.first.latLng : null;
    if (pick != null) return pick;
    if (_curPos != null) return LatLng(_curPos!.latitude, _curPos!.longitude);
    return null;
  }

  bool _shouldShowSearchCircle() {
    if (_tripPhase != TripPhase.browsing) return false;
    if (_offersLoading) return true;
    if (_marketOpen && _offers.isEmpty) return true;
    if (_nearbyDriversBusy && !_marketOpen) return true;
    return false;
  }

  void _syncSearchCircle() {
    final show = _shouldShowSearchCircle();
    final center = _searchCircleCenter();
    if (!mounted) return;

    if (!show || center == null) {
      if (_circles.any((c) => c.circleId == _searchCircleId)) {
        setState(() {
          _circles.removeWhere((x) => x.circleId == _searchCircleId);
        });
      }
      return;
    }

    final radius = _visualSearchRadiusMeters();
    setState(() {
      _circles.removeWhere((x) => x.circleId == _searchCircleId);
      _circles.add(Circle(
        circleId: _searchCircleId,
        center: center,
        radius: radius,
        fillColor: const Color(0xFF00A651).withOpacity(0.12),
        strokeColor: const Color(0xFF00A651).withOpacity(0.30),
        strokeWidth: 2,
      ));
    });
  }

  bool get _hasPickupAndDropoff =>
      _pts.length >= 2 && _pts.first.latLng != null && _pts.last.latLng != null;

  String _computeRouteHash() {
    final parts = <String>[];
    for (final p in _pts) {
      if (p.latLng != null) {
        parts.add(
          '${p.latLng!.latitude.toStringAsFixed(6)},${p.latLng!.longitude.toStringAsFixed(6)}',
        );
      }
    }
    return parts.join('|');
  }

  Future<void> _buildRoute() async {
    if (!(_pts.length >= 2 &&
        _pts.first.latLng != null &&
        _pts.last.latLng != null)) {
      return;
    }

    final routeHash = _computeRouteHash();

    if (_cachedRoute != null &&
        _lastRouteHash == routeHash &&
        !_cachedRoute!.isStale) {
      _applyRouteFromCache(_cachedRoute!.route);
      await _fitCurrentRouteToViewportV2(waitForLayout: true);
      return;
    }

    setState(() {
      _lines.clear();
      _distanceText = null;
      _durationText = null;
      _fare = null;
      _arrivalTime = null;
      _routeUiError = null;
      _markers.removeWhere(
            (m) => m.markerId == _etaMarkerId || m.markerId == _minsMarkerId,
      );
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

        await _fitCurrentRouteToViewportV2(waitForLayout: true);

        _routeRefreshTimer?.cancel();
        _routeRefreshTimer = Timer.periodic(const Duration(minutes: 3), (_) {
          if (_pts.first.latLng != null &&
              _pts.last.latLng != null &&
              !_expanded) {
            _cachedRoute = null;
            _buildRoute();
          }
        });
        return;
      }

      await _buildRouteLegacy(origin, destination, stops);
      await _fitCurrentRouteToViewportV2(waitForLayout: true);
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
      _lines.clear();
    });

    _routePts = points;
    _buildSpatialIndex();
    _buildSpeedColoredPolylines(points, route.speedIntervals);

    _updateRouteBubbles(
      origin: _pts.first.latLng!,
      destination: _pts.last.latLng!,
      secs: durationSeconds,
    ).then((_) => _fitCurrentRouteToViewportV2(waitForLayout: true));
  }

  Future<_V2Route?> _computeRoutesV2(
      LatLng origin,
      LatLng destination,
      List<LatLng> stops,
      ) async {
    final url = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');

    final body = <String, dynamic>{
      'origin': {
        'location': {
          'latLng': {
            'latitude': origin.latitude,
            'longitude': origin.longitude,
          }
        }
      },
      'destination': {
        'location': {
          'latLng': {
            'latitude': destination.latitude,
            'longitude': destination.longitude,
          }
        }
      },
      if (stops.isNotEmpty)
        'intermediates': [
          for (final s in stops)
            {
              'location': {
                'latLng': {
                  'latitude': s.latitude,
                  'longitude': s.longitude,
                }
              }
            }
        ],
      'travelMode': 'DRIVE',
      'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
      'computeAlternativeRoutes': false,
      'optimizeWaypointOrder': stops.isNotEmpty,
      'units': 'METRIC',
      'polylineQuality': 'HIGH_QUALITY',
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
            () => http.post(url, headers: headers, body: jsonEncode(body))
            .timeout(kApiTimeout),
      );
    } catch (_) {
      return null;
    }

    if (res.statusCode != 200) return null;

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final routes =
        (json['routes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (routes.isEmpty) return null;

    final route = routes.first;
    final encoded = (route['polyline']?['encodedPolyline'] ?? '') as String;
    if (encoded.isEmpty) return null;

    final pts = _decodePolyline(encoded);
    final dist = (route['distanceMeters'] ?? 0) as int;
    final durS = _parseDurationSeconds(route['duration']?.toString() ?? '0s');

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

    return _V2Route(pts, dist, durS, intervals);
  }

  int _parseDurationSeconds(String v) {
    if (!v.endsWith('s')) return 0;
    final n = v.substring(0, v.length - 1);
    return double.tryParse(n)?.round() ?? 0;
  }

  void _buildSpeedColoredPolylines(
      List<LatLng> decPts,
      List<_SpeedInterval> intervals,
      ) {
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
      _lines.add(Polyline(
        polylineId: const PolylineId('route_main'),
        points: decPts,
        color: AppColors.primary,
        width: 3,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        geodesic: true,
      ));
      setState(() {});
      return;
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

    final routes =
        (j['routes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
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
      _lines.clear();
    });

    _routePts = pts;
    _buildSpatialIndex();
    _buildSpeedColoredPolylines(pts, const []);

    await _updateRouteBubbles(origin: o, destination: d, secs: dSecs);
    await _fitCurrentRouteToViewportV2(waitForLayout: true);
  }

  Future<void> _updateRouteBubbles({
    required LatLng origin,
    required LatLng destination,
    required int secs,
  }) async {
    final minutes = math.max(1, (secs / 60).round());
    final arrive =
        'Arrive by ${DateFormat('h:mm a').format(DateTime.now().add(Duration(seconds: secs)))}';

    _minsBubbleIcon = await _buildMinutesCircleBadge(minutes);
    _etaBubbleIcon = await _buildArrivePillBadge(arrive);

    if (!mounted) return;
    setState(() {
      _markers.removeWhere(
            (m) => m.markerId == _etaMarkerId || m.markerId == _minsMarkerId,
      );

      _markers.add(Marker(
        markerId: _minsMarkerId,
        position: destination,
        icon: _minsBubbleIcon!,
        anchor: const Offset(0.5, 1.0),
        consumeTapEvents: false,
        zIndex: 998,
      ));

      _markers.add(Marker(
        markerId: _etaMarkerId,
        position: origin,
        icon: _etaBubbleIcon!,
        anchor: const Offset(0.5, 1.0),
        consumeTapEvents: false,
        zIndex: 998,
      ));
    });
  }

  Future<BitmapDescriptor> _buildMinutesCircleBadge(int minutes) async {
    const w = 140.0, h = 160.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final center = const Offset(w / 2, 62);
    const badgeR = 44.0;

    c.drawCircle(
      center + const Offset(0, 6),
      badgeR,
      Paint()
        ..color = Colors.black.withOpacity(0.18)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 10),
    );
    c.drawCircle(center, badgeR, Paint()..color = const Color(0xFF00A651));

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

    final linePaint = Paint()
      ..color = const Color(0xFF00A651)
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    c.drawLine(const Offset(w / 2, 110), const Offset(w / 2, 132), linePaint);

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
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
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

    c.drawRRect(
      pill.shift(const Offset(0, 6)),
      Paint()
        ..color = Colors.black.withOpacity(0.18)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 10),
    );
    c.drawRRect(pill, Paint()..color = const Color(0xFF1A73E8));

    final p = Path()
      ..moveTo(w / 2 - 10, h - 10)
      ..lineTo(w / 2, h)
      ..lineTo(w / 2 + 10, h - 10)
      ..close();
    c.drawPath(p, Paint()..color = const Color(0xFF1A73E8));

    tp.paint(c, Offset((w - tp.width) / 2, ((h - 10) - tp.height) / 2));

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  double _calcFare(int meters) => 500.0 + (meters / 1000.0) * 120.0;

  String _fmtDistance(int m) =>
      (m < 1000) ? '$m m' : '${(m / 1000.0).toStringAsFixed(1)} km';

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

  static const _kRecentsKey = 'recent_places_v5';
  static const int _maxRecents = 30;

  Future<void> _loadRecents() async {
    final raw = _prefs.getString(_kRecentsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      setState(() {
        _recents = list
            .map(Suggestion.fromJson)
            .toList()
            .take(_maxRecents)
            .toList();
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
    _prefs.setString(
      _kRecentsKey,
      jsonEncode(cap.map((e) => e.toJson()).toList()),
    );
    setState(() => _recents = cap);
  }

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

  void _openWallet() {
    final balance = _user != null
        ? double.tryParse(_user!['user_bal']?.toString() ?? '0.0') ?? 0.0
        : null;
    final currency = _user?['user_currency']?.toString() ?? 'NGN';
    showModalBottomSheet(
      context: context,
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

  void _toast(String title, String msg) {
    if (!mounted) return;
    showToastNotification(
      context: context,
      title: title,
      message: msg,
      isSuccess: false,
    );
  }

  double _homeRadiusKm() => 50.0;

  bool _driversChangedEnough(DriverCar a, DriverCar b) {
    final moved = _haversine(a.ll, b.ll);
    final dh = (a.heading - b.heading).abs();
    return moved >= 1.2 || dh >= 6.0;
  }

  void _startNearbyDriversPolling({bool force = false}) {
    if (!mounted) return;
    if (_tripPhase != TripPhase.browsing) return;
    if (_marketOpen) return;

    if (_nearbyDriversTimer != null && !force) return;

    if (_curPos == null) {
      Geolocator.getLastKnownPosition().then((p) {
        if (!mounted || p == null) return;
        _curPos ??= p;
        _startNearbyDriversPolling(force: true);
      });
      return;
    }

    _nearbyDriversTimer?.cancel();
    _nearbyDriversTimer =
        Timer.periodic(kDriversPollInterval, (_) => _tickNearbyDrivers());
    _tickNearbyDrivers();
  }

  void _stopNearbyDriversPolling() {
    _nearbyDriversTimer?.cancel();
    _nearbyDriversTimer = null;
    _nearbyDriversBusy = false;
    _syncSearchCircle();
  }

  void _maybeKickNearbyDrivers() {
    if (!mounted) return;
    if (_tripPhase != TripPhase.browsing) return;
    if (_marketOpen) return;
    if (_nearbyDriversTimer != null) return;
    if (_curPos == null) return;
    _startNearbyDriversPolling();
  }

  Future<void> _tickNearbyDrivers() async {
    if (!mounted) return;
    if (_curPos == null) return;

    final bool allowFirstFetchWhileExpanded = _drivers.isEmpty;
    if (_expanded && !allowFirstFetchWhileExpanded) return;
    if (_marketOpen) return;
    if (_tripPhase != TripPhase.browsing) return;
    if (_nearbyDriversBusy) return;

    final now = DateTime.now();
    if (now.difference(_lastNearbyTickAt) < const Duration(milliseconds: 900)) {
      return;
    }
    _lastNearbyTickAt = now;

    _nearbyDriversBusy = true;
    _syncSearchCircle();

    try {
      final LatLng origin = (_pts.isNotEmpty && _pts.first.latLng != null)
          ? _pts.first.latLng!
          : LatLng(_curPos!.latitude, _curPos!.longitude);

      final riderId = _prefs.getString('user_id') ??
          _user?['id']?.toString() ??
          _user?['user_id']?.toString() ??
          'guest';

      final payload = <String, String>{
        'lat': origin.latitude.toString(),
        'lng': origin.longitude.toString(),
        'radius_km': _homeRadiusKm().toStringAsFixed(1),
        'vehicle': 'car',
        'user_id': riderId,
        if ((_nearbyDriversCursor ?? '').isNotEmpty) 'cursor': _nearbyDriversCursor!,
      };

      final res = await _api
          .request(
        ApiConstants.driversNearbyEndpoint,
        method: 'POST',
        data: payload,
      )
          .timeout(const Duration(seconds: 6));

      if (!mounted) return;
      if (res.statusCode != 200) return;

      dynamic decoded;
      try {
        decoded = jsonDecode(res.body);
      } catch (_) {
        return;
      }

      final Map<String, dynamic> m = decoded is Map<String, dynamic>
          ? decoded
          : (decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{});

      final err = m['error'];
      final errTrue = (err == true) ||
          (err?.toString().toLowerCase() == 'true') ||
          (err?.toString() == '1');
      if (errTrue) return;

      _nearbyDriversCursor = m['cursor']?.toString() ?? _nearbyDriversCursor;

      List raw = const [];
      final cand = m['drivers'] ??
          m['delta'] ??
          m['driversNearby'] ??
          m['drivers_nearby'] ??
          m['nearbyDrivers'] ??
          m['data'] ??
          m['results'];

      if (cand is List) {
        raw = cand;
      } else if (cand is Map) {
        raw = cand.values.toList();
      }

      if (raw.isEmpty) {
        _applyNearbyDrivers(const []);
        return;
      }

      final nextList = <DriverCar>[];
      for (final e in raw) {
        if (e is Map) {
          final d = DriverCar.fromJson(e.cast<String, dynamic>());
          if (d.id.isEmpty) continue;
          if (d.ll.latitude == 0.0 && d.ll.longitude == 0.0) continue;
          nextList.add(d);
        }
      }

      if (nextList.length > kMaxDriverMarkers) {
        nextList.removeRange(kMaxDriverMarkers, nextList.length);
      }

      _applyNearbyDrivers(nextList);
    } catch (_) {
      // ignore polling errors silently
    } finally {
      _nearbyDriversBusy = false;
      _syncSearchCircle();
    }
  }

  void _applyNearbyDrivers(List<DriverCar> list) {
    if (!mounted) return;

    final now = DateTime.now();
    bool changed = false;

    for (final d in list) {
      _driverLastSeen[d.id] = now;
      final existing = _drivers[d.id];
      if (existing == null) {
        _drivers[d.id] = d;
        changed = true;
      } else if (_driversChangedEnough(existing, d)) {
        _drivers[d.id] = d;
        changed = true;
      }
    }

    final staleIds = <String>[];
    _driverLastSeen.forEach((id, lastSeen) {
      if (now.difference(lastSeen).inSeconds > 10) staleIds.add(id);
    });
    for (final id in staleIds) {
      _driverLastSeen.remove(id);
      if (_drivers.remove(id) != null) changed = true;
    }

    if (changed) _refreshDriverMarkers();
  }

  Future<void> _startRideMarket() async {
    if (!_hasPickupAndDropoff) return;

    _stopNearbyDriversPolling();
    await _marketSub?.cancel();
    _marketSub = null;

    setState(() {
      _offersLoading = true;
      _marketOpen = true;
    });
    _syncSearchCircle();

    LatLng safePickup() {
      final p = _pts.isNotEmpty ? _pts.first.latLng : null;
      if (p != null) return p;
      if (_curPos != null) {
        return LatLng(_curPos!.latitude, _curPos!.longitude);
      }
      return _initialCam.target;
    }

    LatLng safeDrop() {
      final d = _pts.isNotEmpty ? _pts.last.latLng : null;
      if (d != null) return d;
      return _initialCam.target;
    }

    _marketSub = _rideMarketService
        .stream(
      origin: safePickup(),
      destination: safeDrop(),
      originProvider: () => safePickup(),
      destinationProvider: () => safeDrop(),
      userIdProvider: () =>
      _prefs.getString('user_id') ?? _user?['id']?.toString() ?? '',
      pollInterval: const Duration(seconds: 2),
    )
        .listen(
          (snap) {
        if (!mounted) return;
        _offers = snap.offers;
        _drivers
          ..clear()
          ..addEntries(snap.drivers.map((d) => MapEntry(d.id, d)));
        _refreshDriverMarkers();
        setState(() => _offersLoading = false);
        _syncSearchCircle();
      },
      onError: (_) {
        if (!mounted) return;
        setState(() => _offersLoading = false);
        _syncSearchCircle();
      },
    );
  }

  void _stopRideMarket({bool restartNearbyPolling = true}) {
    _marketSub?.cancel();
    _marketSub = null;

    if (mounted) {
      setState(() {
        _marketOpen = false;
        _offersLoading = false;
        _offers = const [];
      });
    }

    _syncSearchCircle();
    if (restartNearbyPolling) _startNearbyDriversPolling();
  }

  void _refreshDriverMarkers() {
    final icon = _driverIcon ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
    final next = <Marker>{};
    for (final d in _drivers.values) {
      next.add(Marker(
        markerId: MarkerId('driver_${d.id}'),
        position: d.ll,
        icon: icon,
        flat: true,
        rotation: d.heading,
        anchor: const Offset(0.5, 0.6),
        zIndex: 5,
      ));
    }
    if (!mounted) return;
    setState(() {
      _driverMarkers
        ..clear()
        ..addAll(next);
    });
  }

  Stream<dynamic>? _bookingUpdatesStream() {
    final b = _booking;
    if (b == null) return null;
    try {
      final s = b.updates;
      if (s is Stream) return s as Stream<dynamic>;
    } catch (_) {}
    try {
      final s = b.stream;
      if (s is Stream) return s as Stream<dynamic>;
    } catch (_) {}
    try {
      final s = b.events;
      if (s is Stream) return s as Stream<dynamic>;
    } catch (_) {}
    return null;
  }

  Future<String?> _startBooking({
    required String riderId,
    required String driverId,
    required RideOffer offer,
    required LatLng pickup,
    required LatLng destination,
  }) async {
    if (_booking == null) {
      _lastBookingError = 'BookingController is null';
      _dbg('BOOKING_FAIL', _lastBookingError);
      return null;
    }

    if (riderId.trim().isEmpty || riderId == 'guest') {
      _lastBookingError = 'You must be logged in to book a ride.';
      _dbg('BOOKING_FAIL', _lastBookingError);
      return null;
    }

    if (driverId.trim().isEmpty) {
      _lastBookingError = 'No driver selected.';
      _dbg('BOOKING_FAIL', _lastBookingError);
      return null;
    }

    if (offer.id.trim().isEmpty) {
      _lastBookingError = 'Offer ID is missing.';
      _dbg('BOOKING_FAIL', _lastBookingError);
      return null;
    }

    _dbg('BOOKING_INPUT', {
      'riderId': riderId,
      'driverId': driverId,
      'offerId': offer.id,
      'provider': offer.provider,
      'category': offer.category,
      'pickup': '${pickup.latitude},${pickup.longitude}',
      'destination': '${destination.latitude},${destination.longitude}',
    });

    try {
      final dropOffs = <LatLng>[
        for (int i = 1; i < _pts.length - 1; i++)
          if (_pts[i].latLng != null) _pts[i].latLng!,
      ];

      _booking!.lastError = null;

      final bool ok = await _booking!.createBooking(
        offer: offer,
        pickup: pickup,
        destination: destination,
        pickupText: _pts.first.controller.text.trim(),
        destinationText: _pts.last.controller.text.trim(),
        stops: dropOffs,
        payMethod: 'cash',
        userId: riderId,
        driverId: driverId,
      );

      final String id = (_booking!.rideId ?? '').toString().trim();

      if (ok && id.isNotEmpty) {
        _lastBookingError = null;
        _dbg('BOOKING_OK', {
          'rideId': id,
          'riderId': _booking!.riderId,
          'driverId': _booking!.driverId,
        });
        return id;
      }

      final BookingError? err = _booking!.lastError;
      final String msg = err?.message.trim().isNotEmpty == true
          ? err!.message
          : 'Booking failed — server did not confirm the ride.';

      _lastBookingError = msg;

      _dbg('BOOKING_FAIL_SERVER', {
        'kind': err?.kind.name,
        'status': err?.httpStatus,
        'msg': msg,
        'raw': err?.rawBody,
      });

      return null;
    } catch (e, st) {
      _lastBookingError = e.toString();
      _dbg('BOOKING_FAIL_EXCEPTION', e);
      _dbg('BOOKING_FAIL_ST', st);
      return null;
    }
  }

  Future<void> _onBookDriverAndOffer(
      RideNearbyDriver driver,
      RideOffer offer,
      ) async {
    _stopRideMarket(restartNearbyPolling: false);
    _selectedOffer = offer;

    final String riderId = _prefs.getString('user_id') ??
        _user?['id']?.toString() ??
        _user?['user_id']?.toString() ??
        'guest';

    await _bookingSub?.cancel();
    _bookingSub = null;

    try {
      _booking?.dispose();
    } catch (_) {}

    _booking = BookingController(_api);

    final LatLng pickup = _pickupAnchorLL() ?? _pts.first.latLng!;
    final LatLng destination = _destLL() ?? _pts.last.latLng!;

    final String? rideId = await _startBooking(
      riderId: riderId,
      driverId: driver.id,
      offer: offer,
      pickup: pickup,
      destination: destination,
    );

    if (rideId == null || rideId.trim().isEmpty) {
      final BookingError? err = _booking?.lastError;

      final String kind = err?.kind.name ?? '';
      final int? status = err?.httpStatus;
      String detail = err?.message.trim() ?? '';
      String headline = 'Booking failed';

      if (kind == 'driverBusy' || status == 409) {
        headline = 'Driver unavailable';
        detail = detail.isNotEmpty
            ? detail
            : 'This driver is currently on another ride. Choose another driver.';
      } else if (kind == 'validation' || status == 422) {
        headline = 'Booking error';
        detail = detail.isNotEmpty
            ? detail
            : 'The booking request is missing a required field.';
      } else if (kind == 'networkError') {
        headline = 'Network error';
        detail = detail.isNotEmpty ? detail : 'Check your connection and try again.';
      } else if (kind == 'serverError' || (status != null && status >= 500)) {
        headline = 'Server error';
        detail = detail.isNotEmpty
            ? detail
            : 'The server ran into an issue. Try again shortly.';
      } else if (kind == 'notFound' || status == 404) {
        headline = 'Endpoint not found';
        detail = detail.isNotEmpty
            ? detail
            : 'The booking endpoint could not be reached.';
      } else if (detail.isEmpty) {
        detail = _lastBookingError?.isNotEmpty == true
            ? _lastBookingError!
            : 'Could not book this driver. Please try again.';
      }

      _toast(headline, detail);
      _startRideMarket();
      return;
    }

    if (!mounted) return;

    _engagedDriverId = driver.id;
    _engagedDriverLL = LatLng(driver.lat, driver.lng);

    final Stream<dynamic>? activeStream = _bookingUpdatesStream();

    _bookingSub = activeStream?.listen(
          (dynamic event) {
        if (!mounted) return;

        String statusText = '';
        String msg = '';

        try {
          final rawStatus =
              event?.status ?? event?['status'] ?? event?.state ?? event?['state'];
          if (rawStatus != null) {
            statusText = rawStatus.toString().toLowerCase();
          }
        } catch (_) {}

        try {
          final rawMsg = event?.displayMessage ??
              event?['displayMessage'] ??
              event?.message ??
              event?['message'];
          if (rawMsg != null) {
            msg = rawMsg.toString().trim();
          }
        } catch (_) {}

        if ((statusText.contains('fail') || statusText.contains('error')) &&
            msg.isNotEmpty) {
          _toast('Trip error', msg);
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );

    final List<LatLng> dropOffs = <LatLng>[
      for (int i = 1; i < _pts.length - 1; i++)
        if (_pts[i].latLng != null) _pts[i].latLng!,
    ];

    final List<String> dropOffTexts = <String>[
      for (int i = 1; i < _pts.length - 1; i++)
        if (_pts[i].latLng != null) _pts[i].controller.text.trim(),
    ];

    final LatLng? initialRiderLocation = _curPos == null
        ? (_pts.first.isCurrent ? pickup : null)
        : LatLng(_curPos!.latitude, _curPos!.longitude);

    _dbg('TRIP_NAV_ARGS', {
      'userId': riderId,
      'driverId': driver.id,
      'tripId': rideId,
      'pickup': '${pickup.latitude},${pickup.longitude}',
      'destination': '${destination.latitude},${destination.longitude}',
      'dropOffs': [
        for (final p in dropOffs) '${p.latitude},${p.longitude}',
      ],
      'initialDriverLocation': '${driver.lat},${driver.lng}',
      'initialRiderLocation': initialRiderLocation == null
          ? null
          : '${initialRiderLocation.latitude},${initialRiderLocation.longitude}',
      'enableLivePickupTracking': _pts.first.isCurrent,
    });

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripNavigationPage(
          args: TripNavigationArgs(
            userId: riderId,
            driverId: driver.id,
            tripId: rideId,
            pickup: pickup,
            destination: destination,
            dropOffs: dropOffs,
            originText: _pts.first.controller.text.trim(),
            destinationText: _pts.last.controller.text.trim(),
            dropOffTexts: dropOffTexts,
            driverName: driver.name,
            vehicleType: driver.vehicleType,
            carPlate: driver.carPlate,
            rating: driver.rating,
            initialDriverLocation: LatLng(driver.lat, driver.lng),
            initialRiderLocation: initialRiderLocation,
            initialPhase: TripNavPhase.driverToPickup,
            bookingUpdates: activeStream,
            liveSnapshotProvider: _bookingLiveSnapshotProvider,
            onStartTrip: _bookingStartTrip,
            onCancelTrip: _bookingCancelTrip,
            role: TripNavigationRole.rider,
            tickEvery: const Duration(seconds: 2),
            routeMinGap: const Duration(seconds: 2),
            arrivalMeters: 35.0,
            routeMoveThresholdMeters: 8.0,
            autoFollowCamera: true,
            showStartTripButton: true,
            showCancelButton: true,
            showMetaCard: true,
            showDebugPanel: true,
            enableLivePickupTracking: _pts.first.isCurrent,
            preserveStopOrder: true,
            autoCloseOnCancel: true,
          ),
        ),
      ),
    );

    if (!mounted) return;

    await _bookingSub?.cancel();
    _bookingSub = null;

    try {
      _booking?.dispose();
    } catch (_) {}

    _booking = null;

    _resetTripState(keepRoute: true);
    _startNearbyDriversPolling(force: true);
  }

  LatLng? _pickupAnchorLL() {
    if (_pts.isNotEmpty && _pts.first.isCurrent && _curPos != null) {
      return LatLng(_curPos!.latitude, _curPos!.longitude);
    }
    return _pts.isNotEmpty ? _pts.first.latLng : null;
  }

  LatLng? _destLL() => _pts.isNotEmpty ? _pts.last.latLng : null;

  LatLng? _engagedDriverLLFromPools() {
    final id = _engagedDriverId;
    if (id != null && _drivers.containsKey(id)) return _drivers[id]!.ll;
    return _engagedDriverLL;
  }

  void _setEngagedDriverMarker(LatLng ll, double heading) {
    if (!mounted) return;
    setState(() {
      _markers.removeWhere((m) => m.markerId == _driverSelectedId);
      _markers.add(Marker(
        markerId: _driverSelectedId,
        position: ll,
        icon: _driverIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
        flat: true,
        rotation: heading,
        anchor: const Offset(0.5, 0.6),
        zIndex: 50,
      ));
    });
  }

  Future<void> _updateDriverToPickupPolyline({
    required LatLng driverLL,
    required LatLng pickupLL,
  }) async {
    final now = DateTime.now();
    final movedEnough = _lastDriverLegFrom == null
        ? true
        : _haversine(_lastDriverLegFrom!, driverLL) >= 10.0;
    final timeEnough =
        now.difference(_lastDriverLegRouteAt) >= const Duration(seconds: 4);
    if (!movedEnough && !timeEnough) return;

    _lastDriverLegRouteAt = now;
    _lastDriverLegFrom = driverLL;

    final v2 = await _computeRoutesV2(driverLL, pickupLL, const []);
    if (v2 == null || v2.points.isEmpty) return;

    if (!mounted) return;
    setState(() {
      _driverLines
        ..clear()
        ..add(Polyline(
          polylineId: const PolylineId('driver_halo'),
          points: v2.points,
          color: Colors.white.withOpacity(0.92),
          width: 10,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
          geodesic: true,
        ))
        ..add(Polyline(
          polylineId: const PolylineId('driver_path'),
          points: v2.points,
          color: const Color(0xFF7B1FA2),
          width: 6,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
          geodesic: true,
        ));
    });

    if (!_didFitDriverLeg && !_expanded) {
      _didFitDriverLeg = true;
      final bounds = _computeSmartBounds([driverLL, pickupLL]);
      await _animateBoundsSafeV2(bounds, basePadding: 90);
    }
  }

  Future<void> _updateTripPolyline({
    required LatLng from,
    required LatLng to,
  }) async {
    final now = DateTime.now();
    final movedEnough = _lastTripLegFrom == null
        ? true
        : _haversine(_lastTripLegFrom!, from) >= 12.0;
    final timeEnough =
        now.difference(_lastTripLegRouteAt) >= const Duration(seconds: 6);
    if (!movedEnough && !timeEnough) return;

    _lastTripLegRouteAt = now;
    _lastTripLegFrom = from;

    final v2 = await _computeRoutesV2(from, to, const []);
    if (v2 == null || v2.points.isEmpty) return;

    if (!mounted) return;
    setState(() {
      _driverLines
        ..clear()
        ..add(Polyline(
          polylineId: const PolylineId('trip_halo'),
          points: v2.points,
          color: Colors.white.withOpacity(0.92),
          width: 10,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
          geodesic: true,
        ))
        ..add(Polyline(
          polylineId: const PolylineId('trip_path'),
          points: v2.points,
          color: const Color(0xFF1A73E8),
          width: 6,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
          geodesic: true,
        ));
    });

    if (!_didFitTripLeg && !_expanded) {
      _didFitTripLeg = true;
      final bounds = _computeSmartBounds([from, to]);
      await _animateBoundsSafeV2(bounds, basePadding: 110);
    }
  }

  void _startDriverToPickupTick() {
    _tripTickTimer?.cancel();
    _tripTickTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      if (_tripPhase != TripPhase.driverToPickup &&
          _tripPhase != TripPhase.waitingPickup) {
        return;
      }

      final pickup = _pickupAnchorLL();
      if (pickup == null) return;

      final driverLL = _engagedDriverLLFromPools();
      if (driverLL == null) return;

      final head = (_engagedDriverId != null && _drivers.containsKey(_engagedDriverId))
          ? _drivers[_engagedDriverId]!.heading
          : 0.0;
      _engagedDriverLL = driverLL;
      _setEngagedDriverMarker(driverLL, head);

      if (_tripPhase == TripPhase.driverToPickup) {
        await _updateDriverToPickupPolyline(driverLL: driverLL, pickupLL: pickup);
        final meters = _haversine(driverLL, pickup);
        if (meters <= _arriveMeters) {
          setState(() => _tripPhase = TripPhase.waitingPickup);
          _toast('Driver arrived', 'You can now start the trip.');
        }
      }
    });
  }

  void _startTripNavTick() {
    _tripTickTimer?.cancel();
    _tripTickTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      if (_tripPhase != TripPhase.enRoute) return;

      final user = (_curPos == null)
          ? null
          : LatLng(_curPos!.latitude, _curPos!.longitude);
      final dest = _destLL();
      if (user == null || dest == null) return;

      await _updateTripPolyline(from: user, to: dest);

      final bearing = _bearingBetween(user, dest);
      _navMode = true;
      _camMode = _CamMode.follow;
      _rotateWithHeading = false;
      _useForwardAnchor = false;

      try {
        await _map?.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: user,
              zoom: 17.3,
              tilt: 65,
              bearing: bearing,
            ),
          ),
        );
      } catch (_) {}
    });
  }

  void _resetTripState({bool keepRoute = true}) {
    _tripTickTimer?.cancel();
    _navMode = false;
    _tripPhase = TripPhase.browsing;
    _engagedDriverId = null;
    _engagedDriverLL = null;
    _didFitDriverLeg = false;
    _didFitTripLeg = false;
    _lastDriverLegFrom = null;
    _lastTripLegFrom = null;
    _lastDriverLegRouteAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastTripLegRouteAt = DateTime.fromMillisecondsSinceEpoch(0);

    _bookingSub?.cancel();
    _bookingSub = null;

    if (!mounted) return;
    setState(() {
      _driverLines.clear();
      _markers.removeWhere((m) => m.markerId == _driverSelectedId);
    });

    _enterFollowMode();
    _syncSearchCircle();
  }

  Future<void> _startTrip() async {
    if (_tripPhase != TripPhase.waitingPickup &&
        _tripPhase != TripPhase.driverToPickup) return;
    setState(() {
      _tripPhase = TripPhase.enRoute;
      _driverLines.clear();
    });
    _startTripNavTick();
  }

  void _ensurePlacesSession() {
    if (_placesSession.isEmpty) _placesSession = _uuid.v4();
  }

  void _onTyping(String q) {
    _debounce?.cancel();
    final query = q.trim();

    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _sugs = _recents;
        _isTyping = false;
        _autoStatus = null;
        _autoError = null;
      });
      return;
    }

    if (!_expanded) _expand();
    if (!mounted) return;
    setState(() => _isTyping = true);

    _debounce = Timer(const Duration(milliseconds: 260), () => _fetchSugs(query));
  }

  Future<void> _fetchSugs(String input) async {
    if (_activeRequests >= kMaxConcurrentRequests) return;
    _ensurePlacesSession();

    final int myQueryId = ++_lastQueryId;
    _activeRequests++;

    final origin =
    _curPos == null ? null : LatLng(_curPos!.latitude, _curPos!.longitude);

    try {
      dynamic result = await _auto
          .autocomplete(
        input: input,
        sessionToken: _placesSession,
        apiKey: ApiConstants.kGoogleApiKey,
        country: 'ng',
        origin: origin,
      )
          .timeout(kApiTimeout);

      if (!mounted || myQueryId != _lastQueryId) return;

      try {
        _autoStatus = result.status?.toString();
        _autoError = result.errorMessage?.toString();
      } catch (_) {}

      List<Suggestion> sugs = const [];
      try {
        final preds = result.predictions;
        if (preds is List<Suggestion>) {
          sugs = preds;
        } else if (preds is List) {
          sugs = preds.whereType<Suggestion>().toList();
        }
      } catch (_) {}

      if (sugs.isEmpty) {
        try {
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

          if (!mounted || myQueryId != _lastQueryId) return;
          try {
            _autoStatus = result.status?.toString();
            _autoError = result.errorMessage?.toString();
          } catch (_) {}

          final preds = result.predictions;
          if (preds is List<Suggestion>) {
            sugs = preds;
          } else if (preds is List) {
            sugs = preds.whereType<Suggestion>().toList();
          }
        } catch (_) {}
      }

      if (sugs.isEmpty) {
        try {
          final alt = await _auto
              .findPlaceText(
            input: input,
            apiKey: ApiConstants.kGoogleApiKey,
            origin: origin,
          )
              .timeout(kApiTimeout);

          if (!mounted || myQueryId != _lastQueryId) return;

          if (alt is List<Suggestion>) {
            sugs = alt;
          } else if (alt is List) {
            sugs = alt.whereType<Suggestion>().toList();
          }
          _autoStatus = _autoStatus ?? 'FALLBACK_FIND_PLACE';
        } catch (_) {}
      }

      if (!mounted || myQueryId != _lastQueryId) return;
      setState(() {
        _sugs = sugs.isNotEmpty ? sugs : _recents;
        _isTyping = false;
        _isConnected = true;
      });
    } catch (_) {
      if (!mounted || myQueryId != _lastQueryId) return;
      setState(() {
        _isTyping = false;
        _isConnected = false;
        _sugs = _recents;
      });
    } finally {
      _activeRequests = (_activeRequests - 1).clamp(0, 9999);
    }
  }

  LatLng? _coerceLatLngFromDetails(dynamic det) {
    if (det == null) return null;
    try {
      final ll = det.latLng;
      if (ll is LatLng) return ll;
    } catch (_) {}
    try {
      final g = det.geometry ?? det.result?.geometry ?? det['geometry'];
      final loc = g?.location ?? g?['location'] ?? det.location ?? det['location'];
      final lat = (loc?.lat ??
          loc?['lat'] ??
          loc?.latitude ??
          loc?['latitude']);
      final lng = (loc?.lng ??
          loc?['lng'] ??
          loc?.longitude ??
          loc?['longitude']);
      if (lat is num && lng is num) {
        return LatLng(lat.toDouble(), lng.toDouble());
      }
      if (lat is String && lng is String) {
        final la = double.tryParse(lat);
        final lo = double.tryParse(lng);
        if (la != null && lo != null) return LatLng(la, lo);
      }
    } catch (_) {}
    return null;
  }

  void _focusNextUnfilled() {
    for (int i = 0; i < _pts.length; i++) {
      if (_pts[i].controller.text.trim().isEmpty) {
        _activeIdx = i;
        _pts[i].focus.requestFocus();
        return;
      }
    }
    _collapse();
  }

  Future<void> _selectSug(Suggestion s) async {
    HapticFeedback.selectionClick();
    _ensurePlacesSession();

    try {
      final dynamic det = await _auto
          .placeDetails(
        placeId: s.placeId,
        sessionToken: _placesSession,
        apiKey: ApiConstants.kGoogleApiKey,
      )
          .timeout(kApiTimeout);

      final ll = _coerceLatLngFromDetails(det);
      if (ll == null) {
        _toast('Place Error', 'Could not read location details.');
        return;
      }

      if (!mounted) return;

      setState(() {
        final p = _pts[_activeIdx];
        p
          ..latLng = ll
          ..placeId = s.placeId
          ..controller.text =
          (s.mainText.isNotEmpty ? s.mainText : s.description)
          ..isCurrent = false;
      });

      _putMarker(_activeIdx, ll, s.description);
      _saveRecent(s);
      _placesSession = '';

      if (_hasPickupAndDropoff) {
        _cachedRoute = null;
        await _buildRoute();
        await _fitCurrentRouteToViewportV2(waitForLayout: true);
        await _startRideMarket();
        _collapse();
      } else {
        _focusNextUnfilled();
      }
    } catch (_) {
      _toast('Network Error', 'Failed to load place details.');
    }
  }

  void _addStop() {
    HapticFeedback.selectionClick();
    if (_pts.length >= 6) {
      _toast('Limit', 'Maximum stops reached.');
      return;
    }

    final insertAt = (_pts.length - 1).clamp(1, _pts.length);
    final stopFocus = FocusNode();
    final stopCtl = TextEditingController();

    stopFocus.addListener(() {
      if (stopFocus.hasFocus) _onFocused(_indexOfFocus(stopFocus));
    });

    final stop = RoutePoint(
      type: PointType.stop,
      controller: stopCtl,
      focus: stopFocus,
      hint: 'Add stop',
    );

    if (!mounted) return;
    setState(() {
      _pts.insert(insertAt, stop);
      _activeIdx = insertAt;
    });

    _expand();
    Future.delayed(const Duration(milliseconds: 40), () {
      if (!mounted) return;
      stopFocus.requestFocus();
    });
  }

  void _removeStop(int index) {
    if (index <= 0) return;
    if (index >= _pts.length - 1) return;
    HapticFeedback.selectionClick();

    final removed = _pts[index];
    if (!mounted) return;
    setState(() => _pts.removeAt(index));

    removed.controller.dispose();
    removed.focus.dispose();

    _rebuildPointMarkers();

    if (_hasPickupAndDropoff) {
      _cachedRoute = null;
      _buildRoute();
    }
  }

  void _rebuildPointMarkers() {
    if (!mounted) return;
    setState(() {
      _markers.removeWhere((m) => m.markerId.value.startsWith('p_'));
      for (int i = 0; i < _pts.length; i++) {
        final ll = _pts[i].latLng;
        if (ll == null) continue;
        final p = _pts[i];
        final icon = p.type == PointType.pickup
            ? (_pickupIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure))
            : p.type == PointType.destination
            ? (_dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen))
            : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);

        _markers.add(Marker(
          markerId: MarkerId('p_$i'),
          position: ll,
          icon: icon,
          anchor: const Offset(0.5, 0.5),
          infoWindow: InfoWindow(
            title: _pointLabel(p.type),
            snippet: p.controller.text,
          ),
          consumeTapEvents: false,
        ));
      }
    });
  }

  void _swap() {
    if (_pts.length < 2) return;
    HapticFeedback.selectionClick();

    final a = _pts.first;
    final b = _pts.last;

    if (!mounted) return;
    setState(() {
      final ll = a.latLng;
      final pid = a.placeId;
      final txt = a.controller.text;
      final isCur = a.isCurrent;

      a
        ..latLng = b.latLng
        ..placeId = b.placeId
        ..controller.text = b.controller.text
        ..isCurrent = false;

      b
        ..latLng = ll
        ..placeId = pid
        ..controller.text = txt
        ..isCurrent = isCur;
    });

    _rebuildPointMarkers();

    if (_hasPickupAndDropoff) {
      _cachedRoute = null;
      _buildRoute();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final s = _s(context);
    final safeTop = mq.padding.top;
    final orientation = mq.orientation;

    // Handle orientation changes with smart refit
    if (_lastOrientation != orientation) {
      _lastOrientation = orientation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduleMapPaddingUpdate();

        // Auto-refit route on orientation change
        if (_routePts.isNotEmpty && _camMode == _CamMode.overview) {
          Future.delayed(const Duration(milliseconds: 240), () {
            if (mounted) _fitCurrentRouteToViewportV2(waitForLayout: true);
          });
        }
      });
    }

    final bottomNavH = _effectiveBottomNavH();

    // Landscape-aware FAB positioning
    final fabBottom = orientation == Orientation.landscape
        ? (_sheetHeight + math.max(bottomNavH * 0.6, 8.0) + 12)
        .clamp(60.0, 320.0)
        : (_sheetHeight + bottomNavH + 16).clamp(96.0, 520.0);

    final fabRight = orientation == Orientation.landscape
        ? (14 * s).clamp(8.0, 32.0)
        : (14 * s).clamp(12.0, 28.0);

    final hasSummary = _distanceText != null && _durationText != null;
    final bottomSheetMaxH = mq.size.height *
        (orientation == Orientation.landscape ? 0.75 : 0.60);

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

                if (_routePts.isNotEmpty) {
                  Future.delayed(
                    const Duration(milliseconds: 80),
                        () => _fitCurrentRouteToViewportV2(waitForLayout: false),
                  );
                }

                _maybeKickNearbyDrivers();
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
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.65, 1.0],
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
              onNotifications: () =>
                  Navigator.pushNamed(context, AppRoutes.notifications),
            ),
          ),
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
                      Row(mainAxisSize: MainAxisSize.min, children: const [
                        Icon(Icons.schedule_rounded, size: 17),
                        SizedBox(width: 6),
                      ]),
                      Text(_durationText!,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      Container(
                        height: 16,
                        width: 1,
                        color: AppColors.mintBgLight.withOpacity(.5),
                      ),
                      Row(mainAxisSize: MainAxisSize.min, children: const [
                        Icon(Icons.straighten_rounded, size: 17),
                        SizedBox(width: 6),
                      ]),
                      Text(_distanceText!,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      if (_arrivalTime != null) ...[
                        Container(
                          height: 16,
                          width: 1,
                          color: AppColors.mintBgLight.withOpacity(.5),
                        ),
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
          Positioned(
            right: fabRight,
            bottom: fabBottom,
            child: LocateFab(
              onTap: () async {
                HapticFeedback.selectionClick();
                _enterFollowMode();
                if (_curPos != null) {
                  final ll = LatLng(_curPos!.latitude, _curPos!.longitude);
                  _applyHeadingTick();
                  await _map?.animateCamera(
                    CameraUpdate.newCameraPosition(
                      CameraPosition(target: ll, zoom: 17, tilt: 45),
                    ),
                  );
                } else {
                  await _initLocation(userTriggered: true);
                }
              },
            ),
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
                  key: ValueKey('route_sheet_${_expanded}_$_marketOpen'),
                  bottomNavHeight: bottomNavH,
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
                  userLocation: _curPos == null
                      ? null
                      : GeoPoint(_curPos!.latitude, _curPos!.longitude),
                  pickupLocation: _pickupAnchorLL() == null
                      ? null
                      : GeoPoint(
                    _pickupAnchorLL()!.latitude,
                    _pickupAnchorLL()!.longitude,
                  ),
                  dropLocation: _destLL() == null
                      ? null
                      : GeoPoint(_destLL()!.latitude, _destLL()!.longitude),
                  onRefresh: _startRideMarket,
                  onCancel: () {
                    _stopRideMarket();
                    _resetTripState();
                    setState(() => _marketOpen = false);
                    _syncSearchCircle();
                  },
                  onBook: (driver, offer) async {
                    await _onBookDriverAndOffer(driver, offer);
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
                bottomPadding: bottomNavH + 12,
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
      bottomNavigationBar: (!_marketOpen && _tripPhase == TripPhase.browsing)
          ? CustomBottomNavBar(
        currentIndex: _currentIndex,
        onTap: (i) {
          HapticFeedback.selectionClick();
          setState(() => _currentIndex = i);
          if (i == 1) {
            Navigator.pushNamed(context, AppRoutes.rideHistory);
          }
          if (i == 2) {
            Navigator.pushNamed(context, AppRoutes.profile);
          }
        },
      )
          : null,
    );
  }

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
      _syncSearchCircle();
    } catch (_) {
      final ll = LatLng(_curPos!.latitude, _curPos!.longitude);
      setState(() {
        _pts.first
          ..latLng = ll
          ..controller.text = 'Current location'
          ..isCurrent = true;
      });
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
      case PointType.pickup:
        return 'Pickup';
      case PointType.destination:
        return 'Destination';
      case PointType.stop:
        return 'Stop';
    }
  }

  void _putMarker(int idx, LatLng pos, String title) {
    final p = _pts[idx];
    final id = MarkerId('p_$idx');
    final icon = p.type == PointType.pickup
        ? (_pickupIcon ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure))
        : p.type == PointType.destination
        ? (_dropIcon ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen))
        : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);

    if (!mounted) return;
    setState(() {
      _markers.removeWhere((m) => m.markerId == id);
      _markers.add(Marker(
        markerId: id,
        position: pos,
        icon: icon,
        anchor: const Offset(0.5, 0.5),
        infoWindow: InfoWindow(title: _pointLabel(p.type), snippet: title),
        consumeTapEvents: false,
      ));
    });
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