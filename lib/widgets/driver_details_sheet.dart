// lib/widgets/driver_details_sheet.dart
//
// ✅ Dense, Bybit-like, information-rich details sheet
// ✅ Shows ALL driver + offer + trip fields in a premium layout
// ✅ Location panel: User, Driver, Pickup, Drop (lat/lng + copy)
// ✅ Confirm will SUBMIT to rideBookEndpoint via submitBooking (if provided)
// ✅ Always returns booking payload via Navigator.pop(payload)
//
// Usage (recommended):
// final payload = await showModalBottomSheet<Map<String, dynamic>>(
//   context: context,
//   isScrollControlled: true,
//   backgroundColor: Colors.transparent,
//   builder: (_) => DriverDetailsSheet(
//     driver: driverMap,
//     offer: offerMap,
//     originText: origin,
//     destinationText: dest,
//     distanceText: distanceText,
//     durationText: durationText,
//     tripDistanceKm: tripKm,
//     userLocation: GeoPoint(userLat, userLng),
//     pickupLocation: GeoPoint(pickupLat, pickupLng),
//     dropLocation: GeoPoint(dropLat, dropLng),
//     submitBooking: (payload) => ApiClient.postJson('/rideBookEndpoint', payload),
//   ),
// );

import 'dart:convert';
import 'dart:ui' show
FontFeature,
Canvas,
Size,
Offset,
Rect,
RRect,
Radius;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../themes/app_theme.dart';

/// Simple coordinate holder (no external deps).
class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint(this.lat, this.lng);

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng};

  String toShort() => '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';
}

class DriverDetailsSheet extends StatefulWidget {
  /// Inject your booking endpoint call here.
  /// When provided, Confirm Ride will call this and only close on success.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> payload)? submitBooking;

  final Map<String, dynamic> driver;
  final Map<String, dynamic> offer;

  final String originText;
  final String destinationText;
  final String? distanceText;
  final String? durationText;
  final double tripDistanceKm;

  /// Pass these so the sheet can show + send them to booking endpoint.
  final GeoPoint? userLocation; // user's current GPS
  final GeoPoint? pickupLocation; // pickup coords
  final GeoPoint? dropLocation; // final destination coords

  /// Optional: called on confirm with payload.
  /// (payload is also returned via Navigator.pop)
  final ValueChanged<Map<String, dynamic>>? onConfirm;

  const DriverDetailsSheet({
    super.key,
    required this.driver,
    required this.offer,
    required this.originText,
    required this.destinationText,
    required this.distanceText,
    required this.durationText,
    required this.tripDistanceKm,
    this.userLocation,
    this.pickupLocation,
    this.dropLocation,
    this.onConfirm,
    this.submitBooking,
  });

  @override
  State<DriverDetailsSheet> createState() => _DriverDetailsSheetState();
}

class _DriverDetailsSheetState extends State<DriverDetailsSheet> {
  final _moneyFmt = NumberFormat.decimalPattern();
  late final PageController _pageCtrl;
  int _page = 0;

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  // =========================
  // Helpers: parse + sanitize
  // =========================
  static num _num(dynamic v, num fallback) {
    if (v == null) return fallback;
    if (v is num) return v;
    if (v is String) return num.tryParse(v) ?? fallback;
    return fallback;
  }

  String _s(dynamic v, [String fallback = '']) => (v == null) ? fallback : v.toString();

  List<String> _stringList(dynamic v) {
    if (v == null) return const [];
    if (v is List) {
      return v.map((e) => e.toString()).where((x) => x.trim().isNotEmpty).toList(growable: false);
    }
    final s = v.toString().trim();
    if (s.isEmpty) return const [];
    return s.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList(growable: false);
  }

  String _fixUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('//')) u = 'https:$u';
    if (u.startsWith('http://')) u = 'https://${u.substring(7)}';
    return u;
  }

  double _clampRating(double r) {
    if (r.isNaN || r.isInfinite) return 0;
    return r.clamp(0, 5).toDouble();
  }

  // =========================
  // Icons/colors
  // =========================
  IconData _vehicleIcon(String t) {
    final x = t.trim().toLowerCase();
    if (x.contains('bike')) return Icons.two_wheeler_rounded;
    return Icons.directions_car_filled_rounded;
  }

  IconData _rankIcon(String r) {
    final x = r.trim().toLowerCase();
    if (x.contains('platinum')) return Icons.workspace_premium_rounded;
    if (x.contains('gold')) return Icons.emoji_events_rounded;
    if (x.contains('silver')) return Icons.military_tech_rounded;
    if (x.contains('bronze')) return Icons.military_tech_outlined;
    return Icons.verified_rounded;
  }

  Color _rankColor(String r) {
    final x = r.trim().toLowerCase();
    if (x.contains('platinum')) return const Color(0xFF6A5ACD);
    if (x.contains('gold')) return const Color(0xFFB8860B);
    if (x.contains('silver')) return const Color(0xFF607D8B);
    if (x.contains('bronze')) return const Color(0xFF8D6E63);
    return AppColors.primary;
  }

  String _currencySym() {
    final c = _s(widget.offer['currency'], _s(widget.driver['currency'], 'NGN')).toUpperCase();
    if (c == 'NGN') return '₦';
    if (c == 'USD') return '\$';
    if (c == 'EUR') return '€';
    if (c == 'GBP') return '£';
    return c;
  }

  // =========================
  // Pricing (base + perKm + km)
  // =========================
  double _baseFare() {
    final v = _num(widget.offer['base_fare'], -1).toDouble();
    if (v >= 0) return v;
    return _num(widget.driver['base_fare'], 0).toDouble();
  }

  double _perKm() {
    final v = _num(widget.offer['price_per_km'], -1).toDouble();
    if (v >= 0) return v;
    final d = _num(widget.driver['price_per_km'], -1).toDouble();
    if (d >= 0) return d;
    return _num(widget.offer['price'], 0).toDouble(); // fallback legacy
  }

  double _estimatedTotal() {
    final v = _num(widget.offer['estimated_total'], -1).toDouble();
    if (v > 0) return v;
    final d = _num(widget.driver['estimated_total'], -1).toDouble();
    if (d > 0) return d;
    final p = _num(widget.offer['price_total'], -1).toDouble();
    if (p > 0) return p;
    return 0;
  }

  double _calcTotal() {
    final est = _estimatedTotal();
    if (est > 0) return est;

    final base = _baseFare();
    final per = _perKm();
    final km = widget.tripDistanceKm > 0 ? widget.tripDistanceKm : _num(widget.offer['trip_km'], 0).toDouble();

    if (km > 0 && per > 0) return base + (per * km);
    if (per > 0) return per; // fallback (if km unknown)
    return 0;
  }

  // =========================
  // Locations
  // =========================
  GeoPoint? _driverLoc() {
    final lat = _num(widget.driver['lat'], 0).toDouble();
    final lng = _num(widget.driver['lng'], 0).toDouble();
    return GeoPoint(lat, lng);
  }

  GeoPoint? get _pickupResolved => widget.pickupLocation ?? widget.userLocation;

  // =========================
  // Clipboard
  // =========================
  Future<void> _copy(String label, String value) async {
    final v = value.trim();
    if (v.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: v));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied'), duration: const Duration(milliseconds: 900)),
    );
  }

  // =========================
  // Booking payload (for rideBookEndpoint)
  // =========================
  Map<String, dynamic> _buildBookingPayload() {
    final cur = _currencySym();
    final base = _baseFare();
    final per = _perKm();
    final total = _calcTotal();

    final origin = widget.originText.trim().isEmpty ? 'Pickup' : widget.originText.trim();
    final dest = widget.destinationText.trim().isEmpty ? 'Destination' : widget.destinationText.trim();

    final pickup = _pickupResolved;
    final drop = widget.dropLocation;

    return <String, dynamic>{
      'meta': {
        'created_at': DateTime.now().toIso8601String(),
        'source': 'DriverDetailsSheet',
        'client_submit_enabled': widget.submitBooking != null,
      },
      'trip': {
        'origin_text': origin,
        'destination_text': dest,
        'distance_text': widget.distanceText,
        'duration_text': widget.durationText,
        'trip_km': widget.tripDistanceKm,
      },
      'locations': {
        'user': widget.userLocation?.toJson(),
        'pickup': pickup?.toJson(),
        'drop': drop?.toJson(),
        'driver': _driverLoc()?.toJson(),
        'missing': {
          'user': widget.userLocation == null,
          'pickup': pickup == null,
          'drop': drop == null,
        }
      },
      'driver': Map<String, dynamic>.from(widget.driver),
      'offer': Map<String, dynamic>.from(widget.offer),
      'pricing': {
        'currency_symbol': cur,
        'currency': _s(widget.offer['currency'], _s(widget.driver['currency'], 'NGN')),
        'base_fare': base,
        'price_per_km': per,
        'estimated_total': _estimatedTotal(),
        'computed_total': total,
      },
    };
  }

  Future<void> _handleConfirm() async {
    if (_submitting) return;

    final payload = _buildBookingPayload();

    // Hard guard: you said these must be at finger-tip for booking
    final missing = (payload['locations'] as Map)['missing'] as Map;
    final missUser = missing['user'] == true;
    final missPickup = missing['pickup'] == true;
    final missDrop = missing['drop'] == true;

    if (missUser || missPickup || missDrop) {
      final parts = <String>[];
      if (missUser) parts.add('User');
      if (missPickup) parts.add('Pickup');
      if (missDrop) parts.add('Drop');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Missing locations: ${parts.join(', ')}')),
      );
      return;
    }

    // If no submitBooking provided, just return payload
    if (widget.submitBooking == null) {
      widget.onConfirm?.call(payload);
      if (!mounted) return;
      Navigator.of(context).pop(payload);
      return;
    }

    setState(() => _submitting = true);
    try {
      final res = await widget.submitBooking!(payload);

      // Attach result for caller visibility (still returns the booking payload shape)
      (payload['meta'] as Map<String, dynamic>)['submit_ok'] = true;
      (payload['meta'] as Map<String, dynamic>)['submit_result'] = res;

      widget.onConfirm?.call(payload);
      if (!mounted) return;
      Navigator.of(context).pop(payload);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Booking failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // =========================
  // UI
  // =========================
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cs = Theme.of(context).colorScheme;

    // ---- Driver fields
    final name = _s(widget.driver['name'], 'Driver');
    final category = _s(widget.driver['category'], '');
    final rating = _clampRating(_num(widget.driver['rating'], 0).toDouble());

    final phone = _s(widget.driver['phone'], '');
    final nin = _s(widget.driver['nin'], '');
    final rankRaw = _s(widget.driver['rank'], '').trim();
    final rank = rankRaw.isEmpty ? 'Verified' : rankRaw;

    final vehicleType = _s(widget.driver['vehicle_type'], 'car');
    final seats = vehicleType.toLowerCase().contains('bike') ? 1 : _num(widget.driver['seats'], 4).toInt();
    final desc = _s(widget.driver['vehicle_description'], '');

    final avatar = _fixUrl(_s(widget.driver['avatar_url'], ''));
    final plate = _s(widget.driver['car_plate'], '');

    // raw stats
    final completed = _num(widget.driver['completed_trips'], 0).toInt();
    final cancelled = _num(widget.driver['cancelled_trips'], 0).toInt();
    final incomplete = _num(widget.driver['incomplete_trips'], 0).toInt();
    final reviews = _num(widget.driver['reviews_count'], 0).toInt();
    final totalTrips = _num(widget.driver['total_trips'], 0).toInt();

    // loc core
    final driverLoc = _driverLoc();
    final heading = _num(widget.driver['heading'], 0).toDouble();
    final distKmToUser = _num(widget.driver['distance_km'], 0).toDouble();
    final etaMin = _num(widget.driver['eta_min'], 0).toInt();

    // images
    final imgs = (() {
      final a = _stringList(widget.driver['vehicle_images']).map(_fixUrl).where((x) => x.isNotEmpty).toList(growable: false);
      if (a.isNotEmpty) return a;
      final single = _fixUrl(_s(widget.driver['car_image_url'], ''));
      if (single.isNotEmpty) return <String>[single];
      return <String>[];
    })();

    // trip UI
    final cur = _currencySym();
    final base = _baseFare();
    final perKm = _perKm();
    final total = _calcTotal();

    final origin = widget.originText.trim().isEmpty ? 'Pickup' : widget.originText.trim();
    final dest = widget.destinationText.trim().isEmpty ? 'Destination' : widget.destinationText.trim();

    final distText = widget.distanceText ?? '--';
    final durText = widget.durationText ?? '--';

    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(maxHeight: mq.size.height * 0.88),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.20), blurRadius: 18, offset: const Offset(0, -8)),
            ],
          ),
          child: Column(
            children: [
              const SizedBox(height: 8),
              _handle(cs),
              const SizedBox(height: 6),
              _topBar(cs),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    // Route + Trip summary (dense, premium)
                    _card(
                      cs,
                      child: Column(
                        children: [
                          _FromToMiniDense(
                            origin: origin,
                            dest: dest,
                            cs: cs,
                            rightTop: _miniPill(
                              cs,
                              icon: Icons.price_change_rounded,
                              tone: AppColors.primary,
                              text: total > 0 ? '$cur${_moneyFmt.format(total.round())}' : '—',
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 7,
                            runSpacing: 7,
                            children: [
                              _nxChip(cs, icon: Icons.schedule_rounded, tone: const Color(0xFFB8860B), text: durText),
                              _nxChip(cs, icon: Icons.route_rounded, tone: const Color(0xFF1E8E3E), text: distText),
                              _nxChip(
                                cs,
                                icon: Icons.straighten_rounded,
                                tone: const Color(0xFF1A73E8),
                                text: widget.tripDistanceKm > 0 ? '${widget.tripDistanceKm.toStringAsFixed(2)} km' : '—',
                                mono: true,
                              ),
                              _nxChip(
                                cs,
                                icon: Icons.timer_rounded,
                                tone: const Color(0xFF6A5ACD),
                                text: etaMin > 0 ? '${etaMin}m to pickup' : 'ETA —',
                                mono: true,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 10),

                    // Driver hero
                    _card(
                      cs,
                      child: Row(
                        children: [
                          _avatar(cs, avatar, _initials(name)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          color: cs.onSurface.withOpacity(0.92),
                                          fontSize: 13,
                                          height: 1.05,
                                          letterSpacing: -0.2,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _rankPill(cs, rank),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 7,
                                  runSpacing: 7,
                                  children: [
                                    if (category.isNotEmpty)
                                      _nxChip(cs, icon: Icons.local_taxi_rounded, tone: AppColors.primary, text: category),
                                    _nxChip(
                                      cs,
                                      icon: _vehicleIcon(vehicleType),
                                      tone: const Color(0xFF1A73E8),
                                      text: '${vehicleType.toLowerCase().contains('bike') ? 'Bike' : 'Car'} • $seats',
                                      mono: true,
                                    ),
                                    if (plate.isNotEmpty)
                                      _nxChip(cs, icon: Icons.qr_code_rounded, tone: const Color(0xFF6A5ACD), text: plate, mono: true),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                _starsRow(cs, rating),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 10),

                    // Images carousel (if any)
                    if (imgs.isNotEmpty) ...[
                      _imagesSlider(cs, imgs),
                      const SizedBox(height: 10),
                    ],

                    // Vehicle description (if any)
                    if (desc.trim().isNotEmpty)
                      _card(
                        cs,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_rounded, color: cs.onSurface.withOpacity(0.60), size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                desc,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: cs.onSurface.withOpacity(0.78),
                                  height: 1.25,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    if (desc.trim().isNotEmpty) const SizedBox(height: 10),

                    // Contact + IDs (copy-ready)
                    Row(
                      children: [
                        Expanded(
                          child: _actionCard(
                            cs,
                            title: 'Phone',
                            value: phone.isEmpty ? '—' : phone,
                            icon: Icons.call_rounded,
                            tone: const Color(0xFF1E8E3E),
                            onTap: phone.isEmpty ? null : () => _copy('Phone', phone),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _actionCard(
                            cs,
                            title: 'NIN',
                            value: nin.isEmpty ? '—' : nin,
                            icon: Icons.badge_rounded,
                            tone: const Color(0xFF6A5ACD),
                            onTap: nin.isEmpty ? null : () => _copy('NIN', nin),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // Locations block (finger-tip)
                    _card(
                      cs,
                      header: 'Locations',
                      icon: Icons.public_rounded,
                      child: Column(
                        children: [
                          _locRow(cs, label: 'User', icon: Icons.my_location_rounded, p: widget.userLocation),
                          const SizedBox(height: 8),
                          _locRow(
                            cs,
                            label: 'Driver',
                            icon: Icons.navigation_rounded,
                            p: driverLoc,
                            trailing: _miniText(cs, 'Hd ${heading.toStringAsFixed(0)}°'),
                          ),
                          const SizedBox(height: 8),
                          _locRow(cs, label: 'Pickup', icon: Icons.pin_drop_rounded, p: _pickupResolved),
                          const SizedBox(height: 8),
                          _locRow(cs, label: 'Drop', icon: Icons.flag_rounded, p: widget.dropLocation),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 7,
                            runSpacing: 7,
                            children: [
                              _nxChip(
                                cs,
                                icon: Icons.near_me_rounded,
                                tone: const Color(0xFF1E8E3E),
                                text: distKmToUser > 0
                                    ? (distKmToUser < 1 ? '${(distKmToUser * 1000).round()}m' : '${distKmToUser.toStringAsFixed(2)}km')
                                    : 'Near',
                                mono: true,
                              ),
                              _nxChip(
                                cs,
                                icon: Icons.timer_rounded,
                                tone: const Color(0xFFB8860B),
                                text: etaMin > 0 ? '${etaMin} min' : '—',
                                mono: true,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 10),

                    // Performance (dense tiles)
                    _card(
                      cs,
                      header: 'Performance',
                      icon: Icons.insights_rounded,
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(child: _statTile(cs, 'Completed', '$completed', Icons.check_circle_rounded, const Color(0xFF1E8E3E))),
                              const SizedBox(width: 8),
                              Expanded(child: _statTile(cs, 'Cancelled', '$cancelled', Icons.block_rounded, const Color(0xFFB00020))),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(child: _statTile(cs, 'Incomplete', '$incomplete', Icons.timelapse_rounded, const Color(0xFFB8860B))),
                              const SizedBox(width: 8),
                              Expanded(child: _statTile(cs, 'Reviews', '$reviews', Icons.reviews_rounded, const Color(0xFF6A5ACD))),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _statTile(cs, 'Total trips', '$totalTrips', Icons.verified_rounded, AppColors.primary),
                        ],
                      ),
                    ),

                    const SizedBox(height: 10),

                    // Pricing breakdown (ALL fields)
                    _card(
                      cs,
                      header: 'Trip pricing',
                      icon: Icons.receipt_long_rounded,
                      child: Column(
                        children: [
                          _kvRow(cs, 'Currency', _s(widget.offer['currency'], _s(widget.driver['currency'], 'NGN'))),
                          const SizedBox(height: 6),
                         // _kvRow(cs, 'Base fare', base > 0 ? '$cur${_moneyFmt.format(base.round())}' : '—', mono: true),
                         // const SizedBox(height: 6),
                         // _kvRow(cs, 'Price / km', perKm > 0 ? '$cur${_moneyFmt.format(perKm.round())}/km' : '—', mono: true),
                         // const SizedBox(height: 6),
                         // _kvRow(cs, 'Trip km', widget.tripDistanceKm > 0 ? widget.tripDistanceKm.toStringAsFixed(3) : '—', mono: true),
                          const SizedBox(height: 6),
                          _kvRow(
                            cs,
                            'Estimated total (API)',
                            _estimatedTotal() > 0 ? '$cur${_moneyFmt.format(_estimatedTotal().round())}' : '—',
                            mono: true,
                          ),
                          const SizedBox(height: 10),
                          _bigTotal(cs, total > 0 ? '$cur${_moneyFmt.format(total.round())}' : '—'),
                        ],
                      ),
                    ),

                    const SizedBox(height: 90), // breathing room above confirm bar
                  ],
                ),
              ),

              // Confirm bar
              SafeArea(
                top: false,
                child: Container(
                  padding: EdgeInsets.fromLTRB(12, 10, 12, 10 + mq.padding.bottom),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    border: Border(top: BorderSide(color: cs.onSurface.withOpacity(0.08))),
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _submitting ? null : _handleConfirm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: cs.onSurface.withOpacity(0.12),
                        disabledForegroundColor: cs.onSurface.withOpacity(0.45),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      child: _submitting
                          ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                          : const Text('Confirm ride', style: TextStyle(fontWeight: FontWeight.w900)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =========================
  // Small UI building blocks
  // =========================
  Widget _handle(ColorScheme cs) {
    return Container(
      width: 54,
      height: 5,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), color: cs.onSurface.withOpacity(0.18)),
    );
  }

  Widget _topBar(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: Row(
        children: [
          IconButton(
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Back',
          ),
          Expanded(
            child: Text(
              'Ride details',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.90)),
            ),
          ),
          IconButton(
            onPressed: () {
              final payload = _buildBookingPayload();
              try {
                final pretty = const JsonEncoder.withIndent('  ').convert(payload);
                _copy('Booking payload', pretty);
              } catch (_) {
                _copy('Booking payload', payload.toString());
              }
            },
            icon: const Icon(Icons.copy_all_rounded),
            tooltip: 'Copy payload',
          ),
        ],
      ),
    );
  }

  Widget _card(ColorScheme cs, {String? header, IconData? icon, required Widget child}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: (header == null)
          ? child
          : Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) Icon(icon, size: 18, color: cs.onSurface.withOpacity(0.60)),
              if (icon != null) const SizedBox(width: 8),
              Text(
                header,
                style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.88), fontSize: 12.5),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _miniText(ColorScheme cs, String t) {
    return Text(
      t,
      style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.55), fontSize: 10.5, height: 1.0),
    );
  }

  Widget _rankPill(ColorScheme cs, String rank) {
    final c = _rankColor(rank);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withOpacity(0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_rankIcon(rank), size: 14, color: c),
          const SizedBox(width: 6),
          Text(rank, style: TextStyle(fontWeight: FontWeight.w900, color: c, fontSize: 11, height: 1.0)),
        ],
      ),
    );
  }

  Widget _nxChip(ColorScheme cs, {required IconData icon, required Color tone, required String text, bool mono = false}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withOpacity(0.22), width: 1),
        boxShadow: [
          BoxShadow(blurRadius: 12, offset: const Offset(0, 6), color: tone.withOpacity(0.07)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-0.2, -0.2),
                      radius: 0.9,
                      colors: [tone.withOpacity(0.40), tone.withOpacity(0.08)],
                    ),
                  ),
                ),
                Icon(icon, size: 12.5, color: tone.withOpacity(0.95)),
              ],
            ),
            const SizedBox(width: 6),
            Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: cs.onSurface.withOpacity(0.86),
                fontSize: 10.4,
                height: 1.0,
                letterSpacing: -0.1,
                fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniPill(ColorScheme cs, {required IconData icon, required Color tone, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: tone.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withOpacity(0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: tone),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.86), fontSize: 11, height: 1.0),
          ),
        ],
      ),
    );
  }

  Widget _starsRow(ColorScheme cs, double rating) {
    final r = _clampRating(rating);
    final full = r.floor();
    final half = (r - full) >= 0.5 ? 1 : 0;
    final empty = 5 - full - half;

    final icons = <Widget>[];
    for (int i = 0; i < full; i++) icons.add(const Icon(Icons.star_rounded, size: 16, color: Color(0xFFFFD54F)));
    if (half == 1) icons.add(const Icon(Icons.star_half_rounded, size: 16, color: Color(0xFFFFD54F)));
    for (int i = 0; i < empty; i++) icons.add(Icon(Icons.star_outline_rounded, size: 16, color: cs.onSurface.withOpacity(0.30)));

    return Row(
      children: [
        ...icons,
        const SizedBox(width: 8),
        Text(
          r.toStringAsFixed(2),
          style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.80), fontSize: 12),
        ),
      ],
    );
  }

  Widget _avatar(ColorScheme cs, String url, String initials) {
    final u = url.trim();
    Widget fallback() {
      return Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: cs.onSurface.withOpacity(0.06),
          border: Border.all(color: cs.onSurface.withOpacity(0.10)),
        ),
        child: Center(
          child: Text(initials, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.78))),
        ),
      );
    }

    if (u.isEmpty) return fallback();

    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheW = (54 * dpr).round();

    return ClipOval(
      child: SizedBox(
        width: 54,
        height: 54,
        child: Image.network(
          u,
          fit: BoxFit.cover,
          cacheWidth: cacheW,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, __, ___) => fallback(),
          loadingBuilder: (c, w, p) {
            if (p == null) return w;
            return Container(
              color: cs.onSurface.withOpacity(0.06),
              child: const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.4, valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary)),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _imagesSlider(ColorScheme cs, List<String> imgs) {
    return Container(
      height: 190,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageCtrl,
              itemCount: imgs.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (_, i) {
                final u = _fixUrl(imgs[i]);
                return Image.network(
                  u,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (_, __, ___) => Container(
                    color: cs.onSurface.withOpacity(0.06),
                    child: Icon(Icons.image_not_supported_rounded, color: cs.onSurface.withOpacity(0.55), size: 36),
                  ),
                  loadingBuilder: (c, w, p) {
                    if (p == null) return w;
                    return Container(
                      color: cs.onSurface.withOpacity(0.06),
                      child: const Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.4, valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary)),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 10,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(imgs.length, (i) {
                  final active = i == _page;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 16 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(active ? 0.95 : 0.55),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionCard(
      ColorScheme cs, {
        required String title,
        required String value,
        required IconData icon,
        required Color tone,
        VoidCallback? onTap,
      }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.onSurface.withOpacity(0.08)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: tone.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: tone.withOpacity(0.22)),
              ),
              child: Icon(icon, color: tone, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.70), fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.90)),
                  ),
                ],
              ),
            ),
            if (onTap != null) Icon(Icons.copy_rounded, color: cs.onSurface.withOpacity(0.55), size: 18),
          ],
        ),
      ),
    );
  }

  Widget _statTile(ColorScheme cs, String title, String v, IconData icon, Color tone) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: tone.withOpacity(0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: tone.withOpacity(0.18)),
            ),
            child: Icon(icon, color: tone.withOpacity(0.95), size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.70), fontSize: 12)),
                const SizedBox(height: 4),
                Text(
                  v,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface.withOpacity(0.90),
                    fontSize: 14,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kvRow(ColorScheme cs, String k, String v, {bool mono = false}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            k,
            style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.70), fontSize: 11.5),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          v,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: cs.onSurface.withOpacity(0.90),
            fontSize: 11.5,
            fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
          ),
        ),
      ],
    );
  }

  Widget _bigTotal(ColorScheme cs, String v) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withOpacity(0.22)),
      ),
      child: Row(
        children: [
          Icon(Icons.payments_rounded, color: AppColors.primary.withOpacity(0.95)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Total',
              style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.88), fontSize: 12),
            ),
          ),
          Text(
            v,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: cs.onSurface.withOpacity(0.92),
              fontSize: 14,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _locRow(ColorScheme cs, {required String label, required IconData icon, required GeoPoint? p, Widget? trailing}) {
    final has = p != null;
    final text = has ? p!.toShort() : '—';
    return InkWell(
      onTap: has ? () => _copy('$label location', text) : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        decoration: BoxDecoration(
          color: cs.onSurface.withOpacity(0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.onSurface.withOpacity(0.08)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primary.withOpacity(0.18)),
              ),
              child: Icon(icon, size: 18, color: AppColors.primary.withOpacity(0.95)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.72), fontSize: 11.5)),
                  const SizedBox(height: 3),
                  Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: cs.onSurface.withOpacity(0.90),
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing,
            ] else if (has) ...[
              const SizedBox(width: 10),
              Icon(Icons.copy_rounded, size: 18, color: cs.onSurface.withOpacity(0.55)),
            ],
          ],
        ),
      ),
    );
  }

  String _initials(String s) {
    final parts = s.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return 'D';
    String first(String x) => x.isEmpty ? '' : String.fromCharCode(x.runes.first);
    final a = first(parts.first).toUpperCase();
    final b = parts.length > 1 ? first(parts.last).toUpperCase() : '';
    return (a + b).trim();
  }
}

/// ===============================
/// Route mini (aligned tree like in ride_market_sheet)
/// ===============================
class _FromToMiniDense extends StatelessWidget {
  final String origin;
  final String dest;
  final ColorScheme cs;
  final Widget? rightTop;

  const _FromToMiniDense({
    required this.origin,
    required this.dest,
    required this.cs,
    this.rightTop,
  });

  static const double _h = 48;
  static const double _treeW = 18;
  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _h,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RouteTreeAligned(cs: cs, height: _h, width: _treeW),
          const SizedBox(width: _gap),
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: EdgeInsets.only(right: rightTop == null ? 0 : 118),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _LabeledLine(label: "FROM", value: origin, cs: cs, strong: true),
                      _LabeledLine(label: "TO", value: dest, cs: cs, strong: false),
                    ],
                  ),
                ),
                if (rightTop != null)
                  Positioned(
                    right: 0,
                    top: -1,
                    child: rightTop!,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteTreeAligned extends StatelessWidget {
  final ColorScheme cs;
  final double height;
  final double width;

  const _RouteTreeAligned({
    required this.cs,
    required this.height,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    const start = Color(0xFF1A73E8);
    const end = Color(0xFF1E8E3E);

    return SizedBox(
      width: width,
      height: height,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const _ProNode(color: start, glyph: Icons.my_location_rounded),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: CustomPaint(
                painter: _DottedStemPainter(color: cs.onSurface.withOpacity(0.22)),
              ),
            ),
          ),
          const _ProNode(color: end, glyph: Icons.place_rounded),
        ],
      ),
    );
  }
}

class _ProNode extends StatelessWidget {
  final Color color;
  final IconData glyph;

  const _ProNode({required this.color, required this.glyph});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withOpacity(0.16),
        border: Border.all(color: Colors.white.withOpacity(0.10), width: 0.6),
        boxShadow: [
          BoxShadow(
            blurRadius: 10,
            offset: const Offset(0, 3),
            color: color.withOpacity(0.20),
          ),
        ],
      ),
      child: Center(
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.25, -0.25),
              radius: 0.9,
              colors: [color.withOpacity(0.98), color.withOpacity(0.60)],
            ),
          ),
          child: Center(
            child: Icon(glyph, size: 9, color: Colors.white.withOpacity(0.95)),
          ),
        ),
      ),
    );
  }
}

class _DottedStemPainter extends CustomPainter {
  final Color color;
  const _DottedStemPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    const dashH = 3.0;
    const gap = 2.0;

    final x = size.width / 2;
    double y = 0;

    while (y < size.height) {
      final h = (y + dashH <= size.height) ? dashH : (size.height - y);
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, y + h / 2), width: 1.8, height: h),
        const Radius.circular(99),
      );
      canvas.drawRRect(rect, p);
      y += dashH + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DottedStemPainter oldDelegate) => oldDelegate.color != color;
}

class _LabeledLine extends StatelessWidget {
  final String label;
  final String value;
  final ColorScheme cs;
  final bool strong;

  const _LabeledLine({
    required this.label,
    required this.value,
    required this.cs,
    required this.strong,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 34,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: 9.2,
              height: 1.0,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.4,
              color: cs.onSurface.withOpacity(0.42),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: strong ? 12.2 : 11.2,
              height: 1.0,
              letterSpacing: -0.2,
              fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
              color: cs.onSurface.withOpacity(strong ? 0.92 : 0.66),
            ),
          ),
        ),
      ],
    );
  }
}
