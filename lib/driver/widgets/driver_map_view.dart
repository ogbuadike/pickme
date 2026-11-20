// lib/driver/widgets/driver_map_view.dart
//
// The driver's map. Built once; everything that changes flows through
// ValueNotifiers so the GoogleMap platform view is never recreated and the
// rest of the page never rebuilds because of GPS.
//
//  * Own car: cached top-view bitmap, flat, bearing-rotated, interpolated
//    between fixes by a Ticker that only runs while there is motion to show.
//  * Route to pickup / drop-off via the Routes API, refetched only when the
//    target changes or the driver leaves the route; travelled part trimmed.
//  * Camera follows the car and yields as soon as the user touches the map;
//    [DriverMapController.recenter] resumes following.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../../api/url.dart';
import '../../screens/state/map_graphics_engine.dart';
import '../../services/driver_location_updater.dart';
import '../state/driver_models.dart';

/// Lets the page talk to the map without rebuilding it.
class DriverMapController {
  /// True while the camera is following the car.
  final ValueNotifier<bool> following = ValueNotifier<bool>(true);

  _DriverMapViewState? _state;

  void recenter() => _state?._recenter();

  /// Frame the whole job (car, pickup, destination).
  void showOverview() => _state?._fitOverview(holdFollow: const Duration(seconds: 6));

  void dispose() => following.dispose();
}

class DriverMapView extends StatefulWidget {
  final DriverMapController controller;
  final ValueListenable<DriverLocationFix?> fix;
  final ValueListenable<RideJob?> activeRide;
  final ValueListenable<EdgeInsets> padding;
  final LatLng fallbackTarget;

  const DriverMapView({
    super.key,
    required this.controller,
    required this.fix,
    required this.activeRide,
    required this.padding,
    this.fallbackTarget = const LatLng(6.458985, 7.548266),
  });

  @override
  State<DriverMapView> createState() => _DriverMapViewState();
}

class _DriverMapViewState extends State<DriverMapView> with SingleTickerProviderStateMixin {
  static const String _carAsset = 'assets/images/open_top_view_car.png';
  static const double _followZoom = 16.8;
  static const double _tripTilt = 45.0;
  static const Duration _markerFrame = Duration(milliseconds: 50); // ≤20 platform updates/s
  static const Duration _cameraGap = Duration(milliseconds: 900);
  static const double _offRouteM = 60.0;

  static Future<BitmapDescriptor>? _carIconFuture;
  static Future<List<BitmapDescriptor>>? _stopIconsFuture;

  GoogleMapController? _map;
  late final CameraPosition _initialCamera;
  final ValueNotifier<Set<Marker>> _markers = ValueNotifier<Set<Marker>>(const <Marker>{});
  final ValueNotifier<Set<Polyline>> _polylines = ValueNotifier<Set<Polyline>>(const <Polyline>{});

  BitmapDescriptor? _carIcon;
  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _dropIcon;
  Set<Marker> _stopMarkers = const <Marker>{};

  // Car interpolation.
  late final Ticker _ticker;
  LatLng? _animFrom;
  LatLng? _animTo;
  double _bearingFrom = 0;
  double _bearingTo = 0;
  Duration _animStart = Duration.zero;
  Duration _animLength = const Duration(milliseconds: 900);
  bool _animPending = false;
  LatLng? _shownPos;
  double _shownBearing = 0;
  DateTime _lastMarkerPush = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastFixTime;

  // Camera.
  int _pointersDown = 0;
  bool _cameraReady = false;
  double _zoom = _followZoom;
  DateTime _lastCameraMove = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _followHoldUntil;

  // Route.
  List<LatLng> _route = const <LatLng>[];
  int _routeCursor = 0;
  String? _routeTargetKey;
  DateTime _lastRouteFetch = DateTime.fromMillisecondsSinceEpoch(0);
  int _routeToken = 0;
  bool _routeLoading = false;
  final http.Client _http = http.Client();

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
    final f = widget.fix.value;
    _initialCamera = CameraPosition(target: f?.latLng ?? widget.fallbackTarget, zoom: f == null ? 14.5 : _followZoom);
    _ticker = createTicker(_onTick);
    widget.fix.addListener(_onFix);
    widget.activeRide.addListener(_onRideChanged);
    _loadIcons();
    // Inherited widgets (Theme) are not available until after initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onRideChanged();
      if (widget.fix.value != null) _onFix();
    });
  }

  @override
  void didUpdateWidget(covariant DriverMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fix != widget.fix) {
      oldWidget.fix.removeListener(_onFix);
      widget.fix.addListener(_onFix);
    }
    if (oldWidget.activeRide != widget.activeRide) {
      oldWidget.activeRide.removeListener(_onRideChanged);
      widget.activeRide.addListener(_onRideChanged);
    }
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller._state == this) oldWidget.controller._state = null;
      widget.controller._state = this;
    }
  }

  @override
  void dispose() {
    widget.fix.removeListener(_onFix);
    widget.activeRide.removeListener(_onRideChanged);
    if (widget.controller._state == this) widget.controller._state = null;
    _ticker.dispose();
    _routeToken++;
    _http.close();
    _markers.dispose();
    _polylines.dispose();
    _map?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Icons

  Future<void> _loadIcons() async {
    try {
      _carIconFuture ??= MapGraphicsEngine.assetToMarker(_carAsset, targetWidth: 96);
      _stopIconsFuture ??= Future.wait<BitmapDescriptor>([
        MapGraphicsEngine.createRingDotMarker(const Color(0xFF1A73E8)),
        MapGraphicsEngine.createRingDotMarker(const Color(0xFF00A651)),
      ]);
      final car = await _carIconFuture!;
      final stops = await _stopIconsFuture!;
      if (!mounted) return;
      _carIcon = car;
      _pickupIcon = stops[0];
      _dropIcon = stops[1];
      _rebuildStopMarkers();
      _pushMarkers(force: true);
    } catch (e) {
      _carIconFuture = null;
      _stopIconsFuture = null;
      debugPrint('DriverMapView: icon load failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Car marker interpolation

  void _onFix() {
    final f = widget.fix.value;
    if (f == null || !mounted) return;
    final target = f.latLng;
    final from = _shownPos;

    if (from == null || _distance(from, target) > 300) {
      // First fix or a jump: snap, no animation.
      _ticker.stop();
      _shownPos = target;
      _shownBearing = f.bearing;
      _animFrom = _animTo = target;
      _bearingFrom = _bearingTo = f.bearing;
      _pushMarkers(force: true);
    } else {
      final last = _lastFixTime;
      final gap = last == null ? const Duration(milliseconds: 900) : f.time.difference(last);
      _animFrom = from;
      _animTo = target;
      _bearingFrom = _shownBearing;
      _bearingTo = f.bearing;
      _animLength = Duration(milliseconds: gap.inMilliseconds.clamp(300, 1500));
      _animPending = true;
      if (!_ticker.isActive) {
        _ticker.start();
      }
    }
    _lastFixTime = f.time;
    _followCamera(f);
    _trimRoute(target);
    _maybeFetchRoute();
  }

  void _onTick(Duration elapsed) {
    if (_animPending) {
      _animPending = false;
      _animStart = elapsed;
    }
    final from = _animFrom, to = _animTo;
    if (from == null || to == null) {
      _ticker.stop();
      return;
    }
    final total = _animLength.inMicroseconds;
    final t = total <= 0 ? 1.0 : ((elapsed - _animStart).inMicroseconds / total).clamp(0.0, 1.0);
    _shownPos = LatLng(
      from.latitude + (to.latitude - from.latitude) * t,
      from.longitude + (to.longitude - from.longitude) * t,
    );
    _shownBearing = _lerpAngle(_bearingFrom, _bearingTo, Curves.easeOut.transform(t));
    _pushMarkers(force: t >= 1.0);
    if (t >= 1.0) _ticker.stop();
  }

  void _pushMarkers({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastMarkerPush) < _markerFrame) return;
    _lastMarkerPush = now;
    final pos = _shownPos;
    final icon = _carIcon;
    final next = <Marker>{..._stopMarkers};
    if (pos != null && icon != null) {
      next.add(Marker(
        markerId: const MarkerId('driver_self'),
        position: pos,
        icon: icon,
        rotation: _shownBearing,
        anchor: const Offset(0.5, 0.5),
        flat: true,
        zIndexInt: 999,
        consumeTapEvents: true,
      ));
    }
    _markers.value = next;
  }

  void _rebuildStopMarkers() {
    final ride = widget.activeRide.value;
    final out = <Marker>{};
    if (ride != null) {
      final status = ride.rideStatus;
      if (status.isBeforePickup && ride.hasPickupCoords && _pickupIcon != null) {
        out.add(Marker(
          markerId: const MarkerId('pickup'),
          position: LatLng(ride.pickupLat, ride.pickupLng),
          icon: _pickupIcon!,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 35,
          infoWindow: InfoWindow(title: 'Pickup', snippet: ride.pickupText),
        ));
      }
      if (ride.hasDestCoords && _dropIcon != null) {
        out.add(Marker(
          markerId: const MarkerId('destination'),
          position: LatLng(ride.destLat, ride.destLng),
          icon: _dropIcon!,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 35,
          infoWindow: InfoWindow(title: 'Drop-off', snippet: ride.destText),
        ));
      }
    }
    _stopMarkers = out;
  }

  // ---------------------------------------------------------------------------
  // Ride changes

  void _onRideChanged() {
    if (!mounted) return;
    _rebuildStopMarkers();
    _pushMarkers(force: true);
    final key = _targetKey();
    if (key != _routeTargetKey) {
      _routeTargetKey = key;
      _route = const <LatLng>[];
      _routeCursor = 0;
      _routeToken++; // drop any in-flight fetch for the old target
      _routeLoading = false;
      _lastRouteFetch = DateTime.fromMillisecondsSinceEpoch(0);
      _pushRoute();
      _maybeFetchRoute();
      if (key != null) _fitOverview(holdFollow: const Duration(seconds: 5));
    }
  }

  LatLng? _target() {
    final ride = widget.activeRide.value;
    if (ride == null) return null;
    if (ride.rideStatus.isOnTrip) return ride.hasDestCoords ? LatLng(ride.destLat, ride.destLng) : null;
    if (ride.rideStatus.isBeforePickup) return ride.hasPickupCoords ? LatLng(ride.pickupLat, ride.pickupLng) : null;
    return null;
  }

  String? _targetKey() {
    final ride = widget.activeRide.value;
    final t = _target();
    if (ride == null || t == null) return null;
    return '${ride.id}:${ride.rideStatus.isOnTrip ? 'dest' : 'pickup'}';
  }

  // ---------------------------------------------------------------------------
  // Route

  void _maybeFetchRoute() {
    final target = _target();
    final origin = widget.fix.value?.latLng;
    if (target == null || origin == null || _routeLoading) return;
    final now = DateTime.now();
    final sinceLast = now.difference(_lastRouteFetch);
    final needs = _route.isEmpty
        ? sinceLast > const Duration(seconds: 10)
        : (_distanceToRoute(origin) > _offRouteM && sinceLast > const Duration(seconds: 15));
    if (!needs) return;
    unawaited(_fetchRoute(origin, target));
  }

  Future<void> _fetchRoute(LatLng origin, LatLng dest) async {
    final token = ++_routeToken;
    _routeLoading = true;
    _lastRouteFetch = DateTime.now();
    try {
      final res = await _http
          .post(
            Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes'),
            headers: const {
              'Content-Type': 'application/json',
              'X-Goog-Api-Key': ApiConstants.kGoogleApiKey,
              'X-Goog-FieldMask': 'routes.polyline.encodedPolyline',
            },
            body: jsonEncode({
              'origin': {'location': {'latLng': {'latitude': origin.latitude, 'longitude': origin.longitude}}},
              'destination': {'location': {'latLng': {'latitude': dest.latitude, 'longitude': dest.longitude}}},
              'travelMode': 'DRIVE',
              'routingPreference': 'TRAFFIC_AWARE',
              'polylineQuality': 'OVERVIEW',
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (!mounted || token != _routeToken || res.statusCode != 200) return;
      final decoded = jsonDecode(res.body);
      final routes = decoded is Map ? decoded['routes'] : null;
      if (routes is! List || routes.isEmpty) return;
      final first = routes.first;
      final encoded = first is Map && first['polyline'] is Map ? '${first['polyline']['encodedPolyline'] ?? ''}' : '';
      if (encoded.isEmpty) return;
      _route = _decodePolyline(encoded);
      _routeCursor = 0;
      final pos = _shownPos;
      if (pos != null) _trimRoute(pos, push: false);
      _pushRoute();
    } catch (_) {
      // Keep the straight-line fallback; retried on the next fix after the gap.
    } finally {
      if (token == _routeToken) _routeLoading = false;
    }
  }

  void _trimRoute(LatLng pos, {bool push = true}) {
    if (_route.length < 2) {
      if (push && _target() != null) _pushRoute(); // straight-line fallback follows the car
      return;
    }
    // Search forward from the cursor (cheap), fall back to a full scan.
    var best = _routeCursor;
    var bestD = double.infinity;
    final end = math.min(_route.length, _routeCursor + 60);
    for (var i = _routeCursor; i < end; i++) {
      final d = _distance(pos, _route[i]);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (bestD > _offRouteM) {
      for (var i = 0; i < _route.length; i++) {
        final d = _distance(pos, _route[i]);
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
    }
    if (best != _routeCursor) {
      _routeCursor = best;
      if (push) _pushRoute();
    }
  }

  void _pushRoute() {
    final target = _target();
    if (target == null) {
      if (_polylines.value.isNotEmpty) _polylines.value = const <Polyline>{};
      return;
    }
    final car = _shownPos ?? widget.fix.value?.latLng;
    final List<LatLng> points;
    if (_route.length >= 2) {
      points = <LatLng>[if (car != null) car, ..._route.skip(_routeCursor + 1)];
      if (points.length < 2) points.add(target);
    } else {
      points = <LatLng>[if (car != null) car, target];
    }
    if (points.length < 2) {
      _polylines.value = const <Polyline>{};
      return;
    }
    final color = Theme.of(context).colorScheme.primary;
    _polylines.value = <Polyline>{
      Polyline(
        polylineId: const PolylineId('route_halo'),
        points: points,
        width: 9,
        color: Colors.white.withValues(alpha: 0.9),
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        zIndex: 1,
      ),
      Polyline(
        polylineId: const PolylineId('route_line'),
        points: points,
        width: 5,
        color: color,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        zIndex: 2,
        patterns: _route.length >= 2 ? const <PatternItem>[] : <PatternItem>[PatternItem.dash(18), PatternItem.gap(10)],
      ),
    };
  }

  double _distanceToRoute(LatLng p) {
    if (_route.isEmpty) return double.infinity;
    var best = double.infinity;
    final from = math.max(0, _routeCursor - 5);
    final to = math.min(_route.length, _routeCursor + 60);
    for (var i = from; i < to; i++) {
      final d = _distance(p, _route[i]);
      if (d < best) best = d;
    }
    return best;
  }

  // ---------------------------------------------------------------------------
  // Camera

  bool get _following => widget.controller.following.value;

  void _followCamera(DriverLocationFix f) {
    final map = _map;
    if (map == null || !_cameraReady || !_following || _pointersDown > 0) return;
    final now = DateTime.now();
    final hold = _followHoldUntil;
    if (hold != null && now.isBefore(hold)) return;
    if (now.difference(_lastCameraMove) < _cameraGap) return;
    _lastCameraMove = now;
    final onTrip = widget.activeRide.value != null;
    unawaited(map.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(
      target: f.latLng,
      zoom: _zoom,
      bearing: onTrip && f.isMoving ? f.bearing : 0,
      tilt: onTrip ? _tripTilt : 0,
    ))).catchError((Object _) {}));
  }

  void _recenter() {
    widget.controller.following.value = true;
    _followHoldUntil = null;
    _zoom = _followZoom;
    _lastCameraMove = DateTime.fromMillisecondsSinceEpoch(0);
    final f = widget.fix.value;
    if (f != null) _followCamera(f);
  }

  void _fitOverview({Duration? holdFollow}) {
    final map = _map;
    if (map == null || !_cameraReady || _pointersDown > 0) return;
    final ride = widget.activeRide.value;
    final pts = <LatLng>[
      if (widget.fix.value != null) widget.fix.value!.latLng,
      if (ride != null && ride.rideStatus.isBeforePickup && ride.hasPickupCoords) LatLng(ride.pickupLat, ride.pickupLng),
      if (ride != null && ride.hasDestCoords) LatLng(ride.destLat, ride.destLng),
    ];
    if (pts.length < 2) return;
    var minLat = pts.first.latitude, maxLat = minLat, minLng = pts.first.longitude, maxLng = minLng;
    for (final p in pts.skip(1)) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    if (maxLat - minLat < 0.002) {
      minLat -= 0.001;
      maxLat += 0.001;
    }
    if (maxLng - minLng < 0.002) {
      minLng -= 0.001;
      maxLng += 0.001;
    }
    if (holdFollow != null) _followHoldUntil = DateTime.now().add(holdFollow);
    _lastCameraMove = DateTime.now();
    unawaited(map
        .animateCamera(CameraUpdate.newLatLngBounds(
          LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)),
          64,
        ))
        .catchError((Object _) {}));
  }

  void _onMapCreated(GoogleMapController c) {
    _map = c;
    // Let the first layout (with padding) settle before driving the camera.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _cameraReady = true;
      final f = widget.fix.value;
      if (widget.activeRide.value != null) {
        _fitOverview(holdFollow: const Duration(seconds: 5));
      } else if (f != null) {
        unawaited(c.moveCamera(CameraUpdate.newLatLngZoom(f.latLng, _followZoom)).catchError((Object _) {}));
      }
    });
  }

  void _onCameraMoveStarted() {
    // Camera moving while a finger is down => user gesture: stop following.
    if (_pointersDown > 0 && _following) widget.controller.following.value = false;
  }

  void _onCameraMove(CameraPosition p) {
    if (_pointersDown > 0) _zoom = p.zoom.clamp(12.0, 19.0);
  }

  // ---------------------------------------------------------------------------

  static double _distance(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final la1 = a.latitude * math.pi / 180, la2 = b.latitude * math.pi / 180;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) + math.cos(la1) * math.cos(la2) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
  }

  static double _lerpAngle(double a, double b, double t) {
    var d = (b - a) % 360;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    return (a + d * t + 360) % 360;
  }

  static List<LatLng> _decodePolyline(String enc) {
    final out = <LatLng>[];
    var idx = 0, lat = 0, lng = 0;
    while (idx < enc.length) {
      var shift = 0, result = 0, b = 0;
      do {
        b = enc.codeUnitAt(idx++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && idx < enc.length);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      shift = 0;
      result = 0;
      do {
        if (idx >= enc.length) return out;
        b = enc.codeUnitAt(idx++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      out.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: Listener(
        onPointerDown: (_) => _pointersDown++,
        onPointerUp: (_) => _pointersDown = math.max(0, _pointersDown - 1),
        onPointerCancel: (_) => _pointersDown = math.max(0, _pointersDown - 1),
        child: ListenableBuilder(
          listenable: Listenable.merge([_markers, _polylines, widget.padding]),
          builder: (context, _) => GoogleMap(
            initialCameraPosition: _initialCamera,
            style: isDark ? _darkMapStyle : null,
            padding: widget.padding.value,
            markers: _markers.value,
            polylines: _polylines.value,
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: false,
            mapToolbarEnabled: false,
            rotateGesturesEnabled: true,
            tiltGesturesEnabled: true,
            buildingsEnabled: false,
            indoorViewEnabled: false,
            trafficEnabled: false,
            onMapCreated: _onMapCreated,
            onCameraMoveStarted: _onCameraMoveStarted,
            onCameraMove: _onCameraMove,
          ),
        ),
      ),
    );
  }
}

const String _darkMapStyle =
    '''[{"elementType":"geometry","stylers":[{"color":"#212121"}]},{"elementType":"labels.icon","stylers":[{"visibility":"off"}]},{"elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},{"elementType":"labels.text.stroke","stylers":[{"color":"#212121"}]},{"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#757575"}]},{"featureType":"administrative.country","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]},{"featureType":"administrative.land_parcel","stylers":[{"visibility":"off"}]},{"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#bdbdbd"}]},{"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},{"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#181818"}]},{"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},{"featureType":"poi.park","elementType":"labels.text.stroke","stylers":[{"color":"#1b1b1b"}]},{"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#2c2c2c"}]},{"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#8a8a8a"}]},{"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#373737"}]},{"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3c3c3c"}]},{"featureType":"road.highway.controlled_access","elementType":"geometry","stylers":[{"color":"#4e4e4e"}]},{"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},{"featureType":"transit","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},{"featureType":"water","elementType":"geometry","stylers":[{"color":"#000000"}]},{"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#3d3d3d"}]}]''';
