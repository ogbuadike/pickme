// lib/screens/logistics_map_picker.dart
//
// Route picker for Send Me / Dispatch: pickup + drop-off, route + distance,
// then the details sheet. After a successful booking it hands over to
// LogisticsTrackingPage (searching / assigned / in transit / delivered).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../utility/notification.dart';
import '../services/logistics_service.dart';
import 'logistics/logistics_tracking_page.dart';
import 'logistics_booking_sheet.dart';
import 'state/location_permission_modal.dart';

import 'state/home_models.dart';
import 'state/map_graphics_engine.dart';
import 'state/routing_engine.dart';
import '../services/autocomplete_service.dart';
import '../widgets/auto_overlay.dart';
import '../widgets/route_sheet.dart';

class LogisticsMapPicker extends StatefulWidget {
  final ApiClient api;
  final String userId;
  final String rideType; // 'send_me' or 'dispatch'
  final double? walletBalance;

  const LogisticsMapPicker({
    super.key,
    required this.api,
    required this.userId,
    required this.rideType,
    this.walletBalance,
  });

  @override
  State<LogisticsMapPicker> createState() => _LogisticsMapPickerState();
}

class _LogisticsMapPickerState extends State<LogisticsMapPicker> with TickerProviderStateMixin {
  static const double kHeaderVisualH = 60.0;
  static const String _kRecentsKey = 'recent_logistics_places_v1';

  SharedPreferences? _prefs;
  int _routeSeq = 0;
  bool _routing = false;
  bool _routeFailed = false;
  bool _sheetOpen = false;

  GoogleMapController? _mapController;
  final ValueNotifier<Set<Marker>> _markersNotifier = ValueNotifier({});
  final ValueNotifier<Set<Polyline>> _polylinesNotifier = ValueNotifier({});
  final ValueNotifier<Set<Circle>> _circlesNotifier = ValueNotifier({});

  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  final Set<Circle> _circles = {};

  late AutocompleteService _auto;
  final Uuid _uuid = const Uuid();
  String _placesSession = '';

  List<Suggestion> _sugs = [];
  List<Suggestion> _recents = [];
  bool _isTyping = false;
  Timer? _debounce;

  String? _autoStatus;
  String? _autoError;

  final List<RoutePoint> _pts = [];
  int _activeIdx = 0;
  bool _expanded = false;

  Position? _currentPosition;
  double _calculatedDistanceKm = 0.0;
  String? _distanceText, _durationText;

  BitmapDescriptor? _pickupIcon, _dropIcon, _userPinIcon;
  bool _iconsLoaded = false;

  final GlobalKey _sheetKey = GlobalKey();
  double _sheetHeight = 0;
  EdgeInsets _mapPadding = EdgeInsets.zero;

  late AnimationController _overlayAnimController;
  late Animation<double> _overlayFadeAnim;

  double _userMarkerRotation = 0;

  @override
  void initState() {
    super.initState();
    _auto = AutocompleteService();

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
  }

  Future<void> _bootstrap() async {
    _prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    await _loadRecents();
    await _loadPremiumGraphics();
    await _fetchCurrentLocation();
    if (mounted) WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleMapPaddingUpdate());
  }

  void _initPoints() {
    final pFocus = FocusNode();
    final pCtl = TextEditingController();
    pFocus.addListener(() {
      if (pFocus.hasFocus) _onFocused(0);
    });
    final dFocus = FocusNode();
    final dCtl = TextEditingController();
    dFocus.addListener(() {
      if (dFocus.hasFocus) _onFocused(1);
    });

    final isDispatch = widget.rideType == 'dispatch';
    _pts.addAll([
      RoutePoint(
        type: PointType.pickup,
        controller: pCtl,
        focus: pFocus,
        hint: isDispatch ? 'Where is the cargo?' : 'Start errand from?',
      ),
      RoutePoint(
        type: PointType.destination,
        controller: dCtl,
        focus: dFocus,
        hint: isDispatch ? 'Delivery destination?' : 'Final drop-off point?',
      ),
    ]);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _overlayAnimController.dispose();
    _markersNotifier.dispose();
    _polylinesNotifier.dispose();
    _circlesNotifier.dispose();
    for (final p in _pts) {
      p.controller.dispose();
      p.focus.dispose();
    }
    try {
      _mapController?.dispose();
    } catch (_) {}
    super.dispose();
  }

  // --- FOCUS & UI STATE HELPERS (FIXED) ---

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

  void _onFocused(int index) {
    if (!_expanded) {
      setState(() {
        _activeIdx = index;
        _sugs = _recents;
        _expanded = true;
        _autoStatus = null;
        _autoError = null;
      });
      _overlayAnimController.forward();
    } else {
      setState(() => _activeIdx = index);
    }
  }
  // ----------------------------------------

  void _pushMapState() {
    _markersNotifier.value = Set.from(_markers);
    _polylinesNotifier.value = Set.from(_polylines);
    _circlesNotifier.value = Set.from(_circles);
  }

  Future<void> _loadPremiumGraphics() async {
    final results = await Future.wait<BitmapDescriptor>([
      MapGraphicsEngine.createRingDotMarker(const Color(0xFF1A73E8)),
      MapGraphicsEngine.createRingDotMarker(const Color(0xFF00A651)),
    ]);
    if (!mounted) return;
    setState(() {
      _pickupIcon = results[0];
      _dropIcon = results[1];
      _iconsLoaded = true;
    });
    await _createUserPinIcon();
  }

  Future<void> _createUserPinIcon() async {
    if (!mounted) return;
    _userPinIcon = await MapGraphicsEngine.createPremiumAvatarPin(
      avatarImage: null,
      isDark: Theme.of(context).brightness == Brightness.dark,
      cs: Theme.of(context).colorScheme,
    );
    if (_currentPosition != null) {
      _updateUserMarker(LatLng(_currentPosition!.latitude, _currentPosition!.longitude));
    }
  }

  void _updateUserMarker(LatLng pos, {double? rotation}) {
    if (_userPinIcon == null) return;
    if (rotation != null) _userMarkerRotation = rotation;

    _markers.removeWhere((m) => m.markerId == const MarkerId('user_location'));
    _markers.add(Marker(
      markerId: const MarkerId('user_location'),
      position: pos,
      icon: _userPinIcon!,
      anchor: const Offset(0.5, 0.5),
      flat: true,
      rotation: _userMarkerRotation,
      zIndex: 999,
    ));
    _pushMapState();
  }

  Future<void> _loadRecents() async {
    final prefs = _prefs;
    final raw = prefs?.getString(_kRecentsKey);
    if (prefs == null || raw == null || raw.isEmpty || !mounted) return;
    try {
      setState(() {
        _recents = (jsonDecode(raw) as List)
            .cast<Map<String, dynamic>>()
            .map(Suggestion.fromJson)
            .toList()
            .take(20)
            .toList();
        _sugs = _recents;
      });
    } catch (_) {
      await prefs.remove(_kRecentsKey);
    }
  }

  void _saveRecent(Suggestion s) {
    final up = List<Suggestion>.from(_recents)
      ..removeWhere((e) => e.placeId == s.placeId)
      ..insert(0, s);
    final cap = up.take(20).toList();
    _prefs?.setString(_kRecentsKey, jsonEncode(cap.map((e) => e.toJson()).toList()));
    if (mounted) setState(() => _recents = cap);
  }

  /// Location goes through the shared gate (LocationPermissionModal): it
  /// prompts at most once per session for automatic calls.
  Future<void> _fetchCurrentLocation({bool userTriggered = false}) async {
    try {
      final st = await LocationPermissionModal.ensure(
        context,
        userTriggered: userTriggered,
        message: 'Pick Me uses your location to set the pickup point and find nearby riders.',
      );
      if (!mounted || !st.isGranted) return;

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      if (!mounted) return;
      _currentPosition = pos;

      final ll = LatLng(pos.latitude, pos.longitude);
      _updateUserMarker(ll, rotation: pos.heading.isFinite ? pos.heading : 0);
      _putLocationCircle(ll, accuracy: pos.accuracy);

      if (_mapController != null && _pts.first.latLng == null) {
        _mapController!.animateCamera(CameraUpdate.newLatLngZoom(ll, 15.5));
      }
    } catch (_) {}
  }

  void _putLocationCircle(LatLng c, {double accuracy = 50}) {
    final r = accuracy.clamp(8, 100).toDouble();
    _circles.removeWhere((x) => x.circleId == const CircleId('accuracy'));
    _circles.add(Circle(
      circleId: const CircleId('accuracy'),
      center: c,
      radius: r,
      fillColor: AppColors.primary.withValues(alpha: 0.1),
      strokeColor: AppColors.primary.withValues(alpha: 0.35),
      strokeWidth: 2,
    ));
    _pushMapState();
  }

  void _scheduleMapPaddingUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _sheetKey.currentContext;
      if (ctx != null) {
        final box = ctx.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          final newHeight = box.size.height;
          if (_sheetHeight != newHeight) {
            setState(() {
              _sheetHeight = newHeight;
              final mq = MediaQuery.of(context);
              _mapPadding = EdgeInsets.fromLTRB(8, mq.padding.top + kHeaderVisualH, 8, newHeight + 20);
            });
          }
        }
      }
    });
  }

  void _putMarker(int idx, LatLng pos, String title) {
    final p = _pts[idx];
    final icon = p.type == PointType.pickup
        ? (_pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure))
        : p.type == PointType.destination
        ? (_dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen))
        : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);

    _markers.removeWhere((m) => m.markerId == MarkerId('p_$idx'));
    _markers.add(Marker(
      markerId: MarkerId('p_$idx'),
      position: pos,
      icon: icon,
      anchor: const Offset(0.5, 0.5),
    ));
    _pushMapState();
  }

  Future<void> _useCurrentAsPickup() async {
    if (_currentPosition == null) return;
    HapticFeedback.selectionClick();
    final ll = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
    setState(() {
      _pts.first
        ..latLng = ll
        ..placeId = null
        ..controller.text = 'Current location'
        ..isCurrent = true;
    });
    _putMarker(0, ll, _pts.first.controller.text);
    _focusNextUnfilled();
    if (_pts.last.latLng != null) unawaited(_drawRoute());
    // The courier needs a real address, not "Current location".
    try {
      final marks = await geo.placemarkFromCoordinates(ll.latitude, ll.longitude).timeout(const Duration(seconds: 6));
      if (!mounted || marks.isEmpty || _pts.first.latLng != ll) return;
      final p = marks.first;
      final parts = <String>[
        if ((p.name ?? '').isNotEmpty) p.name!,
        if ((p.street ?? '').isNotEmpty && p.street != p.name) p.street!,
        if ((p.locality ?? '').isNotEmpty) p.locality!,
      ];
      if (parts.isNotEmpty) setState(() => _pts.first.controller.text = parts.join(', '));
    } catch (_) {}
  }

  void _updateMapMarkers() {
    if (!_iconsLoaded) return;
    _markers.removeWhere((m) => m.markerId.value.startsWith('p_'));
    for (int i = 0; i < _pts.length; i++) {
      if (_pts[i].latLng == null) continue;
      _putMarker(i, _pts[i].latLng!, _pts[i].controller.text);
    }
  }

  static double _straightKm(LatLng a, LatLng b) {
    const r = 6371.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(b.latitude - a.latitude), dLng = rad(b.longitude - a.longitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(a.latitude)) * math.cos(rad(b.latitude)) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
  }

  Future<void> _drawRoute() async {
    final origin = _pts.first.latLng;
    final destination = _pts.last.latLng;
    if (origin == null || destination == null) return;
    final int seq = ++_routeSeq;
    setState(() {
      _routing = true;
      _routeFailed = false;
    });

    RouteResult? result;
    try {
      result = await RoutingEngine.computeRoute(origin: origin, destination: destination, stops: const <LatLng>[]);
    } catch (_) {
      result = null;
    }
    if (!mounted || seq != _routeSeq) return; // a newer route request won

    if (result == null || result.points.isEmpty) {
      // Keep the flow usable: estimate road distance from the straight line.
      final km = _straightKm(origin, destination) * 1.3;
      setState(() {
        _routing = false;
        _routeFailed = true;
        _calculatedDistanceKm = km;
        _distanceText = '~${km.toStringAsFixed(1)} km';
        _durationText = null;
        _polylines.clear();
      });
      _pushMapState();
      await _fitCurrentRoute();
      return;
    }

    {
      final RouteResult route = result;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      setState(() {
        _routing = false;
        _calculatedDistanceKm = route.distanceMeters / 1000.0;
        _distanceText = '${(route.distanceMeters / 1000.0).toStringAsFixed(1)} km';
        _durationText = _fmtDuration(route.durationSeconds);

        _polylines.clear();
        _polylines.addAll([
          Polyline(
            polylineId: const PolylineId('halo'),
            points: route.points,
            color: isDark ? Colors.white.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.92),
            width: 10,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
          Polyline(
            polylineId: const PolylineId('core'),
            points: route.points,
            color: _kind.brandColor,
            width: 4,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
        ]);
      });
      _pushMapState();
      await _fitCurrentRoute();
    }
  }

  Future<void> _fitCurrentRoute() async {
    if (_mapController == null) return;
    final pts = <LatLng>[
      for (final p in _pts)
        if (p.latLng != null) p.latLng!
    ];
    if (pts.length < 2) return;
    await _mapController!.animateCamera(CameraUpdate.newLatLngBounds(RoutingEngine.computeSmartBounds(pts), 70.0));
  }

  String _fmtDuration(int s) {
    final mins = (s / 60).round();
    return mins < 60 ? '$mins min' : '${mins ~/ 60}h ${mins % 60}m';
  }

  void _ensurePlacesSession() {
    if (_placesSession.isEmpty) _placesSession = _uuid.v4();
  }

  void _onTyping(String query) {
    _debounce?.cancel();
    final q = query.trim();
    if (q.isEmpty) {
      setState(() {
        _sugs = _recents;
        _isTyping = false;
        _autoStatus = null;
        _autoError = null;
      });
      return;
    }
    setState(() => _isTyping = true);
    _debounce = Timer(const Duration(milliseconds: 260), () => _fetchSugs(q));
  }

  Future<void> _fetchSugs(String input) async {
    _ensurePlacesSession();
    final origin = _currentPosition == null ? null : LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
    try {
      final result = await _auto.autocomplete(
        input: input,
        sessionToken: _placesSession,
        apiKey: ApiConstants.kGoogleApiKey,
        country: 'ng',
        origin: origin,
      );
      if (!mounted) return;
      setState(() {
        _sugs = result.predictions.whereType<Suggestion>().toList();
        if (_sugs.isEmpty) _sugs = _recents;
        _isTyping = false;
        _autoStatus = 'OK';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isTyping = false;
          _autoStatus = 'ERROR';
          _autoError = e.toString();
          _sugs = _recents;
        });
      }
    }
  }

  Future<void> _selectSug(Suggestion s) async {
    HapticFeedback.selectionClick();
    _ensurePlacesSession();
    // The active field can change while details load: bind to the one tapped.
    // Recents tapped on the collapsed sheet always fill the drop-off.
    final RoutePoint target = _expanded ? _pts[_activeIdx.clamp(0, _pts.length - 1)] : _pts.last;
    try {
      final det = await _auto.placeDetails(placeId: s.placeId, sessionToken: _placesSession, apiKey: ApiConstants.kGoogleApiKey);
      if (!mounted) return;
      if (det.latLng == null) {
        showToastNotification(context: context, title: 'Place error', message: 'Could not read that location.', isSuccess: false);
        return;
      }
      if (!_pts.contains(target)) return;

      setState(() {
        target
          ..latLng = det.latLng
          ..placeId = s.placeId
          ..controller.text = s.mainText
          ..isCurrent = false;
      });

      _updateMapMarkers();
      _saveRecent(s);
      _placesSession = '';

      if (_pts.first.latLng != null && _pts.last.latLng != null) {
        _collapse();
        await _drawRoute();
      } else {
        _focusNextUnfilled();
      }
    } catch (_) {
      if (mounted) {
        showToastNotification(context: context, title: 'Network error', message: 'Failed to load place details.', isSuccess: false);
      }
    }
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

  void _addStop() {
    HapticFeedback.selectionClick();
    // user_logistics.php books a single pickup -> drop-off leg; extra stops
    // would be silently dropped (and not priced), so they are not offered.
    showToastNotification(
      context: context,
      title: 'One drop-off per request',
      message: 'Book a separate ${_kind.productName} request for each extra stop.',
      isSuccess: false,
    );
  }

  void _removeStop(int index) {
    if (index <= 0 || index >= _pts.length - 1) return;
    HapticFeedback.selectionClick();
    final removed = _pts[index];
    setState(() => _pts.removeAt(index));
    removed.controller.dispose();
    removed.focus.dispose();
    _updateMapMarkers();
    if (_pts.first.latLng != null && _pts.last.latLng != null) _drawRoute();
  }

  void _swap() {
    if (_pts.length < 2) return;
    HapticFeedback.selectionClick();
    final a = _pts.first, b = _pts.last;
    setState(() {
      final ll = a.latLng, pid = a.placeId, txt = a.controller.text, isCur = a.isCurrent;
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
    _updateMapMarkers();
    if (_pts.first.latLng != null && _pts.last.latLng != null) _drawRoute();
  }

  LogisticsKind get _kind => LogisticsKindX.tryParse(widget.rideType) ?? LogisticsKind.sendMe;

  Future<void> _triggerBookingSheet() async {
    final pickup = _pts.first.latLng, dest = _pts.last.latLng;
    if (pickup == null || dest == null || _sheetOpen || _routing) return;
    if (_calculatedDistanceKm <= 0.02) {
      showToastNotification(
        context: context,
        title: 'Check the route',
        message: 'Pickup and drop-off are the same place.',
        isSuccess: false,
      );
      return;
    }
    HapticFeedback.mediumImpact();
    _sheetOpen = true;
    String? bookedRideId;
    String? bookedOtp;
    try {
      await LogisticsBookingSheet.show(
        context,
        api: widget.api,
        userId: widget.userId,
        rideType: _kind.wire,
        pickup: pickup,
        pickupText: _pts.first.controller.text.trim(),
        dest: dest,
        destText: _pts.last.controller.text.trim(),
        distanceKm: _calculatedDistanceKm,
        walletBalance: widget.walletBalance,
        onSuccess: (String rideId, String? otp) {
          bookedRideId = rideId;
          bookedOtp = otp;
        },
      );
    } finally {
      _sheetOpen = false;
    }
    final String? rideId = bookedRideId;
    if (rideId == null || !mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => LogisticsTrackingPage(
          api: widget.api,
          userId: widget.userId,
          kind: _kind,
          rideId: rideId,
          deliveryOtp: bookedOtp,
          pickup: pickup,
          destination: dest,
          pickupText: _pts.first.controller.text.trim(),
          destinationText: _pts.last.controller.text.trim(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;
    final themeColor = _kind.brandColor;
    final mq = MediaQuery.of(context);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_sheetHeight == 0 && mounted) _scheduleMapPaddingUpdate();
    });

    final bool hasRoute = _pts.first.latLng != null && _pts.last.latLng != null;

    return Scaffold(
      extendBodyBehindAppBar: true,
      resizeToAvoidBottomInset: false,
      backgroundColor: theme.scaffoldBackgroundColor,

      // We do NOT use the Scaffold AppBar here because it intercepts touches meant for the AutoOverlay.
      body: Stack(
        children: [
          // 1. Isolated Map Layer
          Positioned.fill(
            child: _IsolatedLogisticsMapLayer(
              markersNotifier: _markersNotifier,
              polylinesNotifier: _polylinesNotifier,
              circlesNotifier: _circlesNotifier,
              initialCameraPosition: const CameraPosition(
                target: LatLng(6.5244, 3.3792),
                zoom: 12,
              ),
              padding: _mapPadding,
              isDark: isDark,
              onMapCreated: (c) => _mapController = c,
              onTap: (_) => _collapse(),
            ),
          ),

          // 2. Custom Floating Back Button (Hides when searching)
          if (!_expanded)
            Positioned(
              top: mq.padding.top + 8,
              left: 12,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => Navigator.pop(context),
                  borderRadius: BorderRadius.circular(999),
                  child: Ink(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark ? cs.surface : Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 10)],
                    ),
                    child: Icon(Icons.arrow_back_rounded, color: isDark ? Colors.white : Colors.black, size: 20),
                  ),
                ),
              ),
            ),

          // 3. Locate FAB (Hides when searching)
          if (!_expanded)
            Positioned(
              right: uiScale.inset(14),
              bottom: _sheetHeight + 20,
              child: FloatingActionButton(
                mini: true,
                backgroundColor: themeColor,
                onPressed: () async {
                  if (_currentPosition != null) {
                    final ll = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
                    await _mapController?.animateCamera(
                      CameraUpdate.newCameraPosition(CameraPosition(target: ll, zoom: 17, tilt: 45)),
                    );
                  } else {
                    await _fetchCurrentLocation(userTriggered: true);
                  }
                },
                child: const Icon(Icons.my_location, color: Colors.white),
              ),
            ),

          // 4. Bottom Route Sheet
          if (!_expanded)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: KeyedSubtree(
                key: _sheetKey,
                child: Container(
                  padding: EdgeInsets.fromLTRB(uiScale.inset(16), uiScale.inset(16), uiScale.inset(16), uiScale.inset(36)),
                  decoration: BoxDecoration(
                    color: isDark ? cs.surface : Colors.white,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(32))),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 30,
                        offset: const Offset(0, -10),
                      )
                    ],
                  ),
                  child: !hasRoute
                      ? RouteSheet(
                    bottomNavHeight: 0,
                    recentDestinations: _recents,
                    onSearchTap: () {
                      setState(() {
                        _activeIdx = _pts.length - 1;
                        _pts.last.focus.requestFocus();
                      });
                      _expand(); // Triggers overlay perfectly
                    },
                    onRecentTap: _selectSug,
                    sheetTitle: _kind.isDispatch ? 'Dispatch Routes' : 'Errand Routes',
                    sheetSubtitle: 'Enter pickup and destination to calculate fare.',
                  )
                      : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.straighten_rounded, size: 20, color: themeColor),
                          const SizedBox(width: 8),
                          Text(_routing ? 'Calculating…' : (_distanceText ?? ''), style: const TextStyle(fontWeight: FontWeight.w800)),
                          const Spacer(),
                          Text(_routeFailed ? 'Approximate distance' : (_durationText ?? ''), style: const TextStyle(fontWeight: FontWeight.w800)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: uiScale.inset(58),
                        child: ElevatedButton(
                          onPressed: _routing ? null : _triggerBookingSheet,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: themeColor,
                            foregroundColor: _kind.onBrandColor,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(18))),
                          ),
                          child: Text('Continue to Details', style: TextStyle(fontSize: uiScale.font(15), fontWeight: FontWeight.w900)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 5. Auto Overlay (Positioned.fill guarantees touch events)
          if (_expanded)
            Positioned.fill(
              child: FadeTransition(
                opacity: _overlayFadeAnim,
                child: AutoOverlay(
                  safeTop: mq.padding.top,
                  bottomPadding: MediaQuery.of(context).viewInsets.bottom,
                  autoStatus: _autoStatus,
                  autoError: _autoError,
                  isTyping: _isTyping,
                  activeIndex: _activeIdx,
                  points: _pts,
                  suggestions: _sugs,
                  recents: _recents,
                  hasGps: _currentPosition != null,
                  onUseCurrentPickup: _useCurrentAsPickup,
                  onTyping: _onTyping,
                  onFocused: _onFocused,
                  onSelectSuggestion: _selectSug,
                  fmtDistance: (m) => m < 1000 ? '$m m' : '${(m / 1000).toStringAsFixed(1)} km',
                  onAddStop: _addStop,
                  onRemoveStop: _removeStop,
                  onSwap: _swap,
                  onClose: _collapse,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Reusable Isolated Map Widget ──
class _IsolatedLogisticsMapLayer extends StatelessWidget {
  final ValueNotifier<Set<Marker>> markersNotifier;
  final ValueNotifier<Set<Polyline>> polylinesNotifier;
  final ValueNotifier<Set<Circle>> circlesNotifier;
  final CameraPosition initialCameraPosition;
  final EdgeInsets padding;
  final bool isDark;
  final void Function(GoogleMapController) onMapCreated;
  final void Function(LatLng) onTap;

  const _IsolatedLogisticsMapLayer({
    required this.markersNotifier,
    required this.polylinesNotifier,
    required this.circlesNotifier,
    required this.initialCameraPosition,
    required this.padding,
    required this.isDark,
    required this.onMapCreated,
    required this.onTap,
  });

  String? _getMapStyle() {
    if (!isDark) return null;
    return '''[
      {"elementType": "geometry", "stylers": [{"color": "#212121"}]},
      {"elementType": "labels.icon", "stylers": [{"visibility": "off"}]},
      {"elementType": "labels.text.fill", "stylers": [{"color": "#757575"}]},
      {"elementType": "labels.text.stroke", "stylers": [{"color": "#212121"}]},
      {"featureType": "administrative", "elementType": "geometry", "stylers": [{"color": "#757575"}]},
      {"featureType": "administrative.country", "elementType": "labels.text.fill", "stylers": [{"color": "#9e9e9e"}]},
      {"featureType": "administrative.land_parcel", "stylers": [{"visibility": "off"}]},
      {"featureType": "administrative.locality", "elementType": "labels.text.fill", "stylers": [{"color": "#bdbdbd"}]},
      {"featureType": "poi", "elementType": "labels.text.fill", "stylers": [{"color": "#757575"}]},
      {"featureType": "poi.park", "elementType": "geometry", "stylers": [{"color": "#181818"}]},
      {"featureType": "poi.park", "elementType": "labels.text.fill", "stylers": [{"color": "#616161"}]},
      {"featureType": "poi.park", "elementType": "labels.text.stroke", "stylers": [{"color": "#1b1b1b"}]},
      {"featureType": "road", "elementType": "geometry.fill", "stylers": [{"color": "#2c2c2c"}]},
      {"featureType": "road", "elementType": "labels.text.fill", "stylers": [{"color": "#8a8a8a"}]},
      {"featureType": "road.arterial", "elementType": "geometry", "stylers": [{"color": "#373737"}]},
      {"featureType": "road.highway", "elementType": "geometry", "stylers": [{"color": "#3c3c3c"}]},
      {"featureType": "road.highway.controlled_access", "elementType": "geometry", "stylers": [{"color": "#4e4e4e"}]},
      {"featureType": "road.local", "elementType": "labels.text.fill", "stylers": [{"color": "#616161"}]},
      {"featureType": "transit", "elementType": "labels.text.fill", "stylers": [{"color": "#757575"}]},
      {"featureType": "water", "elementType": "geometry", "stylers": [{"color": "#000000"}]},
      {"featureType": "water", "elementType": "labels.text.fill", "stylers": [{"color": "#3d3d3d"}]}
    ]''';
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<Set<Marker>>(
        valueListenable: markersNotifier,
        builder: (_, markers, __) => ValueListenableBuilder<Set<Polyline>>(
          valueListenable: polylinesNotifier,
          builder: (_, polylines, ___) => ValueListenableBuilder<Set<Circle>>(
            valueListenable: circlesNotifier,
            builder: (_, circles, ____) => GoogleMap(
              initialCameraPosition: initialCameraPosition,
              padding: padding,
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
              mapToolbarEnabled: false,
              rotateGesturesEnabled: false,
              tiltGesturesEnabled: false,
              buildingsEnabled: false,
              indoorViewEnabled: false,
              trafficEnabled: false,
              markers: markers,
              polylines: polylines,
              circles: circles,
              onMapCreated: (c) {
                if (isDark) c.setMapStyle(_getMapStyle());
                onMapCreated(c);
              },
              onTap: onTap,
            ),
          ),
        ),
      ),
    );
  }
}
