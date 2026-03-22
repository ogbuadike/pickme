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
//     durationText: durationText,Launching lib/main.dart on 2201117SG (wireless) in debug mode...
// Running Gradle task 'assembleDebug'...
// lib/widgets/driver_details_sheet.dart:1437:15: Error: The argument type 'num' can't be assigned to the parameter type 'double?'.
//       height: h,
//               ^
// Target kernel_snapshot_program failed: Exception
//
//
// FAILURE: Build failed with an exception.
//
// * What went wrong:
// Execution failed for task ':app:compileFlutterBuildDebug'.
// > Process 'command '/Volumes/Chibuikem_SSD/Flutter_SDK/flutter/bin/flutter'' finished with non-zero exit value 1
//
// * Try:
// > Run with --stacktrace option to get the stack trace.
// > Run with --info or --debug option to get more log output.
// > Run with --scan to get full insights.
// > Get more help at https://help.gradle.org.
//
// BUILD FAILED in 45s
// Error: Gradle task assembleDebug failed with exit code 1
//     tripDistanceKm: tripKm,
//     userLocation: GeoPoint(userLat, userLng),
//     pickupLocation: GeoPoint(pickupLat, pickupLng),
//     dropLocation: GeoPoint(dropLat, dropLng),
//     submitBooking: (payload) => ApiClient.postJson('/rideBookEndpoint', payload),
//   ),
// );

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Canvas, FontFeature, Offset, Size;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/geo_point.dart';
import '../services/address_resolver_service.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';

/// Simple coordinate holder (no external deps).

class DriverDetailsSheet extends StatefulWidget {
  /// Inject your booking endpoint call here.
  /// When provided, Confirm Ride will call this and only close on success.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> payload)?
  submitBooking;

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

  late Future<String> _userAddressFuture;
  late Future<String> _driverAddressFuture;
  late Future<String> _pickupAddressFuture;
  late Future<String> _dropAddressFuture;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
    _primeAddressFutures();
  }

  @override
  void didUpdateWidget(covariant DriverDetailsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.driver != widget.driver ||
        oldWidget.userLocation != widget.userLocation ||
        oldWidget.pickupLocation != widget.pickupLocation ||
        oldWidget.dropLocation != widget.dropLocation) {
      _primeAddressFutures();
    }
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _primeAddressFutures() {
    _userAddressFuture = _addressFromGeoPoint(
      widget.userLocation,
      fallback: 'User location unavailable',
    );
    _driverAddressFuture = _addressFromLatLng(
      _num(widget.driver['lat'], 0).toDouble(),
      _num(widget.driver['lng'], 0).toDouble(),
      fallback: 'Driver location unavailable',
    );
    _pickupAddressFuture = _addressFromGeoPoint(
      _pickupResolved,
      fallback: 'Pickup location unavailable',
    );
    _dropAddressFuture = _addressFromGeoPoint(
      widget.dropLocation,
      fallback: 'Drop location unavailable',
    );
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

  String _s(dynamic v, [String fallback = '']) =>
      (v == null) ? fallback : v.toString();

  String _pickString(List<Map<String, dynamic>> sources, List<String> keys) {
    for (final source in sources) {
      for (final key in keys) {
        final raw = source[key];
        final value = raw?.toString().trim() ?? '';
        if (value.isNotEmpty) return value;
      }
    }
    return '';
  }

  List<String> _stringList(dynamic v) {
    if (v == null) return const [];
    if (v is List) {
      return v
          .map((e) => e.toString())
          .where((x) => x.trim().isNotEmpty)
          .toList(growable: false);
    }
    final s = v.toString().trim();
    if (s.isEmpty) return const [];
    return s
        .split(',')
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty)
        .toList(growable: false);
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
    final c =
    _s(widget.offer['currency'], _s(widget.driver['currency'], 'NGN'))
        .toUpperCase();
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
    final km = widget.tripDistanceKm > 0
        ? widget.tripDistanceKm
        : _num(widget.offer['trip_km'], 0).toDouble();

    if (km > 0 && per > 0) return base + (per * km);
    if (per > 0) return per;
    return 0;
  }

  // =========================
  // Locations
  // =========================
  GeoPoint? get _pickupResolved => widget.pickupLocation ?? widget.userLocation;

  Future<String> _addressFromGeoPoint(
      GeoPoint? point, {
        required String fallback,
      }) async {
    if (point == null) return fallback;

    try {
      final dynamic p = point;
      final lat = (p.latitude ?? p.lat) as num;
      final lng = (p.longitude ?? p.lng) as num;
      return _addressFromLatLng(
        lat.toDouble(),
        lng.toDouble(),
        fallback: fallback,
      );
    } catch (_) {
      try {
        final dynamic p = point;
        final map = p.toJson() as Map<String, dynamic>;
        final lat = _num(map['lat'] ?? map['latitude'], double.nan).toDouble();
        final lng = _num(map['lng'] ?? map['longitude'], double.nan).toDouble();
        return _addressFromLatLng(lat, lng, fallback: fallback);
      } catch (_) {
        return fallback;
      }
    }
  }

  Future<String> _addressFromLatLng(
      double lat,
      double lng, {
        required String fallback,
      }) async {
    if (!lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) {
      return fallback;
    }
    return AddressResolverService.detailedAddressFromLatLng(
      lat,
      lng,
      fallback: fallback,
    );
  }

  // =========================
  // Clipboard
  // =========================
  Future<void> _copy(String label, String value) async {
    final v = value.trim();
    if (v.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: v));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied'),
        duration: const Duration(milliseconds: 900),
      ),
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

    final origin =
    widget.originText.trim().isEmpty ? 'Pickup' : widget.originText.trim();
    final dest = widget.destinationText.trim().isEmpty
        ? 'Destination'
        : widget.destinationText.trim();

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
        'driver': {
          'lat': _num(widget.driver['lat'], 0).toDouble(),
          'lng': _num(widget.driver['lng'], 0).toDouble(),
        },
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
        'currency': _s(
          widget.offer['currency'],
          _s(widget.driver['currency'], 'NGN'),
        ),
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

    if (widget.submitBooking == null) {
      widget.onConfirm?.call(payload);
      if (!mounted) return;
      Navigator.of(context).pop(payload);
      return;
    }

    setState(() => _submitting = true);
    try {
      final res = await widget.submitBooking!(payload);
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
    final ui = UIScale.of(context);
    final cs = Theme.of(context).colorScheme;

    final sources = <Map<String, dynamic>>[widget.driver, widget.offer];

    final name = _pickString(sources, const ['name']).isEmpty
        ? 'Driver'
        : _pickString(sources, const ['name']);
    final category = _pickString(sources, const ['category']);
    final rating = _clampRating(_num(widget.driver['rating'], 0).toDouble());

    final phone = _pickString(
      sources,
      const ['phone', 'phone_number', 'tel', 'mobile'],
    );
    final nin = _pickString(
      sources,
      const ['nin', 'national_id', 'nationalId'],
    );
    final rankRaw = _pickString(sources, const ['rank']).trim();
    final rank = rankRaw.isEmpty ? 'Verified' : rankRaw;

    final vehicleType = _pickString(
      sources,
      const ['vehicle_type', 'vehicle'],
    ).isEmpty
        ? 'car'
        : _pickString(sources, const ['vehicle_type', 'vehicle']);
    final seats =
    vehicleType.toLowerCase().contains('bike')
        ? 1
        : _num(widget.driver['seats'] ?? widget.offer['seats'], 4).toInt();
    final desc = _pickString(
      sources,
      const ['vehicle_description', 'description'],
    );

    final avatar = _fixUrl(_pickString(sources, const ['avatar_url', 'avatar']));
    final plate = _pickString(sources, const ['car_plate', 'plate']);

    final completed = _num(widget.driver['completed_trips'], 0).toInt();
    final reviews = _num(widget.driver['reviews_count'], 0).toInt();
    final totalTrips = _num(widget.driver['total_trips'], 0).toInt();

    final heading = _num(widget.driver['heading'], 0).toDouble();
    final distKmToUser = _num(widget.driver['distance_km'], 0).toDouble();
    final etaMin = _num(widget.driver['eta_min'] ?? widget.offer['eta_min'], 0)
        .toInt();

    final imgs = (() {
      final a = _stringList(widget.driver['vehicle_images'])
          .map(_fixUrl)
          .where((x) => x.isNotEmpty)
          .toList(growable: false);
      if (a.isNotEmpty) return a;
      final single = _fixUrl(_s(widget.driver['car_image_url'], ''));
      if (single.isNotEmpty) return <String>[single];
      return <String>[];
    })();

    final cur = _currencySym();
    final base = _baseFare();
    final perKm = _perKm();
    final total = _calcTotal();

    final origin =
    widget.originText.trim().isEmpty ? 'Pickup' : widget.originText.trim();
    final dest = widget.destinationText.trim().isEmpty
        ? 'Destination'
        : widget.destinationText.trim();

    final distText = widget.distanceText ?? '--';
    final durText = widget.durationText ?? '--';

    final bool isLandscape = mq.orientation == Orientation.landscape;
    final double maxHeight = isLandscape ? mq.size.height * 0.94 : mq.size.height * 0.88;
    final double sidePad = ui.inset(12).clamp(12.0, 16.0);
    final double cardGap = ui.gap(10).clamp(8.0, 12.0);

    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(maxHeight: maxHeight),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(ui.radius(18).clamp(16.0, 20.0)),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.20),
                blurRadius: 18,
                offset: const Offset(0, -8),
              ),
            ],
          ),
          child: Column(
            children: [
              SizedBox(height: ui.gap(8).clamp(8.0, 10.0)),
              _handle(cs, ui),
              SizedBox(height: ui.gap(6).clamp(6.0, 8.0)),
              _topBar(cs, ui),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(sidePad, 0, sidePad, sidePad),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _card(
                      cs,
                      ui,
                      child: Column(
                        children: [
                          _FromToMiniDense(
                            origin: origin,
                            dest: dest,
                            cs: cs,
                            ui: ui,
                            rightTop: _miniPill(
                              cs,
                              ui,
                              icon: Icons.price_change_rounded,
                              tone: AppColors.primary,
                              text: total > 0
                                  ? '$cur${_moneyFmt.format(total.round())}'
                                  : '—',
                            ),
                          ),
                          SizedBox(height: cardGap),
                          Wrap(
                            spacing: ui.gap(7).clamp(6.0, 8.0),
                            runSpacing: ui.gap(7).clamp(6.0, 8.0),
                            children: [
                              _nxChip(
                                cs,
                                ui,
                                icon: Icons.schedule_rounded,
                                tone: const Color(0xFFB8860B),
                                text: durText,
                              ),
                              _nxChip(
                                cs,
                                ui,
                                icon: Icons.route_rounded,
                                tone: const Color(0xFF1E8E3E),
                                text: distText,
                              ),
                              _nxChip(
                                cs,
                                ui,
                                icon: Icons.straighten_rounded,
                                tone: const Color(0xFF1A73E8),
                                text: widget.tripDistanceKm > 0
                                    ? '${widget.tripDistanceKm.toStringAsFixed(2)} km'
                                    : '—',
                                mono: true,
                              ),
                              _nxChip(
                                cs,
                                ui,
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
                    SizedBox(height: cardGap),
                    _card(
                      cs,
                      ui,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _avatar(cs, ui, avatar, _initials(name)),
                              SizedBox(width: ui.gap(12).clamp(10.0, 14.0)),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Wrap(
                                      spacing: ui.gap(8).clamp(6.0, 10.0),
                                      runSpacing: ui.gap(6).clamp(4.0, 8.0),
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      children: [
                                        Text(
                                          name,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: cs.onSurface.withOpacity(0.92),
                                            fontSize: ui.font(14).clamp(13.0, 15.0),
                                            height: 1.05,
                                            letterSpacing: -0.2,
                                          ),
                                        ),
                                        _rankPill(cs, ui, rank),
                                      ],
                                    ),
                                    SizedBox(height: ui.gap(8).clamp(6.0, 10.0)),
                                    Wrap(
                                      spacing: ui.gap(7).clamp(6.0, 8.0),
                                      runSpacing: ui.gap(7).clamp(6.0, 8.0),
                                      children: [
                                        if (category.isNotEmpty)
                                          _nxChip(
                                            cs,
                                            ui,
                                            icon: Icons.local_taxi_rounded,
                                            tone: AppColors.primary,
                                            text: category,
                                          ),
                                        _nxChip(
                                          cs,
                                          ui,
                                          icon: _vehicleIcon(vehicleType),
                                          tone: const Color(0xFF1A73E8),
                                          text:
                                          '${vehicleType.toLowerCase().contains('bike') ? 'Bike' : 'Car'} • $seats',
                                          mono: true,
                                        ),
                                        if (plate.isNotEmpty)
                                          _nxChip(
                                            cs,
                                            ui,
                                            icon: Icons.qr_code_rounded,
                                            tone: const Color(0xFF6A5ACD),
                                            text: plate,
                                            mono: true,
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: ui.gap(10).clamp(8.0, 12.0)),
                          _starsRow(cs, ui, rating),
                          if (desc.trim().isNotEmpty) ...[
                            SizedBox(height: ui.gap(10).clamp(8.0, 12.0)),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.info_rounded,
                                  color: cs.onSurface.withOpacity(0.60),
                                  size: ui.icon(18).clamp(18.0, 20.0),
                                ),
                                SizedBox(width: ui.gap(8).clamp(8.0, 10.0)),
                                Expanded(
                                  child: Text(
                                    desc,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: cs.onSurface.withOpacity(0.78),
                                      height: 1.3,
                                      fontSize: ui.font(12).clamp(12.0, 13.0),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (imgs.isNotEmpty) ...[
                      SizedBox(height: cardGap),
                      _imagesSlider(cs, ui, imgs),
                    ],
                    SizedBox(height: cardGap),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final stacked = constraints.maxWidth < 430;
                        if (stacked) {
                          return Column(
                            children: [
                              _actionCard(
                                cs,
                                ui,
                                title: 'Phone',
                                value: phone.isEmpty ? '—' : phone,
                                icon: Icons.call_rounded,
                                tone: const Color(0xFF1E8E3E),
                                onTap: phone.isEmpty ? null : () => _copy('Phone', phone),
                              ),
                              SizedBox(height: ui.gap(8).clamp(8.0, 10.0)),
                              _actionCard(
                                cs,
                                ui,
                                title: 'NIN',
                                value: nin.isEmpty ? '—' : nin,
                                icon: Icons.badge_rounded,
                                tone: const Color(0xFF6A5ACD),
                                onTap: nin.isEmpty ? null : () => _copy('NIN', nin),
                              ),
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(
                              child: _actionCard(
                                cs,
                                ui,
                                title: 'Phone',
                                value: phone.isEmpty ? '—' : phone,
                                icon: Icons.call_rounded,
                                tone: const Color(0xFF1E8E3E),
                                onTap: phone.isEmpty ? null : () => _copy('Phone', phone),
                              ),
                            ),
                            SizedBox(width: ui.gap(8).clamp(8.0, 10.0)),
                            Expanded(
                              child: _actionCard(
                                cs,
                                ui,
                                title: 'NIN',
                                value: nin.isEmpty ? '—' : nin,
                                icon: Icons.badge_rounded,
                                tone: const Color(0xFF6A5ACD),
                                onTap: nin.isEmpty ? null : () => _copy('NIN', nin),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    SizedBox(height: cardGap),
                    _card(
                      cs,
                      ui,
                      header: 'Locations',
                      icon: Icons.public_rounded,
                      child: Column(
                        children: [
                          _locRow(
                            cs,
                            ui,
                            label: 'User',
                            icon: Icons.my_location_rounded,
                            future: _userAddressFuture,
                          ),
                          SizedBox(height: ui.gap(8).clamp(8.0, 10.0)),
                          _locRow(
                            cs,
                            ui,
                            label: 'Driver',
                            icon: Icons.navigation_rounded,
                            future: _driverAddressFuture,
                            trailing: _miniText(cs, ui, 'Hd ${heading.toStringAsFixed(0)}°'),
                          ),
                          SizedBox(height: ui.gap(8).clamp(8.0, 10.0)),
                          _locRow(
                            cs,
                            ui,
                            label: 'Pickup',
                            icon: Icons.pin_drop_rounded,
                            future: _pickupAddressFuture,
                          ),
                          SizedBox(height: ui.gap(8).clamp(8.0, 10.0)),
                          _locRow(
                            cs,
                            ui,
                            label: 'Drop',
                            icon: Icons.flag_rounded,
                            future: _dropAddressFuture,
                          ),
                          SizedBox(height: ui.gap(10).clamp(8.0, 12.0)),
                          Wrap(
                            spacing: ui.gap(7).clamp(6.0, 8.0),
                            runSpacing: ui.gap(7).clamp(6.0, 8.0),
                            children: [
                              _nxChip(
                                cs,
                                ui,
                                icon: Icons.near_me_rounded,
                                tone: const Color(0xFF1E8E3E),
                                text: distKmToUser > 0
                                    ? (distKmToUser < 1
                                    ? '${(distKmToUser * 1000).round()}m'
                                    : '${distKmToUser.toStringAsFixed(2)}km')
                                    : 'Near',
                                mono: true,
                              ),
                              _nxChip(
                                cs,
                                ui,
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
                    SizedBox(height: cardGap),
                    _card(
                      cs,
                      ui,
                      header: 'Performance',
                      icon: Icons.insights_rounded,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final stacked = constraints.maxWidth < 480;
                          if (stacked) {
                            return Column(
                              children: [
                                _statTile(
                                  cs,
                                  ui,
                                  'Completed',
                                  '$completed',
                                  Icons.check_circle_rounded,
                                  const Color(0xFF1E8E3E),
                                ),
                                SizedBox(height: ui.gap(8).clamp(8.0, 10.0)),
                                _statTile(
                                  cs,
                                  ui,
                                  'Reviews',
                                  '$reviews',
                                  Icons.reviews_rounded,
                                  const Color(0xFF6A5ACD),
                                ),
                                SizedBox(height: ui.gap(8).clamp(8.0, 10.0)),
                                _statTile(
                                  cs,
                                  ui,
                                  'Total trips',
                                  '$totalTrips',
                                  Icons.verified_rounded,
                                  AppColors.primary,
                                ),
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(
                                child: _statTile(
                                  cs,
                                  ui,
                                  'Completed',
                                  '$completed',
                                  Icons.check_circle_rounded,
                                  const Color(0xFF1E8E3E),
                                ),
                              ),
                              SizedBox(width: ui.gap(8).clamp(8.0, 10.0)),
                              Expanded(
                                child: _statTile(
                                  cs,
                                  ui,
                                  'Reviews',
                                  '$reviews',
                                  Icons.reviews_rounded,
                                  const Color(0xFF6A5ACD),
                                ),
                              ),
                              SizedBox(width: ui.gap(8).clamp(8.0, 10.0)),
                              Expanded(
                                child: _statTile(
                                  cs,
                                  ui,
                                  'Total trips',
                                  '$totalTrips',
                                  Icons.verified_rounded,
                                  AppColors.primary,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    SizedBox(height: cardGap),
                    _card(
                      cs,
                      ui,
                      header: 'Trip pricing',
                      icon: Icons.receipt_long_rounded,
                      child: Column(
                        children: [
                          Wrap(
                            spacing: ui.gap(8).clamp(8.0, 10.0),
                            runSpacing: ui.gap(8).clamp(8.0, 10.0),
                            children: [
                              _priceMetricTile(
                                cs,
                                ui,
                                title: 'Base fare',
                                value: base > 0
                                    ? '$cur${_moneyFmt.format(base.round())}'
                                    : '—',
                                tone: const Color(0xFF1A73E8),
                              ),
                              _priceMetricTile(
                                cs,
                                ui,
                                title: 'Per km',
                                value: perKm > 0
                                    ? '$cur${_moneyFmt.format(perKm.round())}'
                                    : '—',
                                tone: const Color(0xFF6A5ACD),
                              ),
                              _priceMetricTile(
                                cs,
                                ui,
                                title: 'Trip km',
                                value: widget.tripDistanceKm > 0
                                    ? widget.tripDistanceKm.toStringAsFixed(2)
                                    : '—',
                                tone: const Color(0xFF1E8E3E),
                              ),
                              _priceMetricTile(
                                cs,
                                ui,
                                title: 'API total',
                                value: _estimatedTotal() > 0
                                    ? '$cur${_moneyFmt.format(_estimatedTotal().round())}'
                                    : '—',
                                tone: const Color(0xFFB8860B),
                              ),
                            ],
                          ),
                          SizedBox(height: ui.gap(12).clamp(10.0, 14.0)),
                          _kvRow(
                            cs,
                            ui,
                            'Currency',
                            _s(widget.offer['currency'], _s(widget.driver['currency'], 'NGN')),
                          ),
                          SizedBox(height: ui.gap(6).clamp(6.0, 8.0)),
                          // _kvRow(cs, 'Base fare', base > 0 ? '$cur${_moneyFmt.format(base.round())}' : '—', mono: true),
                          // const SizedBox(height: 6),
                          // _kvRow(cs, 'Price / km', perKm > 0 ? '$cur${_moneyFmt.format(perKm.round())}/km' : '—', mono: true),
                          // const SizedBox(height: 6),
                          // _kvRow(cs, 'Trip km', widget.tripDistanceKm > 0 ? widget.tripDistanceKm.toStringAsFixed(3) : '—', mono: true),
                          SizedBox(height: ui.gap(6).clamp(6.0, 8.0)),
                          _kvRow(
                            cs,
                            ui,
                            'Estimated total (API)',
                            _estimatedTotal() > 0
                                ? '$cur${_moneyFmt.format(_estimatedTotal().round())}'
                                : '—',
                            mono: true,
                          ),
                          SizedBox(height: ui.gap(10).clamp(10.0, 12.0)),
                          _bigTotal(
                            cs,
                            ui,
                            total > 0 ? '$cur${_moneyFmt.format(total.round())}' : '—',
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: ui.gap(90).clamp(84.0, 100.0)),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    sidePad,
                    ui.gap(10).clamp(10.0, 12.0),
                    sidePad,
                    ui.gap(10).clamp(10.0, 12.0) + mq.padding.bottom,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    border: Border(
                      top: BorderSide(color: cs.onSurface.withOpacity(0.08)),
                    ),
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: ui.inset(52).clamp(50.0, 56.0),
                    child: ElevatedButton(
                      onPressed: _submitting ? null : _handleConfirm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: cs.onSurface.withOpacity(0.12),
                        disabledForegroundColor: cs.onSurface.withOpacity(0.45),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            ui.radius(16).clamp(14.0, 18.0),
                          ),
                        ),
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
                          : Text(
                        'Confirm ride',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: ui.font(13).clamp(13.0, 14.0),
                        ),
                      ),
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
  Widget _handle(ColorScheme cs, UIScale ui) {
    return Container(
      width: ui.inset(54).clamp(50.0, 58.0),
      height: 5,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: cs.onSurface.withOpacity(0.18),
      ),
    );
  }

  Widget _topBar(ColorScheme cs, UIScale ui) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ui.inset(10).clamp(10.0, 12.0),
        0,
        ui.inset(10).clamp(10.0, 12.0),
        ui.gap(6).clamp(6.0, 8.0),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            icon: Icon(
              Icons.arrow_back_rounded,
              size: ui.icon(22).clamp(22.0, 24.0),
            ),
            tooltip: 'Back',
          ),
          Expanded(
            child: Text(
              'Ride details',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: cs.onSurface.withOpacity(0.90),
                fontSize: ui.font(14).clamp(13.0, 15.0),
              ),
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
            icon: Icon(
              Icons.copy_all_rounded,
              size: ui.icon(21).clamp(21.0, 23.0),
            ),
            tooltip: 'Copy payload',
          ),
        ],
      ),
    );
  }

  Widget _card(
      ColorScheme cs,
      UIScale ui, {
        String? header,
        IconData? icon,
        required Widget child,
      }) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        ui.inset(12).clamp(12.0, 14.0),
        ui.inset(12).clamp(12.0, 14.0),
        ui.inset(12).clamp(12.0, 14.0),
        ui.inset(12).clamp(12.0, 14.0),
      ),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(ui.radius(14).clamp(14.0, 16.0)),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: (header == null)
          ? child
          : Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null)
                Icon(
                  icon,
                  size: ui.icon(18).clamp(18.0, 20.0),
                  color: cs.onSurface.withOpacity(0.60),
                ),
              if (icon != null) SizedBox(width: ui.gap(8).clamp(8.0, 10.0)),
              Text(
                header,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: cs.onSurface.withOpacity(0.88),
                  fontSize: ui.font(12.5).clamp(12.5, 13.5),
                ),
              ),
            ],
          ),
          SizedBox(height: ui.gap(10).clamp(8.0, 12.0)),
          child,
        ],
      ),
    );
  }

  Widget _miniText(ColorScheme cs, UIScale ui, String t) {
    return Text(
      t,
      style: TextStyle(
        fontWeight: FontWeight.w900,
        color: cs.onSurface.withOpacity(0.55),
        fontSize: ui.font(10.5).clamp(10.0, 11.0),
        height: 1.0,
      ),
    );
  }

  Widget _rankPill(ColorScheme cs, UIScale ui, String rank) {
    final c = _rankColor(rank);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(10).clamp(9.0, 11.0),
        vertical: ui.inset(6).clamp(5.0, 7.0),
      ),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withOpacity(0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_rankIcon(rank), size: ui.icon(14).clamp(14.0, 15.0), color: c),
          SizedBox(width: ui.gap(6).clamp(5.0, 7.0)),
          Text(
            rank,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: c,
              fontSize: ui.font(11).clamp(10.5, 11.5),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _nxChip(
      ColorScheme cs,
      UIScale ui, {
        required IconData icon,
        required Color tone,
        required String text,
        bool mono = false,
      }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withOpacity(0.22), width: 1),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: ui.inset(8).clamp(7.0, 9.0),
          vertical: ui.inset(5).clamp(4.0, 6.0),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: ui.icon(12.5).clamp(12.0, 13.0), color: tone),
            SizedBox(width: ui.gap(6).clamp(5.0, 7.0)),
            Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: cs.onSurface.withOpacity(0.86),
                fontSize: ui.font(10.4).clamp(10.0, 11.0),
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

  Widget _miniPill(
      ColorScheme cs,
      UIScale ui, {
        required IconData icon,
        required Color tone,
        required String text,
      }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(9).clamp(8.0, 10.0),
        vertical: ui.inset(6).clamp(5.0, 7.0),
      ),
      decoration: BoxDecoration(
        color: tone.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withOpacity(0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: ui.icon(14).clamp(14.0, 15.0), color: tone),
          SizedBox(width: ui.gap(6).clamp(5.0, 7.0)),
          Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: cs.onSurface.withOpacity(0.86),
              fontSize: ui.font(11).clamp(10.5, 11.5),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _starsRow(ColorScheme cs, UIScale ui, double rating) {
    final r = _clampRating(rating);
    final full = r.floor();
    final half = (r - full) >= 0.5 ? 1 : 0;
    final empty = 5 - full - half;

    final icons = <Widget>[];
    for (int i = 0; i < full; i++) {
      icons.add(Icon(
        Icons.star_rounded,
        size: ui.icon(16).clamp(16.0, 18.0),
        color: const Color(0xFFFFD54F),
      ));
    }
    if (half == 1) {
      icons.add(Icon(
        Icons.star_half_rounded,
        size: ui.icon(16).clamp(16.0, 18.0),
        color: const Color(0xFFFFD54F),
      ));
    }
    for (int i = 0; i < empty; i++) {
      icons.add(Icon(
        Icons.star_outline_rounded,
        size: ui.icon(16).clamp(16.0, 18.0),
        color: cs.onSurface.withOpacity(0.30),
      ));
    }

    return Row(
      children: [
        ...icons,
        SizedBox(width: ui.gap(8).clamp(8.0, 10.0)),
        Text(
          r.toStringAsFixed(2),
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: cs.onSurface.withOpacity(0.80),
            fontSize: ui.font(12).clamp(12.0, 13.0),
          ),
        ),
      ],
    );
  }

  Widget _avatar(ColorScheme cs, UIScale ui, String url, String initials) {
    final size = ui.inset(54).clamp(52.0, 58.0);
    final u = url.trim();

    Widget fallback() {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: cs.onSurface.withOpacity(0.06),
          border: Border.all(color: cs.onSurface.withOpacity(0.10)),
        ),
        child: Center(
          child: Text(
            initials,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: cs.onSurface.withOpacity(0.78),
              fontSize: ui.font(12).clamp(12.0, 13.0),
            ),
          ),
        ),
      );
    }

    if (u.isEmpty) return fallback();

    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheW = (size * dpr).round();

    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
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
                  height: 18.0,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _imagesSlider(ColorScheme cs, UIScale ui, List<String> imgs) {
    final double h = math.min<double>(
      220.0,
      math.max<double>(170.0, MediaQuery.of(context).size.height * 0.24),
    );

    return Container(
      height: h,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(ui.radius(14).clamp(14.0, 16.0)),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ui.radius(14).clamp(14.0, 16.0)),
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
                    child: Icon(
                      Icons.image_not_supported_rounded,
                      color: cs.onSurface.withOpacity(0.55),
                      size: ui.icon(36).clamp(34.0, 38.0),
                    ),
                  ),
                  loadingBuilder: (c, w, p) {
                    if (p == null) return w;
                    return Container(
                      color: cs.onSurface.withOpacity(0.06),
                      child: const Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
                          ),
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
      ColorScheme cs,
      UIScale ui, {
        required String title,
        required String value,
        required IconData icon,
        required Color tone,
        VoidCallback? onTap,
      }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ui.radius(14).clamp(14.0, 16.0)),
      child: Container(
        padding: EdgeInsets.fromLTRB(
          ui.inset(12).clamp(12.0, 14.0),
          ui.inset(12).clamp(12.0, 14.0),
          ui.inset(12).clamp(12.0, 14.0),
          ui.inset(12).clamp(12.0, 14.0),
        ),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(ui.radius(14).clamp(14.0, 16.0)),
          border: Border.all(color: cs.onSurface.withOpacity(0.08)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: ui.inset(40).clamp(40.0, 44.0),
              height: ui.inset(40).clamp(40.0, 44.0),
              decoration: BoxDecoration(
                color: tone.withOpacity(0.12),
                borderRadius: BorderRadius.circular(ui.radius(12).clamp(12.0, 14.0)),
                border: Border.all(color: tone.withOpacity(0.22)),
              ),
              child: Icon(icon, color: tone, size: ui.icon(20).clamp(20.0, 22.0)),
            ),
            SizedBox(width: ui.gap(10).clamp(10.0, 12.0)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: cs.onSurface.withOpacity(0.70),
                      fontSize: ui.font(12).clamp(12.0, 13.0),
                    ),
                  ),
                  SizedBox(height: ui.gap(4).clamp(4.0, 6.0)),
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: cs.onSurface.withOpacity(0.90),
                      fontSize: ui.font(12.5).clamp(12.0, 13.0),
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(
                Icons.copy_rounded,
                color: cs.onSurface.withOpacity(0.55),
                size: ui.icon(18).clamp(18.0, 20.0),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statTile(
      ColorScheme cs,
      UIScale ui,
      String title,
      String v,
      IconData icon,
      Color tone,
      ) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        ui.inset(12).clamp(12.0, 14.0),
        ui.inset(12).clamp(12.0, 14.0),
        ui.inset(12).clamp(12.0, 14.0),
        ui.inset(12).clamp(12.0, 14.0),
      ),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(ui.radius(14).clamp(14.0, 16.0)),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Container(
            width: ui.inset(40).clamp(40.0, 44.0),
            height: ui.inset(40).clamp(40.0, 44.0),
            decoration: BoxDecoration(
              color: tone.withOpacity(0.10),
              borderRadius: BorderRadius.circular(ui.radius(12).clamp(12.0, 14.0)),
              border: Border.all(color: tone.withOpacity(0.18)),
            ),
            child: Icon(icon, color: tone.withOpacity(0.95), size: ui.icon(20).clamp(20.0, 22.0)),
          ),
          SizedBox(width: ui.gap(10).clamp(10.0, 12.0)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface.withOpacity(0.70),
                    fontSize: ui.font(12).clamp(12.0, 13.0),
                  ),
                ),
                SizedBox(height: ui.gap(4).clamp(4.0, 6.0)),
                Text(
                  v,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface.withOpacity(0.90),
                    fontSize: ui.font(14).clamp(13.5, 15.0),
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

  Widget _kvRow(
      ColorScheme cs,
      UIScale ui,
      String k,
      String v, {
        bool mono = false,
      }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            k,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: cs.onSurface.withOpacity(0.70),
              fontSize: ui.font(11.5).clamp(11.5, 12.5),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            v,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: cs.onSurface.withOpacity(0.90),
              fontSize: ui.font(11.5).clamp(11.5, 12.5),
              fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
            ),
          ),
        ),
      ],
    );
  }

  Widget _bigTotal(ColorScheme cs, UIScale ui, String v) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        ui.inset(12).clamp(12.0, 14.0),
        ui.inset(12).clamp(12.0, 14.0),
        ui.inset(12).clamp(12.0, 14.0),
        ui.inset(12).clamp(12.0, 14.0),
      ),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.10),
        borderRadius: BorderRadius.circular(ui.radius(14).clamp(14.0, 16.0)),
        border: Border.all(color: AppColors.primary.withOpacity(0.22)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.payments_rounded,
            color: AppColors.primary.withOpacity(0.95),
            size: ui.icon(20).clamp(20.0, 22.0),
          ),
          SizedBox(width: ui.gap(10).clamp(10.0, 12.0)),
          Expanded(
            child: Text(
              'Total',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: cs.onSurface.withOpacity(0.88),
                fontSize: ui.font(12).clamp(12.0, 13.0),
              ),
            ),
          ),
          Flexible(
            child: Text(
              v,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: cs.onSurface.withOpacity(0.92),
                fontSize: ui.font(14).clamp(13.5, 15.0),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _priceMetricTile(
      ColorScheme cs,
      UIScale ui, {
        required String title,
        required String value,
        required Color tone,
      }) {
    return Container(
      width: 145,
      padding: EdgeInsets.fromLTRB(
        ui.inset(10).clamp(10.0, 12.0),
        ui.inset(10).clamp(10.0, 12.0),
        ui.inset(10).clamp(10.0, 12.0),
        ui.inset(10).clamp(10.0, 12.0),
      ),
      decoration: BoxDecoration(
        color: tone.withOpacity(0.08),
        borderRadius: BorderRadius.circular(ui.radius(12).clamp(12.0, 14.0)),
        border: Border.all(color: tone.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: cs.onSurface.withOpacity(0.64),
              fontSize: ui.font(10.5).clamp(10.0, 11.0),
            ),
          ),
          SizedBox(height: ui.gap(4).clamp(4.0, 6.0)),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: cs.onSurface.withOpacity(0.92),
              fontSize: ui.font(12.4).clamp(12.0, 13.0),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _locRow(
      ColorScheme cs,
      UIScale ui, {
        required String label,
        required IconData icon,
        required Future<String> future,
        Widget? trailing,
      }) {
    return FutureBuilder<String>(
      future: future,
      builder: (context, snapshot) {
        final text = (snapshot.data ?? 'Resolving address...').trim();
        final canCopy =
            snapshot.connectionState == ConnectionState.done &&
                text.isNotEmpty &&
                text != '—';

        return InkWell(
          onTap: canCopy ? () => _copy('$label location', text) : null,
          borderRadius: BorderRadius.circular(ui.radius(12).clamp(12.0, 14.0)),
          child: Container(
            padding: EdgeInsets.fromLTRB(
              ui.inset(10).clamp(10.0, 12.0),
              ui.inset(10).clamp(10.0, 12.0),
              ui.inset(10).clamp(10.0, 12.0),
              ui.inset(10).clamp(10.0, 12.0),
            ),
            decoration: BoxDecoration(
              color: cs.onSurface.withOpacity(0.03),
              borderRadius: BorderRadius.circular(ui.radius(12).clamp(12.0, 14.0)),
              border: Border.all(color: cs.onSurface.withOpacity(0.08)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: ui.inset(34).clamp(34.0, 38.0),
                  height: ui.inset(34).clamp(34.0, 38.0),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(ui.radius(12).clamp(12.0, 14.0)),
                    border: Border.all(color: AppColors.primary.withOpacity(0.18)),
                  ),
                  child: Icon(
                    icon,
                    size: ui.icon(18).clamp(18.0, 20.0),
                    color: AppColors.primary.withOpacity(0.95),
                  ),
                ),
                SizedBox(width: ui.gap(10).clamp(10.0, 12.0)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: cs.onSurface.withOpacity(0.72),
                          fontSize: ui.font(11.5).clamp(11.5, 12.5),
                        ),
                      ),
                      SizedBox(height: ui.gap(3).clamp(3.0, 5.0)),
                      Text(
                        text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: cs.onSurface.withOpacity(0.90),
                          fontSize: ui.font(12).clamp(12.0, 13.0),
                          height: 1.28,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  SizedBox(width: ui.gap(10).clamp(8.0, 10.0)),
                  trailing,
                ] else if (canCopy) ...[
                  SizedBox(width: ui.gap(10).clamp(8.0, 10.0)),
                  Icon(
                    Icons.copy_rounded,
                    size: ui.icon(18).clamp(18.0, 20.0),
                    color: cs.onSurface.withOpacity(0.55),
                  ),
                ],
              ],
            ),
          ),
        );
      },
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
  final UIScale ui;
  final Widget? rightTop;

  const _FromToMiniDense({
    required this.origin,
    required this.dest,
    required this.cs,
    required this.ui,
    this.rightTop,
  });

  @override
  Widget build(BuildContext context) {
    final bool narrow = MediaQuery.of(context).size.width < 390;
    final double h = ui.inset(52).clamp(48.0, 58.0);

    final route = SizedBox(
      height: h,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RouteTreeAligned(
            cs: cs,
            ui: ui,
            height: h,
            width: ui.inset(18).clamp(16.0, 20.0),
          ),
          SizedBox(width: ui.gap(10).clamp(8.0, 10.0)),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _LabeledLine(
                  label: 'FROM',
                  value: origin,
                  cs: cs,
                  strong: true,
                  ui: ui,
                ),
                _LabeledLine(
                  label: 'TO',
                  value: dest,
                  cs: cs,
                  strong: false,
                  ui: ui,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (rightTop == null) return route;

    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          route,
          SizedBox(height: ui.gap(8).clamp(6.0, 8.0)),
          rightTop!,
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: route),
        SizedBox(width: ui.gap(10).clamp(8.0, 10.0)),
        rightTop!,
      ],
    );
  }
}

class _RouteTreeAligned extends StatelessWidget {
  final ColorScheme cs;
  final UIScale ui;
  final double height;
  final double width;

  const _RouteTreeAligned({
    required this.cs,
    required this.ui,
    required this.height,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _RouteTreePainter(color: cs.onSurface.withOpacity(0.22)),
      ),
    );
  }
}

class _RouteTreePainter extends CustomPainter {
  final Color color;

  const _RouteTreePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const start = Color(0xFF1A73E8);
    const end = Color(0xFF1E8E3E);

    final x = size.width / 2;
    const topY = 6.0;
    final bottomY = size.height - 6.0;
    const topStem = 13.0;
    final bottomStem = bottomY - 7.0;

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    double y = topStem;
    while (y < bottomStem) {
      final y2 = math.min(y + 3.0, bottomStem);
      canvas.drawLine(Offset(x, y), Offset(x, y2), linePaint);
      y += 5.0;
    }

    canvas.drawCircle(Offset(x, topY), 6.0, Paint()..color = start.withOpacity(0.16));
    canvas.drawCircle(Offset(x, topY), 4.0, Paint()..color = start);

    canvas.drawCircle(Offset(x, bottomY), 6.0, Paint()..color = end.withOpacity(0.16));
    canvas.drawCircle(Offset(x, bottomY), 4.0, Paint()..color = end);
  }

  @override
  bool shouldRepaint(covariant _RouteTreePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _LabeledLine extends StatelessWidget {
  final String label;
  final String value;
  final ColorScheme cs;
  final bool strong;
  final UIScale ui;

  const _LabeledLine({
    required this.label,
    required this.value,
    required this.cs,
    required this.strong,
    required this.ui,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: ui.inset(34).clamp(30.0, 36.0),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: ui.font(9.2).clamp(9.0, 10.0),
              height: 1.0,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.4,
              color: cs.onSurface.withOpacity(0.42),
            ),
          ),
        ),
        SizedBox(width: ui.gap(6).clamp(4.0, 6.0)),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: ui.font(strong ? 12.2 : 11.2).clamp(
                strong ? 12.0 : 11.0,
                strong ? 13.0 : 12.0,
              ),
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