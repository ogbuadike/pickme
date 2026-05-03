// lib/widgets/ride_market_sheet.dart
//
// ─── THE ULTIMATE HYBRID REWRITE + VEHICLE FILTER ───────────────────────────
//  • Keeps the brilliant 38px horizontal _buildRouteStrip.
//  • OVERRIDES height: Allows up to 85% of the screen height.
//  • OVERRIDES bottom bar: Uses native SafeArea.
//  • NEW: Instant Vehicle Filter (All, Car, Ke-ke, Bike).
// ────────────────────────────────────────────────────────────────────────────

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

// ═════════════════════════════════════════════════════════════════════════════
//  Data model
// ═════════════════════════════════════════════════════════════════════════════
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
    return (first(parts.first).toUpperCase() + (parts.length > 1 ? first(parts.last).toUpperCase() : '')).trim();
  }

  List<String> get imagesEffective {
    final out = vehicleImages.map((x) => x.trim()).where((s) => s.isNotEmpty).toList();
    if (out.isEmpty && carImageUrl.trim().isNotEmpty) out.add(carImageUrl.trim());
    return out;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  RideMarketSheet
// ═════════════════════════════════════════════════════════════════════════════
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

  // FILTER STATE
  String _activeFilter = 'All'; // Options: 'All', 'Car', 'Ke-ke', 'Bike'
  String? _selectedDriverId;

  bool _fullyFrozen = false;
  DateTime? _settleUntil;

  // ── Vehicle Identification ────────────────────────────────────────────────
  bool _isBike(String vt) {
    final v = vt.toLowerCase();
    return v.contains('bike') || v.contains('moto');
  }

  bool _isKeke(String vt) {
    final v = vt.toLowerCase();
    return v.contains('keke') || v.contains('tricycle') || v.contains('rickshaw');
  }

  bool _isCar(String vt) {
    return !_isBike(vt) && !_isKeke(vt);
  }

  // Gets the current list of drivers respecting the selected filter
  List<RideNearbyDriver> get _filteredDrivers {
    if (_activeFilter == 'All') return _stableDrivers;
    return _stableDrivers.where((d) {
      if (_activeFilter == 'Bike') return _isBike(d.vehicleType);
      if (_activeFilter == 'Ke-ke') return _isKeke(d.vehicleType);
      if (_activeFilter == 'Car') return _isCar(d.vehicleType);
      return true;
    }).toList();
  }

  bool get _showNoDrivers => !widget.loading && _filteredDrivers.isEmpty;

  // ── Distance ──────────────────────────────────────────────────────────────
  double get _tripKm {
    if (widget.tripDistanceKm != null && widget.tripDistanceKm! > 0) {
      return widget.tripDistanceKm!;
    }
    return _parseDistanceKm(widget.distanceText ?? '');
  }

  double _parseDistanceKm(String s) {
    final t = s.trim().toLowerCase();
    if (t.isEmpty) return 0;
    final numStr = RegExp(r'([\d.]+)').firstMatch(t)?.group(1);
    final v = numStr == null ? 0.0 : (double.tryParse(numStr) ?? 0.0);
    if (v <= 0) return 0;
    if (t.contains('m') && !t.contains('km')) return v / 1000.0;
    return v;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reconcileDrivers();
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

  // ── Utility ───────────────────────────────────────────────────────────────
  static num _num(dynamic v, num fallback) {
    if (v == null) return fallback;
    if (v is num) return v;
    if (v is String) return num.tryParse(v) ?? fallback;
    return fallback;
  }

  static List<String> _strList(dynamic v) {
    if (v == null) return const <String>[];
    if (v is List) {
      return v.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList(growable: false);
    }
    final s = v.toString().trim();
    if (s.isEmpty) return const <String>[];
    if (s.startsWith('[') && s.endsWith(']')) {
      return s.substring(1, s.length - 1)
          .split(',')
          .map((x) => x.replaceAll('"', '').replaceAll("'", '').trim())
          .where((x) => x.isNotEmpty)
          .toList(growable: false);
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

  bool _hasPrice(RideNearbyDriver d) =>
      d.estimatedTotal > 0 || d.pricePerKm > 0 || d.baseFare > 0;
  bool _hasImage(RideNearbyDriver d) =>
      d.imagesEffective.isNotEmpty || d.carImageUrl.trim().isNotEmpty;
  bool _hasContactData(RideNearbyDriver d) =>
      d.phone.trim().isNotEmpty || d.nin.trim().isNotEmpty;
  bool _hasPerformanceData(RideNearbyDriver d) =>
      d.completedTrips > 0 || d.reviewsCount > 0 || d.totalTrips > 0;
  bool _hasProfileData(RideNearbyDriver d) =>
      d.rank.trim().isNotEmpty ||
          d.vehicleDescription.trim().isNotEmpty ||
          d.avatarUrl.trim().isNotEmpty ||
          d.carPlate.trim().isNotEmpty;

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
      if (_isBike(vehicleType)) seats = 1;
      return RideNearbyDriver(
        id: (d.id ?? '').toString(),
        name: (d.name ?? 'Driver').toString(),
        category: (d.category ?? 'Standard').toString(),
        rating: _num(d.rating, 0).toDouble(),
        carPlate: (d.carPlate ?? d.car_plate ?? d.plate ?? '').toString(),
        heading: _num(d.heading, 0).toDouble(),
        lat: lat, lng: lng,
        distanceKm: _num(d.distanceKm ?? d.distance_km, 0).toDouble(),
        etaMin: _num(d.etaMin ?? d.eta_min, 0).toInt(),
        vehicleType: vehicleType, seats: seats,
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
      if (_isBike(vt)) seats = 1;
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
        vehicleType: vt, seats: seats,
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
    return const RideNearbyDriver(
      id: '', name: 'Driver', category: 'Standard', rating: 0,
      carPlate: '', heading: 0, lat: 0, lng: 0, distanceKm: 0, etaMin: 0,
    );
  }

  // ── Ranking ───────────────────────────────────────────────────────────────
  int _rankWeight(String r) {
    final x = r.trim().toLowerCase();
    if (x.contains('diamond'))  return 6;
    if (x.contains('platinum')) return 5;
    if (x.contains('gold'))     return 4;
    if (x.contains('silver'))   return 3;
    if (x.contains('bronze'))   return 2;
    if (x.contains('verified')) return 1;
    return 0;
  }

  double _safeRating(double r) =>
      r.isNaN || r.isInfinite ? 0 : r.clamp(0, 5).toDouble();

  int _compareDrivers(RideNearbyDriver a, RideNearbyDriver b) {
    final c1 = _safeRating(b.rating).compareTo(_safeRating(a.rating));
    if (c1 != 0) return c1;
    final c2 = _rankWeight(b.rank.trim().isEmpty ? 'verified' : b.rank)
        .compareTo(_rankWeight(a.rank.trim().isEmpty ? 'verified' : a.rank));
    if (c2 != 0) return c2;
    final c3 = a.etaMin.compareTo(b.etaMin);
    if (c3 != 0) return c3;
    final c4 = a.distanceKm.compareTo(b.distanceKm);
    if (c4 != 0) return c4;
    final c5 = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (c5 != 0) return c5;
    return a.id.compareTo(b.id);
  }

  // ── Stable list management ────────────────────────────────────────────────
  void _resetStable({bool alsoClearSelection = false}) {
    _stableIds.clear();
    _stableDrivers = const <RideNearbyDriver>[];
    _fullyFrozen = false;
    _settleUntil = null;
    if (alsoClearSelection) _selectedDriverId = null;
  }

  void _reconcileDrivers() {
    if (_selectedDriverId != null) { _fullyFrozen = true; return; }
    if (_settleUntil != null && DateTime.now().isAfter(_settleUntil!)) {
      _fullyFrozen = true;
    }
    if (_fullyFrozen) return;

    final incomingRaw = widget.drivers ?? const <dynamic>[];
    if (incomingRaw.isEmpty) return;

    final incoming = <RideNearbyDriver>[];
    for (final x in incomingRaw) {
      final d = _driverVM(x);
      if (d.id.isNotEmpty) incoming.add(d);
    }
    if (incoming.isEmpty) return;

    final byId = <String, RideNearbyDriver>{for (final d in incoming) d.id: d};

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
      final old   = oldById[id];
      final fresh = byId[id];
      if (old == null && fresh != null) {
        updated.add(fresh); changed = true; continue;
      }
      if (old != null && fresh != null) {
        final enrich = (!_hasPrice(old) && _hasPrice(fresh)) ||
            (!_hasImage(old) && _hasImage(fresh)) ||
            (_safeRating(old.rating) <= 0 && _safeRating(fresh.rating) > 0) ||
            (!_hasContactData(old) && _hasContactData(fresh)) ||
            (!_hasPerformanceData(old) && _hasPerformanceData(fresh)) ||
            (!_hasProfileData(old) && _hasProfileData(fresh));
        if (enrich) { updated.add(fresh); changed = true; } else { updated.add(old); }
        continue;
      }
      if (old != null) updated.add(old);
    }

    if (updated.isNotEmpty &&
        updated.every((d) => _hasPrice(d) || _tripKm <= 0) &&
        updated.every(_hasImage) &&
        updated.every(_hasContactData) &&
        updated.every(_hasPerformanceData)) {
      _fullyFrozen = true;
    }
    if (changed) setState(() => _stableDrivers = updated);
  }

  // ── Formatting ────────────────────────────────────────────────────────────
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
    final km = _tripKm > 0 ? _tripKm : (d.tripKm > 0 ? d.tripKm : 0);
    if (km > 0 && d.pricePerKm > 0) return d.baseFare + d.pricePerKm * km;
    return 0;
  }

  String _fmtDistShort(double km) {
    if (km <= 0) return 'Near';
    if (km < 1) return '${(km * 1000).round()}m';
    return '${km.toStringAsFixed(1)}km';
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  HYBRID MAX HEIGHT: 85% instead of 78% for max visibility
  // ─────────────────────────────────────────────────────────────────────────
  double _sheetMaxHeight(MediaQueryData mq, UIScale uiScale) {
    final h = mq.size.height;
    if (uiScale.landscape) {
      return (h * 0.85).clamp(220.0, 500.0);
    }
    return (h * 0.85).clamp(380.0, 800.0);
  }

  // ── Cancel confirm dialog ─────────────────────────────────────────────────
  Future<void> _handleCancelAction(
      BuildContext context, UIScale uiScale, bool isDark, ColorScheme cs) async {
    HapticFeedback.mediumImpact();
    final bool? confirm = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withOpacity(isDark ? 0.75 : 0.5),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (ctx, anim1, _) {
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
                      color: isDark
                          ? cs.surface.withOpacity(0.88)
                          : Colors.white.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(uiScale.radius(20)),
                      border: Border.all(color: cs.error.withOpacity(0.3), width: 1.2),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withOpacity(0.2),
                            blurRadius: 24,
                            offset: const Offset(0, 8))
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: uiScale.icon(48),
                          height: uiScale.icon(48),
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: cs.error.withOpacity(0.12)),
                          child: Icon(Icons.warning_amber_rounded,
                              size: uiScale.icon(24), color: cs.error),
                        ),
                        SizedBox(height: uiScale.gap(14)),
                        Text(
                          'Cancel Search?',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: uiScale.font(16),
                            fontWeight: FontWeight.w900,
                            color: isDark ? cs.onSurface : AppColors.textPrimary,
                            letterSpacing: -0.3,
                          ),
                        ),
                        SizedBox(height: uiScale.gap(8)),
                        Text(
                          'Stop searching? Your trip details will be saved.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: uiScale.font(11),
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? cs.onSurfaceVariant
                                : AppColors.textSecondary,
                            height: 1.4,
                          ),
                        ),
                        SizedBox(height: uiScale.gap(20)),
                        Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.symmetric(
                                      vertical: uiScale.inset(10)),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                          uiScale.radius(12))),
                                ),
                                child: Text(
                                  'Yes, Cancel',
                                  style: TextStyle(
                                      fontSize: uiScale.font(11),
                                      fontWeight: FontWeight.w800,
                                      color: cs.error),
                                ),
                              ),
                            ),
                            SizedBox(width: uiScale.gap(8)),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                  isDark ? cs.primary : AppColors.primary,
                                  foregroundColor:
                                  isDark ? cs.onPrimary : Colors.white,
                                  padding: EdgeInsets.symmetric(
                                      vertical: uiScale.inset(10)),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                          uiScale.radius(12))),
                                  elevation: 0,
                                ),
                                child: Text('Keep Searching',
                                    style: TextStyle(
                                        fontSize: uiScale.font(11),
                                        fontWeight: FontWeight.w800)),
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

  // ═══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final mq      = MediaQuery.of(context);
    final uiScale = UIScale.of(context);
    final theme   = Theme.of(context);
    final cs      = theme.colorScheme;
    final isDark  = theme.brightness == Brightness.dark;

    // Use the filtered list!
    final drivers = _filteredDrivers;
    final maxH    = _sheetMaxHeight(mq, uiScale);

    return Align(
      alignment: Alignment.bottomCenter,
      child: ClipRRect(
        borderRadius:
        BorderRadius.vertical(top: Radius.circular(uiScale.radius(22))),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(maxHeight: maxH),
            decoration: BoxDecoration(
              color: isDark
                  ? cs.surface.withOpacity(0.92)
                  : Colors.white.withOpacity(0.97),
              borderRadius: BorderRadius.vertical(
                  top: Radius.circular(uiScale.radius(22))),
              border: Border(
                top: BorderSide(
                  color: isDark
                      ? cs.outline.withOpacity(0.4)
                      : AppColors.mintBgLight.withOpacity(0.3),
                  width: 1.0,
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? 0.40 : 0.10),
                  blurRadius: uiScale.reduceFx ? 12 : 22,
                  offset: const Offset(0, -8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: uiScale.gap(6)),
                Container(
                  width: uiScale.landscape ? 40 : 46,
                  height: 4.0,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: isDark
                        ? cs.onSurfaceVariant.withOpacity(0.45)
                        : AppColors.textSecondary.withOpacity(0.20),
                  ),
                ),
                SizedBox(height: uiScale.gap(4)),

                _buildTopBar(context, uiScale, isDark: isDark, cs: cs),

                // Pass the length of the filtered list to the route strip
                _buildRouteStrip(context, uiScale, count: drivers.length, isDark: isDark, cs: cs),

                SizedBox(height: uiScale.gap(8)),

                // ── NEW: Vehicle Filter Strip ────────────────────────────────
                _buildFilterStrip(uiScale, isDark: isDark, cs: cs),

                SizedBox(height: uiScale.gap(4)),

                Flexible(
                  child: _buildContent(
                      context, drivers, uiScale,
                      isDark: isDark, cs: cs),
                ),

                _buildBottomBar(
                    context, mq, drivers, uiScale,
                    isDark: isDark, cs: cs),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Top bar ─────────────────────────────────────────────────────────────
  Widget _buildTopBar(BuildContext context, UIScale ui,
      {required bool isDark, required ColorScheme cs}) {
    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal: ui.inset(10), vertical: ui.inset(4)),
      child: Row(
        children: [
          _glassBtn(
            icon: Icons.close_rounded,
            isDark: isDark, cs: cs, ui: ui,
            onTap: () => _handleCancelAction(context, ui, isDark, cs),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Select Driver',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: isDark ? cs.onSurface : AppColors.textPrimary,
                    fontSize: ui.font(13),
                    letterSpacing: -0.25,
                    height: 1.0,
                  ),
                ),
                SizedBox(height: ui.gap(3)),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.loading)
                      SizedBox(
                        width: ui.icon(8), height: ui.icon(8),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              isDark ? cs.primary : AppColors.primary),
                        ),
                      )
                    else
                      Container(
                        width: ui.icon(6), height: ui.icon(6),
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF00E676)),
                      ),
                    SizedBox(width: ui.gap(4)),
                    Text(
                      widget.loading ? 'Searching...' : 'Live Market',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? cs.onSurfaceVariant
                            : AppColors.textSecondary,
                        fontSize: ui.font(9.5),
                        height: 1.0,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _glassBtn(
            icon: Icons.refresh_rounded,
            isDark: isDark, cs: cs, ui: ui,
            onTap: () {
              HapticFeedback.lightImpact();
              setState(() => _resetStable(alsoClearSelection: true));
              widget.onRefresh();
            },
          ),
        ],
      ),
    );
  }

  // ─── Compact Route Strip ───────────────────────────────────────────────────
  Widget _buildRouteStrip(BuildContext context, UIScale ui,
      {required int count, required bool isDark, required ColorScheme cs}) {
    final origin = widget.originText.trim().isEmpty
        ? 'Pickup'
        : widget.originText.trim();
    final dest = widget.destinationText.trim().isEmpty
        ? 'Destination'
        : widget.destinationText.trim();
    final primary = isDark ? cs.primary : AppColors.primary;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(10)),
      child: Container(
        height: 38,
        padding: EdgeInsets.symmetric(horizontal: ui.inset(10)),
        decoration: BoxDecoration(
          color: isDark
              ? cs.surfaceVariant.withOpacity(0.28)
              : Colors.black.withOpacity(0.025),
          borderRadius: BorderRadius.circular(ui.radius(10)),
          border: Border.all(
            color: isDark
                ? cs.outline.withOpacity(0.35)
                : AppColors.mintBgLight.withOpacity(0.5),
            width: 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 7, height: 7,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: Color(0xFF1A73E8)),
            ),
            SizedBox(width: ui.gap(5)),
            Expanded(
              flex: 5,
              child: Text(
                origin,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: ui.font(10.5),
                  color: isDark ? cs.onSurface : AppColors.textPrimary,
                  height: 1.0,
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: ui.gap(5)),
              child: Icon(Icons.arrow_forward_rounded,
                  size: ui.icon(11),
                  color: isDark
                      ? cs.onSurfaceVariant.withOpacity(0.5)
                      : Colors.black26),
            ),
            Container(
              width: 7, height: 7,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: Color(0xFF1E8E3E)),
            ),
            SizedBox(width: ui.gap(5)),
            Expanded(
              flex: 5,
              child: Text(
                dest,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: ui.font(10.5),
                  color: isDark ? cs.onSurface : AppColors.textPrimary,
                  height: 1.0,
                ),
              ),
            ),
            SizedBox(width: ui.gap(6)),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: ui.inset(6), vertical: ui.inset(3)),
              decoration: BoxDecoration(
                color: primary.withOpacity(0.10),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: primary.withOpacity(0.28), width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.radar_rounded, size: ui.icon(8.5), color: primary),
                  SizedBox(width: ui.gap(3)),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: ui.font(8.5),
                      fontWeight: FontWeight.w900,
                      color: primary,
                      height: 1.0,
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

  // ─── Vehicle Filter Strip (NEW) ───────────────────────────────────────────
  Widget _buildFilterStrip(UIScale ui, {required bool isDark, required ColorScheme cs}) {
    final filters = ['All', 'Car', 'Ke-ke', 'Bike'];
    final icons = {
      'All': Icons.apps_rounded,
      'Car': Icons.directions_car_rounded,
      'Ke-ke': Icons.electric_rickshaw_rounded,
      'Bike': Icons.two_wheeler_rounded,
    };

    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: ui.inset(10)),
        itemCount: filters.length,
        separatorBuilder: (_, __) => SizedBox(width: ui.gap(6)),
        itemBuilder: (_, i) {
          final f = filters[i];
          final selected = _activeFilter == f;
          final primary = isDark ? cs.primary : AppColors.primary;

          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() {
                _activeFilter = f;
                // Clear selection if the current selected driver doesn't match the new filter
                if (_selectedDriverId != null) {
                  final stillExists = _filteredDrivers.any((d) => d.id == _selectedDriverId);
                  if (!stillExists) _selectedDriverId = null;
                }
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: EdgeInsets.symmetric(horizontal: ui.inset(12)),
              decoration: BoxDecoration(
                color: selected
                    ? primary.withOpacity(0.12)
                    : (isDark ? cs.surfaceVariant.withOpacity(0.3) : Colors.black.withOpacity(0.03)),
                borderRadius: BorderRadius.circular(ui.radius(10)),
                border: Border.all(
                  color: selected
                      ? primary
                      : (isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.5)),
                  width: 1,
                ),
              ),
              alignment: Alignment.center,
              child: Row(
                children: [
                  Icon(
                      icons[f],
                      size: ui.icon(14),
                      color: selected ? primary : (isDark ? cs.onSurfaceVariant : AppColors.textSecondary)
                  ),
                  SizedBox(width: ui.gap(5)),
                  Text(
                    f,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
                      fontSize: ui.font(11.5),
                      letterSpacing: -0.2,
                      color: selected ? primary : (isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ─── Driver list content ──────────────────────────────────────────────────
  Widget _buildContent(BuildContext context, List<RideNearbyDriver> drivers,
      UIScale ui, {required bool isDark, required ColorScheme cs}) {
    return RepaintBoundary(
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
            ui.inset(10), ui.gap(4), ui.inset(10), ui.gap(4)),
        shrinkWrap: true,
        children: [
          if (_showNoDrivers)
            _buildEmptyState(context, ui, isDark: isDark, cs: cs)
          else ...[
            if (widget.loading && drivers.isEmpty)
              _buildLoadingRow(context, ui, isDark: isDark, cs: cs),
            ...List.generate(drivers.length, (i) {
              final d        = drivers[i];
              final selected = _selectedDriverId == d.id;
              return Padding(
                padding: EdgeInsets.only(bottom: ui.gap(5)),
                child: KeyedSubtree(
                  key: ValueKey(d.id),
                  child: _buildDriverCard(
                    context, d, ui,
                    selected: selected, isDark: isDark, cs: cs,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _selectedDriverId = d.id);
                    },
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  String _vehicleLabel(String vt) {
    if (_isBike(vt)) return 'Bike';
    if (_isKeke(vt)) return 'Ke-ke';
    return 'Car';
  }

  IconData _vehicleIcon(String t) {
    if (_isBike(t)) return Icons.two_wheeler_rounded;
    if (_isKeke(t)) return Icons.electric_rickshaw_rounded;
    return Icons.directions_car_rounded;
  }

  // ─── Tighter Driver Card ──────────────────────────────────────────────────
  Widget _buildDriverCard(
      BuildContext context, RideNearbyDriver d, UIScale ui, {
        required bool selected,
        required bool isDark,
        required ColorScheme cs,
        required VoidCallback onTap,
      }) {
    final rankText  = d.rank.trim().isEmpty ? 'Verified' : d.rank.trim();
    final rc        = _rankColor(rankText, isDark, cs);
    final vt        = d.vehicleType.trim().isEmpty ? 'car' : d.vehicleType.trim();
    final seats     = _isBike(vt) ? 1 : (d.seats <= 0 ? 4 : d.seats);
    final etaText   = d.etaMin <= 0 ? '1m' : '${d.etaMin}m';
    final distText  = _fmtDistShort(d.distanceKm);
    final total     = _driverTotal(d);
    final sym       = _curSym(d.currency);
    final totalText = total > 0 ? '$sym${_moneyFmt.format(total.round())}' : '—';
    final img       = d.imagesEffective.isNotEmpty
        ? _fixUrl(d.imagesEffective.first)
        : '';

    const double avatarSz = 30;
    const double thumbSz  = 28;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ui.radius(13)),
        boxShadow: selected
            ? [
          BoxShadow(
            color: (isDark ? cs.primary : AppColors.primary)
                .withOpacity(0.14),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(ui.radius(13)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
                horizontal: ui.inset(10), vertical: ui.inset(8)),
            decoration: BoxDecoration(
              color: selected
                  ? (isDark
                  ? cs.primary.withOpacity(0.11)
                  : AppColors.primary.withOpacity(0.055))
                  : (isDark
                  ? cs.surfaceVariant.withOpacity(0.28)
                  : Colors.white),
              borderRadius: BorderRadius.circular(ui.radius(13)),
              border: Border.all(
                color: selected
                    ? (isDark ? cs.primary : AppColors.primary)
                    : (isDark
                    ? cs.outline.withOpacity(0.28)
                    : AppColors.mintBgLight.withOpacity(0.55)),
                width: selected ? 1.5 : 1.0,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _avatarWithRank(
                  context, ui, d.avatarUrl, d.initials, rankText, rc,
                  size: avatarSz, selected: selected, isDark: isDark, cs: cs,
                ),
                SizedBox(width: ui.gap(8)),
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
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: isDark
                                    ? cs.onSurface
                                    : AppColors.textPrimary,
                                fontSize: ui.font(12.5),
                                height: 1.0,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                          SizedBox(width: ui.gap(4)),
                          _ratingPill(context, ui, d.rating,
                              isDark: isDark, cs: cs),
                        ],
                      ),
                      SizedBox(height: ui.gap(5)),
                      SizedBox(
                        height: 18,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          padding: EdgeInsets.zero,
                          children: [
                            _chip(ui,
                                icon: _vehicleIconNx(vt),
                                text: _vehicleLabel(vt),
                                tone: isDark ? cs.primary : AppColors.primary,
                                isDark: isDark, cs: cs),
                            SizedBox(width: ui.gap(4)),
                            _chip(ui,
                                icon: Icons.airline_seat_recline_normal_rounded,
                                text: '$seats',
                                tone: const Color(0xFF1A73E8),
                                isDark: isDark, cs: cs),
                            SizedBox(width: ui.gap(4)),
                            _chip(ui,
                                icon: Icons.av_timer_rounded,
                                text: etaText,
                                tone: const Color(0xFFB8860B),
                                isDark: isDark, cs: cs),
                            SizedBox(width: ui.gap(4)),
                            _chip(ui,
                                icon: Icons.route_rounded,
                                text: distText,
                                tone: isDark
                                    ? cs.primary
                                    : const Color(0xFF1E8E3E),
                                isDark: isDark, cs: cs),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: ui.gap(6)),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _thumb(context, ui, img, vt,
                            size: thumbSz, isDark: isDark, cs: cs),
                        if (selected) ...[
                          SizedBox(width: ui.gap(4)),
                          Icon(Icons.check_circle_rounded,
                              size: ui.icon(13),
                              color: isDark ? cs.primary : AppColors.primary),
                        ],
                      ],
                    ),
                    SizedBox(height: ui.gap(4)),
                    Text(
                      totalText,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: isDark ? cs.onSurface : AppColors.textPrimary,
                        fontSize: ui.font(13),
                        height: 1.0,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
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

  // ── Avatar with rank badge ─────────────────────────────────────────────────
  Widget _avatarWithRank(
      BuildContext context, UIScale ui, String url, String initials,
      String rank, Color rc, {
        required double size,
        required bool selected,
        required bool isDark,
        required ColorScheme cs,
      }) {
    final borderColor = selected
        ? (isDark ? cs.primary : AppColors.primary)
        : (isDark ? cs.outline.withOpacity(0.35) : Colors.black12);
    final bg = isDark
        ? cs.surfaceVariant
        : AppColors.mintBgLight.withOpacity(0.5);
    final u = _fixUrl(url);

    Widget fallback() => Container(
      width: size, height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bg,
        border: Border.all(
            color: borderColor, width: selected ? 1.5 : 1.0),
      ),
      child: Center(
        child: Text(
          initials,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: isDark ? cs.onSurface : AppColors.textPrimary,
            fontSize: ui.font(10),
          ),
        ),
      ),
    );

    final avatar = u.isEmpty
        ? fallback()
        : ClipOval(
      child: Container(
        width: size, height: size,
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(
              color: borderColor, width: selected ? 1.5 : 1.0),
        ),
        child: Image.network(u,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback()),
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
              padding: EdgeInsets.all(ui.inset(2)),
              decoration: BoxDecoration(
                color: isDark ? cs.surface : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                    color: isDark ? cs.outline : Colors.black12),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 2,
                      offset: const Offset(0, 1))
                ],
              ),
              child: Icon(_rankIcon(rank), size: ui.icon(7.5), color: rc),
            ),
          ),
        ],
      ),
    );
  }

  // ── Vehicle thumbnail ─────────────────────────────────────────────────────
  Widget _thumb(BuildContext context, UIScale ui, String url, String vehicleType,
      {required double size, required bool isDark, required ColorScheme cs}) {
    Widget fallback() => Container(
      width: size, height: size,
      decoration: BoxDecoration(
        color: isDark
            ? cs.surfaceVariant
            : AppColors.mintBgLight.withOpacity(0.5),
        borderRadius: BorderRadius.circular(ui.radius(7)),
        border: Border.all(
            color: isDark
                ? cs.outline.withOpacity(0.35)
                : Colors.black12),
      ),
      child: Center(
        child: Icon(_vehicleIcon(vehicleType),
            color: isDark
                ? cs.onSurfaceVariant
                : AppColors.textSecondary.withOpacity(0.6),
            size: ui.icon(12)),
      ),
    );

    final u = _fixUrl(url);
    if (u.isEmpty) return fallback();
    return ClipRRect(
      borderRadius: BorderRadius.circular(ui.radius(7)),
      child: SizedBox(
        width: size, height: size,
        child: Image.network(u,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback()),
      ),
    );
  }

  // ── Rating pill ───────────────────────────────────────────────────────────
  Widget _ratingPill(BuildContext context, UIScale ui, double rating,
      {required bool isDark, required ColorScheme cs}) {
    final r = rating.clamp(0, 5).toDouble();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: ui.inset(5), vertical: ui.inset(2.5)),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: const Color(0xFFFFD54F).withOpacity(0.14),
        border: Border.all(color: const Color(0xFFFFD54F).withOpacity(0.38)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded,
              size: ui.icon(9.0), color: const Color(0xFFFFC107)),
          SizedBox(width: ui.gap(2)),
          Text(
            r.toStringAsFixed(1),
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: isDark
                  ? Colors.white
                  : AppColors.textPrimary.withOpacity(0.9),
              fontSize: ui.font(8.5),
              height: 1.0,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  // ── Compact chip ─────────────────────────────────────────────────────────
  Widget _chip(UIScale ui,
      {required IconData icon,
        required String text,
        required Color tone,
        required bool isDark,
        required ColorScheme cs}) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: ui.inset(5.5), vertical: ui.inset(2)),
      decoration: BoxDecoration(
        color: tone.withOpacity(isDark ? 0.14 : 0.06),
        borderRadius: BorderRadius.circular(999),
        border:
        Border.all(color: tone.withOpacity(isDark ? 0.38 : 0.14), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: ui.icon(8.5), color: tone),
          SizedBox(width: ui.gap(3)),
          Text(
            text,
            maxLines: 1,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: isDark ? cs.onSurface : AppColors.textPrimary,
              fontSize: ui.font(8.5),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  // ── Loading row ───────────────────────────────────────────────────────────
  Widget _buildLoadingRow(BuildContext context, UIScale ui,
      {required bool isDark, required ColorScheme cs}) {
    return Container(
      margin: EdgeInsets.only(bottom: ui.gap(6)),
      padding: EdgeInsets.all(ui.inset(10)),
      decoration: BoxDecoration(
        color: isDark
            ? cs.surfaceVariant.withOpacity(0.28)
            : Colors.black.withOpacity(0.02),
        borderRadius: BorderRadius.circular(ui.radius(11)),
        border: Border.all(
            color: isDark
                ? cs.outline.withOpacity(0.28)
                : Colors.black.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: ui.icon(13), height: ui.icon(13),
            child: CircularProgressIndicator(
              strokeWidth: 2.0,
              valueColor: AlwaysStoppedAnimation<Color>(
                  isDark ? cs.primary : AppColors.primary),
            ),
          ),
          SizedBox(width: ui.gap(10)),
          Expanded(
            child: Text(
              'Finding drivers nearby...',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: isDark ? cs.onSurface : AppColors.textPrimary,
                fontSize: ui.font(10.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Empty state ───────────────────────────────────────────────────────────
  Widget _buildEmptyState(BuildContext context, UIScale ui,
      {required bool isDark, required ColorScheme cs}) {

    // Check if there are drivers, but none match the current filter
    final hasOthers = _stableDrivers.isNotEmpty;
    final emptyMsg = hasOthers ? 'No ${_activeFilter}s available' : 'No drivers available';

    return Padding(
      padding: EdgeInsets.symmetric(vertical: ui.gap(16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: EdgeInsets.all(ui.inset(10)),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? cs.surface : Colors.white,
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4))
              ],
            ),
            child: Icon(Icons.directions_car_filled_rounded,
                color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                size: ui.icon(22)),
          ),
          SizedBox(height: ui.gap(10)),
          Text(
            emptyMsg,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: isDark ? cs.onSurface : AppColors.textPrimary,
              fontSize: ui.font(12),
              letterSpacing: -0.2,
            ),
          ),
          SizedBox(height: ui.gap(4)),
          Text(
            'Please try refreshing in a moment.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
              fontSize: ui.font(10.5),
            ),
          ),
          SizedBox(height: ui.gap(14)),
          SizedBox(
            height: 38,
            child: ElevatedButton(
              onPressed: () {
                HapticFeedback.selectionClick();
                setState(() => _resetStable(alsoClearSelection: true));
                widget.onRefresh();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark ? cs.primary : AppColors.primary,
                foregroundColor: isDark ? cs.onPrimary : Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(ui.radius(10))),
                elevation: 0,
                padding: EdgeInsets.symmetric(horizontal: ui.inset(24)),
              ),
              child: Text('Refresh',
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: ui.font(11.5))),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Native SafeArea Bottom Bar ────────────────────────────────
  Widget _buildBottomBar(
      BuildContext context, MediaQueryData mq,
      List<RideNearbyDriver> drivers, UIScale ui, {
        required bool isDark,
        required ColorScheme cs,
      }) {
    final selectedList = _selectedDriverId != null
        ? drivers.where((x) => x.id == _selectedDriverId).toList()
        : <RideNearbyDriver>[];
    final driverSelected = selectedList.isNotEmpty;

    // Use native bottom padding to handle iOS home indicator/Android nav bars
    final bottomSafe = math.max(mq.padding.bottom, ui.inset(12));
    final buttonH = math.max(44.0, ui.landscape ? ui.gap(40) : ui.gap(46));

    return Container(
      padding: EdgeInsets.fromLTRB(
          ui.inset(16), ui.inset(10), ui.inset(16), bottomSafe + ui.inset(6)),
      decoration: BoxDecoration(
        color: isDark
            ? cs.surface.withOpacity(0.85)
            : Colors.white.withOpacity(0.95),
        border: Border(
          top: BorderSide(
            color: isDark
                ? cs.outline.withOpacity(0.35)
                : Colors.black.withOpacity(0.04),
          ),
        ),
      ),
      child: SizedBox(
        width: double.infinity,
        height: buttonH,
        child: ElevatedButton(
          onPressed: driverSelected
              ? () async {
            HapticFeedback.selectionClick();
            final d = selectedList.first;
            setState(() => _fullyFrozen = true);

            final payload =
            await showModalBottomSheet<Map<String, dynamic>>(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => DriverDetailsSheet(
                driver: _driverToMap(d),
                offer: _offerMapFromDriver(d),
                originText: widget.originText,
                destinationText: widget.destinationText,
                distanceText: widget.distanceText,
                durationText: widget.durationText,
                tripDistanceKm: _tripKm,
                userLocation: widget.userLocation,
                pickupLocation: widget.pickupLocation,
                dropLocation: widget.dropLocation,
              ),
            );

            if (payload == null) {
              setState(() => _fullyFrozen = false);
              return;
            }

            final offer = RideOffer(
              id: 'driver-${d.id}',
              provider: 'PickMe',
              category: d.category.isNotEmpty
                  ? d.category
                  : _vehicleLabel(d.vehicleType),
              etaToPickupMin: d.etaMin,
              price: _driverTotal(d).round(),
              surge: false,
              driverName: d.name,
              rating: d.rating,
              carPlate: d.carPlate,
              seats: d.seats,
              currency: d.currency,
              pricePerKm: d.pricePerKm,
              baseFare: d.baseFare,
              estimatedTotal: _driverTotal(d),
              vehicleType: d.vehicleType,
            );
            widget.onBook(d, offer);
          }
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: isDark ? cs.primary : AppColors.primary,
            foregroundColor: isDark ? cs.onPrimary : Colors.white,
            disabledBackgroundColor:
            isDark ? cs.surfaceVariant : AppColors.mintBgLight,
            disabledForegroundColor: isDark
                ? cs.onSurfaceVariant.withOpacity(0.5)
                : AppColors.textSecondary.withOpacity(0.5),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(ui.radius(14))),
            elevation: driverSelected ? 3 : 0,
          ),
          child: Text(
            driverSelected
                ? 'Continue with ${selectedList.first.name.split(" ").first}'
                : 'Select a driver to continue',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: ui.font(13.5),
              letterSpacing: -0.1,
            ),
          ),
        ),
      ),
    );
  }

  // ── Map helpers ───────────────────────────────────────────────────────────
  Map<String, dynamic> _driverToMap(RideNearbyDriver d) => <String, dynamic>{
    'id': d.id, 'name': d.name, 'category': d.category,
    'rating': d.rating, 'car_plate': d.carPlate,
    'lat': d.lat, 'lng': d.lng, 'heading': d.heading,
    'distance_km': d.distanceKm, 'eta_min': d.etaMin,
    'vehicle_type': d.vehicleType, 'seats': d.seats,
    'vehicle_images': d.vehicleImages,
    'vehicle_description': d.vehicleDescription,
    'car_image_url': d.carImageUrl, 'avatar_url': d.avatarUrl,
    'phone': d.phone, 'nin': d.nin, 'rank': d.rank,
    'completed_trips': d.completedTrips, 'cancelled_trips': d.cancelledTrips,
    'incomplete_trips': d.incompleteTrips, 'reviews_count': d.reviewsCount,
    'total_trips': d.totalTrips, 'currency': d.currency,
    'price_per_km': d.pricePerKm, 'base_fare': d.baseFare,
    'estimated_total': _driverTotal(d), 'trip_km': _tripKm,
  };

  Map<String, dynamic> _offerMapFromDriver(RideNearbyDriver d) {
    final total = _driverTotal(d);
    return <String, dynamic>{
      'id': 'driver-${d.id}', 'provider': 'PickMe',
      'category': _vehicleLabel(d.vehicleType),
      'vehicle_type': d.vehicleType, 'seats': d.seats,
      'eta_min': d.etaMin, 'currency': d.currency,
      'price_per_km': d.pricePerKm, 'base_fare': d.baseFare,
      'estimated_total': total, 'trip_km': _tripKm, 'price_total': total,
    };
  }

  // ── Icon helpers ──────────────────────────────────────────────────────────
  IconData _rankIcon(String r) {
    final x = r.trim().toLowerCase();
    if (x.contains('platinum')) return Icons.workspace_premium_rounded;
    if (x.contains('gold'))     return Icons.emoji_events_rounded;
    if (x.contains('silver'))   return Icons.military_tech_rounded;
    if (x.contains('bronze'))   return Icons.military_tech_outlined;
    return Icons.verified_rounded;
  }

  Color _rankColor(String r, bool isDark, ColorScheme cs) {
    final x = r.trim().toLowerCase();
    if (x.contains('platinum')) return const Color(0xFF6A5ACD);
    if (x.contains('gold'))     return const Color(0xFFB8860B);
    if (x.contains('silver'))   return const Color(0xFF607D8B);
    if (x.contains('bronze'))   return const Color(0xFF8D6E63);
    return isDark ? cs.primary : const Color(0xFF1E8E3E);
  }

  // ── Glass button ──────────────────────────────────────────────────────────
  Widget _glassBtn({
    required IconData icon,
    required bool isDark,
    required ColorScheme cs,
    required UIScale ui,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: EdgeInsets.all(ui.inset(6)),
          decoration: BoxDecoration(
            color: isDark
                ? cs.surfaceVariant.withOpacity(0.45)
                : AppColors.mintBgLight.withOpacity(0.45),
            shape: BoxShape.circle,
            border: Border.all(
                color: isDark
                    ? cs.outline.withOpacity(0.35)
                    : Colors.black.withOpacity(0.05)),
          ),
          child: Icon(icon,
              size: ui.icon(15),
              color: isDark ? cs.onSurface : AppColors.textPrimary),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  Standalone helpers
// ═════════════════════════════════════════════════════════════════════════════
IconData _vehicleIconNx(String vt) {
  final v = vt.toLowerCase();
  if (v.contains('bike') || v.contains('moto')) return Icons.two_wheeler_rounded;
  if (v.contains('keke') || v.contains('tricycle') || v.contains('rickshaw')) return Icons.electric_rickshaw_rounded;
  if (v.contains('bus')  || v.contains('van'))  return Icons.airport_shuttle_rounded;
  if (v.contains('lux')  || v.contains('vip'))  return Icons.workspace_premium_rounded;
  return Icons.directions_car_filled_rounded;
}