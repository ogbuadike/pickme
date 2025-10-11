// lib/screens/home/home_page.dart
// Pick Me — Premium Modular Home with Optimized Layout (map-first)
// - Map stays visible/touchable via dynamic GoogleMap.padding
// - Tiny & responsive via _s(context) scale factor
// - Clean orchestration: HomePage <-> RouteSheet <-> AutoOverlay
// - Heavily commented for future maintenance

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../api/url.dart';
import '../../api/api_client.dart';
import '../../themes/app_theme.dart';
import '../../utility/notification.dart';
import '../../routes/routes.dart';

import '../../widgets/bottom_navigation_bar.dart';
import '../../widgets/app_menu_drawer.dart';
import '../../widgets/fund_account_sheet.dart';

import 'state/home_models.dart';
import '../services/autocomplete_service.dart';
import '../widgets/header_bar.dart';
import '../widgets/locate_fab.dart';
import '../widgets/route_sheet.dart';
import '../widgets/auto_overlay.dart';

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // ────────────────────────────────────────────────────────────────────────────
  // LAYOUT CONSTANTS — keep UI tiny; map should dominate
  // ────────────────────────────────────────────────────────────────────────────
  static const double kBottomNavH = 74;     // bottom nav height
  static const double kHeaderVisualH = 88;  // visual header height (below safeTop)

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _sheetKey = GlobalKey(); // to measure RouteSheet height

  // Runtime-measured heights used for GoogleMap.padding
  double _sheetHeight = 0;
  EdgeInsets _mapPadding = EdgeInsets.zero;

  // ────────────────────────────────────────────────────────────────────────────
  // INFRASTRUCTURE
  // ────────────────────────────────────────────────────────────────────────────
  late SharedPreferences _prefs;
  late ApiClient _api;
  Map<String, dynamic>? _user;
  bool _busyProfile = false;
  int _currentIndex = 0;

  // ────────────────────────────────────────────────────────────────────────────
  // MAP STATE
  // ────────────────────────────────────────────────────────────────────────────
  GoogleMapController? _map;
  final CameraPosition _initialCam = const CameraPosition(
    target: LatLng(6.458985, 7.548266), // Onitsha fallback
    zoom: 14,
  );
  Position? _curPos;
  StreamSubscription<Position>? _gpsSub;
  final Set<Marker> _markers = {};
  final Set<Polyline> _lines = {};
  final Set<Circle> _circles = {};

  // ────────────────────────────────────────────────────────────────────────────
  // ROUTE POINTS
  // ────────────────────────────────────────────────────────────────────────────
  final List<RoutePoint> _pts = [];
  int _activeIdx = 0;

  // ────────────────────────────────────────────────────────────────────────────
  // AUTOCOMPLETE (Google Places)
  // ────────────────────────────────────────────────────────────────────────────
  final _uuid = const Uuid();
  String _placesSession = '';
  Timer? _debounce;
  late final AutocompleteService _auto;
  List<Suggestion> _sugs = [];
  List<Suggestion> _recents = [];
  bool _isTyping = false;
  int _lastQueryId = 0;
  String? _autoStatus;
  String? _autoError;

  // ────────────────────────────────────────────────────────────────────────────
  // TRIP STATE
  // ────────────────────────────────────────────────────────────────────────────
  String? _distanceText;
  String? _durationText;
  double? _fare;

  // ────────────────────────────────────────────────────────────────────────────
  // UI STATE
  // ────────────────────────────────────────────────────────────────────────────
  bool _expanded = false; // AutoOverlay visible?

  // ────────────────────────────────────────────────────────────────────────────
  // UTILITIES
  // ────────────────────────────────────────────────────────────────────────────

  /// Pixel-aware scale factor: tiny on small phones (~0.75) → 1.0 on larger
  double _s(BuildContext c) {
    final size = MediaQuery.of(c).size;
    final shortest = math.min(size.width, size.height);
    return (shortest / 390.0).clamp(0.75, 1.00);
  }

  void _log(String msg, [Object? data]) {
    final d = data == null ? '' : '  -> $data';
    debugPrint('[Home] $msg$d');
  }

  // ────────────────────────────────────────────────────────────────────────────
  // LIFECYCLE
  // ────────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);
    _auto = AutocompleteService(logger: _log);
    _initPoints();
    _bootstrap();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _gpsSub?.cancel();
    for (final p in _pts) {
      p.controller.dispose();
      p.focus.dispose();
    }
    _map?.dispose();
    super.dispose();
  }

  // ────────────────────────────────────────────────────────────────────────────
  // BOOTSTRAP
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> _bootstrap() async {
    _prefs = await SharedPreferences.getInstance();
    await Future.wait([_fetchUser(), _initLocation(), _loadRecents()]);
    _scheduleMapPaddingUpdate(); // ensure map padding matches header/sheet
  }

  Future<void> _fetchUser() async {
    setState(() => _busyProfile = true);
    try {
      final uid = _prefs.getString('user_id') ?? '';
      if (uid.isEmpty) return;
      final res = await _api.request(
        ApiConstants.userInfoEndpoint,
        method: 'POST',
        data: {'user': uid},
      );
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body['error'] == false) setState(() => _user = body['user']);
      }
    } catch (e) {
      _log('User fetch error', e);
    } finally {
      if (mounted) setState(() => _busyProfile = false);
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // LOCATION
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> _initLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        _toast('Location Required', 'Please enable location services');
        _log('Location permission denied');
        return;
      }

      _curPos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      _log('GPS', {'lat': _curPos!.latitude, 'lng': _curPos!.longitude});

      await _animate(
        LatLng(_curPos!.latitude, _curPos!.longitude),
        zoom: 16,
      );
      await _useCurrentAsPickup();

      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      ).listen(_onGps);
    } catch (e) {
      _log('Location error', e);
      _toast('Location Error', 'Failed to acquire current location');
    }
  }

  void _onGps(Position p) {
    _curPos = p;
    if (_pts.isNotEmpty && _pts.first.latLng != null && _pts.first.isCurrent) {
      _updatePickupFromGps();
    }
  }

  Future<void> _animate(LatLng t, {double zoom = 15}) async {
    await _map?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: t, zoom: zoom)),
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
      _putLocationCircle(ll);
    } catch (e) {
      _log('Reverse geocode error', e);
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
    _putLocationCircle(ll);
  }

  void _putLocationCircle(LatLng c) {
    setState(() {
      _circles
        ..clear()
        ..add(Circle(
          circleId: const CircleId('cur'),
          center: c,
          radius: 50,
          fillColor: AppColors.primary.withOpacity(0.15),
          strokeColor: AppColors.primary.withOpacity(0.4),
          strokeWidth: 2,
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

  // ────────────────────────────────────────────────────────────────────────────
  // ROUTE POINTS
  // ────────────────────────────────────────────────────────────────────────────
  void _initPoints() {
    final pickupFocus = FocusNode();
    final pickupCtl = TextEditingController();
    pickupFocus.addListener(() {
      if (pickupFocus.hasFocus) _onFocused(0);
    });
    final pickup = RoutePoint(
      type: PointType.pickup,
      controller: pickupCtl,
      focus: pickupFocus,
      hint: 'Pickup location',
    );

    final destFocus = FocusNode();
    final destCtl = TextEditingController();
    destFocus.addListener(() {
      if (destFocus.hasFocus) _onFocused(1);
    });
    final dest = RoutePoint(
      type: PointType.destination,
      controller: destCtl,
      focus: destFocus,
      hint: 'Where to?',
    );

    _pts.addAll([pickup, dest]);
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
    Future.delayed(const Duration(milliseconds: 80), () {
      s.focus.requestFocus();
    });
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

  // ────────────────────────────────────────────────────────────────────────────
  // AUTOCOMPLETE
  // ────────────────────────────────────────────────────────────────────────────
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
      _log('New Places session', _placesSession);
    }
  }

  Future<void> _fetchSugs(String input) async {
    _ensureSession();
    final origin = _curPos == null ? null : LatLng(_curPos!.latitude, _curPos!.longitude);
    final int myQueryId = ++_lastQueryId;

    try {
      var result = await _auto.autocomplete(
        input: input,
        sessionToken: _placesSession,
        apiKey: ApiConstants.kGoogleApiKey,
        country: 'ng',
        origin: origin,
      );
      if (!mounted || myQueryId != _lastQueryId) return;

      _autoStatus = result.status;
      _autoError = result.errorMessage;

      var sugs = result.predictions;
      if (sugs.isEmpty) {
        _log('Autocomplete empty; trying relaxed params');
        result = await _auto.autocomplete(
          input: input,
          sessionToken: _placesSession,
          apiKey: ApiConstants.kGoogleApiKey,
          country: 'ng',
          origin: origin,
          relaxedTypes: true,
        );
        _autoStatus = result.status;
        _autoError = result.errorMessage;
        sugs = result.predictions;

        if (sugs.isEmpty) {
          _log('Relaxed still empty; FindPlace fallback');
          sugs = await _auto.findPlaceText(
            input: input,
            apiKey: ApiConstants.kGoogleApiKey,
            origin: origin,
          );
          _autoStatus = _autoStatus ?? 'FALLBACK_FIND_PLACE';
        }
      }

      setState(() {
        _sugs = sugs;
        _isTyping = false;
      });

      if ((_autoStatus != null && _autoStatus != 'OK') || sugs.isEmpty) {
        if (_autoError != null && _autoError!.isNotEmpty) {
          _toast('Places API', _autoError!);
        }
      }
    } catch (e) {
      if (!mounted || myQueryId != _lastQueryId) return;
      _log('Autocomplete exception', e);
      setState(() => _isTyping = false);
      _toast('Autocomplete Error', 'Check internet and API key configuration.');
    }
  }

  Future<void> _selectSug(Suggestion s) async {
    HapticFeedback.mediumImpact();
    try {
      final det = await _auto.placeDetails(
        placeId: s.placeId,
        sessionToken: _placesSession,
        apiKey: ApiConstants.kGoogleApiKey,
      );
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
      await _animate(det.latLng!, zoom: 16);
      _focusNextUnfilled();
      if (_hasRoute()) await _buildRoute();
    } catch (e) {
      _log('Place details error', e);
    }
  }

  void _focusNextUnfilled() {
    for (int i = 0; i < _pts.length; i++) {
      if (_pts[i].latLng == null) {
        Future.delayed(const Duration(milliseconds: 120),
                () => _pts[i].focus.requestFocus());
        return;
      }
    }
    Future.delayed(const Duration(milliseconds: 120), () {
      FocusScope.of(context).unfocus();
      _collapse();
    });
  }

  // ────────────────────────────────────────────────────────────────────────────
  // DIRECTIONS
  // ────────────────────────────────────────────────────────────────────────────
  bool _hasRoute() =>
      _pts.length >= 2 && _pts.first.latLng != null && _pts.last.latLng != null;

  Future<void> _buildRoute() async {
    if (!_hasRoute()) return;
    setState(() {
      _lines.clear();
      _distanceText = null;
      _durationText = null;
      _fare = null;
    });

    final o = _pts.first.latLng!;
    final d = _pts.last.latLng!;
    final stops = <LatLng>[
      for (int i = 1; i < _pts.length - 1; i++)
        if (_pts[i].latLng != null) _pts[i].latLng!,
    ];

    final wp = stops.isNotEmpty
        ? '&waypoints=optimize:true|${stops.map((w) => '${w.latitude},${w.longitude}').join('|')}'
        : '';

    final url =
        '${ApiConstants.kDirectionsUrl}?origin=${o.latitude},${o.longitude}'
        '&destination=${d.latitude},${d.longitude}$wp&key=${ApiConstants.kGoogleApiKey}';

    _log('Directions URL', url);

    try {
      final r = await http.get(Uri.parse(url));
      _log('Directions status', r.statusCode);
      if (r.statusCode != 200) {
        _toast('Route Error', 'HTTP ${r.statusCode}');
        return;
      }
      final j = jsonDecode(r.body);
      final routes = (j['routes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (routes.isEmpty) {
        _toast('Route Error', 'No routes found');
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
      final pts = _decodePolyline(poly);

      setState(() {
        _distanceText = _fmtDistance(dMeters);
        _durationText = _fmtDuration(dSecs);
        _fare = _calcFare(dMeters);
        _lines.add(Polyline(
          polylineId: const PolylineId('route'),
          points: pts,
          color: AppColors.primary,
          width: 6,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
          geodesic: true,
        ));
      });

      _fitBounds(pts);
    } catch (e) {
      _log('Directions error', e);
      _toast('Route Error', 'Failed to calculate route');
    }
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

  // ────────────────────────────────────────────────────────────────────────────
  // MARKERS
  // ────────────────────────────────────────────────────────────────────────────
  void _putMarker(int idx, LatLng pos, String title) {
    final p = _pts[idx];
    final id = MarkerId('p_$idx');
    final icon = p.type == PointType.pickup
        ? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure)
        : p.type == PointType.destination
        ? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed)
        : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    setState(() {
      _markers.removeWhere((m) => m.markerId == id);
      _markers.add(Marker(
        markerId: id,
        position: pos,
        icon: icon,
        infoWindow: InfoWindow(title: p.type.label, snippet: title),
      ));
    });
  }

  // ────────────────────────────────────────────────────────────────────────────
  // RECENTS (local storage)
  // ────────────────────────────────────────────────────────────────────────────
  static const _kRecentsKey = 'recent_places_v4';

  Future<void> _loadRecents() async {
    final raw = _prefs.getString(_kRecentsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      setState(() {
        _recents = list.map(Suggestion.fromJson).toList();
        _sugs = _recents;
      });
    } catch (e) {
      _log('Load recents error', e);
    }
  }

  void _saveRecent(Suggestion s) {
    final up = List<Suggestion>.from(_recents);
    up.removeWhere((e) => e.placeId == s.placeId);
    up.insert(0, s);
    final cap = up.take(24).toList();
    _prefs.setString(_kRecentsKey, jsonEncode(cap.map((e) => e.toJson()).toList()));
    setState(() => _recents = cap);
  }

  // ────────────────────────────────────────────────────────────────────────────
  // SHEET/OVERLAY VISIBILITY + MAP PADDING
  // ────────────────────────────────────────────────────────────────────────────
  void _expand() {
    setState(() => _expanded = true);
    _scheduleMapPaddingUpdate();
  }

  void _collapse() {
    FocusScope.of(context).unfocus();
    setState(() => _expanded = false);
    _scheduleMapPaddingUpdate();
  }

  /// Measure RouteSheet height after layout and update GoogleMap.padding.
  void _scheduleMapPaddingUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _sheetKey.currentContext;
      double newHeight = 0;
      if (ctx != null) {
        final box = ctx.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) newHeight = box.size.height;
      }
      _sheetHeight = newHeight;
      _applyMapPadding();
    });
  }

  /// Apply padding to GoogleMap (this prop exists on the widget, not controller).
  void _applyMapPadding() {
    if (!mounted) return;
    final mq = MediaQuery.of(context);
    final topPad = mq.padding.top + kHeaderVisualH;         // safeTop + header
    final bottomPad = _sheetHeight + kBottomNavH + 12;      // sheet + nav + gap
    setState(() {
      _mapPadding = EdgeInsets.fromLTRB(0, topPad, 0, bottomPad);
    });
  }

  // ────────────────────────────────────────────────────────────────────────────
  // UI HELPERS
  // ────────────────────────────────────────────────────────────────────────────
  // In your HomePage class (_HomePageState), replace the _openWallet method:

  void _openWallet() {
    // Extract balance and currency from user data
    final balance = _user != null
        ? double.tryParse(_user!['user_bal']?.toString() ?? '0.0') ?? 0.0
        : null;

    final currency = _user?['user_currency']?.toString() ?? 'NGN';

    showModalBottomSheet(
      context: context,
      isScrollControlled: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FundAccountSheet(
        account: _user, // Pass the entire user object; the sheet will extract what it needs
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
    showToastNotification(
      context: context,
      title: title,
      message: msg,
      isSuccess: false,
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // BUILD
  // ────────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final s = _s(context);
    final safeTop = mq.padding.top;

    // FAB floats just above the measured sheet height
    final double fabBottom = (_sheetHeight + kBottomNavH + 16).clamp(96.0, 520.0);

    return Scaffold(
      key: _scaffoldKey,
      drawer: AppMenuDrawer(user: _user),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // MAP — pass dynamic padding so nothing is hidden
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: _initialCam,
              padding: _mapPadding, // <<— key change: widget prop, not controller
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
              mapToolbarEnabled: false,
              markers: _markers,
              polylines: _lines,
              circles: _circles,
              onMapCreated: (c) {
                _map = c;
                _scheduleMapPaddingUpdate();
              },
              onTap: (_) => _collapse(),
            ),
          ),

          // Soft gradient under status bar/header for contrast
          Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: Container(
                height: safeTop + (kHeaderVisualH * s),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
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

          // Header
          Positioned(
            top: safeTop, left: 0, right: 0,
            child: HeaderBar(
              user: _user,
              busyProfile: _busyProfile,
              onMenu: () => _scaffoldKey.currentState?.openDrawer(),
              onWallet: _openWallet,
              onNotifications: () => Navigator.pushNamed(context, AppRoutes.notifications),
            ),
          ),

          // Locate FAB — tiny & responsive; sits above the sheet
          Positioned(
            right: 14 * s,
            bottom: fabBottom,
            child: LocateFab(
              onTap: () async {
                HapticFeedback.selectionClick();
                if (_curPos != null) {
                  await _animate(LatLng(_curPos!.latitude, _curPos!.longitude), zoom: 17);
                } else {
                  await _initLocation();
                }
              },
            ),
          ),

          // Fixed RouteSheet — we key it so we can measure height each frame
          // Fixed RouteSheet — force rebuild with ValueKey when overlay dismisses
          Positioned(
            left: 0, right: 0, bottom: 0,
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

          // Full-screen auto-complete overlay (API signature matches your current widget)
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

              // ✅ NEW: let RouteEditor add/remove stop fields inside the overlay
              onAddStop: _addStop,
              onRemoveStop: _removeStop,

              // (optional but recommended) keep swap consistent everywhere
              onSwap: _swap,

              onClose: () {
                // Ensure UI becomes tappable again after closing overlay
                FocusManager.instance.primaryFocus?.unfocus();
                _collapse();  // your existing collapse
                // Nudge a rebuild after the fade-out finishes
                Future.delayed(const Duration(milliseconds: 50), () {
                  if (mounted) setState(() {});
                });
              },
            )

        ],
      ),

      bottomNavigationBar: CustomBottomNavBar(
        currentIndex: _currentIndex,
        onTap: (i) {
          setState(() => _currentIndex = i);
          if (i == 1) Navigator.pushNamed(context, AppRoutes.rideHistory);
          if (i == 2) Navigator.pushNamed(context, AppRoutes.profile);
        },
      ),
    );
  }
}
