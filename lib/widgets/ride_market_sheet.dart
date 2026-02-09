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
  });
}

class RideMarketSheet extends StatefulWidget {
  final double bottomNavHeight;

  final String originText;
  final String destinationText;

  final String? distanceText;
  final String? durationText;

  final int driversNearbyCount;
  final List<dynamic>? drivers;

  final List<RideOffer> offers;
  final bool loading;

  final VoidCallback onRefresh;
  final VoidCallback onCancel;

  /// Booking action: after user selects a driver + offer and taps the green button.
  final void Function(RideNearbyDriver driver, RideOffer offer) onBook;

  const RideMarketSheet({
    super.key,
    required this.bottomNavHeight,
    required this.originText,
    required this.destinationText,
    required this.distanceText,
    required this.durationText,
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
    if (raw is DriverCar) {
      final ll = (raw as dynamic).ll;
      final lat = (ll != null) ? (ll.latitude as double) : 0.0;
      final lng = (ll != null) ? (ll.longitude as double) : 0.0;

      return RideNearbyDriver(
        id: ((raw as dynamic).id ?? '').toString(),
        name: ((raw as dynamic).name ?? 'Driver').toString(),
        category: ((raw as dynamic).category ?? 'Economy').toString(),
        rating: _num((raw as dynamic).rating, 0).toDouble(),
        carPlate: ((raw as dynamic).carPlate ?? '').toString(),
        heading: _num((raw as dynamic).heading, 0).toDouble(),
        lat: lat,
        lng: lng,
        distanceKm: _num((raw as dynamic).distanceKm, 0).toDouble(),
        etaMin: _num((raw as dynamic).etaMin, 0).toInt(),
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
      );
    }

    // Unknown object
    try {
      final d = raw as dynamic;
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
    return m;
  }

  String _offerTitle(RideOffer o) {
    final m = _offerToMap(o);
    return (m['category'] ?? m['name'] ?? m['label'] ?? 'Ride').toString();
  }

  int _offerEta(RideOffer o) => _num(_offerToMap(o)['eta_min'], 0).toInt();
  double _offerPrice(RideOffer o) => _num(_offerToMap(o)['price'], 0).toDouble();
  double _offerOld(RideOffer o) => _num(_offerToMap(o)['original_price'], 0).toDouble();

  String _currency(RideOffer o) {
    final c = (_offerToMap(o)['currency'] ?? 'NGN').toString().toUpperCase();
    if (c == 'NGN') return '₦';
    if (c == 'USD') return '\$';
    return c;
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
            icon: const Icon(Icons.arrow_back_rounded),
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
            _section('Nearby drivers'),
            const SizedBox(height: 8),
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
            _section('Nearby drivers'),
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
              _pill(context, Icons.gps_fixed_rounded, _hasDrivers ? '$_driversCountEffective drivers' : '0 drivers'),
            ],
          ),
        ],
      ),
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

  Widget _driverCard(BuildContext context, RideNearbyDriver d, {required bool selected, required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;

    final distText = d.distanceKm <= 0
        ? 'Nearby'
        : d.distanceKm < 1
        ? '${(d.distanceKm * 1000).round()} m'
        : '${d.distanceKm.toStringAsFixed(1)} km';

    final eta = d.etaMin <= 0 ? '1 min' : '${d.etaMin} min';

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
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.onSurface.withOpacity(0.06),
                border: Border.all(color: cs.onSurface.withOpacity(0.10)),
              ),
              child: Center(
                child: Text(
                  _initials(d.name),
                  style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.75)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.85))),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _miniChip(context, Icons.local_taxi_rounded, d.category),
                      if (d.carPlate.trim().isNotEmpty) _miniChip(context, Icons.confirmation_number_rounded, d.carPlate.trim()),
                      _miniChip(context, Icons.timer_rounded, eta),
                      _miniChip(context, Icons.near_me_rounded, distText),
                      _stars(context, d.rating),
                    ],
                  ),
                ],
              ),
            ),
            if (selected) Icon(Icons.check_circle_rounded, color: AppColors.primary),
          ],
        ),
      ),
    );
  }

  Widget _offerCard(BuildContext context, RideOffer offer, {required bool selected, required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;
    final title = _offerTitle(offer);
    final eta = _offerEta(offer);
    final price = _offerPrice(offer);
    final old = _offerOld(offer);
    final cur = _currency(offer);

    final priceText = '$cur${_moneyFmt.format(price.round())}';
    final oldText = (old > 0 && old > price) ? '$cur${_moneyFmt.format(old.round())}' : null;

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
              child: Icon(Icons.directions_car_rounded, color: cs.onSurface.withOpacity(0.65), size: 28),
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
                      _stars(context, 4.9),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(priceText, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.85))),
                if (oldText != null) ...[
                  const SizedBox(height: 2),
                  Text(oldText,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: cs.onSurface.withOpacity(0.45),
                        decoration: TextDecoration.lineThrough,
                      )),
                ],
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

  Widget _bottomBar(BuildContext context, MediaQueryData mq) {
    final cs = Theme.of(context).colorScheme;

    final drivers = _driversVM;
    final offers = _offersRaw;

    final driverSelected = (_selectedDriverIdx >= 0 && _selectedDriverIdx < drivers.length);
    final offerSelected = (_selectedOfferIdx >= 0 && _selectedOfferIdx < offers.length);

    final canBook = driverSelected && offerSelected;

    final offerTitle = offerSelected ? _offerTitle(offers[_selectedOfferIdx]) : 'Ride';

    final btnText = canBook ? 'Select $offerTitle' : (driverSelected ? 'Select a ride option' : 'Select a driver');

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
                onPressed: canBook
                    ? () {
                  final d = drivers[_selectedDriverIdx];
                  final o = offers[_selectedOfferIdx];
                  widget.onBook(d, o);
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

  String _initials(String s) {
    final parts = s.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return 'D';
    String first(String x) => x.isEmpty ? '' : String.fromCharCode(x.runes.first);
    final a = first(parts.first).toUpperCase();
    final b = parts.length > 1 ? first(parts.last).toUpperCase() : '';
    return (a + b).trim();
  }
}
