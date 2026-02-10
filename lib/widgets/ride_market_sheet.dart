// lib/widgets/ride_market_sheet.dart
//
// Bottom-sheet (edge-to-edge, touches bottom) + driver selection + offer selection.
// Auto-locks when drivers appear to stop shuffling so user can choose calmly.
//
// REQUIRED in HomePage call:
//  - pass drivers + driversNearbyCount
//  - implement onBook(driver, offer)
//
// NOTE: uses your theme + AppColors.primary (light theme friendly)

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../themes/app_theme.dart';
import '../services/ride_market_service.dart'; // RideOffer, DriverCar (or compatible)
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

  // ✅ NEW (fits your API standard; added, not removing anything)
  final String vehicleType; // car | bike
  final int seats;
  final List<String> vehicleImages; // multiple images
  final String vehicleDescription;
  final String carImageUrl; // backward compat / single image
  final String phone;
  final String nin;
  final String rank;
  final int completedTrips;
  final int cancelledTrips;
  final int incompleteTrips;
  final int reviewsCount;
  final int totalTrips;
  final String avatarUrl;

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

    // defaults
    this.vehicleType = 'car',
    this.seats = 4,
    this.vehicleImages = const [],
    this.vehicleDescription = '',
    this.carImageUrl = '',
    this.phone = '',
    this.nin = '',
    this.rank = '',
    this.completedTrips = 0,
    this.cancelledTrips = 0,
    this.incompleteTrips = 0,
    this.reviewsCount = 0,
    this.totalTrips = 0,
    this.avatarUrl = '',
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
    final imgs = <String>[];
    for (final x in vehicleImages) {
      final s = x.trim();
      if (s.isNotEmpty) imgs.add(s);
    }
    if (imgs.isEmpty && carImageUrl.trim().isNotEmpty) imgs.add(carImageUrl.trim());
    return imgs;
  }
}

class RideMarketSheet extends StatefulWidget {
  final double bottomNavHeight;

  final String originText;
  final String destinationText;

  final String? distanceText;
  final String? durationText;

  // ✅ optional numeric distance (km) if you have it; otherwise we parse distanceText.
  final double? tripDistanceKm;

  final int driversNearbyCount;
  final List<dynamic>? drivers;

  final List<RideOffer> offers;
  final bool loading;

  final VoidCallback onRefresh;
  final VoidCallback onCancel;

  /// Booking action: after user selects a driver + offer and confirms in driver details sheet.
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
  });

  @override
  State<RideMarketSheet> createState() => _RideMarketSheetState();
}

class _RideMarketSheetState extends State<RideMarketSheet> {
  final _moneyFmt = NumberFormat.decimalPattern();

  // Auto-lock when drivers appear (stops shuffling)
  bool _locked = false;

  // Snapshots used while locked
  List<dynamic> _driversSnap = const [];
  List<RideOffer> _offersSnap = const [];
  int _driversCountSnap = 0;

  // Selection
  int _selectedDriverIdx = -1;
  int _selectedOfferIdx = -1;

  bool get _effectiveLoading => _locked ? false : widget.loading;

  List<dynamic> get _driversRaw => _locked ? _driversSnap : (widget.drivers ?? const []);
  List<RideOffer> get _offersRaw => _locked ? _offersSnap : widget.offers;

  int get _driversCountEffective {
    final count = _locked ? _driversCountSnap : widget.driversNearbyCount;
    return math.max(count, _driversVM.length);
  }

  bool get _hasDrivers => _driversCountEffective > 0;
  bool get _hasOffers => _offersRaw.isNotEmpty;

  // ✅ Only show “No cars nearby” when truly nothing exists.
  bool get _showNoCars => !_effectiveLoading && !_hasDrivers && !_hasOffers;

  // -------------------------
  // Robust adapters
  // -------------------------
  RideNearbyDriver _driverVM(dynamic raw) {
    // helper for list fields
    List<String> strList(dynamic v) {
      if (v == null) return const [];
      if (v is List) {
        return v.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList();
      }
      // sometimes backend could send CSV
      final s = v.toString().trim();
      if (s.isEmpty) return const [];
      if (s.startsWith('[') && s.endsWith(']')) {
        // looks like JSON array string but without decoding here; keep simple split fallback
        final inner = s.substring(1, s.length - 1);
        return inner
            .split(',')
            .map((x) => x.replaceAll('"', '').replaceAll("'", '').trim())
            .where((x) => x.isNotEmpty)
            .toList();
      }
      return s.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
    }

    if (raw is DriverCar) {
      final ll = (raw as dynamic).ll;
      final lat = (ll != null) ? (ll.latitude as double) : 0.0;
      final lng = (ll != null) ? (ll.longitude as double) : 0.0;

      // try read new fields if they exist on object
      final d = raw as dynamic;

      return RideNearbyDriver(
        id: ((d).id ?? '').toString(),
        name: ((d).name ?? 'Driver').toString(),
        category: ((d).category ?? 'Economy').toString(),
        rating: _num((d).rating, 0).toDouble(),
        carPlate: ((d).carPlate ?? '').toString(),
        heading: _num((d).heading, 0).toDouble(),
        lat: lat,
        lng: lng,
        distanceKm: _num((d).distanceKm, 0).toDouble(),
        etaMin: _num((d).etaMin, 0).toInt(),

        vehicleType: ((d).vehicleType ?? (d).vehicle_type ?? 'car').toString(),
        seats: _num((d).seats, 4).toInt(),
        vehicleImages: strList((d).vehicleImages ?? (d).vehicle_images),
        vehicleDescription: ((d).vehicleDescription ?? (d).vehicle_description ?? '').toString(),
        carImageUrl: ((d).carImageUrl ?? (d).car_image_url ?? '').toString(),
        phone: ((d).phone ?? '').toString(),
        nin: ((d).nin ?? '').toString(),
        rank: ((d).rank ?? '').toString(),
        completedTrips: _num((d).completedTrips ?? (d).completed_trips, 0).toInt(),
        cancelledTrips: _num((d).cancelledTrips ?? (d).cancelled_trips, 0).toInt(),
        incompleteTrips: _num((d).incompleteTrips ?? (d).incomplete_trips, 0).toInt(),
        reviewsCount: _num((d).reviewsCount ?? (d).reviews_count, 0).toInt(),
        totalTrips: _num((d).totalTrips ?? (d).total_trips, 0).toInt(),
        avatarUrl: ((d).avatarUrl ?? (d).avatar_url ?? '').toString(),
      );
    }

    if (raw is Map) {
      final m = raw.cast<String, dynamic>();
      return RideNearbyDriver(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? 'Driver').toString(),
        category: (m['category'] ?? 'Economy').toString(),
        rating: _num(m['rating'], 0).toDouble(),
        carPlate: (m['car_plate'] ?? m['plate'] ?? '').toString(),
        heading: _num(m['heading'], 0).toDouble(),
        lat: _num(m['lat'], 0).toDouble(),
        lng: _num(m['lng'], 0).toDouble(),
        distanceKm: _num(m['distance_km'], 0).toDouble(),
        etaMin: _num(m['eta_min'], 0).toInt(),

        // ✅ your API fields
        vehicleType: (m['vehicle_type'] ?? 'car').toString(),
        seats: _num(m['seats'], 4).toInt(),
        vehicleImages: strList(m['vehicle_images']),
        vehicleDescription: (m['vehicle_description'] ?? '').toString(),
        carImageUrl: (m['car_image_url'] ?? '').toString(),
        phone: (m['phone'] ?? '').toString(),
        nin: (m['nin'] ?? '').toString(),
        rank: (m['rank'] ?? '').toString(),
        completedTrips: _num(m['completed_trips'], 0).toInt(),
        cancelledTrips: _num(m['cancelled_trips'], 0).toInt(),
        incompleteTrips: _num(m['incomplete_trips'], 0).toInt(),
        reviewsCount: _num(m['reviews_count'], 0).toInt(),
        totalTrips: _num(m['total_trips'], 0).toInt(),
        avatarUrl: (m['avatar_url'] ?? '').toString(),
      );
    }

    // Unknown object
    try {
      final d = raw as dynamic;

      List<String> strList(dynamic v) {
        if (v == null) return const [];
        if (v is List) {
          return v.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList();
        }
        final s = v.toString().trim();
        if (s.isEmpty) return const [];
        return s.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
      }

      return RideNearbyDriver(
        id: (d.id ?? '').toString(),
        name: (d.name ?? 'Driver').toString(),
        category: (d.category ?? 'Economy').toString(),
        rating: _num(d.rating, 0).toDouble(),
        carPlate: (d.carPlate ?? d.car_plate ?? d.plate ?? '').toString(),
        heading: _num(d.heading, 0).toDouble(),
        lat: _num(d.ll?.latitude ?? d.lat, 0).toDouble(),
        lng: _num(d.ll?.longitude ?? d.lng, 0).toDouble(),
        distanceKm: _num(d.distanceKm ?? d.distance_km, 0).toDouble(),
        etaMin: _num(d.etaMin ?? d.eta_min, 0).toInt(),

        vehicleType: (d.vehicleType ?? d.vehicle_type ?? 'car').toString(),
        seats: _num(d.seats, 4).toInt(),
        vehicleImages: strList(d.vehicleImages ?? d.vehicle_images),
        vehicleDescription: (d.vehicleDescription ?? d.vehicle_description ?? '').toString(),
        carImageUrl: (d.carImageUrl ?? d.car_image_url ?? '').toString(),
        phone: (d.phone ?? '').toString(),
        nin: (d.nin ?? '').toString(),
        rank: (d.rank ?? '').toString(),
        completedTrips: _num(d.completedTrips ?? d.completed_trips, 0).toInt(),
        cancelledTrips: _num(d.cancelledTrips ?? d.cancelled_trips, 0).toInt(),
        incompleteTrips: _num(d.incompleteTrips ?? d.incomplete_trips, 0).toInt(),
        reviewsCount: _num(d.reviewsCount ?? d.reviews_count, 0).toInt(),
        totalTrips: _num(d.totalTrips ?? d.total_trips, 0).toInt(),
        avatarUrl: (d.avatarUrl ?? d.avatar_url ?? '').toString(),
      );
    } catch (_) {
      return const RideNearbyDriver(
        id: '',
        name: 'Driver',
        category: 'Economy',
        rating: 0,
        carPlate: '',
        heading: 0,
        lat: 0,
        lng: 0,
        distanceKm: 0,
        etaMin: 0,
      );
    }
  }

  static num _num(dynamic v, num fallback) {
    if (v == null) return fallback;
    if (v is num) return v;
    if (v is String) return num.tryParse(v) ?? fallback;
    return fallback;
  }

  List<RideNearbyDriver> get _driversVM {
    final out = <RideNearbyDriver>[];
    for (final x in _driversRaw) {
      final d = _driverVM(x);
      if (d.id.isEmpty) continue;
      out.add(d);
    }
    out.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    return out;
  }

  Map<String, dynamic> _offerToMap(RideOffer o) {
    try {
      final j = (o as dynamic).toJson?.call();
      if (j is Map) return j.cast<String, dynamic>();
    } catch (_) {}
    final d = o as dynamic;
    final m = <String, dynamic>{};
    try { m['category'] = d.category; } catch (_) {}
    try { m['name'] = d.name; } catch (_) {}
    try { m['label'] = d.label; } catch (_) {}
    try { m['eta_min'] = d.etaMin; } catch (_) {}
    try { m['price'] = d.price; } catch (_) {}
    try { m['currency'] = d.currency; } catch (_) {}
    try { m['seats'] = d.seats; } catch (_) {}
    try { m['rating'] = d.rating; } catch (_) {}
    try { m['promo_applied'] = d.promoApplied; } catch (_) {}
    try { m['original_price'] = d.originalPrice; } catch (_) {}

    // ✅ allow per-km pricing payloads
    try { m['price_per_km'] = d.pricePerKm; } catch (_) {}
    try { m['vehicle_type'] = d.vehicleType; } catch (_) {}
    return m;
  }

  String _offerTitle(RideOffer o) {
    final m = _offerToMap(o);
    return (m['category'] ?? m['name'] ?? m['label'] ?? 'Ride').toString();
  }

  int _offerEta(RideOffer o) => _num(_offerToMap(o)['eta_min'], 0).toInt();

  double _offerPerKmPrice(RideOffer o) {
    final m = _offerToMap(o);
    final pk = _num(m['price_per_km'], -1).toDouble();
    if (pk >= 0) return pk;
    // fallback: treat "price" as per-km if no other info
    return _num(m['price'], 0).toDouble();
  }

  double _offerOld(RideOffer o) => _num(_offerToMap(o)['original_price'], 0).toDouble();

  String _currency(RideOffer o) {
    final c = (_offerToMap(o)['currency'] ?? 'NGN').toString().toUpperCase();
    if (c == 'NGN') return '₦';
    if (c == 'USD') return '\$';
    return c;
  }

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
    return v; // assume km
  }

  double _offerTotalForTrip(RideOffer o) {
    final perKm = _offerPerKmPrice(o);
    final km = _tripKm;
    if (km > 0) return perKm * km;
    return perKm;
  }

  Map<String, dynamic> _driverToMap(RideNearbyDriver d) {
    return <String, dynamic>{
      'id': d.id,
      'name': d.name,
      'category': d.category,
      'rating': d.rating,
      'car_plate': d.carPlate,
      'lat': d.lat,
      'lng': d.lng,
      'heading': d.heading,
      'distance_km': d.distanceKm,
      'eta_min': d.etaMin,

      'vehicle_type': d.vehicleType,
      'seats': d.seats,
      'vehicle_images': d.vehicleImages,
      'vehicle_description': d.vehicleDescription,
      'car_image_url': d.carImageUrl,

      'phone': d.phone,
      'nin': d.nin,
      'rank': d.rank,
      'completed_trips': d.completedTrips,
      'cancelled_trips': d.cancelledTrips,
      'incomplete_trips': d.incompleteTrips,
      'reviews_count': d.reviewsCount,
      'total_trips': d.totalTrips,
      'avatar_url': d.avatarUrl,
    };
  }

  // -------------------------
  // Auto-lock when drivers appear
  // -------------------------
  @override
  void didUpdateWidget(covariant RideMarketSheet oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Default-select first offer when offers arrive (like Bolt “Select Bolt”).
    if (_selectedOfferIdx < 0 && widget.offers.isNotEmpty) {
      _selectedOfferIdx = 0;
    }

    // Auto-lock when drivers become available (stops shuffling)
    final incomingDriversCount = math.max(widget.driversNearbyCount, (widget.drivers ?? const []).length);
    if (!_locked && incomingDriversCount > 0) {
      _lockNow();
    }
  }

  void _lockNow() {
    setState(() {
      _locked = true;
      _driversSnap = List<dynamic>.from(widget.drivers ?? const []);
      _offersSnap = List<RideOffer>.from(widget.offers);
      _driversCountSnap = widget.driversNearbyCount;
    });
  }

  void _unlockAndRefresh() {
    setState(() {
      _locked = false;
      _driversSnap = const [];
      _offersSnap = const [];
      _driversCountSnap = 0;
      _selectedDriverIdx = -1;
      // Keep offer default behavior
    });
    widget.onRefresh();
  }

  // -------------------------
  // UI
  // -------------------------
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cs = Theme.of(context).colorScheme;

    // True “bottom sheet” feel: full width, bottom-aligned, no outer margin.
    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(
            // Similar to screenshot: not too tall; scroll inside.
            maxHeight: mq.size.height * 0.52,
          ),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.18),
                blurRadius: 16,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: Column(
            children: [
              const SizedBox(height: 8),
              _handle(cs),
              const SizedBox(height: 6),
              _topBar(context),
              Expanded(child: _content(context)),
              _bottomBar(context, mq),
            ],
          ),
        ),
      ),
    );
  }

  Widget _handle(ColorScheme cs) {
    return Container(
      width: 54,
      height: 5,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: cs.onSurface.withOpacity(0.18),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          IconButton(
            onPressed: widget.onCancel,
            icon: const Icon(Icons.close_rounded),
          ),
          Expanded(
            child: Text(
              'Ride options',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: cs.onSurface.withOpacity(0.85),
              ),
            ),
          ),
          IconButton(
            onPressed: _locked ? _unlockAndRefresh : widget.onRefresh,
            icon: Icon(_locked ? Icons.lock_open_rounded : Icons.refresh_rounded),
            tooltip: _locked ? 'Unlock & refresh' : 'Refresh',
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final drivers = _driversVM;
    final offers = _offersRaw;

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      children: [
        _routeMini(context),
        const SizedBox(height: 10),

        if (_locked)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.primary.withOpacity(0.25)),
            ),
            child: Row(
              children: [
                Icon(Icons.lock_rounded, color: AppColors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Drivers found. List locked so user can select.',
                    style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.78)),
                  ),
                ),
              ],
            ),
          ),

        if (_locked) const SizedBox(height: 10),

        if (_showNoCars) ...[
          _emptyState(context),
        ] else ...[
          if (drivers.isNotEmpty) ...[
            _driversHeader(context, drivers.length),
            const SizedBox(height: 8),
            if (drivers.length >= 2) ...[
              _smartDriverInsights(context, drivers),
              const SizedBox(height: 10),
            ],
            ...List.generate(drivers.length, (i) {
              final selected = i == _selectedDriverIdx;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _driverCard(context, drivers[i], selected: selected, onTap: () {
                  setState(() => _selectedDriverIdx = i);
                }),
              );
            }),
            const SizedBox(height: 6),
          ] else if (_hasDrivers) ...[
            _driversHeader(context, 0),
            const SizedBox(height: 8),
            _hint(context, '${_driversCountEffective} drivers nearby', 'Pass drivers list to show full details.'),
            const SizedBox(height: 10),
          ],

          _section('Ride options'),
          const SizedBox(height: 8),

          if (_effectiveLoading) _loadingRow(context),

          ...List.generate(offers.length, (i) {
            final selected = i == _selectedOfferIdx;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _offerCard(context, offers[i], selected: selected, onTap: () {
                setState(() => _selectedOfferIdx = i);
              }),
            );
          }),

          if (!_effectiveLoading && _hasDrivers && offers.isEmpty)
            _hint(context, 'Drivers found', 'Fetching prices… tap refresh if it takes too long.'),
        ],
      ],
    );
  }

  Widget _routeMini(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final origin = widget.originText.trim().isEmpty ? 'Pickup' : widget.originText.trim();
    final dest = widget.destinationText.trim().isEmpty ? 'Destination' : widget.destinationText.trim();
    final dist = widget.distanceText ?? '--';
    final dur = widget.durationText ?? '--';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          // ✅ blue/green dot like your screenshot
          Column(
            children: [
              Container(width: 10, height: 10, decoration: const BoxDecoration(color: Color(0xFF1A73E8), shape: BoxShape.circle)),
              Container(width: 2, height: 18, margin: const EdgeInsets.symmetric(vertical: 3), decoration: BoxDecoration(color: cs.onSurface.withOpacity(0.18), borderRadius: BorderRadius.circular(99))),
              Container(width: 10, height: 10, decoration: const BoxDecoration(color: Color(0xFF1E8E3E), shape: BoxShape.circle)),
            ],
          ),
          const SizedBox(width: 10),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(origin, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.85))),
                const SizedBox(height: 4),
                Text(dest, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurface.withOpacity(0.60))),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _pill(context, Icons.schedule_rounded, dur),
                    const SizedBox(width: 8),
                    _pill(context, Icons.straighten_rounded, dist),
                    const Spacer(),
                    _nearbyPill(context),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _nearbyPill(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final txt = _hasDrivers ? '$_driversCountEffective nearby' : '0 nearby';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.04),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.onSurface.withOpacity(0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.near_me_rounded, size: 16, color: cs.onSurface.withOpacity(0.65)),
          const SizedBox(width: 8),
          Text(txt, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.75), fontSize: 12)),
        ],
      ),
    );
  }

  Widget _driversHeader(BuildContext context, int count) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text('Nearby drivers', style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.88), fontSize: 13)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.primary.withOpacity(0.25)),
          ),
          child: Text(
            count > 0 ? '$count available' : '${_driversCountEffective} nearby',
            style: TextStyle(fontWeight: FontWeight.w900, color: AppColors.primary, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _smartDriverInsights(BuildContext context, List<RideNearbyDriver> drivers) {
    final cs = Theme.of(context).colorScheme;
    final bestRated = drivers.reduce((a, b) => (a.rating >= b.rating) ? a : b);
    final nearest = drivers.reduce((a, b) => (a.distanceKm <= b.distanceKm) ? a : b);
    final fastest = drivers.reduce((a, b) => (a.etaMin <= b.etaMin) ? a : b);

    Widget chip(String title, String value, IconData icon) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(14),
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
                child: Icon(icon, color: AppColors.primary, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.75), fontSize: 11)),
                    const SizedBox(height: 4),
                    Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.88), fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        chip('Best rated', '${bestRated.name} • ${bestRated.rating.toStringAsFixed(2)}', Icons.star_rounded),
        const SizedBox(width: 8),
        chip('Nearest', '${nearest.name} • ${_fmtDist(nearest.distanceKm)}', Icons.near_me_rounded),
        const SizedBox(width: 8),
        chip('Fastest', '${fastest.name} • ${fastest.etaMin} min', Icons.timer_rounded),
      ],
    );
  }

  Widget _section(String t) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(t, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
    );
  }

  Widget _pill(BuildContext context, IconData icon, String text) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.onSurface.withOpacity(0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: cs.onSurface.withOpacity(0.65)),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.75), fontSize: 12)),
        ],
      ),
    );
  }

  String _fmtDist(double km) {
    if (km <= 0) return 'Nearby';
    if (km < 1) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(1)} km';
  }

  Color _rankColor(String r) {
    final x = r.trim().toLowerCase();
    if (x.contains('platinum')) return const Color(0xFF6A5ACD);
    if (x.contains('gold')) return const Color(0xFFB8860B);
    if (x.contains('silver')) return const Color(0xFF607D8B);
    if (x.contains('bronze')) return const Color(0xFF8D6E63);
    return AppColors.primary;
  }

  IconData _vehicleIcon(String t) {
    final x = t.trim().toLowerCase();
    if (x.contains('bike')) return Icons.two_wheeler_rounded;
    return Icons.directions_car_rounded;
  }

  Widget _driverCard(BuildContext context, RideNearbyDriver d, {required bool selected, required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;

    final distText = _fmtDist(d.distanceKm);
    final eta = d.etaMin <= 0 ? '1 min' : '${d.etaMin} min';

    final rank = d.rank.trim().isEmpty ? 'Verified' : d.rank.trim();
    final rankColor = _rankColor(rank);

    final vehicleType = d.vehicleType.trim().isEmpty ? 'car' : d.vehicleType.trim();
    final seats = (vehicleType.toLowerCase().contains('bike')) ? 1 : (d.seats <= 0 ? 4 : d.seats);

    final vehicleThumb = d.imagesEffective.isNotEmpty ? d.imagesEffective.first : '';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withOpacity(0.10) : cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.primary.withOpacity(0.40) : cs.onSurface.withOpacity(0.08),
            width: selected ? 1.4 : 1.0,
          ),
        ),
        child: Row(
          children: [
            // avatar
            _avatarCircle(context, d.avatarUrl, d.initials, selected: selected),
            const SizedBox(width: 10),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.90))),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: rankColor.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: rankColor.withOpacity(0.20)),
                        ),
                        child: Text(rank, style: TextStyle(fontWeight: FontWeight.w900, color: rankColor, fontSize: 11)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _miniChip(context, _vehicleIcon(vehicleType), '${vehicleType.toLowerCase().contains('bike') ? 'Bike' : 'Car'} • $seats seats'),
                      _miniChip(context, Icons.local_taxi_rounded, d.category),
                      if (d.carPlate.trim().isNotEmpty) _miniChip(context, Icons.confirmation_number_rounded, d.carPlate.trim()),
                      _miniChip(context, Icons.timer_rounded, eta),
                      _miniChip(context, Icons.near_me_rounded, distText),
                      _stars(context, d.rating),
                      if (d.totalTrips > 0) _miniChip(context, Icons.verified_rounded, '${d.totalTrips} trips'),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(width: 10),

            // vehicle thumb
            if (vehicleThumb.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: Image.network(
                    vehicleThumb,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.low,
                    errorBuilder: (_, __, ___) => Container(
                      color: cs.onSurface.withOpacity(0.06),
                      child: Icon(_vehicleIcon(vehicleType), color: cs.onSurface.withOpacity(0.55)),
                    ),
                    loadingBuilder: (c, w, p) {
                      if (p == null) return w;
                      return Container(
                        color: cs.onSurface.withOpacity(0.06),
                        child: Center(
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
              )
            else
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: cs.onSurface.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.onSurface.withOpacity(0.10)),
                ),
                child: Icon(_vehicleIcon(vehicleType), color: cs.onSurface.withOpacity(0.55)),
              ),

            if (selected) ...[
              const SizedBox(width: 8),
              Icon(Icons.check_circle_rounded, color: AppColors.primary),
            ],
          ],
        ),
      ),
    );
  }

  Widget _avatarCircle(BuildContext context, String url, String initials, {required bool selected}) {
    final cs = Theme.of(context).colorScheme;
    final borderColor = selected ? AppColors.primary.withOpacity(0.35) : cs.onSurface.withOpacity(0.10);
    final bg = cs.onSurface.withOpacity(0.06);

    Widget fallback() {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(shape: BoxShape.circle, color: bg, border: Border.all(color: borderColor)),
        child: Center(
          child: Text(initials, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.75))),
        ),
      );
    }

    final u = url.trim();
    if (u.isEmpty) return fallback();

    return ClipOval(
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: bg, border: Border.all(color: borderColor)),
        child: Image.network(
          u,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, __, ___) => fallback(),
          loadingBuilder: (c, w, p) {
            if (p == null) return w;
            return Container(
              color: bg,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2.2, valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary)),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _offerCard(BuildContext context, RideOffer offer, {required bool selected, required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;
    final title = _offerTitle(offer);
    final eta = _offerEta(offer);
    final perKm = _offerPerKmPrice(offer);
    final total = _offerTotalForTrip(offer);
    final old = _offerOld(offer);
    final cur = _currency(offer);

    final km = _tripKm;
    final totalText = '$cur${_moneyFmt.format(total.round())}';
    final perKmText = perKm > 0 ? '$cur${_moneyFmt.format(perKm.round())}/km' : '';
    final kmText = km > 0 ? '${km.toStringAsFixed(1)} km' : '';

    final oldText = (old > 0 && old > total) ? '$cur${_moneyFmt.format(old.round())}' : null;

    // if a driver is selected, show seats/type from driver
    final drivers = _driversVM;
    final driverSelected = (_selectedDriverIdx >= 0 && _selectedDriverIdx < drivers.length);
    final d = driverSelected ? drivers[_selectedDriverIdx] : null;

    final vt = (d?.vehicleType ?? (_offerToMap(offer)['vehicle_type'] ?? 'car')).toString();
    final seats = (vt.toLowerCase().contains('bike')) ? 1 : (d?.seats ?? _num(_offerToMap(offer)['seats'], 4).toInt());

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withOpacity(0.10) : cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.primary.withOpacity(0.40) : cs.onSurface.withOpacity(0.08),
            width: selected ? 1.4 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: cs.onSurface.withOpacity(0.05),
                border: Border.all(color: cs.onSurface.withOpacity(0.08)),
              ),
              child: Icon(_vehicleIcon(vt), color: cs.onSurface.withOpacity(0.65), size: 28),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.85))),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _miniChip(context, Icons.timer_rounded, eta <= 0 ? '—' : '$eta min'),
                      if (kmText.isNotEmpty) _miniChip(context, Icons.straighten_rounded, kmText),
                      if (perKmText.isNotEmpty) _miniChip(context, Icons.price_change_rounded, perKmText),
                      _miniChip(context, _vehicleIcon(vt), '${vt.toLowerCase().contains('bike') ? 'Bike' : 'Car'} • $seats'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(totalText, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.88))),
                if (oldText != null) ...[
                  const SizedBox(height: 2),
                  Text(oldText,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: cs.onSurface.withOpacity(0.45),
                        decoration: TextDecoration.lineThrough,
                      )),
                ],
                const SizedBox(height: 4),
                Text('Trip total', style: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurface.withOpacity(0.55), fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniChip(BuildContext context, IconData icon, String text) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: cs.onSurface.withOpacity(0.04),
        border: Border.all(color: cs.onSurface.withOpacity(0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: cs.onSurface.withOpacity(0.65)),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.70), fontSize: 12)),
        ],
      ),
    );
  }

  Widget _stars(BuildContext context, double rating) {
    final cs = Theme.of(context).colorScheme;
    final r = rating.clamp(0, 5);
    final full = r.floor();
    final half = (r - full) >= 0.5 ? 1 : 0;
    final empty = 5 - full - half;

    final icons = <Widget>[];
    for (int i = 0; i < full; i++) icons.add(const Icon(Icons.star_rounded, size: 16, color: Color(0xFFFFD54F)));
    if (half == 1) icons.add(const Icon(Icons.star_half_rounded, size: 16, color: Color(0xFFFFD54F)));
    for (int i = 0; i < empty; i++) icons.add(Icon(Icons.star_outline_rounded, size: 16, color: cs.onSurface.withOpacity(0.30)));

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...icons,
        const SizedBox(width: 6),
        Text(r.toStringAsFixed(2), style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.65), fontSize: 12)),
      ],
    );
  }

  Widget _loadingRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Searching…', style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.75))),
          ),
        ],
      ),
    );
  }

  Widget _hint(BuildContext context, String title, String subtitle) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_rounded, color: cs.onSurface.withOpacity(0.55)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.80))),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface.withOpacity(0.58), height: 1.2)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Column(
        children: [
          Icon(Icons.directions_car_filled_rounded, color: cs.onSurface.withOpacity(0.55), size: 36),
          const SizedBox(height: 10),
          Text('No cars nearby right now', style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.82))),
          const SizedBox(height: 6),
          Text('Try again in a moment.', style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface.withOpacity(0.58))),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton(
              onPressed: widget.onRefresh,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text('Try again', style: TextStyle(fontWeight: FontWeight.w900)),
            ),
          ),
        ],
      ),
    );
  }

  // ✅ bottom bar now opens driver details sheet when user taps "Select ..."
  Widget _bottomBar(BuildContext context, MediaQueryData mq) {
    final cs = Theme.of(context).colorScheme;

    final drivers = _driversVM;
    final offers = _offersRaw;

    final driverSelected = (_selectedDriverIdx >= 0 && _selectedDriverIdx < drivers.length);
    final offerSelected = (_selectedOfferIdx >= 0 && _selectedOfferIdx < offers.length);

    final canProceed = driverSelected && offerSelected;

    final offerTitle = offerSelected ? _offerTitle(offers[_selectedOfferIdx]) : 'Ride';

    final btnText = canProceed ? 'Select $offerTitle' : (driverSelected ? 'Select a ride option' : 'Select a driver');

    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(12, 10, 12, 10 + mq.padding.bottom + widget.bottomNavHeight),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          border: Border(top: BorderSide(color: cs.onSurface.withOpacity(0.08))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Payment row (screenshot-like)
            Row(
              children: [
                Icon(Icons.payments_rounded, color: cs.onSurface.withOpacity(0.60), size: 18),
                const SizedBox(width: 8),
                Text('Cash', style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.78))),
                const SizedBox(width: 6),
                Icon(Icons.keyboard_arrow_down_rounded, color: cs.onSurface.withOpacity(0.55)),
                const Spacer(),
                if (_locked) Text('Locked', style: TextStyle(fontWeight: FontWeight.w900, color: AppColors.primary)),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: canProceed
                    ? () async {
                  final d = drivers[_selectedDriverIdx];
                  final o = offers[_selectedOfferIdx];

                  final driverMap = _driverToMap(d);
                  final offerMap = _offerToMap(o);

                  await showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) {
                      return DriverDetailsSheet(
                        driver: driverMap,
                        offer: offerMap,
                        originText: widget.originText,
                        destinationText: widget.destinationText,
                        distanceText: widget.distanceText,
                        durationText: widget.durationText,
                        tripDistanceKm: _tripKm,
                        onConfirm: () {
                          Navigator.of(context).pop();
                          widget.onBook(d, o);
                        },
                      );
                    },
                  );
                }
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.primary.withOpacity(0.35),
                  disabledForegroundColor: Colors.white.withOpacity(0.75),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 0,
                ),
                child: Text(btnText, style: const TextStyle(fontWeight: FontWeight.w900)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
