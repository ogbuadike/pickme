import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../api/url.dart';
import '../services/booking_controller.dart';
import '../themes/app_theme.dart';

enum TripNavPhase {
  driverToPickup,
  waitingPickup,
  enRoute,
  completed,
  cancelled,
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
  final TripNavPhase initialPhase;

  final Stream<dynamic>? bookingUpdates;
  final Future<void> Function()? onStartTrip;
  final Future<void> Function()? onCancelTrip;

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
    this.initialPhase = TripNavPhase.driverToPickup,
    this.bookingUpdates,
    this.onStartTrip,
    this.onCancelTrip,
  });
}

class TripNavigationPage extends StatefulWidget {
  final TripNavigationArgs args;

  const TripNavigationPage({
    super.key,
    required this.args,
  });

  @override
  State<TripNavigationPage> createState() => _TripNavigationPageState();
}

class _TripNavigationPageState extends State<TripNavigationPage> {
  static const double _arrivalMeters = 35.0;
  static const Duration _tickEvery = Duration(seconds: 2);

  GoogleMapController? _map;
  StreamSubscription<dynamic>? _bookingSub;
  Timer? _tickTimer;

  final Set<Marker> _markers = <Marker>{};
  final Set<Polyline> _polylines = <Polyline>{};

  LatLng? _driverLL;
  LatLng? _lastDriverLL;
  double _driverHeading = 0.0;

  TripNavPhase _phase = TripNavPhase.driverToPickup;
  int _activeStopIndex = 0;

  String? _distanceText;
  String? _durationText;

  bool _busyRoute = false;
  bool _busyStart = false;
  bool _busyCancel = false;
  bool _didInitialFit = false;

  DateTime _lastRouteAt = DateTime.fromMillisecondsSinceEpoch(0);

  List<LatLng> get _allTargets => <LatLng>[
    ...widget.args.dropOffs,
    widget.args.destination,
  ];

  List<String> get _allTargetTexts => <String>[
    ...widget.args.dropOffTexts,
    widget.args.destinationText,
  ];

  LatLng get _currentTarget {
    if (_phase == TripNavPhase.driverToPickup ||
        _phase == TripNavPhase.waitingPickup) {
      return widget.args.pickup;
    }

    if (_allTargets.isEmpty) return widget.args.destination;
    final int idx = _activeStopIndex.clamp(0, _allTargets.length - 1);
    return _allTargets[idx];
  }

  String get _currentTargetText {
    if (_phase == TripNavPhase.driverToPickup ||
        _phase == TripNavPhase.waitingPickup) {
      return widget.args.originText;
    }

    if (_allTargetTexts.isEmpty) return widget.args.destinationText;
    final int idx = _activeStopIndex.clamp(0, _allTargetTexts.length - 1);
    return _allTargetTexts[idx];
  }

  @override
  void initState() {
    super.initState();
    _driverLL = widget.args.initialDriverLocation;
    _phase = widget.args.initialPhase;

    _syncMarkers();
    _listenBooking();

    _tickTimer = Timer.periodic(_tickEvery, (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick(force: true));
  }

  @override
  void dispose() {
    _bookingSub?.cancel();
    _tickTimer?.cancel();
    try {
      _map?.dispose();
    } catch (_) {}
    super.dispose();
  }

  void _listenBooking() {
    final Stream<dynamic>? stream = widget.args.bookingUpdates;
    if (stream == null) return;

    _bookingSub?.cancel();
    _bookingSub = stream.listen(
          (dynamic event) {
        _applyBookingUpdate(event);
      },
      onError: (_) {},
    );
  }

  void _applyBookingUpdate(dynamic event) {
    final Map<String, dynamic> payload = _eventMap(event);

    final LatLng? ll = _coerceDriverLL(payload, event);
    if (ll != null) {
      _lastDriverLL = _driverLL;
      _driverLL = ll;
    }

    final double? heading = _coerceHeading(payload, event);
    if (heading != null) {
      _driverHeading = heading;
    }

    final TripNavPhase? nextPhase = _coercePhase(payload, event);
    if (nextPhase != null) {
      _phase = nextPhase;
    }

    final int? stopIndex = _coerceStopIndex(payload, event);
    if (stopIndex != null && _allTargets.isNotEmpty) {
      _activeStopIndex = stopIndex.clamp(0, _allTargets.length - 1);
    }

    if (!mounted) return;
    setState(() {
      _syncMarkers();
    });
  }

  Map<String, dynamic> _eventMap(dynamic event) {
    if (event is BookingUpdate) {
      return <String, dynamic>{
        'booking_status_enum': event.status.name,
        ...event.data,
      };
    }

    if (event is Map<String, dynamic>) return event;
    if (event is Map) return event.cast<String, dynamic>();

    try {
      final dynamic data = event.data;
      if (data is Map<String, dynamic>) {
        return <String, dynamic>{...data};
      }
      if (data is Map) {
        return data.cast<String, dynamic>();
      }
    } catch (_) {}

    return <String, dynamic>{};
  }

  Future<void> _tick({bool force = false}) async {
    if (!mounted) return;

    final LatLng? driver = _driverLL;
    if (driver == null) {
      if (mounted) setState(() {});
      return;
    }

    if (_phase == TripNavPhase.driverToPickup) {
      final double meters = _haversine(driver, widget.args.pickup);
      if (meters <= _arrivalMeters) {
        _phase = TripNavPhase.waitingPickup;
      }
    } else if (_phase == TripNavPhase.enRoute) {
      final double meters = _haversine(driver, _currentTarget);
      if (meters <= _arrivalMeters) {
        if (_activeStopIndex < _allTargets.length - 1) {
          _activeStopIndex += 1;
        } else {
          _phase = TripNavPhase.completed;
        }
      }
    }

    _syncMarkers();
    await _rebuildRoute(force: force);
    await _followDriverCamera();

    if (!mounted) return;
    setState(() {});
  }

  void _syncMarkers() {
    final Set<Marker> next = <Marker>{
      Marker(
        markerId: const MarkerId('pickup'),
        position: widget.args.pickup,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: InfoWindow(
          title: 'Pickup',
          snippet: widget.args.originText,
        ),
      ),
      Marker(
        markerId: const MarkerId('destination'),
        position: widget.args.destination,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: InfoWindow(
          title: 'Destination',
          snippet: widget.args.destinationText,
        ),
      ),
    };

    for (int i = 0; i < widget.args.dropOffs.length; i++) {
      next.add(
        Marker(
          markerId: MarkerId('drop_$i'),
          position: widget.args.dropOffs[i],
          icon:
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          infoWindow: InfoWindow(
            title: 'Drop-off ${i + 1}',
            snippet: i < widget.args.dropOffTexts.length
                ? widget.args.dropOffTexts[i]
                : 'Stop ${i + 1}',
          ),
        ),
      );
    }

    if (_driverLL != null) {
      next.add(
        Marker(
          markerId: const MarkerId('driver'),
          position: _driverLL!,
          icon:
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
          anchor: const Offset(0.5, 0.5),
          flat: true,
          rotation: _driverRotation(),
          zIndex: 50,
          infoWindow: InfoWindow(
            title: widget.args.driverName ?? 'Driver',
            snippet:
            '${widget.args.vehicleType ?? 'Car'}${(widget.args.carPlate ?? '').trim().isNotEmpty ? ' • ${widget.args.carPlate!.trim()}' : ''}',
          ),
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
    if (!force && now.difference(_lastRouteAt) < const Duration(seconds: 2)) {
      return;
    }
    if (_driverLL == null) return;
    if (_phase == TripNavPhase.completed || _phase == TripNavPhase.cancelled) {
      return;
    }

    _busyRoute = true;
    _lastRouteAt = now;

    try {
      final _RouteResult? route = await _computeRoute(_driverLL!, _currentTarget);
      if (route == null || route.points.isEmpty) return;

      _distanceText = _fmtDistance(route.distanceMeters);
      _durationText = _fmtDuration(route.durationSeconds);

      _polylines
        ..clear()
        ..add(
          Polyline(
            polylineId: const PolylineId('nav_halo'),
            points: route.points,
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
            points: route.points,
            color: _phase == TripNavPhase.enRoute
                ? const Color(0xFF1A73E8)
                : const Color(0xFF7B1FA2),
            width: 6,
            geodesic: true,
            jointType: JointType.round,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ),
        );

      if (_map != null && !_didInitialFit) {
        _didInitialFit = true;
        final LatLngBounds bounds = _boundsFrom(<LatLng>[_driverLL!, _currentTarget]);
        try {
          await _map!.animateCamera(
            CameraUpdate.newLatLngBounds(bounds, 90),
          );
        } catch (_) {}
      }
    } finally {
      _busyRoute = false;
    }
  }

  Future<void> _followDriverCamera() async {
    if (_map == null || _driverLL == null) return;

    final double bearing = _driverRotation();
    try {
      await _map!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _driverLL!,
            zoom: _phase == TripNavPhase.enRoute ? 17.4 : 16.8,
            tilt: _phase == TripNavPhase.enRoute ? 58 : 44,
            bearing: bearing,
          ),
        ),
      );
    } catch (_) {}
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
    if (_busyStart) return;

    setState(() {
      _busyStart = true;
    });

    try {
      if (widget.args.onStartTrip != null) {
        await widget.args.onStartTrip!.call();
      }

      if (!mounted) return;
      setState(() {
        _phase = TripNavPhase.enRoute;
      });

      await _tick(force: true);
    } finally {
      if (!mounted) return;
      setState(() {
        _busyStart = false;
      });
    }
  }

  Future<void> _cancelTripPressed() async {
    if (_busyCancel) return;

    setState(() {
      _busyCancel = true;
    });

    try {
      if (widget.args.onCancelTrip != null) {
        await widget.args.onCancelTrip!.call();
      }

      if (!mounted) return;
      setState(() {
        _phase = TripNavPhase.cancelled;
      });

      Navigator.of(context).maybePop();
    } finally {
      if (!mounted) return;
      setState(() {
        _busyCancel = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: _driverLL ?? widget.args.pickup,
                zoom: 15.5,
              ),
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
              mapToolbarEnabled: false,
              rotateGesturesEnabled: true,
              tiltGesturesEnabled: true,
              padding: const EdgeInsets.only(top: 88, bottom: 250),
              markers: _markers,
              polylines: _polylines,
              onMapCreated: (GoogleMapController c) {
                _map = c;
                _tick(force: true);
              },
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: _TopGlassBar(
              title: _phaseTitle,
              subtitle: _phaseSubtitle,
              onBack: () => Navigator.of(context).maybePop(),
            ),
          ),
          DraggableScrollableSheet(
            initialChildSize: 0.28,
            minChildSize: 0.24,
            maxChildSize: 0.58,
            builder: (BuildContext context, ScrollController controller) {
              return Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withOpacity(0.22),
                      blurRadius: 24,
                      offset: const Offset(0, -8),
                    ),
                  ],
                ),
                child: Column(
                  children: <Widget>[
                    const SizedBox(height: 10),
                    Container(
                      width: 58,
                      height: 6,
                      decoration: BoxDecoration(
                        color: cs.onSurface.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView(
                        controller: controller,
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
                        children: <Widget>[
                          _PhaseCard(
                            phase: _phase,
                            driverName: widget.args.driverName ?? 'Driver',
                            vehicleType: widget.args.vehicleType ?? 'Car',
                            carPlate: widget.args.carPlate ?? '',
                            rating: widget.args.rating ?? 0,
                            distanceText: _distanceText ?? '—',
                            durationText: _durationText ?? '—',
                          ),
                          const SizedBox(height: 12),
                          _RouteCard(
                            from: widget.args.originText,
                            to: widget.args.destinationText,
                            currentTarget: _currentTargetText,
                            dropOffTexts: widget.args.dropOffTexts,
                            activeStopIndex: _activeStopIndex,
                            phase: _phase,
                          ),
                          const SizedBox(height: 12),
                          _MetaCard(
                            userId: widget.args.userId,
                            driverId: widget.args.driverId,
                            tripId: widget.args.tripId,
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: <Widget>[
                              if (_phase == TripNavPhase.waitingPickup)
                                Expanded(
                                  child: SizedBox(
                                    height: 52,
                                    child: ElevatedButton(
                                      onPressed:
                                      _busyStart ? null : _startTripPressed,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.primary,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                          BorderRadius.circular(18),
                                        ),
                                        elevation: 0,
                                      ),
                                      child: _busyStart
                                          ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          valueColor:
                                          AlwaysStoppedAnimation<
                                              Color>(Colors.white),
                                        ),
                                      )
                                          : const Text(
                                        'Start Trip',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              if (_phase == TripNavPhase.waitingPickup)
                                const SizedBox(width: 10),
                              Expanded(
                                child: SizedBox(
                                  height: 52,
                                  child: OutlinedButton(
                                    onPressed:
                                    _busyCancel ? null : _cancelTripPressed,
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: cs.onSurface,
                                      side: BorderSide(
                                        color: cs.onSurface.withOpacity(0.12),
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                    ),
                                    child: _busyCancel
                                        ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                      ),
                                    )
                                        : Text(
                                      _phase == TripNavPhase.completed
                                          ? 'Close'
                                          : 'Close Navigation',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  String get _phaseTitle {
    switch (_phase) {
      case TripNavPhase.driverToPickup:
        return 'Driver approaching pickup';
      case TripNavPhase.waitingPickup:
        return 'Driver arrived';
      case TripNavPhase.enRoute:
        return 'Trip in progress';
      case TripNavPhase.completed:
        return 'Trip completed';
      case TripNavPhase.cancelled:
        return 'Trip cancelled';
    }
  }

  String get _phaseSubtitle {
    switch (_phase) {
      case TripNavPhase.driverToPickup:
        return 'Live driver position refreshes every 2 seconds';
      case TripNavPhase.waitingPickup:
        return 'You can safely start the trip now';
      case TripNavPhase.enRoute:
        return 'Following driver to the next stop or destination';
      case TripNavPhase.completed:
        return 'Ride has ended';
      case TripNavPhase.cancelled:
        return 'Ride was cancelled';
    }
  }

  TripNavPhase? _coercePhase(Map<String, dynamic> payload, dynamic rawEvent) {
    if (rawEvent is BookingUpdate) {
      switch (rawEvent.status) {
        case BookingStatus.searching:
        case BookingStatus.driverAssigned:
        case BookingStatus.driverArriving:
          break;
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

    String raw = '';

    raw = _string(
      payload['phase'] ??
          payload['status'] ??
          payload['state'] ??
          payload['ride_status'] ??
          (payload['ride'] is Map ? (payload['ride'] as Map)['status'] : null),
    ).toLowerCase();

    if (raw.isEmpty) return null;

    if (raw == 'searching') return TripNavPhase.driverToPickup;
    if (raw == 'driver_assigned') return TripNavPhase.driverToPickup;
    if (raw == 'enroute_pickup') return TripNavPhase.driverToPickup;
    if (raw == 'arrived_pickup') return TripNavPhase.waitingPickup;
    if (raw == 'in_ride' || raw == 'on_trip' || raw == 'in_progress') {
      return TripNavPhase.enRoute;
    }
    if (raw == 'completed' || raw == 'done' || raw == 'finished') {
      return TripNavPhase.completed;
    }
    if (raw == 'canceled' || raw == 'cancelled') {
      return TripNavPhase.cancelled;
    }

    if (raw.contains('arrived')) return TripNavPhase.waitingPickup;
    if (raw.contains('in_ride') ||
        raw.contains('on_trip') ||
        raw.contains('progress') ||
        raw.contains('riding')) {
      return TripNavPhase.enRoute;
    }
    if (raw.contains('completed') ||
        raw.contains('done') ||
        raw.contains('finished')) {
      return TripNavPhase.completed;
    }
    if (raw.contains('cancel')) return TripNavPhase.cancelled;
    if (raw.contains('pickup') || raw.contains('assigned')) {
      return TripNavPhase.driverToPickup;
    }

    return null;
  }

  int? _coerceStopIndex(Map<String, dynamic> payload, dynamic rawEvent) {
    final dynamic top = payload['stop_index'] ??
        payload['waypoint_index'] ??
        payload['active_stop_index'];

    final int? direct = _toInt(top);
    if (direct != null) return direct;

    if (payload['ride'] is Map) {
      final Map<dynamic, dynamic> ride = payload['ride'] as Map<dynamic, dynamic>;
      final int? nested = _toInt(
        ride['stop_index'] ?? ride['waypoint_index'] ?? ride['active_stop_index'],
      );
      if (nested != null) return nested;
    }

    try {
      final dynamic v =
          rawEvent.stopIndex ?? rawEvent.waypointIndex ?? rawEvent.activeStopIndex;
      return _toInt(v);
    } catch (_) {}

    return null;
  }

  LatLng? _coerceDriverLL(Map<String, dynamic> payload, dynamic rawEvent) {
    final double? flatLat = _toDouble(
      payload['driverLat'] ??
          payload['lat'] ??
          payload['latitude'] ??
          payload['driver_lat'],
    );
    final double? flatLng = _toDouble(
      payload['driverLng'] ??
          payload['lng'] ??
          payload['longitude'] ??
          payload['driver_lng'],
    );

    if (flatLat != null && flatLng != null) {
      return LatLng(flatLat, flatLng);
    }

    final dynamic driver = payload['driver'] ??
        payload['location'] ??
        payload['driverLocation'];

    if (driver is Map) {
      final double? la = _toDouble(driver['lat'] ?? driver['latitude']);
      final double? lo = _toDouble(driver['lng'] ?? driver['longitude']);
      if (la != null && lo != null) {
        return LatLng(la, lo);
      }
    }

    if (payload['ride'] is Map) {
      final Map<dynamic, dynamic> ride = payload['ride'] as Map<dynamic, dynamic>;
      final double? la = _toDouble(
        ride['driver_lat'] ?? ride['lat'] ?? ride['latitude'],
      );
      final double? lo = _toDouble(
        ride['driver_lng'] ?? ride['lng'] ?? ride['longitude'],
      );
      if (la != null && lo != null) {
        return LatLng(la, lo);
      }
    }

    try {
      final double? la =
      _toDouble(rawEvent.driverLat ?? rawEvent.lat ?? rawEvent.latitude);
      final double? lo =
      _toDouble(rawEvent.driverLng ?? rawEvent.lng ?? rawEvent.longitude);
      if (la != null && lo != null) {
        return LatLng(la, lo);
      }
    } catch (_) {}

    try {
      final dynamic d = rawEvent.driver ?? rawEvent.location ?? rawEvent.driverLocation;
      if (d != null) {
        final double? la = _toDouble(d.lat ?? d.latitude);
        final double? lo = _toDouble(d.lng ?? d.longitude);
        if (la != null && lo != null) {
          return LatLng(la, lo);
        }
      }
    } catch (_) {}

    return null;
  }

  double? _coerceHeading(Map<String, dynamic> payload, dynamic rawEvent) {
    final double? top = _toDouble(
      payload['heading'] ??
          payload['bearing'] ??
          payload['driver_heading'] ??
          payload['driverHeading'],
    );
    if (top != null) return top;

    final dynamic driver = payload['driver'];
    if (driver is Map) {
      final double? nested = _toDouble(driver['heading'] ?? driver['bearing']);
      if (nested != null) return nested;
    }

    try {
      final double? direct = _toDouble(
        rawEvent.heading ?? rawEvent.bearing ?? rawEvent.driverHeading,
      );
      if (direct != null) return direct;
    } catch (_) {}

    return null;
  }

  String _string(dynamic v, [String fallback = '']) {
    if (v == null) return fallback;
    final String s = v.toString().trim();
    return s.isEmpty ? fallback : s;
  }

  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim());
  }

  int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString().trim());
  }

  Future<_RouteResult?> _computeRoute(LatLng origin, LatLng destination) async {
    final Uri url = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');

    final Map<String, dynamic> body = <String, dynamic>{
      'origin': <String, dynamic>{
        'location': <String, dynamic>{
          'latLng': <String, double>{
            'latitude': origin.latitude,
            'longitude': origin.longitude,
          },
        },
      },
      'destination': <String, dynamic>{
        'location': <String, dynamic>{
          'latLng': <String, double>{
            'latitude': destination.latitude,
            'longitude': destination.longitude,
          },
        },
      },
      'travelMode': 'DRIVE',
      'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
      'computeAlternativeRoutes': false,
      'units': 'METRIC',
      'polylineQuality': 'HIGH',
    };

    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': ApiConstants.kGoogleApiKey,
      'X-Goog-FieldMask':
      'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline',
    };

    try {
      final http.Response res = await http
          .post(url, headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return null;

      final Map<String, dynamic> decoded =
      jsonDecode(res.body) as Map<String, dynamic>;

      final List<Map<String, dynamic>> routes =
          (decoded['routes'] as List?)
              ?.whereType<Map>()
              .map((Map e) => e.cast<String, dynamic>())
              .toList() ??
              const <Map<String, dynamic>>[];

      if (routes.isEmpty) return null;

      final Map<String, dynamic> route = routes.first;
      final String encoded =
          route['polyline']?['encodedPolyline']?.toString() ?? '';
      if (encoded.isEmpty) return null;

      final List<LatLng> points = _decodePolyline(encoded);
      final int distanceMeters = _toInt(route['distanceMeters']) ?? 0;
      final int durationSeconds =
      _parseDurationSeconds(route['duration']?.toString() ?? '0s');

      return _RouteResult(
        points: points,
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
      );
    } catch (_) {
      return null;
    }
  }

  int _parseDurationSeconds(String v) {
    if (!v.endsWith('s')) return 0;
    final String n = v.substring(0, v.length - 1);
    return double.tryParse(n)?.round() ?? 0;
  }

  List<LatLng> _decodePolyline(String enc) {
    final List<LatLng> out = <LatLng>[];
    int idx = 0;
    int lat = 0;
    int lng = 0;

    while (idx < enc.length) {
      int b;
      int shift = 0;
      int result = 0;

      do {
        b = enc.codeUnitAt(idx++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final int dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = enc.codeUnitAt(idx++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final int dlng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dlng;

      out.add(LatLng(lat / 1e5, lng / 1e5));
    }

    return out;
  }

  LatLngBounds _boundsFrom(List<LatLng> pts) {
    double minLat = pts.first.latitude;
    double maxLat = pts.first.latitude;
    double minLng = pts.first.longitude;
    double maxLng = pts.first.longitude;

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

    double deg2rad(double d) => d * (math.pi / 180.0);

    final double dLat = deg2rad(b.latitude - a.latitude);
    final double dLng = deg2rad(b.longitude - a.longitude);
    final double la1 = deg2rad(a.latitude);
    final double la2 = deg2rad(b.latitude);

    final double h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(la1) *
            math.cos(la2) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);

    return 2 * earth * math.asin(math.min(1.0, math.sqrt(h)));
  }

  double _bearingBetween(LatLng a, LatLng b) {
    double deg2rad(double d) => d * (math.pi / 180.0);
    double rad2deg(double r) => r * (180.0 / math.pi);

    final double lat1 = deg2rad(a.latitude);
    final double lat2 = deg2rad(b.latitude);
    final double dLon = deg2rad(b.longitude - a.longitude);

    final double y = math.sin(dLon) * math.cos(lat2);
    final double x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    final double deg = rad2deg(math.atan2(y, x));
    return (deg + 360.0) % 360.0;
  }

  String _fmtDistance(int meters) {
    if (meters < 1000) return '$meters m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String _fmtDuration(int secs) {
    final int mins = (secs / 60).round();
    if (mins < 60) return '$mins min';
    final int h = mins ~/ 60;
    final int m = mins % 60;
    return '${h}h ${m}m';
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

class _TopGlassBar extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onBack;

  const _TopGlassBar({
    required this.title,
    required this.subtitle,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.22),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: Row(
          children: <Widget>[
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.80),
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhaseCard extends StatelessWidget {
  final TripNavPhase phase;
  final String driverName;
  final String vehicleType;
  final String carPlate;
  final double rating;
  final String distanceText;
  final String durationText;

  const _PhaseCard({
    required this.phase,
    required this.driverName,
    required this.vehicleType,
    required this.carPlate,
    required this.rating,
    required this.distanceText,
    required this.durationText,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;

    late final Color tone;
    late final String label;

    switch (phase) {
      case TripNavPhase.driverToPickup:
        tone = const Color(0xFF7B1FA2);
        label = 'Driver → Pickup';
        break;
      case TripNavPhase.waitingPickup:
        tone = const Color(0xFF1E8E3E);
        label = 'Arrived';
        break;
      case TripNavPhase.enRoute:
        tone = const Color(0xFF1A73E8);
        label = 'On Trip';
        break;
      case TripNavPhase.completed:
        tone = const Color(0xFF00897B);
        label = 'Completed';
        break;
      case TripNavPhase.cancelled:
        tone = const Color(0xFFB00020);
        label = 'Cancelled';
        break;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: tone.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: tone.withOpacity(0.22)),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: tone,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                rating > 0 ? '⭐ ${rating.toStringAsFixed(1)}' : 'Live',
                style: TextStyle(
                  color: cs.onSurface.withOpacity(0.78),
                  fontWeight: FontWeight.w900,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(child: _TinyMetric(label: 'Driver', value: driverName)),
              const SizedBox(width: 10),
              Expanded(child: _TinyMetric(label: 'Vehicle', value: vehicleType)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: _TinyMetric(
                  label: 'Plate',
                  value: carPlate.isEmpty ? '—' : carPlate,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: _TinyMetric(label: 'ETA', value: durationText)),
              const SizedBox(width: 10),
              Expanded(
                child: _TinyMetric(label: 'Distance', value: distanceText),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RouteCard extends StatelessWidget {
  final String from;
  final String to;
  final String currentTarget;
  final List<String> dropOffTexts;
  final int activeStopIndex;
  final TripNavPhase phase;

  const _RouteCard({
    required this.from,
    required this.to,
    required this.currentTarget,
    required this.dropOffTexts,
    required this.activeStopIndex,
    required this.phase,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Route',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: cs.onSurface.withOpacity(0.90),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          _RouteLine(label: 'FROM', value: from, strong: true),
          const SizedBox(height: 8),
          if (dropOffTexts.isNotEmpty) ...<Widget>[
            for (int i = 0; i < dropOffTexts.length; i++) ...<Widget>[
              _RouteLine(
                label: 'STOP ${i + 1}',
                value: dropOffTexts[i],
                strong: phase == TripNavPhase.enRoute && i == activeStopIndex,
              ),
              const SizedBox(height: 8),
            ],
          ],
          _RouteLine(
            label: 'TO',
            value: to,
            strong: phase != TripNavPhase.driverToPickup,
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.primary.withOpacity(0.16)),
            ),
            child: Text(
              'Current target: $currentTarget',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaCard extends StatelessWidget {
  final String userId;
  final String driverId;
  final String tripId;

  const _MetaCard({
    required this.userId,
    required this.driverId,
    required this.tripId,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: _TinyMetric(label: 'User ID', value: userId)),
          const SizedBox(width: 10),
          Expanded(child: _TinyMetric(label: 'Driver ID', value: driverId)),
          const SizedBox(width: 10),
          Expanded(child: _TinyMetric(label: 'Trip ID', value: tripId)),
        ],
      ),
    );
  }
}

class _TinyMetric extends StatelessWidget {
  final String label;
  final String value;

  const _TinyMetric({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurface.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: cs.onSurface.withOpacity(0.58),
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value.isEmpty ? '—' : value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: cs.onSurface.withOpacity(0.90),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteLine extends StatelessWidget {
  final String label;
  final String value;
  final bool strong;

  const _RouteLine({
    required this.label,
    required this.value,
    this.strong = false,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;

    return Row(
      children: <Widget>[
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 10,
              color: cs.onSurface.withOpacity(0.46),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
              fontSize: strong ? 12 : 11,
            ),
          ),
        ),
      ],
    );
  }
}