// lib/widgets/ride_market_sheet.dart
import 'dart:math' as math;
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' as intl;

import '../models/geo_point.dart';
import '../services/ride_market_service.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import 'driver_details_sheet.dart';

class RideNearbyDriver {
  final String id;
  final String name;
  final String category;
  final double rating;
  final String carPlate;
  final double heading;
  final double lat;
  final double lng;
  final double distanceKm;
  final int etaMin;

  final String vehicleType;
  final int seats;
  final List<String> vehicleImages;
  final String vehicleDescription;
  final String carImageUrl;
  final String avatarUrl;
  final String phone;
  final String nin;
  final String rank;

  final int completedTrips;
  final int cancelledTrips;
  final int incompleteTrips;
  final int reviewsCount;
  final int totalTrips;

  final String currency;
  final double pricePerKm;
  final double baseFare;
  final double estimatedTotal;
  final double tripKm;

  const RideNearbyDriver({
    required this.id,
    required this.name,
    required this.category,
    required this.rating,
    required this.carPlate,
    required this.heading,
    required this.lat,
    required this.lng,
    required this.distanceKm,
    required this.etaMin,
    this.vehicleType = 'car',
    this.seats = 4,
    this.vehicleImages = const [],
    this.vehicleDescription = '',
    this.carImageUrl = '',
    this.avatarUrl = '',
    this.phone = '',
    this.nin = '',
    this.rank = '',
    this.completedTrips = 0,
    this.cancelledTrips = 0,
    this.incompleteTrips = 0,
    this.reviewsCount = 0,
    this.totalTrips = 0,
    this.currency = 'NGN',
    this.pricePerKm = 0,
    this.baseFare = 0,
    this.estimatedTotal = 0,
    this.tripKm = 0,
  });

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return 'D';
    String first(String x) => x.isEmpty ? '' : String.fromCharCode(x.runes.first);
    final a = first(parts.first).toUpperCase();
    final b = parts.length > 1 ? first(parts.last).toUpperCase() : '';
    return (a + b).trim();
  }

  List<String> get imagesEffective {
    final out = <String>[];
    for (final x in vehicleImages) {
      final s = x.trim();
      if (s.isNotEmpty) out.add(s);
    }
    if (out.isEmpty && carImageUrl.trim().isNotEmpty) out.add(carImageUrl.trim());
    return out;
  }
}

class RideMarketSheet extends StatefulWidget {
  final double bottomNavHeight;
  final String originText;
  final String destinationText;
  final String? distanceText;
  final String? durationText;
  final double? tripDistanceKm;
  final int driversNearbyCount;
  final List<dynamic>? drivers;
  final List<RideOffer> offers;
  final bool loading;
  final GeoPoint? userLocation;
  final GeoPoint? pickupLocation;
  final GeoPoint? dropLocation;
  final VoidCallback onRefresh;
  final VoidCallback onCancel;
  final void Function(RideNearbyDriver driver, RideOffer offer) onBook;

  const RideMarketSheet({
    super.key,
    required this.bottomNavHeight,
    required this.originText,
    required this.destinationText,
    required this.distanceText,
    required this.durationText,
    this.tripDistanceKm,
    required this.driversNearbyCount,
    this.drivers,
    required this.offers,
    required this.loading,
    required this.onRefresh,
    required this.onCancel,
    required this.onBook,
    this.userLocation,
    this.pickupLocation,
    this.dropLocation,
  });

  @override
  State<RideMarketSheet> createState() => _RideMarketSheetState();
}

class _RideMarketSheetState extends State<RideMarketSheet> {
  final _moneyFmt = intl.NumberFormat.decimalPattern();

  final List<String> _stableIds = <String>[];
  List<RideNearbyDriver> _stableDrivers = const <RideNearbyDriver>[];
  String? _selectedDriverId;

  bool _fullyFrozen = false;
  DateTime? _settleUntil;

  bool get _showNoDrivers => !widget.loading && _stableDrivers.isEmpty && (widget.drivers ?? const []).isEmpty;

  double get _tripKm {
    if (widget.tripDistanceKm != null && widget.tripDistanceKm! > 0) return widget.tripDistanceKm!;
    return _parseDistanceKm(widget.distanceText ?? '');
  }

  double _parseDistanceKm(String s) {
    final t = s.trim().toLowerCase();
    if (t.isEmpty) return 0;
    final numStr = RegExp(r'([\d.]+)').firstMatch(t)?.group(1);
    final v = (numStr == null) ? 0.0 : (double.tryParse(numStr) ?? 0.0);
    if (v <= 0) return 0;
    if (t.contains('m') && !t.contains('km')) return v / 1000.0;
    return v;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reconcileDrivers();
    });
  }

  @override
  void didUpdateWidget(covariant RideMarketSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final routeChanged = oldWidget.originText != widget.originText ||
        oldWidget.destinationText != widget.destinationText ||
        oldWidget.tripDistanceKm != widget.tripDistanceKm ||
        oldWidget.distanceText != widget.distanceText;

    if (routeChanged) _resetStable(alsoClearSelection: true);
    _reconcileDrivers();
  }

  static num _num(dynamic v, num fallback) {
    if (v == null) return fallback;
    if (v is num) return v;
    if (v is String) return num.tryParse(v) ?? fallback;
    return fallback;
  }

  static List<String> _strList(dynamic v) {
    if (v == null) return const <String>[];
    if (v is List) return v.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList(growable: false);
    final s = v.toString().trim();
    if (s.isEmpty) return const <String>[];
    if (s.startsWith('[') && s.endsWith(']')) {
      return s.substring(1, s.length - 1).split(',').map((x) => x.replaceAll('"', '').replaceAll("'", '').trim()).where((x) => x.isNotEmpty).toList(growable: false);
    }
    return s.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList(growable: false);
  }

  String _fixUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('//')) u = 'https:$u';
    if (u.startsWith('http://')) u = 'https://${u.substring(7)}';
    return u;
  }

  bool _hasPrice(RideNearbyDriver d) => d.estimatedTotal > 0 || d.pricePerKm > 0 || d.baseFare > 0;
  bool _hasImage(RideNearbyDriver d) => d.imagesEffective.isNotEmpty || d.carImageUrl.trim().isNotEmpty;
  bool _hasContactData(RideNearbyDriver d) => d.phone.trim().isNotEmpty || d.nin.trim().isNotEmpty;
  bool _hasPerformanceData(RideNearbyDriver d) => d.completedTrips > 0 || d.reviewsCount > 0 || d.totalTrips > 0;
  bool _hasProfileData(RideNearbyDriver d) => d.rank.trim().isNotEmpty || d.vehicleDescription.trim().isNotEmpty || d.avatarUrl.trim().isNotEmpty || d.carPlate.trim().isNotEmpty;

  RideNearbyDriver _driverVM(dynamic raw) {
    if (raw is DriverCar) {
      final d = raw as dynamic;
      final ll = d.ll;
      final lat = (ll != null) ? (ll.latitude as double) : 0.0;
      final lng = (ll != null) ? (ll.longitude as double) : 0.0;

      String vehicleType = 'car';
      try { vehicleType = (d.vehicleType ?? d.vehicle_type ?? 'car').toString(); } catch (_) {}

      int seats = 4;
      try { seats = (d.seats is num) ? (d.seats as num).toInt() : seats; } catch (_) {}
      if (vehicleType.toLowerCase().contains('bike')) seats = 1;

      return RideNearbyDriver(
        id: (d.id ?? '').toString(),
        name: (d.name ?? 'Driver').toString(),
        category: (d.category ?? 'Standard').toString(),
        rating: _num(d.rating, 0).toDouble(),
        carPlate: (d.carPlate ?? d.car_plate ?? d.plate ?? '').toString(),
        heading: _num(d.heading, 0).toDouble(),
        lat: lat,
        lng: lng,
        distanceKm: _num(d.distanceKm ?? d.distance_km, 0).toDouble(),
        etaMin: _num(d.etaMin ?? d.eta_min, 0).toInt(),
        vehicleType: vehicleType,
        seats: seats,
        vehicleImages: _strList(d.vehicleImages ?? d.vehicle_images).map(_fixUrl).where((x) => x.isNotEmpty).toList(growable: false),
        vehicleDescription: (d.vehicleDescription ?? d.vehicle_description ?? '').toString(),
        carImageUrl: _fixUrl((d.carImageUrl ?? d.car_image_url ?? '').toString()),
        avatarUrl: _fixUrl((d.avatarUrl ?? d.avatar_url ?? '').toString()),
        phone: (d.phone ?? d.phone_number ?? d.tel ?? d.mobile ?? '').toString(),
        nin: (d.nin ?? d.national_id ?? d.nationalId ?? '').toString(),
        rank: (d.rank ?? '').toString(),
        completedTrips: _num(d.completedTrips ?? d.completed_trips, 0).toInt(),
        cancelledTrips: _num(d.cancelledTrips ?? d.cancelled_trips, 0).toInt(),
        incompleteTrips: _num(d.incompleteTrips ?? d.incomplete_trips, 0).toInt(),
        reviewsCount: _num(d.reviewsCount ?? d.reviews_count, 0).toInt(),
        totalTrips: _num(d.totalTrips ?? d.total_trips, 0).toInt(),
        currency: (d.currency ?? 'NGN').toString(),
        pricePerKm: _num(d.pricePerKm ?? d.price_per_km, 0).toDouble(),
        baseFare: _num(d.baseFare ?? d.base_fare, 0).toDouble(),
        estimatedTotal: _num(d.estimatedTotal ?? d.estimated_total ?? d.price_total, 0).toDouble(),
        tripKm: _num(d.tripKm ?? d.trip_km, 0).toDouble(),
      );
    }

    if (raw is Map) {
      final m = raw.cast<String, dynamic>();
      final vt = (m['vehicle_type'] ?? 'car').toString();
      int seats = _num(m['seats'], 4).toInt();
      if (vt.toLowerCase().contains('bike')) seats = 1;

      return RideNearbyDriver(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? 'Driver').toString(),
        category: (m['category'] ?? 'Standard').toString(),
        rating: _num(m['rating'], 0).toDouble(),
        carPlate: (m['car_plate'] ?? m['plate'] ?? '').toString(),
        heading: _num(m['heading'], 0).toDouble(),
        lat: _num(m['lat'], 0).toDouble(),
        lng: _num(m['lng'], 0).toDouble(),
        distanceKm: _num(m['distance_km'], 0).toDouble(),
        etaMin: _num(m['eta_min'], 0).toInt(),
        vehicleType: vt,
        seats: seats,
        vehicleImages: _strList(m['vehicle_images']).map(_fixUrl).where((x) => x.isNotEmpty).toList(growable: false),
        vehicleDescription: (m['vehicle_description'] ?? '').toString(),
        carImageUrl: _fixUrl((m['car_image_url'] ?? '').toString()),
        avatarUrl: _fixUrl((m['avatar_url'] ?? '').toString()),
        phone: (m['phone'] ?? m['phone_number'] ?? m['tel'] ?? m['mobile'] ?? '').toString(),
        nin: (m['nin'] ?? m['national_id'] ?? m['nationalId'] ?? '').toString(),
        rank: (m['rank'] ?? '').toString(),
        completedTrips: _num(m['completed_trips'], 0).toInt(),
        cancelledTrips: _num(m['cancelled_trips'], 0).toInt(),
        incompleteTrips: _num(m['incomplete_trips'], 0).toInt(),
        reviewsCount: _num(m['reviews_count'], 0).toInt(),
        totalTrips: _num(m['total_trips'], 0).toInt(),
        currency: (m['currency'] ?? 'NGN').toString(),
        pricePerKm: _num(m['price_per_km'], 0).toDouble(),
        baseFare: _num(m['base_fare'], 0).toDouble(),
        estimatedTotal: _num(m['estimated_total'] ?? m['price_total'], 0).toDouble(),
        tripKm: _num(m['trip_km'], 0).toDouble(),
      );
    }
    return const RideNearbyDriver(id: '', name: 'Driver', category: 'Standard', rating: 0, carPlate: '', heading: 0, lat: 0, lng: 0, distanceKm: 0, etaMin: 0);
  }

  int _rankWeight(String r) {
    final x = r.trim().toLowerCase();
    if (x.contains('diamond')) return 6;
    if (x.contains('platinum')) return 5;
    if (x.contains('gold')) return 4;
    if (x.contains('silver')) return 3;
    if (x.contains('bronze')) return 2;
    if (x.contains('verified')) return 1;
    return 0;
  }

  double _safeRating(double r) => r.isNaN || r.isInfinite ? 0 : r.clamp(0, 5).toDouble();

  int _compareDrivers(RideNearbyDriver a, RideNearbyDriver b) {
    final c1 = _safeRating(b.rating).compareTo(_safeRating(a.rating));
    if (c1 != 0) return c1;
    final c2 = _rankWeight(b.rank.trim().isEmpty ? 'verified' : b.rank).compareTo(_rankWeight(a.rank.trim().isEmpty ? 'verified' : a.rank));
    if (c2 != 0) return c2;
    final c3 = a.etaMin.compareTo(b.etaMin);
    if (c3 != 0) return c3;
    final c4 = a.distanceKm.compareTo(b.distanceKm);
    if (c4 != 0) return c4;
    final c5 = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (c5 != 0) return c5;
    return a.id.compareTo(b.id);
  }

  void _resetStable({bool alsoClearSelection = false}) {
    _stableIds.clear();
    _stableDrivers = const <RideNearbyDriver>[];
    _fullyFrozen = false;
    _settleUntil = null;
    if (alsoClearSelection) _selectedDriverId = null;
  }

  void _reconcileDrivers() {
    if (_selectedDriverId != null) { _fullyFrozen = true; return; }
    if (_settleUntil != null && DateTime.now().isAfter(_settleUntil!)) _fullyFrozen = true;
    if (_fullyFrozen) return;

    final incomingRaw = widget.drivers ?? const <dynamic>[];
    if (incomingRaw.isEmpty) return;

    final incoming = <RideNearbyDriver>[];
    for (final x in incomingRaw) {
      final d = _driverVM(x);
      if (d.id.isNotEmpty) incoming.add(d);
    }
    if (incoming.isEmpty) return;

    final byId = <String, RideNearbyDriver>{};
    for (final d in incoming) byId[d.id] = d;

    if (_stableIds.isEmpty) {
      incoming.sort(_compareDrivers);
      _stableIds.addAll(incoming.map((e) => e.id));
      _stableDrivers = List<RideNearbyDriver>.from(incoming, growable: false);
      _settleUntil = DateTime.now().add(const Duration(milliseconds: 1200));
      setState(() {});
      return;
    }

    final oldById = <String, RideNearbyDriver>{for (final d in _stableDrivers) d.id: d};
    bool changed = false;
    final updated = <RideNearbyDriver>[];

    for (final id in _stableIds) {
      final old = oldById[id];
      final fresh = byId[id];

      if (old == null && fresh != null) { updated.add(fresh); changed = true; continue; }
      if (old != null && fresh != null) {
        if ((!_hasPrice(old) && _hasPrice(fresh)) || (!_hasImage(old) && _hasImage(fresh)) || (_safeRating(old.rating) <= 0 && _safeRating(fresh.rating) > 0) || (!_hasContactData(old) && _hasContactData(fresh)) || (!_hasPerformanceData(old) && _hasPerformanceData(fresh)) || (!_hasProfileData(old) && _hasProfileData(fresh))) {
          updated.add(fresh); changed = true;
        } else { updated.add(old); }
        continue;
      }
      if (old != null) updated.add(old);
    }

    if (updated.isNotEmpty && updated.every((d) => _hasPrice(d) || _tripKm <= 0) && updated.every(_hasImage) && updated.every(_hasContactData) && updated.every(_hasPerformanceData)) _fullyFrozen = true;
    if (changed) setState(() => _stableDrivers = updated);
  }

  String _curSym(String c) {
    final x = c.trim().toUpperCase();
    if (x == 'NGN') return '₦';
    if (x == 'USD') return '\$';
    if (x == 'EUR') return '€';
    if (x == 'GBP') return '£';
    return x;
  }

  double _driverTotal(RideNearbyDriver d) {
    if (d.estimatedTotal > 0) return d.estimatedTotal;
    final km = (_tripKm > 0) ? _tripKm : (d.tripKm > 0 ? d.tripKm : 0);
    if (km > 0 && d.pricePerKm > 0) return d.baseFare + d.pricePerKm * km;
    return 0;
  }

  double _sheetMaxHeight(MediaQueryData mq, UIScale uiScale) {
    final h = mq.size.height;
    double target;
    if (uiScale.landscape) { target = h * (uiScale.tablet ? 0.72 : 0.65); }
    else if (uiScale.tiny) { target = h * 0.45; }
    else if (uiScale.compact) { target = h * 0.48; }
    else { target = h * 0.50; }
    return target.clamp(uiScale.landscape ? 200.0 : 250.0, uiScale.landscape ? 460.0 : 500.0);
  }

  double _bottomInset(MediaQueryData mq, UIScale uiScale, double maxH) {
    final raw = widget.bottomNavHeight + mq.padding.bottom + uiScale.gap(8);
    final cap = uiScale.landscape ? math.max(14.0, maxH * 0.15) : math.max(16.0, maxH * 0.18);
    return raw.clamp(12.0, cap);
  }

  // --- PREMIUM SCALED-DOWN CANCEL DIALOG ---
  Future<void> _handleCancelAction(BuildContext context, UIScale uiScale, bool isDark, ColorScheme cs) async {
    HapticFeedback.mediumImpact();
    final bool? confirm = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withOpacity(isDark ? 0.75 : 0.5),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (ctx, anim1, anim2) {
        return ScaleTransition(
          scale: CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
          child: FadeTransition(
            opacity: anim1,
            child: AlertDialog(
              backgroundColor: Colors.transparent,
              elevation: 0,
              contentPadding: EdgeInsets.zero,
              insetPadding: EdgeInsets.symmetric(horizontal: uiScale.inset(20)),
              content: ClipRRect(
                borderRadius: BorderRadius.circular(uiScale.radius(20)),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Container(
                    padding: EdgeInsets.all(uiScale.inset(20)),
                    decoration: BoxDecoration(
                      color: isDark ? cs.surface.withOpacity(0.85) : Colors.white.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(uiScale.radius(20)),
                      border: Border.all(color: cs.error.withOpacity(0.3), width: 1.2),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 24, offset: const Offset(0, 8))],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: uiScale.icon(48),
                          height: uiScale.icon(48),
                          decoration: BoxDecoration(shape: BoxShape.circle, color: cs.error.withOpacity(0.12)),
                          child: Icon(Icons.warning_amber_rounded, size: uiScale.icon(24), color: cs.error),
                        ),
                        SizedBox(height: uiScale.gap(16)),
                        Text(
                          'Cancel Search?',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: uiScale.font(16.5),
                            fontWeight: FontWeight.w900,
                            color: isDark ? cs.onSurface : AppColors.textPrimary,
                            letterSpacing: -0.3,
                          ),
                        ),
                        SizedBox(height: uiScale.gap(8)),
                        Text(
                          'Are you sure you want to stop searching? Your trip details will be saved.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: uiScale.font(11.5),
                            fontWeight: FontWeight.w600,
                            color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                            height: 1.4,
                          ),
                        ),
                        SizedBox(height: uiScale.gap(24)),
                        Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.symmetric(vertical: uiScale.inset(10)),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(12))),
                                ),
                                child: Text(
                                  'Yes, Cancel',
                                  style: TextStyle(fontSize: uiScale.font(11.5), fontWeight: FontWeight.w800, color: cs.error),
                                ),
                              ),
                            ),
                            SizedBox(width: uiScale.gap(8)),
                            Expanded(
                              flex: 1,
                              child: ElevatedButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isDark ? cs.primary : AppColors.primary,
                                  foregroundColor: isDark ? cs.onPrimary : Colors.white,
                                  padding: EdgeInsets.symmetric(vertical: uiScale.inset(10)),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(12))),
                                  elevation: 0,
                                ),
                                child: Text('Keep Searching', style: TextStyle(fontSize: uiScale.font(11.5), fontWeight: FontWeight.w800)),
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

    if (confirm == true) widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final drivers = _stableDrivers;
    final maxH = _sheetMaxHeight(mq, uiScale);

    return Align(
      alignment: Alignment.bottomCenter,
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(24))),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(maxHeight: maxH),
            decoration: BoxDecoration(
              color: isDark ? cs.surface.withOpacity(0.92) : Colors.white.withOpacity(0.97),
              borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(24))),
              border: Border(top: BorderSide(color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.3), width: 1.0)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? 0.40 : 0.10),
                  blurRadius: uiScale.reduceFx ? 12 : 22,
                  offset: const Offset(0, -8),
                ),
              ],
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final dense = constraints.maxHeight < 330;
                final ultraDense = constraints.maxHeight < 285;

                return Column(
                  children: [
                    SizedBox(height: uiScale.gap(6)),
                    Container(
                      width: uiScale.landscape ? 44 : 50,
                      height: 4.0,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : AppColors.textSecondary.withOpacity(0.22),
                      ),
                    ),
                    SizedBox(height: uiScale.gap(4)),
                    _topBar(context, uiScale, dense: dense, isDark: isDark, cs: cs),
                    Expanded(
                      child: _content(context, drivers, uiScale, dense: dense, ultraDense: ultraDense, isDark: isDark, cs: cs),
                    ),
                    _bottomBar(context, mq, drivers, uiScale, dense: dense, maxHeight: maxH, isDark: isDark, cs: cs),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, UIScale uiScale, {required bool dense, required bool isDark, required ColorScheme cs}) {
    final iconSize = uiScale.icon(dense ? 14 : 16);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: uiScale.inset(10)),
      child: Row(
        children: [
          _glassButton(icon: Icons.close_rounded, iconSize: iconSize, isDark: isDark, cs: cs, uiScale: uiScale, onTap: () => _handleCancelAction(context, uiScale, isDark, cs)),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Select Driver',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: isDark ? cs.onSurface : AppColors.textPrimary,
                    fontSize: uiScale.font(dense ? 12.5 : 13.5),
                    height: 1.0,
                    letterSpacing: -0.25,
                  ),
                ),
                SizedBox(height: uiScale.gap(3)),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.loading) ...[
                      SizedBox(
                        width: uiScale.icon(8), height: uiScale.icon(8),
                        child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(isDark ? cs.primary : AppColors.primary)),
                      ),
                      SizedBox(width: uiScale.gap(4)),
                    ] else ...[
                      Container(
                        width: uiScale.icon(6), height: uiScale.icon(6),
                        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF00E676)),
                      ),
                      SizedBox(width: uiScale.gap(4)),
                    ],
                    Text(
                      widget.loading ? 'Searching...' : 'Live Market',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                        fontSize: uiScale.font(dense ? 9.5 : 10.3),
                        height: 1.0,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _glassButton(icon: Icons.refresh_rounded, iconSize: iconSize, isDark: isDark, cs: cs, uiScale: uiScale, onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _resetStable(alsoClearSelection: true));
            widget.onRefresh();
          }),
        ],
      ),
    );
  }

  Widget _glassButton({required IconData icon, required double iconSize, required bool isDark, required ColorScheme cs, required UIScale uiScale, required VoidCallback onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: EdgeInsets.all(uiScale.inset(6)),
          decoration: BoxDecoration(
            color: isDark ? cs.surfaceVariant.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.5),
            shape: BoxShape.circle,
            border: Border.all(color: isDark ? cs.outline.withOpacity(0.4) : Colors.black.withOpacity(0.05)),
          ),
          child: Icon(icon, size: iconSize, color: isDark ? cs.onSurface : AppColors.textPrimary),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, List<RideNearbyDriver> drivers, UIScale uiScale, {required bool dense, required bool ultraDense, required bool isDark, required ColorScheme cs}) {
    return RepaintBoundary(
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(uiScale.inset(10), uiScale.gap(8), uiScale.inset(10), uiScale.gap(6)),
        children: [
          _routeMini(context, uiScale, dense: dense, isDark: isDark, cs: cs),
          SizedBox(height: uiScale.gap(8)),
          if (_showNoDrivers)
            _emptyState(context, uiScale, isDark: isDark, cs: cs)
          else ...[
            if (widget.loading && drivers.isEmpty) _loadingRow(context, uiScale, isDark: isDark, cs: cs),
            ...List.generate(drivers.length, (i) {
              final d = drivers[i];
              final selected = (_selectedDriverId == d.id);
              return Padding(
                padding: EdgeInsets.only(bottom: uiScale.gap(6)),
                child: KeyedSubtree(
                  key: ValueKey(d.id),
                  child: _driverCard(
                    context, d, uiScale,
                    dense: dense, ultraDense: ultraDense, selected: selected, isDark: isDark, cs: cs,
                    onTap: () { HapticFeedback.selectionClick(); setState(() => _selectedDriverId = d.id); },
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _routeMini(BuildContext context, UIScale uiScale, {required bool dense, required bool isDark, required ColorScheme cs}) {
    final origin = widget.originText.trim().isEmpty ? 'Pickup' : widget.originText.trim();
    final dest = widget.destinationText.trim().isEmpty ? 'Destination' : widget.destinationText.trim();
    final count = math.max(widget.driversNearbyCount, _stableDrivers.length);

    return Container(
      padding: EdgeInsets.all(uiScale.inset(dense ? 8 : 10)),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceVariant.withOpacity(0.3) : Colors.black.withOpacity(0.02),
        borderRadius: BorderRadius.circular(uiScale.radius(12)),
        border: Border.all(color: isDark ? cs.outline.withOpacity(0.4) : AppColors.mintBgLight.withOpacity(0.5), width: 1.0),
      ),
      child: _FromToMini(origin: origin, dest: dest, count: count, cs: cs, uiScale: uiScale, dense: dense, isDark: isDark),
    );
  }

  IconData _vehicleIcon(String t) {
    final x = t.trim().toLowerCase();
    if (x.contains('bike')) return Icons.two_wheeler_rounded;
    return Icons.directions_car_rounded;
  }

  IconData _rankIcon(String r) {
    final x = r.trim().toLowerCase();
    if (x.contains('platinum')) return Icons.workspace_premium_rounded;
    if (x.contains('gold')) return Icons.emoji_events_rounded;
    if (x.contains('silver')) return Icons.military_tech_rounded;
    if (x.contains('bronze')) return Icons.military_tech_outlined;
    return Icons.verified_rounded;
  }

  Color _rankColor(String r, bool isDark, ColorScheme cs) {
    final x = r.trim().toLowerCase();
    if (x.contains('platinum')) return const Color(0xFF6A5ACD);
    if (x.contains('gold')) return const Color(0xFFB8860B);
    if (x.contains('silver')) return const Color(0xFF607D8B);
    if (x.contains('bronze')) return const Color(0xFF8D6E63);
    return isDark ? cs.primary : const Color(0xFF1E8E3E);
  }

  Widget _driverCard(
      BuildContext context, RideNearbyDriver d, UIScale uiScale, {
        required bool dense, required bool ultraDense, required bool selected,
        required bool isDark, required ColorScheme cs, required VoidCallback onTap,
      }) {
    final rankText = d.rank.trim().isEmpty ? 'Verified' : d.rank.trim();
    final rc = _rankColor(rankText, isDark, cs);
    final vt = d.vehicleType.trim().isEmpty ? 'car' : d.vehicleType.trim();
    final seats = vt.toLowerCase().contains('bike') ? 1 : (d.seats <= 0 ? 4 : d.seats);
    final etaText = d.etaMin <= 0 ? '1m' : '${d.etaMin}m';
    final distText = _fmtDistShort(d.distanceKm);

    final total = _driverTotal(d);
    final sym = _curSym(d.currency);
    final totalText = total > 0 ? '$sym${_moneyFmt.format(total.round())}' : '—';
    final img = (d.imagesEffective.isNotEmpty) ? _fixUrl(d.imagesEffective.first) : '';

    final avatarSize = ultraDense ? 28.0 : (dense ? 30.0 : 34.0);
    final thumbSize = ultraDense ? 26.0 : (dense ? 28.0 : 32.0);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(uiScale.radius(14)),
        boxShadow: selected
            ? [BoxShadow(color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.15), blurRadius: 12, offset: const Offset(0, 4))]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(uiScale.radius(14)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.all(uiScale.inset(dense ? 8 : 10)),
            decoration: BoxDecoration(
              color: selected ? (isDark ? cs.primary.withOpacity(0.12) : AppColors.primary.withOpacity(0.06)) : (isDark ? cs.surfaceVariant.withOpacity(0.3) : Colors.white),
              borderRadius: BorderRadius.circular(uiScale.radius(14)),
              border: Border.all(color: selected ? (isDark ? cs.primary : AppColors.primary) : (isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.6)), width: selected ? 1.5 : 1.0),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _avatarWithRank(context, uiScale, d.avatarUrl, d.initials, rankText, rc, size: avatarSize, selected: selected, isDark: isDark, cs: cs),
                SizedBox(width: uiScale.gap(8)),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              d.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary, fontSize: uiScale.font(ultraDense ? 11.5 : (dense ? 12.0 : 13.0)), height: 1.0, letterSpacing: -0.2),
                            ),
                          ),
                          SizedBox(width: uiScale.gap(4)),
                          _ratingPill(context, uiScale, d.rating, isDark: isDark, cs: cs),
                        ],
                      ),
                      SizedBox(height: uiScale.gap(6)),
                      SizedBox(
                        height: ultraDense ? 18 : 20,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          padding: EdgeInsets.zero,
                          children: [
                            _chipNx(context, uiScale: uiScale, icon: _vehicleIconNx(vt), text: vt.toLowerCase().contains('bike') ? 'Bike' : 'Car', tone: isDark ? cs.primary : AppColors.primary, strong: true, isDark: isDark, cs: cs),
                            SizedBox(width: uiScale.gap(4)),
                            _chipNx(context, uiScale: uiScale, icon: Icons.airline_seat_recline_normal_rounded, text: '$seats', tone: const Color(0xFF1A73E8), isDark: isDark, cs: cs),
                            SizedBox(width: uiScale.gap(4)),
                            _chipNx(context, uiScale: uiScale, icon: Icons.av_timer_rounded, text: etaText, tone: const Color(0xFFB8860B), isDark: isDark, cs: cs),
                            SizedBox(width: uiScale.gap(4)),
                            _chipNx(context, uiScale: uiScale, icon: Icons.route_rounded, text: distText, tone: isDark ? cs.primary : const Color(0xFF1E8E3E), isDark: isDark, cs: cs),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: uiScale.gap(6)),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _thumb(context, uiScale, img, vt, size: thumbSize, isDark: isDark, cs: cs),
                        if (selected) ...[SizedBox(width: uiScale.gap(4)), Icon(Icons.check_circle_rounded, size: uiScale.icon(14), color: isDark ? cs.primary : AppColors.primary)],
                      ],
                    ),
                    SizedBox(height: uiScale.gap(4)),
                    Text(
                      totalText,
                      maxLines: 1,
                      style: TextStyle(fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary, fontSize: uiScale.font(ultraDense ? 11.5 : (dense ? 12.0 : 13.5)), height: 1.0, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _fmtDistShort(double km) {
    if (km <= 0) return 'Near';
    if (km < 1) return '${(km * 1000).round()}m';
    return '${km.toStringAsFixed(1)}km';
  }

  Widget _ratingPill(BuildContext context, UIScale uiScale, double rating, {required bool isDark, required ColorScheme cs}) {
    final r = rating.clamp(0, 5).toDouble();
    return Container(
      padding: EdgeInsets.symmetric(horizontal: uiScale.inset(5), vertical: uiScale.inset(3)),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: const Color(0xFFFFD54F).withOpacity(isDark ? 0.15 : 0.15),
        border: Border.all(color: const Color(0xFFFFD54F).withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: uiScale.icon(9.5), color: const Color(0xFFFFC107)),
          SizedBox(width: uiScale.gap(2)),
          Text(r.toStringAsFixed(1), style: TextStyle(fontWeight: FontWeight.w900, color: isDark ? Colors.white : AppColors.textPrimary.withOpacity(0.9), fontSize: uiScale.font(9.0), height: 1.0, fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }

  Widget _avatarWithRank(BuildContext context, UIScale uiScale, String url, String initials, String rank, Color rc, {required double size, required bool selected, required bool isDark, required ColorScheme cs}) {
    final borderColor = selected ? (isDark ? cs.primary : AppColors.primary) : (isDark ? cs.outline.withOpacity(0.4) : Colors.black12);
    final bg = isDark ? cs.surfaceVariant : AppColors.mintBgLight.withOpacity(0.5);
    final u = _fixUrl(url);

    Widget avatarFallback() {
      return Container(
        width: size, height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: bg, border: Border.all(color: borderColor, width: selected ? 1.5 : 1.0)),
        child: Center(child: Text(initials, style: TextStyle(fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary, fontSize: uiScale.font(10.5)))),
      );
    }

    final avatar = (u.isEmpty) ? avatarFallback() : ClipOval(
      child: Container(
        width: size, height: size,
        decoration: BoxDecoration(color: bg, border: Border.all(color: borderColor, width: selected ? 1.5 : 1.0)),
        child: Image.network(u, fit: BoxFit.cover, errorBuilder: (_, __, ___) => avatarFallback()),
      ),
    );

    return SizedBox(
      width: size + 2, height: size + 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: avatar),
          Positioned(
            right: -2, top: -2,
            child: Container(
              padding: EdgeInsets.all(uiScale.inset(2)),
              decoration: BoxDecoration(color: isDark ? cs.surface : Colors.white, shape: BoxShape.circle, border: Border.all(color: isDark ? cs.outline : Colors.black12), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 2, offset: const Offset(0, 1))]),
              child: Icon(_rankIcon(rank), size: uiScale.icon(8), color: rc),
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(BuildContext context, UIScale uiScale, String url, String vehicleType, {required double size, required bool isDark, required ColorScheme cs}) {
    Widget fallback() {
      return Container(
        width: size, height: size,
        decoration: BoxDecoration(color: isDark ? cs.surfaceVariant : AppColors.mintBgLight.withOpacity(0.5), borderRadius: BorderRadius.circular(uiScale.radius(8)), border: Border.all(color: isDark ? cs.outline.withOpacity(0.4) : Colors.black12)),
        child: Center(child: Icon(_vehicleIcon(vehicleType), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(0.6), size: uiScale.icon(12))),
      );
    }
    final u = _fixUrl(url);
    if (u.isEmpty) return fallback();
    return ClipRRect(
      borderRadius: BorderRadius.circular(uiScale.radius(8)),
      child: SizedBox(width: size, height: size, child: Image.network(u, fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback())),
    );
  }

  Widget _loadingRow(BuildContext context, UIScale uiScale, {required bool isDark, required ColorScheme cs}) {
    return Container(
      margin: EdgeInsets.only(bottom: uiScale.gap(8)),
      padding: EdgeInsets.all(uiScale.inset(10)),
      decoration: BoxDecoration(color: isDark ? cs.surfaceVariant.withOpacity(0.3) : Colors.black.withOpacity(0.02), borderRadius: BorderRadius.circular(uiScale.radius(12)), border: Border.all(color: isDark ? cs.outline.withOpacity(0.3) : Colors.black.withOpacity(0.05))),
      child: Row(
        children: [
          SizedBox(width: uiScale.icon(14), height: uiScale.icon(14), child: CircularProgressIndicator(strokeWidth: 2.0, valueColor: AlwaysStoppedAnimation<Color>(isDark ? cs.primary : AppColors.primary))),
          SizedBox(width: uiScale.gap(10)),
          Expanded(child: Text('Finding drivers...', style: TextStyle(fontWeight: FontWeight.w800, color: isDark ? cs.onSurface : AppColors.textPrimary, fontSize: uiScale.font(10.5)))),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context, UIScale uiScale, {required bool isDark, required ColorScheme cs}) {
    return Container(
      padding: EdgeInsets.all(uiScale.inset(16)),
      decoration: BoxDecoration(color: isDark ? cs.surfaceVariant.withOpacity(0.3) : Colors.black.withOpacity(0.02), borderRadius: BorderRadius.circular(uiScale.radius(12)), border: Border.all(color: isDark ? cs.outline.withOpacity(0.3) : Colors.black.withOpacity(0.05))),
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.all(uiScale.inset(10)),
            decoration: BoxDecoration(shape: BoxShape.circle, color: isDark ? cs.surface : Colors.white, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))]),
            child: Icon(Icons.directions_car_filled_rounded, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, size: uiScale.icon(22)),
          ),
          SizedBox(height: uiScale.gap(10)),
          Text('No drivers available', style: TextStyle(fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary, fontSize: uiScale.font(12.5), letterSpacing: -0.3)),
          SizedBox(height: uiScale.gap(4)),
          Text('Please try refreshing in a moment.', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontSize: uiScale.font(10.5))),
          SizedBox(height: uiScale.gap(16)),
          SizedBox(
            width: double.infinity, height: 40,
            child: ElevatedButton(
              onPressed: () { HapticFeedback.selectionClick(); setState(() => _resetStable(alsoClearSelection: true)); widget.onRefresh(); },
              style: ElevatedButton.styleFrom(backgroundColor: isDark ? cs.primary : AppColors.primary, foregroundColor: isDark ? cs.onPrimary : Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(10))), elevation: 0),
              child: Text('Refresh', style: TextStyle(fontWeight: FontWeight.w900, fontSize: uiScale.font(11.5))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(BuildContext context, MediaQueryData mq, List<RideNearbyDriver> drivers, UIScale uiScale, {required bool dense, required double maxHeight, required bool isDark, required ColorScheme cs}) {
    final selected = (_selectedDriverId != null) ? drivers.where((x) => x.id == _selectedDriverId).toList(growable: false) : const <RideNearbyDriver>[];
    final driverSelected = selected.isNotEmpty;
    final bottomInset = _bottomInset(mq, uiScale, maxHeight);

    final buttonHeight = math.max(40.0, uiScale.landscape ? uiScale.gap(44) : uiScale.gap(50));

    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(uiScale.inset(10), uiScale.inset(8), uiScale.inset(10), bottomInset),
        decoration: BoxDecoration(
          color: isDark ? cs.surface.withOpacity(0.8) : Colors.white.withOpacity(0.9),
          border: Border(top: BorderSide(color: isDark ? cs.outline.withOpacity(0.4) : Colors.black.withOpacity(0.04))),
        ),
        child: SizedBox(
          width: double.infinity,
          height: buttonHeight,
          child: ElevatedButton(
            onPressed: driverSelected ? () async {
              HapticFeedback.selectionClick();
              final d = selected.first;
              setState(() => _fullyFrozen = true);

              final driverMap = _driverToMap(d);
              final offerMap = _offerMapFromDriver(d);

              final payload = await showModalBottomSheet<Map<String, dynamic>>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) {
                  return DriverDetailsSheet(
                    driver: driverMap, offer: offerMap,
                    originText: widget.originText, destinationText: widget.destinationText,
                    distanceText: widget.distanceText, durationText: widget.durationText,
                    tripDistanceKm: _tripKm, userLocation: widget.userLocation,
                    pickupLocation: widget.pickupLocation, dropLocation: widget.dropLocation,
                  );
                },
              );

              // RESTORED: If the user cancels or dismisses the Details Sheet, do not book.
              if (payload == null) {
                setState(() => _fullyFrozen = false);
                return;
              }

              final offer = RideOffer(
                id: 'driver-${d.id}', provider: 'PickMe',
                category: d.category.isNotEmpty ? d.category : (d.vehicleType.toLowerCase().contains('bike') ? 'Bike' : 'Car'),
                etaToPickupMin: d.etaMin, price: _driverTotal(d).round(),
                surge: false, driverName: d.name, rating: d.rating,
                carPlate: d.carPlate, seats: d.seats, currency: d.currency,
                pricePerKm: d.pricePerKm, baseFare: d.baseFare,
                estimatedTotal: _driverTotal(d), vehicleType: d.vehicleType,
              );

              widget.onBook(d, offer);
            } : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark ? cs.primary : AppColors.primary,
              foregroundColor: isDark ? cs.onPrimary : Colors.white,
              disabledBackgroundColor: isDark ? cs.surfaceVariant : AppColors.mintBgLight,
              disabledForegroundColor: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : AppColors.textSecondary.withOpacity(0.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(16))),
              elevation: driverSelected ? 4 : 0,
            ),
            child: Text(
              driverSelected ? 'Continue with ${selected.first.name.split(" ").first}' : 'Select a driver to continue',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: uiScale.font(13.5), letterSpacing: -0.15),
            ),
          ),
        ),
      ),
    );
  }

  Map<String, dynamic> _driverToMap(RideNearbyDriver d) {
    return <String, dynamic>{
      'id': d.id, 'name': d.name, 'category': d.category, 'rating': d.rating, 'car_plate': d.carPlate,
      'lat': d.lat, 'lng': d.lng, 'heading': d.heading, 'distance_km': d.distanceKm, 'eta_min': d.etaMin,
      'vehicle_type': d.vehicleType, 'seats': d.seats, 'vehicle_images': d.vehicleImages,
      'vehicle_description': d.vehicleDescription, 'car_image_url': d.carImageUrl, 'avatar_url': d.avatarUrl,
      'phone': d.phone, 'nin': d.nin, 'rank': d.rank, 'completed_trips': d.completedTrips,
      'cancelled_trips': d.cancelledTrips, 'incomplete_trips': d.incompleteTrips, 'reviews_count': d.reviewsCount,
      'total_trips': d.totalTrips, 'currency': d.currency, 'price_per_km': d.pricePerKm,
      'base_fare': d.baseFare, 'estimated_total': _driverTotal(d), 'trip_km': _tripKm,
    };
  }

  Map<String, dynamic> _offerMapFromDriver(RideNearbyDriver d) {
    final total = _driverTotal(d);
    return <String, dynamic>{
      'id': 'driver-${d.id}', 'provider': 'PickMe',
      'category': d.vehicleType.toLowerCase().contains('bike') ? 'Bike' : 'Car',
      'vehicle_type': d.vehicleType, 'seats': d.seats, 'eta_min': d.etaMin,
      'currency': d.currency, 'price_per_km': d.pricePerKm, 'base_fare': d.baseFare,
      'estimated_total': total, 'trip_km': _tripKm, 'price_total': total,
    };
  }
}

class _FromToMini extends StatelessWidget {
  final String origin;
  final String dest;
  final int count;
  final ColorScheme cs;
  final UIScale uiScale;
  final bool dense;
  final bool isDark;

  const _FromToMini({required this.origin, required this.dest, required this.count, required this.cs, required this.uiScale, required this.dense, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final h = dense ? 38.0 : 42.0;
    final treeW = dense ? 14.0 : 16.0;
    final gap = dense ? 6.0 : 8.0;

    return SizedBox(
      height: h,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RouteTreeAligned(cs: cs, uiScale: uiScale, height: h, width: treeW, dense: dense, isDark: isDark),
          SizedBox(width: gap),
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _LabeledLine(label: 'FROM', value: origin, cs: cs, uiScale: uiScale, strong: true, isDark: isDark),
                    _LabeledLine(label: 'TO', value: dest, cs: cs, uiScale: uiScale, strong: false, isDark: isDark),
                  ],
                ),
                Positioned(
                  right: 0, top: 0, bottom: 0,
                  child: Center(child: _NearbyPillMini(count: count, cs: cs, uiScale: uiScale, isDark: isDark)),
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
  final UIScale uiScale;
  final double height;
  final double width;
  final bool dense;
  final bool isDark;

  const _RouteTreeAligned({required this.cs, required this.uiScale, required this.height, required this.width, required this.dense, required this.isDark});

  @override
  Widget build(BuildContext context) {
    const start = Color(0xFF1A73E8);
    const end = Color(0xFF1E8E3E);

    return SizedBox(
      width: width, height: height,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _ProNode(color: start, glyph: Icons.my_location_rounded, size: dense ? 9.0 : 10.0, iconSize: dense ? 6.0 : 7.0),
          Expanded(child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: CustomPaint(painter: _DottedStemPainter(color: isDark ? cs.outline : Colors.black26)))),
          _ProNode(color: end, glyph: Icons.place_rounded, size: dense ? 9.0 : 10.0, iconSize: dense ? 6.0 : 7.0),
        ],
      ),
    );
  }
}

class _ProNode extends StatelessWidget {
  final Color color;
  final IconData glyph;
  final double size;
  final double iconSize;

  const _ProNode({required this.color, required this.glyph, required this.size, required this.iconSize});

  @override
  Widget build(BuildContext context) {
    final inner = size - 2;
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color.withOpacity(0.2)),
      child: Center(
        child: Container(
          width: inner, height: inner,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          child: Center(child: Icon(glyph, size: iconSize, color: Colors.white)),
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
    const dashH = 2.0; const gap = 2.0;
    final x = size.width / 2; double y = 0;
    while (y < size.height) {
      final h = (y + dashH <= size.height) ? dashH : (size.height - y);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y + h / 2), width: 1.5, height: h), const Radius.circular(99)), p);
      y += dashH + gap;
    }
  }
  @override
  bool shouldRepaint(covariant _DottedStemPainter old) => old.color != color;
}

class _LabeledLine extends StatelessWidget {
  final String label;
  final String value;
  final ColorScheme cs;
  final UIScale uiScale;
  final bool strong;
  final bool isDark;

  const _LabeledLine({required this.label, required this.value, required this.cs, required this.uiScale, required this.strong, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 32,
          child: Text(label, style: TextStyle(fontSize: uiScale.font(7.8), height: 1.0, fontWeight: FontWeight.w900, letterSpacing: 0.3, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
        ),
        SizedBox(width: uiScale.gap(4)),
        Expanded(
          child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: uiScale.font(strong ? 11.5 : 10.5), height: 1.0, letterSpacing: -0.15, fontWeight: strong ? FontWeight.w900 : FontWeight.w700, color: isDark ? cs.onSurface : AppColors.textPrimary)),
        ),
      ],
    );
  }
}

class _NearbyPillMini extends StatelessWidget {
  final int count;
  final ColorScheme cs;
  final UIScale uiScale;
  final bool isDark;

  const _NearbyPillMini({required this.count, required this.cs, required this.uiScale, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: uiScale.inset(6), vertical: uiScale.inset(4)),
      decoration: BoxDecoration(
        color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.3), width: 1.0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.radar_rounded, size: uiScale.icon(9), color: isDark ? cs.primary : AppColors.primary),
          SizedBox(width: uiScale.gap(3)),
          Text('$count Nearby', style: TextStyle(fontSize: uiScale.font(8.5), height: 1.0, fontWeight: FontWeight.w900, color: isDark ? cs.primary : AppColors.primary)),
        ],
      ),
    );
  }
}

IconData _vehicleIconNx(String vt) {
  final v = vt.toLowerCase();
  if (v.contains('bike') || v.contains('moto')) return Icons.two_wheeler_rounded;
  if (v.contains('bus') || v.contains('van')) return Icons.airport_shuttle_rounded;
  if (v.contains('lux') || v.contains('vip')) return Icons.workspace_premium_rounded;
  return Icons.directions_car_filled_rounded;
}

Widget _chipNx(
    BuildContext context, {
      required UIScale uiScale,
      required IconData icon,
      required String text,
      required Color tone,
      bool strong = false,
      bool mono = false,
      required bool isDark,
      required ColorScheme cs,
    }) {
  return Container(
    padding: EdgeInsets.symmetric(horizontal: uiScale.inset(6), vertical: uiScale.inset(2.5)),
    decoration: BoxDecoration(
      color: tone.withOpacity(isDark ? 0.15 : 0.06),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: tone.withOpacity(isDark ? 0.4 : 0.15), width: 1),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: uiScale.icon(9.0), color: tone),
        SizedBox(width: uiScale.gap(3)),
        Text(
          text,
          maxLines: 1,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: isDark ? cs.onSurface : AppColors.textPrimary,
            fontSize: uiScale.font(8.8),
            height: 1.0,
            fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
          ),
        ),
      ],
    ),
  );
}