// lib/screens/logistics/logistics_tracking_page.dart
//
// Post-booking screen for Send Me / Dispatch: searching (with timeout +
// cancel), rider assigned, arrived at pickup, in transit, arrived, delivered.
// Shows the delivery PIN to the sender (who shares it with the recipient) and
// a live driver marker. Backed by BookingController (ride_status.php polling
// with backoff, pause in background, stop on terminal state).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/api_client.dart';
import '../../services/booking_controller.dart';
import '../../services/logistics_service.dart';
import '../../ui/ui_scale.dart';
import '../../utility/notification.dart';

String logisticsStatusLabel(String status, LogisticsKind kind) {
  final String rider = kind.isDispatch ? 'courier' : 'rider';
  switch (RideStatusCode.normalize(status)) {
    case RideStatusCode.searching:
      return 'Looking for a $rider…';
    case RideStatusCode.accepted:
    case RideStatusCode.enroutePickup:
      return 'A $rider is heading to the pickup';
    case RideStatusCode.arrivedPickup:
      return 'The $rider is at the pickup';
    case RideStatusCode.inProgress:
      return kind.isDispatch ? 'Package in transit' : 'Errand in progress';
    case RideStatusCode.arrivedDestination:
      return 'The $rider has arrived - share the PIN';
    case RideStatusCode.completed:
      return kind.isDispatch ? 'Delivered' : 'Errand completed';
    case RideStatusCode.canceled:
      return 'Cancelled';
    default:
      return 'Updating…';
  }
}

int _stepOf(String status) {
  switch (RideStatusCode.normalize(status)) {
    case RideStatusCode.searching:
      return 0;
    case RideStatusCode.accepted:
    case RideStatusCode.enroutePickup:
    case RideStatusCode.arrivedPickup:
      return 1;
    case RideStatusCode.inProgress:
      return 2;
    case RideStatusCode.arrivedDestination:
      return 3;
    case RideStatusCode.completed:
      return 4;
    default:
      return 0;
  }
}

class LogisticsTrackingPage extends StatefulWidget {
  final ApiClient api;
  final String userId;
  final LogisticsKind kind;
  final String rideId;
  final String? deliveryOtp;
  final LatLng? pickup;
  final LatLng? destination;
  final String? pickupText;
  final String? destinationText;
  final Map<String, dynamic>? initialPayload;

  const LogisticsTrackingPage({
    super.key,
    required this.api,
    required this.userId,
    required this.kind,
    required this.rideId,
    this.deliveryOtp,
    this.pickup,
    this.destination,
    this.pickupText,
    this.destinationText,
    this.initialPayload,
  });

  @override
  State<LogisticsTrackingPage> createState() => _LogisticsTrackingPageState();
}

class _LogisticsTrackingPageState extends State<LogisticsTrackingPage> {
  late final BookingController _booking =
      BookingController(widget.api, searchTimeout: const Duration(minutes: 15));
  late final LogisticsService _service = LogisticsService(widget.api);
  StreamSubscription<BookingUpdate>? _sub;

  String _status = RideStatusCode.searching;
  String? _message;
  String _otp = '';
  String _driverName = '';
  String _driverPlate = '';
  String _driverPhone = '';
  bool _cancelling = false;
  bool _detailsLoaded = false;

  GoogleMapController? _map;
  final ValueNotifier<Set<Marker>> _markers = ValueNotifier<Set<Marker>>(<Marker>{});
  LatLng? _pickup;
  LatLng? _destination;
  LatLng? _driverLL;

  @override
  void initState() {
    super.initState();
    _otp = (widget.deliveryOtp ?? '').trim();
    _pickup = widget.pickup;
    _destination = widget.destination;
    _sub = _booking.updates.listen(_onUpdate);
    _booking.attachToRide(
      rideId: widget.rideId,
      riderId: widget.userId,
      rideType: widget.kind.wire,
      pickup: widget.pickup,
      destination: widget.destination,
      pickupText: widget.pickupText,
      destinationText: widget.destinationText,
      initialPayload: widget.initialPayload,
    );
    _pickup ??= _booking.pickup;
    _destination ??= _booking.destination;
    _rebuildMarkers();
    if (_otp.isEmpty) _loadDetails();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _booking.dispose();
    _markers.dispose();
    super.dispose();
  }

  Future<void> _loadDetails() async {
    final Map<String, dynamic>? d = await _service.rideDetails(widget.userId, widget.rideId);
    if (!mounted || d == null) return;
    setState(() {
      _detailsLoaded = true;
      final String otp = (d['delivery_otp'] ?? '').toString().trim();
      if (otp.isNotEmpty) _otp = otp;
      final String phone = (d['peer_phone'] ?? '').toString().trim();
      if (phone.isNotEmpty) _driverPhone = phone;
      final String name = (d['peer_name'] ?? '').toString().trim();
      if (name.isNotEmpty && name != 'Searching...') _driverName = name;
      final String plate = (d['peer_plate'] ?? '').toString().trim();
      if (plate.isNotEmpty) _driverPlate = plate;
    });
  }

  void _onUpdate(BookingUpdate u) {
    if (!mounted) return;
    if (u.status == BookingStatus.failed) {
      // Transient tracking problems: keep last known state, show a hint.
      setState(() => _message = u.displayMessage);
      return;
    }
    final String prev = _status;
    final Map<String, dynamic> d = u.data;
    final dynamic driver = d['driver'];
    final double? lat = d['driver_lat'] is num ? (d['driver_lat'] as num).toDouble() : null;
    final double? lng = d['driver_lng'] is num ? (d['driver_lng'] as num).toDouble() : null;
    setState(() {
      _status = u.rawStatus;
      _message = u.isTerminal && u.status == BookingStatus.cancelled
          ? (d['displayMessage']?.toString() ?? 'This request was cancelled.')
          : null;
      if (driver is Map) {
        final String name = (driver['name'] ?? '').toString().trim();
        if (name.isNotEmpty) _driverName = name;
        final String plate = (driver['car_plate'] ?? '').toString().trim();
        if (plate.isNotEmpty) _driverPlate = plate;
      }
    });
    _pickup ??= _booking.pickup;
    _destination ??= _booking.destination;
    if (lat != null && lng != null && _status != RideStatusCode.searching) {
      _driverLL = LatLng(lat, lng);
    }
    _rebuildMarkers();

    // Driver just got assigned: fetch phone (not part of ride_status).
    if (prev == RideStatusCode.searching && _status != RideStatusCode.searching && !_detailsLoaded) {
      _loadDetails();
    }
    if (prev != _status) HapticFeedback.mediumImpact();
  }

  void _rebuildMarkers() {
    final Set<Marker> m = <Marker>{
      if (_pickup != null)
        Marker(
          markerId: const MarkerId('pickup'),
          position: _pickup!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        ),
      if (_destination != null)
        Marker(
          markerId: const MarkerId('drop'),
          position: _destination!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        ),
      if (_driverLL != null)
        Marker(
          markerId: const MarkerId('driver'),
          position: _driverLL!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
          zIndexInt: 10,
        ),
    };
    _markers.value = m;
  }

  void _fit() {
    final List<LatLng> pts = <LatLng>[
      if (_pickup != null) _pickup!,
      if (_destination != null) _destination!,
      if (_driverLL != null) _driverLL!,
    ];
    if (pts.length < 2 || _map == null) return;
    double minLat = pts.first.latitude, maxLat = minLat, minLng = pts.first.longitude, maxLng = minLng;
    for (final LatLng p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    if (maxLat - minLat < 0.002) {
      minLat -= 0.001;
      maxLat += 0.001;
    }
    if (maxLng - minLng < 0.002) {
      minLng -= 0.001;
      maxLng += 0.001;
    }
    _map!
        .animateCamera(CameraUpdate.newLatLngBounds(
            LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)), 48))
        .catchError((_) {});
  }

  bool get _cancellable => const <String>{
        RideStatusCode.searching,
        RideStatusCode.accepted,
        RideStatusCode.enroutePickup,
        RideStatusCode.arrivedPickup,
      }.contains(_status);

  bool get _terminal => RideStatusCode.isTerminal(_status);

  Future<void> _cancel() async {
    if (_cancelling || !_cancellable) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Cancel this request?'),
        content: Text(_status == RideStatusCode.searching
            ? 'We will stop looking for a ${widget.kind.isDispatch ? 'courier' : 'rider'}.'
            : 'A ${widget.kind.isDispatch ? 'courier' : 'rider'} is already on the way.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, cancel')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _cancelling = true);
    final bool done = await _booking.cancelBooking(reason: 'sender_cancelled');
    if (!mounted) return;
    setState(() => _cancelling = false);
    if (!done) {
      showToastNotification(
        context: context,
        title: 'Could not cancel',
        message: _booking.lastError?.message ?? 'Please try again.',
        isSuccess: false,
      );
    }
  }

  Future<void> _call() async {
    final String clean = _driverPhone.replaceAll(RegExp(r'[^\d+]'), '');
    if (clean.isEmpty) return;
    final Uri uri = Uri(scheme: 'tel', path: clean);
    try {
      if (!await launchUrl(uri) && mounted) {
        showToastNotification(context: context, title: 'Error', message: 'Unable to place call.', isSuccess: false);
      }
    } catch (_) {
      if (mounted) {
        showToastNotification(context: context, title: 'Error', message: 'Unable to place call.', isSuccess: false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final UIScale ui = UIScale.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final Color brand = widget.kind.brandColor;
    final int step = _stepOf(_status);
    final bool cancelled = _status == RideStatusCode.canceled;

    return PopScope(
      canPop: !_cancelling,
      child: Scaffold(
        appBar: AppBar(title: Text('${widget.kind.productName} #${widget.rideId}')),
        body: SafeArea(
          child: ListView(
            padding: EdgeInsets.all(ui.inset(16)),
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(ui.radius(18)),
                child: SizedBox(
                  height: 200,
                  child: (_pickup ?? _destination) == null
                      ? ColoredBox(color: cs.surfaceContainerHighest)
                      : ValueListenableBuilder<Set<Marker>>(
                          valueListenable: _markers,
                          builder: (_, Set<Marker> markers, __) => GoogleMap(
                            initialCameraPosition: CameraPosition(target: (_pickup ?? _destination)!, zoom: 13),
                            markers: markers,
                            zoomControlsEnabled: false,
                            myLocationButtonEnabled: false,
                            mapToolbarEnabled: false,
                            compassEnabled: false,
                            onMapCreated: (GoogleMapController c) {
                              _map = c;
                              Future<void>.delayed(const Duration(milliseconds: 250), _fit);
                            },
                          ),
                        ),
                ),
              ),
              SizedBox(height: ui.gap(16)),
              Text(
                logisticsStatusLabel(_status, widget.kind),
                style: TextStyle(fontSize: ui.font(20), fontWeight: FontWeight.w900),
              ),
              if (_message != null) ...<Widget>[
                SizedBox(height: ui.gap(6)),
                Text(_message!, style: TextStyle(color: cancelled ? cs.error : cs.onSurfaceVariant)),
              ],
              SizedBox(height: ui.gap(12)),
              if (!cancelled)
                Row(
                  children: List<Widget>.generate(5, (int i) {
                    return Expanded(
                      child: Container(
                        height: 6,
                        margin: EdgeInsets.only(right: i == 4 ? 0 : 4),
                        decoration: BoxDecoration(
                          color: i <= step ? brand : cs.onSurface.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    );
                  }),
                ),
              if (_status == RideStatusCode.searching) ...<Widget>[
                SizedBox(height: ui.gap(12)),
                const LinearProgressIndicator(),
              ],
              SizedBox(height: ui.gap(20)),
              if (_otp.isNotEmpty && !cancelled) _OtpCard(otp: _otp, kind: widget.kind, delivered: _terminal),
              if (_driverName.isNotEmpty && !cancelled) ...<Widget>[
                SizedBox(height: ui.gap(16)),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(backgroundColor: brand.withValues(alpha: 0.15), child: Icon(widget.kind.icon, color: brand)),
                  title: Text(_driverName, style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: _driverPlate.isEmpty ? null : Text(_driverPlate),
                  trailing: _driverPhone.isEmpty || _terminal
                      ? null
                      : IconButton(icon: const Icon(Icons.call_rounded), onPressed: _call, tooltip: 'Call'),
                ),
              ],
              SizedBox(height: ui.gap(8)),
              _RouteRow(icon: Icons.radio_button_checked_rounded, color: const Color(0xFF1A73E8), text: widget.pickupText ?? ''),
              _RouteRow(icon: Icons.location_on_rounded, color: const Color(0xFF00A651), text: widget.destinationText ?? ''),
              SizedBox(height: ui.gap(24)),
              if (_cancellable)
                OutlinedButton(
                  onPressed: _cancelling ? null : _cancel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: cs.error,
                    minimumSize: const Size.fromHeight(50),
                    side: BorderSide(color: cs.error.withValues(alpha: 0.5)),
                  ),
                  child: _cancelling
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Cancel request', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              if (_terminal)
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: brand,
                    foregroundColor: widget.kind.onBrandColor,
                    minimumSize: const Size.fromHeight(50),
                  ),
                  child: Text(cancelled ? 'Back' : 'Done', style: const TextStyle(fontWeight: FontWeight.w900)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RouteRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _RouteRow({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

class _OtpCard extends StatelessWidget {
  final String otp;
  final LogisticsKind kind;
  final bool delivered;
  const _OtpCard({required this.otp, required this.kind, required this.delivered});

  @override
  Widget build(BuildContext context) {
    final UIScale ui = UIScale.of(context);
    final Color brand = kind.brandColor;
    final String hint = kind.isDispatch
        ? 'Share this PIN with the recipient only. The courier must enter it to hand over the package.'
        : 'Give this PIN to whoever receives the errand. The rider needs it to complete the job.';
    return Container(
      padding: EdgeInsets.all(ui.inset(16)),
      decoration: BoxDecoration(
        color: brand.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(ui.radius(16)),
        border: Border.all(color: brand.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.vpn_key_rounded, color: brand, size: 18),
              const SizedBox(width: 8),
              Text('DELIVERY PIN', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.8, color: brand)),
              const Spacer(),
              if (!delivered)
                IconButton(
                  tooltip: 'Copy PIN',
                  icon: const Icon(Icons.copy_rounded, size: 20),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: otp));
                    HapticFeedback.selectionClick();
                    showToastNotification(context: context, title: 'Copied', message: 'PIN copied.', isSuccess: true);
                  },
                ),
            ],
          ),
          Semantics(
            label: 'Delivery PIN ${otp.split('').join(' ')}',
            child: Text(otp, style: TextStyle(fontSize: ui.font(40), fontWeight: FontWeight.w900, letterSpacing: 12)),
          ),
          const SizedBox(height: 6),
          Text(delivered ? 'Handoff confirmed.' : hint, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
