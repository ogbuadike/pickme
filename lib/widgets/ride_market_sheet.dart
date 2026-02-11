// lib/widgets/ride_market_sheet.dart
//
// ✅ Dense “Bybit-like” UI (tiny scale, information-rich)
// ✅ Stable list with freeze (prevents reload vibe)
// ✅ NOW: initial driver list is ordered by Highest Rating + Rank (then ETA/dist as tie-breakers)
// ✅ Organized into clear sections for long-term maintenance
//
// NOTE: Uses FontFeature -> requires dart:ui import.

import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;

import '../themes/app_theme.dart';
import '../services/ride_market_service.dart'; // RideOffer, DriverCar
import 'driver_details_sheet.dart';

/// ===============================
/// DATA MODEL (UI VM)
/// ===============================
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

  // vehicle/profile
  final String vehicleType; // car | bike
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

  // pricing (driver-based)
  final String currency; // e.g. NGN
  final double pricePerKm; // e.g. 250
  final double baseFare; // e.g. 500
  final double estimatedTotal; // server computed if any
  final double tripKm; // echo from API if any

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

/// ===============================
/// MAIN SHEET
/// ===============================
class RideMarketSheet extends StatefulWidget {
  final double bottomNavHeight;

  final String originText;
  final String destinationText;
  final String? distanceText;
  final String? durationText;
  final double? tripDistanceKm;

  final int driversNearbyCount;
  final List<dynamic>? drivers;

  final List<RideOffer> offers; // legacy / optional
  final bool loading;

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
  });

  @override
  State<RideMarketSheet> createState() => _RideMarketSheetState();
}

class _RideMarketSheetState extends State<RideMarketSheet> {
  final _moneyFmt = intl.NumberFormat.decimalPattern();

  // ✅ Stable list (frozen order)
  final List<String> _stableIds = <String>[];
  List<RideNearbyDriver> _stableDrivers = const [];

  // ✅ selection by ID (no index drift)
  String? _selectedDriverId;

  // ✅ Freeze controls
  bool _orderFrozen = false; // we have a stable ID order
  bool _fullyFrozen = false; // stop updating driver cards (prevents reload feel)
  DateTime? _settleUntil; // allow brief enrichment window right after first load

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

    // If route changed, reset everything so new trip has fresh list.
    final routeChanged = oldWidget.originText != widget.originText ||
        oldWidget.destinationText != widget.destinationText ||
        oldWidget.tripDistanceKm != widget.tripDistanceKm ||
        oldWidget.distanceText != widget.distanceText;

    if (routeChanged) {
      _resetStable(alsoClearSelection: true);
    }

    _reconcileDrivers();
  }

  /// ===============================
  /// ADAPTER + NORMALIZERS
  /// ===============================
  static num _num(dynamic v, num fallback) {
    if (v == null) return fallback;
    if (v is num) return v;
    if (v is String) return num.tryParse(v) ?? fallback;
    return fallback;
  }

  static List<String> _strList(dynamic v) {
    if (v == null) return const [];
    if (v is List) {
      return v.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList(growable: false);
    }

    final s = v.toString().trim();
    if (s.isEmpty) return const [];
    if (s.startsWith('[') && s.endsWith(']')) {
      final inner = s.substring(1, s.length - 1);
      return inner
          .split(',')
          .map((x) => x.replaceAll('"', '').replaceAll("'", '').trim())
          .where((x) => x.isNotEmpty)
          .toList(growable: false);
    }
    return s.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList(growable: false);
  }

  // ✅ normalize URLs for more reliable loading
  String _fixUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('//')) u = 'https:$u';
    if (u.startsWith('http://')) u = 'https://${u.substring(7)}';
    return u;
  }

  RideNearbyDriver _driverVM(dynamic raw) {
    if (raw is DriverCar) {
      final d = raw as dynamic;

      final ll = d.ll;
      final lat = (ll != null) ? (ll.latitude as double) : 0.0;
      final lng = (ll != null) ? (ll.longitude as double) : 0.0;

      String vehicleType = 'car';
      try {
        vehicleType = (d.vehicleType ?? d.vehicle_type ?? 'car').toString();
      } catch (_) {}

      int seats = 4;
      try {
        seats = (d.seats is num) ? (d.seats as num).toInt() : seats;
      } catch (_) {}
      if (vehicleType.toLowerCase().contains('bike')) seats = 1;

      String rank = '';
      try {
        rank = (d.rank ?? '').toString();
      } catch (_) {}

      String avatarUrl = '';
      try {
        avatarUrl = (d.avatarUrl ?? d.avatar_url ?? '').toString();
      } catch (_) {}

      String carPlate = '';
      try {
        carPlate = (d.carPlate ?? d.car_plate ?? d.plate ?? '').toString();
      } catch (_) {}

      final currency = (() {
        try {
          return (d.currency ?? 'NGN').toString();
        } catch (_) {
          return 'NGN';
        }
      })();

      final pricePerKm = (() {
        try {
          return _num(d.pricePerKm ?? d.price_per_km, 0).toDouble();
        } catch (_) {
          return 0.0;
        }
      })();

      final baseFare = (() {
        try {
          return _num(d.baseFare ?? d.base_fare, 0).toDouble();
        } catch (_) {
          return 0.0;
        }
      })();

      final estimatedTotal = (() {
        try {
          return _num(d.estimatedTotal ?? d.estimated_total ?? d.price_total, 0).toDouble();
        } catch (_) {
          return 0.0;
        }
      })();

      final tripKm = (() {
        try {
          return _num(d.tripKm ?? d.trip_km, 0).toDouble();
        } catch (_) {
          return 0.0;
        }
      })();

      List<String> images = const [];
      try {
        final v = d.vehicleImages ?? d.vehicle_images;
        images = _strList(v);
      } catch (_) {}

      String carImg = '';
      try {
        carImg = (d.carImageUrl ?? d.car_image_url ?? '').toString();
      } catch (_) {}

      return RideNearbyDriver(
        id: (d.id ?? '').toString(),
        name: (d.name ?? 'Driver').toString(),
        category: (d.category ?? 'Standard').toString(),
        rating: _num(d.rating, 0).toDouble(),
        carPlate: carPlate,
        heading: _num(d.heading, 0).toDouble(),
        lat: lat,
        lng: lng,
        distanceKm: _num(d.distanceKm ?? d.distance_km, 0).toDouble(),
        etaMin: _num(d.etaMin ?? d.eta_min, 0).toInt(),
        vehicleType: vehicleType,
        seats: seats,
        vehicleImages: images.map(_fixUrl).where((x) => x.isNotEmpty).toList(growable: false),
        carImageUrl: _fixUrl(carImg),
        avatarUrl: _fixUrl(avatarUrl),
        rank: rank,
        currency: currency,
        pricePerKm: pricePerKm,
        baseFare: baseFare,
        estimatedTotal: estimatedTotal,
        tripKm: tripKm,
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
        carImageUrl: _fixUrl((m['car_image_url'] ?? '').toString()),
        avatarUrl: _fixUrl((m['avatar_url'] ?? '').toString()),
        rank: (m['rank'] ?? '').toString(),
        currency: (m['currency'] ?? 'NGN').toString(),
        pricePerKm: _num(m['price_per_km'], 0).toDouble(),
        baseFare: _num(m['base_fare'], 0).toDouble(),
        estimatedTotal: _num(m['estimated_total'] ?? m['price_total'], 0).toDouble(),
        tripKm: _num(m['trip_km'], 0).toDouble(),
      );
    }

    return const RideNearbyDriver(
      id: '',
      name: 'Driver',
      category: 'Standard',
      rating: 0,
      carPlate: '',
      heading: 0,
      lat: 0,
      lng: 0,
      distanceKm: 0,
      etaMin: 0,
    );
  }

  /// ===============================
  /// ORDERING: Highest Rating + Rank
  /// ===============================
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

  double _safeRating(double r) {
    if (r.isNaN || r.isInfinite) return 0;
    return r.clamp(0, 5).toDouble();
  }

  int _compareDrivers(RideNearbyDriver a, RideNearbyDriver b) {
    // Primary: rating desc
    final ar = _safeRating(a.rating);
    final br = _safeRating(b.rating);
    final c1 = br.compareTo(ar);
    if (c1 != 0) return c1;

    // Secondary: rank weight desc (empty -> verified)
    final aw = _rankWeight(a.rank.trim().isEmpty ? 'verified' : a.rank);
    final bw = _rankWeight(b.rank.trim().isEmpty ? 'verified' : b.rank);
    final c2 = bw.compareTo(aw);
    if (c2 != 0) return c2;

    // Next best tie-breakers: closer ETA, closer distance
    final c3 = a.etaMin.compareTo(b.etaMin);
    if (c3 != 0) return c3;

    final c4 = a.distanceKm.compareTo(b.distanceKm);
    if (c4 != 0) return c4;

    // Deterministic
    final an = a.name.toLowerCase();
    final bn = b.name.toLowerCase();
    final c5 = an.compareTo(bn);
    if (c5 != 0) return c5;

    return a.id.compareTo(b.id);
  }

  /// ===============================
  /// FREEZE / STABILIZE (Stops “Reloading” Feel)
  /// ===============================
  bool _hasPrice(RideNearbyDriver d) {
    if (d.estimatedTotal > 0) return true;
    if (d.pricePerKm > 0) return true;
    if (d.baseFare > 0) return true;
    return false;
  }

  bool _hasImage(RideNearbyDriver d) {
    if (d.imagesEffective.isNotEmpty) return true;
    if (d.carImageUrl.trim().isNotEmpty) return true;
    return false;
  }

  void _resetStable({bool alsoClearSelection = false}) {
    _stableIds.clear();
    _stableDrivers = const [];
    _orderFrozen = false;
    _fullyFrozen = false;
    _settleUntil = null;
    if (alsoClearSelection) _selectedDriverId = null;
  }

  void _reconcileDrivers() {
    // If user already selected a driver, freeze immediately (old “lock” vibe).
    if (_selectedDriverId != null) {
      _fullyFrozen = true;
      return;
    }

    // After settle window ends, freeze fully.
    if (_settleUntil != null && DateTime.now().isAfter(_settleUntil!)) {
      _fullyFrozen = true;
    }
    if (_fullyFrozen) return;

    final incomingRaw = widget.drivers ?? const [];
    if (incomingRaw.isEmpty) return;

    final incoming = <RideNearbyDriver>[];
    for (final x in incomingRaw) {
      final d = _driverVM(x);
      if (d.id.isEmpty) continue;
      incoming.add(d);
    }
    if (incoming.isEmpty) return;

    final byId = <String, RideNearbyDriver>{};
    for (final d in incoming) {
      byId[d.id] = d;
    }

    // ✅ First non-empty load: sort by rating+rank, then freeze IDs (no later reordering)
    if (_stableIds.isEmpty) {
      incoming.sort(_compareDrivers);

      _stableIds.addAll(incoming.map((e) => e.id));
      _stableDrivers = List<RideNearbyDriver>.from(incoming, growable: false);

      _orderFrozen = true;
      _settleUntil = DateTime.now().add(const Duration(milliseconds: 1200)); // brief enrich window

      if (_selectedDriverId != null && !_stableIds.contains(_selectedDriverId)) {
        _selectedDriverId = null;
      }

      setState(() {});
      return;
    }

    // ✅ After order frozen: keep IDs fixed; only enrich missing price/images/rating during settle window
    final oldById = <String, RideNearbyDriver>{for (final d in _stableDrivers) d.id: d};

    bool changed = false;
    final updated = <RideNearbyDriver>[];

    for (final id in _stableIds) {
      final old = oldById[id];
      final fresh = byId[id];

      if (old == null && fresh != null) {
        updated.add(fresh);
        changed = true;
        continue;
      }

      if (old != null && fresh != null) {
        final needPrice = !_hasPrice(old) && _hasPrice(fresh);
        final needImage = !_hasImage(old) && _hasImage(fresh);
        final needRating = (_safeRating(old.rating) <= 0 && _safeRating(fresh.rating) > 0);

        if (needPrice || needImage || needRating) {
          updated.add(fresh);
          changed = true;
        } else {
          updated.add(old);
        }
        continue;
      }

      if (old != null) updated.add(old);
    }

    // If everything now has price/images OR settle window ended -> freeze fully
    final allGood = updated.isNotEmpty &&
        updated.every((d) => _hasPrice(d) || _tripKm <= 0) &&
        updated.every(_hasImage);
    if (allGood) _fullyFrozen = true;

    if (changed) {
      setState(() => _stableDrivers = updated);
    }
  }

  /// ===============================
  /// PRICING DISPLAY
  /// ===============================
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

  /// ===============================
  /// BUILD
  /// ===============================
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cs = Theme.of(context).colorScheme;

    final drivers = _stableDrivers;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(maxHeight: mq.size.height * 0.56),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.20),
                blurRadius: 20,
                offset: const Offset(0, -10),
              ),
            ],
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              _handle(cs),
              const SizedBox(height: 8),
              _topBar(context),
              Expanded(child: _content(context, drivers)),
              _bottomBar(context, mq, drivers),
            ],
          ),
        ),
      ),
    );
  }

  Widget _handle(ColorScheme cs) {
    return Container(
      width: 60,
      height: 6,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: cs.onSurface.withOpacity(0.16),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          IconButton(
            onPressed: widget.onCancel,
            icon: const Icon(Icons.close_rounded),
            tooltip: 'Close',
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  'Select a driver',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface.withOpacity(0.92),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.loading ? 'Searching…' : 'Live availability',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface.withOpacity(0.55),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              setState(() => _resetStable(alsoClearSelection: true));
              widget.onRefresh();
            },
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, List<RideNearbyDriver> drivers) {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      children: [
        _routeMini(context),
        const SizedBox(height: 10),
        if (_showNoDrivers)
          _emptyState(context)
        else ...[
          const SizedBox(height: 10),
          if (widget.loading && drivers.isEmpty) _loadingRow(context),
          ...List.generate(drivers.length, (i) {
            final d = drivers[i];
            final selected = (_selectedDriverId == d.id);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: KeyedSubtree(
                key: ValueKey(d.id),
                child: _driverCard(
                  context,
                  d,
                  selected: selected,
                  onTap: () => setState(() => _selectedDriverId = d.id),
                ),
              ),
            );
          }),
        ],
      ],
    );
  }

  Widget _routeMini(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final origin = widget.originText.trim().isEmpty ? 'Pickup' : widget.originText.trim();
    final dest = widget.destinationText.trim().isEmpty ? 'Destination' : widget.destinationText.trim();
    final count = math.max(widget.driversNearbyCount, _stableDrivers.length);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: _FromToMini(origin: origin, dest: dest, count: count, cs: cs),
    );
  }

  /// ===============================
  /// DRIVER CARD (Dense + Premium)
  /// ===============================
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

  Color _rankColor(String r) {
    final x = r.trim().toLowerCase();
    if (x.contains('platinum')) return const Color(0xFF6A5ACD);
    if (x.contains('gold')) return const Color(0xFFB8860B);
    if (x.contains('silver')) return const Color(0xFF607D8B);
    if (x.contains('bronze')) return const Color(0xFF8D6E63);
    return const Color(0xFF1E8E3E);
  }

  Widget _driverCard(BuildContext context, RideNearbyDriver d, {required bool selected, required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;

    final rankText = d.rank.trim().isEmpty ? 'Verified' : d.rank.trim();
    final rc = _rankColor(rankText);

    final vt = d.vehicleType.trim().isEmpty ? 'car' : d.vehicleType.trim();
    final seats = vt.toLowerCase().contains('bike') ? 1 : (d.seats <= 0 ? 4 : d.seats);

    final etaText = d.etaMin <= 0 ? '1m' : '${d.etaMin}m';
    final distText = _fmtDistShort(d.distanceKm);

    final total = _driverTotal(d);
    final sym = _curSym(d.currency);
    final totalText = total > 0 ? '$sym${_moneyFmt.format(total.round())}' : '—';

    final img = (d.imagesEffective.isNotEmpty) ? _fixUrl(d.imagesEffective.first) : '';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: selected
            ? [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.16),
            blurRadius: 18,
            offset: const Offset(0, 10),
          )
        ]
            : [],
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary.withOpacity(0.10) : cs.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? AppColors.primary.withOpacity(0.55) : cs.onSurface.withOpacity(0.08),
              width: selected ? 1.6 : 1.0,
            ),
            boxShadow: selected
                ? [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 10),
                color: AppColors.primary.withOpacity(0.10),
              ),
              BoxShadow(
                blurRadius: 10,
                offset: const Offset(0, 4),
                color: Colors.black.withOpacity(0.08),
              ),
            ]
                : [
              BoxShadow(
                blurRadius: 10,
                offset: const Offset(0, 6),
                color: Colors.black.withOpacity(0.06),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _avatarWithRank(context, d.avatarUrl, d.initials, rankText, rc, selected: selected),
              const SizedBox(width: 10),

              // MAIN
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
                              color: cs.onSurface.withOpacity(0.92),
                              fontSize: 12.2,
                              height: 1.05,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _starsBadge(context, d.rating),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        _chipNx(
                          context,
                          icon: _vehicleIconNx(vt),
                          text: vt.toLowerCase().contains('bike') ? 'Bike' : 'Car',
                          tone: AppColors.primary,
                          strong: true,
                        ),
                        _chipNx(
                          context,
                          icon: Icons.airline_seat_recline_normal_rounded,
                          text: '$seats seat',
                          tone: const Color(0xFF1A73E8),
                        ),
                        if (d.carPlate.trim().isNotEmpty)
                          _chipNx(
                            context,
                            icon: Icons.qr_code_rounded,
                            text: d.carPlate.trim(),
                            tone: const Color(0xFF6A5ACD),
                            mono: true,
                          ),
                        _chipNx(
                          context,
                          icon: Icons.av_timer_rounded,
                          text: etaText,
                          tone: const Color(0xFFB8860B),
                        ),
                        _chipNx(
                          context,
                          icon: Icons.route_rounded,
                          text: distText,
                          tone: const Color(0xFF1E8E3E),
                        ),
                        if (d.category.trim().isNotEmpty)
                          _chipNx(
                            context,
                            icon: Icons.bolt_rounded,
                            text: _shortCat(d.category),
                            tone: AppColors.primary,
                          ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 10),

              // RIGHT: stable price column
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 82, maxWidth: 92),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        _thumb(context, img, vt),
                        if (selected) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.verified_rounded, size: 18, color: AppColors.primary.withOpacity(0.95)),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      totalText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: cs.onSurface.withOpacity(0.92),
                        fontSize: 12.2,
                        height: 1.05,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _shortCat(String s) {
    final x = s.trim();
    if (x.length <= 10) return x;
    return '${x.substring(0, 10)}…';
  }

  String _fmtDistShort(double km) {
    if (km <= 0) return 'Near';
    if (km < 1) return '${(km * 1000).round()}m';
    return '${km.toStringAsFixed(1)}km';
  }

  /// ===============================
  /// UI PARTS
  /// ===============================
  Widget _starsBadge(BuildContext context, double rating) {
    final cs = Theme.of(context).colorScheme;
    final r = rating.clamp(0, 5).toDouble();
    int full = r.floor();
    final hasHalf = (r - full) >= 0.5;
    if (full > 5) full = 5;

    final icons = <Widget>[];
    for (int i = 0; i < full; i++) {
      icons.add(const Icon(Icons.star_rounded, size: 14, color: Color(0xFFFFD54F)));
    }
    if (hasHalf && full < 5) icons.add(const Icon(Icons.star_half_rounded, size: 14, color: Color(0xFFFFD54F)));
    while (icons.length < 5) {
      icons.add(Icon(Icons.star_outline_rounded, size: 14, color: cs.onSurface.withOpacity(0.25)));
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: const Color(0xFFFFD54F).withOpacity(0.14),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...icons,
          const SizedBox(width: 6),
          Text(
            r.toStringAsFixed(1),
            style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.82), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _avatarWithRank(
      BuildContext context,
      String url,
      String initials,
      String rank,
      Color rc, {
        required bool selected,
      }) {
    final cs = Theme.of(context).colorScheme;
    final borderColor = selected ? AppColors.primary.withOpacity(0.45) : cs.onSurface.withOpacity(0.10);
    final bg = cs.onSurface.withOpacity(0.06);
    final u = _fixUrl(url);

    Widget avatarFallback() {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(shape: BoxShape.circle, color: bg, border: Border.all(color: borderColor, width: 1.2)),
        child: Center(
          child: Text(initials, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.78), fontSize: 12)),
        ),
      );
    }

    final avatar = (u.isEmpty)
        ? avatarFallback()
        : ClipOval(
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: bg, border: Border.all(color: borderColor, width: 1.2)),
        child: Image.network(
          u,
          fit: BoxFit.cover,
          cacheWidth: (44 * MediaQuery.of(context).devicePixelRatio).round(),
          filterQuality: FilterQuality.low,
          errorBuilder: (_, __, ___) => avatarFallback(),
          loadingBuilder: (c, w, p) {
            if (p == null) return w;
            return Container(
              color: bg,
              child: const Center(
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

    return SizedBox(
      width: 46,
      height: 46,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: avatar),
          Positioned(
            right: -1,
            top: -1,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: cs.onSurface.withOpacity(0.10)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.10),
                    blurRadius: 10,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Icon(_rankIcon(rank), size: 14, color: rc),
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(BuildContext context, String url, String vehicleType) {
    final cs = Theme.of(context).colorScheme;

    Widget fallback() {
      return Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: cs.onSurface.withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.onSurface.withOpacity(0.10)),
        ),
        child: Center(child: Icon(_vehicleIcon(vehicleType), color: cs.onSurface.withOpacity(0.55), size: 22)),
      );
    }

    final u = _fixUrl(url);
    if (u.isEmpty) return fallback();

    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheW = (54 * dpr).round();

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
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

  Widget _loadingRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Searching…', style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.78))),
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
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Column(
        children: [
          Icon(Icons.directions_car_filled_rounded, color: cs.onSurface.withOpacity(0.55), size: 36),
          const SizedBox(height: 10),
          Text('No drivers nearby', style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.84))),
          const SizedBox(height: 6),
          Text('Try refresh in a moment.', style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface.withOpacity(0.60))),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: () {
                setState(() => _resetStable(alsoClearSelection: true));
                widget.onRefresh();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 0,
              ),
              child: const Text('Refresh', style: TextStyle(fontWeight: FontWeight.w900)),
            ),
          ),
        ],
      ),
    );
  }

  /// ===============================
  /// BOTTOM BAR
  /// ===============================
  Widget _bottomBar(BuildContext context, MediaQueryData mq, List<RideNearbyDriver> drivers) {
    final cs = Theme.of(context).colorScheme;

    final selected = (_selectedDriverId != null)
        ? drivers.where((x) => x.id == _selectedDriverId).toList(growable: false)
        : const <RideNearbyDriver>[];

    final driverSelected = selected.isNotEmpty;

    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(12, 10, 12, 10 + mq.padding.bottom + widget.bottomNavHeight),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          border: Border(top: BorderSide(color: cs.onSurface.withOpacity(0.08))),
        ),
        child: SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: driverSelected
                ? () async {
              final d = selected.first;

              // freeze immediately once selecting (prevents any refresh feel)
              setState(() => _fullyFrozen = true);

              final driverMap = _driverToMap(d);
              final offerMap = _offerMapFromDriver(d);

              final payload = await showModalBottomSheet<Map<String, dynamic>>(
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

                    // ✅ Pass coords if you have them
                    userLocation: /* GeoPoint(userLat, userLng) */ null,
                    pickupLocation: /* GeoPoint(pickupLat, pickupLng) */ null,
                    dropLocation: /* GeoPoint(dropLat, dropLng) */ null,
                  );
                },
              );

              if (payload != null) {
                // ✅ Send payload to rideBookEndpoint here (your API client)
                // await ApiClient.post('/rideBookEndpoint', payload);

                // Keep your existing onBook flow if needed:
                // widget.onBook(d, offer);
              }

            }
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: cs.onSurface.withOpacity(0.10),
              disabledForegroundColor: cs.onSurface.withOpacity(0.40),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              elevation: 0,
            ),
            child: const Text('Select a driver', style: TextStyle(fontWeight: FontWeight.w900)),
          ),
        ),
      ),
    );
  }

  /// ===============================
  /// MAP BUILDERS (Details Sheet)
  /// ===============================
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
      'avatar_url': d.avatarUrl,
      'phone': d.phone,
      'nin': d.nin,
      'rank': d.rank,
      'completed_trips': d.completedTrips,
      'cancelled_trips': d.cancelledTrips,
      'incomplete_trips': d.incompleteTrips,
      'reviews_count': d.reviewsCount,
      'total_trips': d.totalTrips,
      // pricing
      'currency': d.currency,
      'price_per_km': d.pricePerKm,
      'base_fare': d.baseFare,
      'estimated_total': _driverTotal(d),
      'trip_km': _tripKm,
    };
  }

  Map<String, dynamic> _offerMapFromDriver(RideNearbyDriver d) {
    final total = _driverTotal(d);
    return <String, dynamic>{
      'id': 'driver-${d.id}',
      'provider': 'PickMe',
      'category': d.vehicleType.toLowerCase().contains('bike') ? 'Bike' : 'Car',
      'vehicle_type': d.vehicleType,
      'seats': d.seats,
      'eta_min': d.etaMin,
      'currency': d.currency,
      'price_per_km': d.pricePerKm,
      'base_fare': d.baseFare,
      'estimated_total': total,
      'trip_km': _tripKm,
      'price_total': total,
    };
  }
}

/// ===============================
/// ROUTE MINI (From/To tree)
/// ===============================
class _FromToMini extends StatelessWidget {
  final String origin;
  final String dest;
  final int count;
  final ColorScheme cs;

  const _FromToMini({
    required this.origin,
    required this.dest,
    required this.count,
    required this.cs,
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
                  padding: const EdgeInsets.only(right: 110),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _LabeledLine(label: "FROM", value: origin, cs: cs, strong: true),
                      _LabeledLine(label: "TO", value: dest, cs: cs, strong: false),
                    ],
                  ),
                ),
                Positioned(
                  right: 0,
                  top: -1,
                  child: _NearbyPillMini(count: count, cs: cs),
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
              colors: [
                color.withOpacity(0.98),
                color.withOpacity(0.60),
              ],
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

class _NearbyPillMini extends StatelessWidget {
  final int count;
  final ColorScheme cs;

  const _NearbyPillMini({required this.count, required this.cs});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.60),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.primary.withOpacity(0.25), width: 1),
        boxShadow: [
          BoxShadow(
            blurRadius: 14,
            offset: const Offset(0, 6),
            color: Colors.black.withOpacity(0.18),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.near_me_rounded, size: 12, color: AppColors.primary),
            const SizedBox(width: 5),
            Text(
              "$count nearby",
              style: TextStyle(
                fontSize: 10.4,
                height: 1.0,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.15,
                color: cs.onSurface.withOpacity(0.88),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ===============================
/// NEXT-GEN CHIP (tiny, premium)
/// ===============================
IconData _vehicleIconNx(String vt) {
  final v = vt.toLowerCase();
  if (v.contains('bike') || v.contains('moto')) return Icons.two_wheeler_rounded;
  if (v.contains('bus') || v.contains('van')) return Icons.airport_shuttle_rounded;
  if (v.contains('lux') || v.contains('vip')) return Icons.workspace_premium_rounded;
  return Icons.directions_car_filled_rounded;
}

Widget _chipNx(
    BuildContext context, {
      required IconData icon,
      required String text,
      required Color tone,
      bool strong = false,
      bool mono = false,
    }) {
  final cs = Theme.of(context).colorScheme;

  return DecoratedBox(
    decoration: BoxDecoration(
      color: tone.withOpacity(0.10),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: tone.withOpacity(0.22), width: 1),
      boxShadow: [
        BoxShadow(
          blurRadius: 12,
          offset: const Offset(0, 6),
          color: tone.withOpacity(0.07),
        ),
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
                    colors: [
                      tone.withOpacity(0.40),
                      tone.withOpacity(0.08),
                    ],
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
              fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
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
