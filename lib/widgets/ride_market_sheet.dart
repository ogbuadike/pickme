// lib/widgets/ride_market_sheet.dart
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
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
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'D';

    String first(String x) =>
        x.isEmpty ? '' : String.fromCharCode(x.runes.first);

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
    if (out.isEmpty && carImageUrl.trim().isNotEmpty) {
      out.add(carImageUrl.trim());
    }
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

  bool get _showNoDrivers =>
      !widget.loading &&
          _stableDrivers.isEmpty &&
          (widget.drivers ?? const []).isEmpty;

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

    if (routeChanged) {
      _resetStable(alsoClearSelection: true);
    }

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
    if (v is List) {
      return v
          .map((e) => e.toString())
          .where((s) => s.trim().isNotEmpty)
          .toList(growable: false);
    }

    final s = v.toString().trim();
    if (s.isEmpty) return const <String>[];
    if (s.startsWith('[') && s.endsWith(']')) {
      final inner = s.substring(1, s.length - 1);
      return inner
          .split(',')
          .map((x) => x.replaceAll('"', '').replaceAll("'", '').trim())
          .where((x) => x.isNotEmpty)
          .toList(growable: false);
    }

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

  bool _hasPrice(RideNearbyDriver d) {
    return d.estimatedTotal > 0 || d.pricePerKm > 0 || d.baseFare > 0;
  }

  bool _hasImage(RideNearbyDriver d) {
    return d.imagesEffective.isNotEmpty || d.carImageUrl.trim().isNotEmpty;
  }

  bool _hasContactData(RideNearbyDriver d) {
    return d.phone.trim().isNotEmpty || d.nin.trim().isNotEmpty;
  }

  bool _hasPerformanceData(RideNearbyDriver d) {
    return d.completedTrips > 0 || d.reviewsCount > 0 || d.totalTrips > 0;
  }

  bool _hasProfileData(RideNearbyDriver d) {
    return d.rank.trim().isNotEmpty ||
        d.vehicleDescription.trim().isNotEmpty ||
        d.avatarUrl.trim().isNotEmpty ||
        d.carPlate.trim().isNotEmpty;
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

      String vehicleDescription = '';
      try {
        vehicleDescription =
            (d.vehicleDescription ?? d.vehicle_description ?? '').toString();
      } catch (_) {}

      String phone = '';
      try {
        phone = (d.phone ?? d.phone_number ?? d.tel ?? d.mobile ?? '')
            .toString();
      } catch (_) {}

      String nin = '';
      try {
        nin = (d.nin ?? d.national_id ?? d.nationalId ?? '').toString();
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
          return _num(
            d.estimatedTotal ?? d.estimated_total ?? d.price_total,
            0,
          ).toDouble();
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

      final completedTrips = (() {
        try {
          return _num(d.completedTrips ?? d.completed_trips, 0).toInt();
        } catch (_) {
          return 0;
        }
      })();

      final cancelledTrips = (() {
        try {
          return _num(d.cancelledTrips ?? d.cancelled_trips, 0).toInt();
        } catch (_) {
          return 0;
        }
      })();

      final incompleteTrips = (() {
        try {
          return _num(d.incompleteTrips ?? d.incomplete_trips, 0).toInt();
        } catch (_) {
          return 0;
        }
      })();

      final reviewsCount = (() {
        try {
          return _num(d.reviewsCount ?? d.reviews_count, 0).toInt();
        } catch (_) {
          return 0;
        }
      })();

      final totalTrips = (() {
        try {
          return _num(d.totalTrips ?? d.total_trips, 0).toInt();
        } catch (_) {
          return 0;
        }
      })();

      List<String> images = const <String>[];
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
        vehicleImages: images
            .map(_fixUrl)
            .where((x) => x.isNotEmpty)
            .toList(growable: false),
        vehicleDescription: vehicleDescription,
        carImageUrl: _fixUrl(carImg),
        avatarUrl: _fixUrl(avatarUrl),
        phone: phone,
        nin: nin,
        rank: rank,
        completedTrips: completedTrips,
        cancelledTrips: cancelledTrips,
        incompleteTrips: incompleteTrips,
        reviewsCount: reviewsCount,
        totalTrips: totalTrips,
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
        vehicleImages: _strList(m['vehicle_images'])
            .map(_fixUrl)
            .where((x) => x.isNotEmpty)
            .toList(growable: false),
        vehicleDescription: (m['vehicle_description'] ?? '').toString(),
        carImageUrl: _fixUrl((m['car_image_url'] ?? '').toString()),
        avatarUrl: _fixUrl((m['avatar_url'] ?? '').toString()),
        phone: (m['phone'] ?? m['phone_number'] ?? m['tel'] ?? m['mobile'] ?? '')
            .toString(),
        nin: (m['nin'] ?? m['national_id'] ?? m['nationalId'] ?? '')
            .toString(),
        rank: (m['rank'] ?? '').toString(),
        completedTrips: _num(m['completed_trips'], 0).toInt(),
        cancelledTrips: _num(m['cancelled_trips'], 0).toInt(),
        incompleteTrips: _num(m['incomplete_trips'], 0).toInt(),
        reviewsCount: _num(m['reviews_count'], 0).toInt(),
        totalTrips: _num(m['total_trips'], 0).toInt(),
        currency: (m['currency'] ?? 'NGN').toString(),
        pricePerKm: _num(m['price_per_km'], 0).toDouble(),
        baseFare: _num(m['base_fare'], 0).toDouble(),
        estimatedTotal:
        _num(m['estimated_total'] ?? m['price_total'], 0).toDouble(),
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
    final ar = _safeRating(a.rating);
    final br = _safeRating(b.rating);
    final c1 = br.compareTo(ar);
    if (c1 != 0) return c1;

    final aw = _rankWeight(a.rank.trim().isEmpty ? 'verified' : a.rank);
    final bw = _rankWeight(b.rank.trim().isEmpty ? 'verified' : b.rank);
    final c2 = bw.compareTo(aw);
    if (c2 != 0) return c2;

    final c3 = a.etaMin.compareTo(b.etaMin);
    if (c3 != 0) return c3;

    final c4 = a.distanceKm.compareTo(b.distanceKm);
    if (c4 != 0) return c4;

    final an = a.name.toLowerCase();
    final bn = b.name.toLowerCase();
    final c5 = an.compareTo(bn);
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
    if (_selectedDriverId != null) {
      _fullyFrozen = true;
      return;
    }

    if (_settleUntil != null && DateTime.now().isAfter(_settleUntil!)) {
      _fullyFrozen = true;
    }
    if (_fullyFrozen) return;

    final incomingRaw = widget.drivers ?? const <dynamic>[];
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

    if (_stableIds.isEmpty) {
      incoming.sort(_compareDrivers);
      _stableIds.addAll(incoming.map((e) => e.id));
      _stableDrivers = List<RideNearbyDriver>.from(incoming, growable: false);
      _settleUntil = DateTime.now().add(const Duration(milliseconds: 1200));
      setState(() {});
      return;
    }

    final oldById = <String, RideNearbyDriver>{
      for (final d in _stableDrivers) d.id: d,
    };

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
        final needRating =
        (_safeRating(old.rating) <= 0 && _safeRating(fresh.rating) > 0);
        final needContact = !_hasContactData(old) && _hasContactData(fresh);
        final needPerformance =
            !_hasPerformanceData(old) && _hasPerformanceData(fresh);
        final needProfile = !_hasProfileData(old) && _hasProfileData(fresh);

        if (needPrice ||
            needImage ||
            needRating ||
            needContact ||
            needPerformance ||
            needProfile) {
          updated.add(fresh);
          changed = true;
        } else {
          updated.add(old);
        }
        continue;
      }

      if (old != null) updated.add(old);
    }

    final allGood = updated.isNotEmpty &&
        updated.every((d) => _hasPrice(d) || _tripKm <= 0) &&
        updated.every(_hasImage) &&
        updated.every(_hasContactData) &&
        updated.every(_hasPerformanceData);

    if (allGood) _fullyFrozen = true;

    if (changed) {
      setState(() => _stableDrivers = updated);
    }
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
    if (km > 0 && d.pricePerKm > 0) {
      return d.baseFare + d.pricePerKm * km;
    }
    return 0;
  }

  double _sheetMaxHeight(MediaQueryData mq, UIScale ui) {
    final h = mq.size.height;
    double target;

    if (ui.landscape) {
      target = h * (ui.tablet ? 0.80 : 0.76);
    } else if (ui.tiny) {
      target = h * 0.60;
    } else if (ui.compact) {
      target = h * 0.56;
    } else {
      target = h * 0.52;
    }

    return target.clamp(
      ui.landscape ? 220.0 : 250.0,
      ui.landscape ? 520.0 : 560.0,
    );
  }

  double _bottomInset(MediaQueryData mq, UIScale ui, double maxH) {
    final raw = widget.bottomNavHeight + mq.padding.bottom + ui.gap(5);
    final cap = ui.landscape
        ? math.max(14.0, maxH * 0.12)
        : math.max(18.0, maxH * 0.16);
    return raw.clamp(8.0, cap);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final ui = UIScale.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final drivers = _stableDrivers;
    final maxH = _sheetMaxHeight(mq, ui);

    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(maxHeight: maxH),
          decoration: BoxDecoration(
            // FIXED: Ensure surface is correctly applied for OLED dark mode
            color: isDark ? cs.surface : theme.cardColor,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(ui.radius(18)),
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black.withOpacity(0.5) : Colors.black.withOpacity(0.16),
                blurRadius: ui.reduceFx ? 8 : 16,
                offset: const Offset(0, -8),
              ),
            ],
            border: isDark ? Border(top: BorderSide(color: cs.outline, width: 1.0)) : null,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final dense = constraints.maxHeight < 330;
              final ultraDense = constraints.maxHeight < 285;

              return Column(
                children: [
                  SizedBox(height: ui.gap(6)),
                  _handle(cs, ui, isDark),
                  SizedBox(height: ui.gap(4)),
                  _topBar(context, ui, dense: dense, isDark: isDark, cs: cs),
                  Expanded(
                    child: _content(
                      context,
                      drivers,
                      ui,
                      dense: dense,
                      ultraDense: ultraDense,
                      isDark: isDark,
                      cs: cs,
                    ),
                  ),
                  _bottomBar(
                    context,
                    mq,
                    drivers,
                    ui,
                    dense: dense,
                    maxHeight: maxH,
                    isDark: isDark,
                    cs: cs,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _handle(ColorScheme cs, UIScale ui, bool isDark) {
    return Container(
      width: ui.landscape ? 38 : 46,
      height: 4,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : cs.onSurface.withOpacity(0.16),
      ),
    );
  }

  Widget _topBar(BuildContext context, UIScale ui, {required bool dense, required bool isDark, required ColorScheme cs}) {
    final iconSize = ui.icon(dense ? 15 : 17);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(4)),
      child: Row(
        children: [
          IconButton(
            onPressed: widget.onCancel,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.all(ui.inset(4)),
            constraints: BoxConstraints.tightFor(
              width: ui.gap(30),
              height: ui.gap(30),
            ),
            icon: Icon(Icons.close_rounded, size: iconSize, color: cs.onSurface),
            tooltip: 'Close',
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Select driver',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface,
                    fontSize: ui.font(dense ? 11.0 : 12.0),
                    height: 1.0,
                    letterSpacing: -0.18,
                  ),
                ),
                SizedBox(height: ui.gap(1)),
                Text(
                  widget.loading ? 'Searching…' : 'Live',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    // FIXED: Removed opacity to stop fenty text, using solid grey for dark mode
                    color: isDark ? cs.onSurfaceVariant : cs.onSurface.withOpacity(0.55),
                    fontSize: ui.font(dense ? 8.7 : 9.5),
                    height: 1.0,
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
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.all(ui.inset(4)),
            constraints: BoxConstraints.tightFor(
              width: ui.gap(30),
              height: ui.gap(30),
            ),
            icon: Icon(Icons.refresh_rounded, size: iconSize, color: cs.onSurface),
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }

  Widget _content(
      BuildContext context,
      List<RideNearbyDriver> drivers,
      UIScale ui, {
        required bool dense,
        required bool ultraDense,
        required bool isDark,
        required ColorScheme cs,
      }) {
    return RepaintBoundary(
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          ui.inset(8),
          0,
          ui.inset(8),
          ui.gap(6),
        ),
        children: [
          _routeMini(context, ui, dense: dense, isDark: isDark, cs: cs),
          SizedBox(height: ui.gap(6)),
          if (_showNoDrivers)
            _emptyState(context, ui, isDark: isDark, cs: cs)
          else ...[
            if (widget.loading && drivers.isEmpty) _loadingRow(context, ui, isDark: isDark, cs: cs),
            ...List.generate(drivers.length, (i) {
              final d = drivers[i];
              final selected = (_selectedDriverId == d.id);

              return Padding(
                padding: EdgeInsets.only(bottom: ui.gap(6)),
                child: KeyedSubtree(
                  key: ValueKey(d.id),
                  child: _driverCard(
                    context,
                    d,
                    ui,
                    dense: dense,
                    ultraDense: ultraDense,
                    selected: selected,
                    isDark: isDark,
                    cs: cs,
                    onTap: () => setState(() => _selectedDriverId = d.id),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _routeMini(BuildContext context, UIScale ui, {required bool dense, required bool isDark, required ColorScheme cs}) {
    final origin =
    widget.originText.trim().isEmpty ? 'Pickup' : widget.originText.trim();
    final dest = widget.destinationText.trim().isEmpty
        ? 'Destination'
        : widget.destinationText.trim();
    final count = math.max(widget.driversNearbyCount, _stableDrivers.length);

    return Container(
      padding: EdgeInsets.fromLTRB(
        ui.inset(dense ? 8 : 10),
        ui.inset(dense ? 8 : 9),
        ui.inset(dense ? 8 : 10),
        ui.inset(dense ? 8 : 9),
      ),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceVariant.withOpacity(0.5) : cs.surface,
        borderRadius: BorderRadius.circular(ui.radius(13)),
        border: Border.all(color: isDark ? cs.outline : cs.onSurface.withOpacity(0.08)),
      ),
      child: _FromToMini(
        origin: origin,
        dest: dest,
        count: count,
        cs: cs,
        ui: ui,
        dense: dense,
        isDark: isDark,
      ),
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
      BuildContext context,
      RideNearbyDriver d,
      UIScale ui, {
        required bool dense,
        required bool ultraDense,
        required bool selected,
        required bool isDark,
        required ColorScheme cs,
        required VoidCallback onTap,
      }) {

    final rankText = d.rank.trim().isEmpty ? 'Verified' : d.rank.trim();
    final rc = _rankColor(rankText, isDark, cs);

    final vt = d.vehicleType.trim().isEmpty ? 'car' : d.vehicleType.trim();
    final seats =
    vt.toLowerCase().contains('bike') ? 1 : (d.seats <= 0 ? 4 : d.seats);

    final etaText = d.etaMin <= 0 ? '1m' : '${d.etaMin}m';
    final distText = _fmtDistShort(d.distanceKm);

    final total = _driverTotal(d);
    final sym = _curSym(d.currency);
    final totalText = total > 0 ? '$sym${_moneyFmt.format(total.round())}' : '—';

    final img =
    (d.imagesEffective.isNotEmpty) ? _fixUrl(d.imagesEffective.first) : '';

    final avatarSize = ultraDense ? 28.0 : (dense ? 30.0 : 32.0);
    final thumbSize = ultraDense ? 26.0 : (dense ? 28.0 : 30.0);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ui.radius(14)),
        boxShadow: selected
            ? [
          BoxShadow(
            color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.10),
            blurRadius: ui.reduceFx ? 6 : 12,
            offset: const Offset(0, 5),
          ),
        ]
            : null,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ui.radius(14)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          padding: EdgeInsets.fromLTRB(
            ui.inset(7),
            ui.inset(6),
            ui.inset(7),
            ui.inset(6),
          ),
          decoration: BoxDecoration(
            color: selected
                ? (isDark ? cs.primary.withOpacity(0.12) : AppColors.primary.withOpacity(0.08))
                : (isDark ? cs.surfaceVariant.withOpacity(0.5) : cs.surface),
            borderRadius: BorderRadius.circular(ui.radius(14)),
            border: Border.all(
              color: selected
                  ? (isDark ? cs.primary.withOpacity(0.5) : AppColors.primary.withOpacity(0.46))
                  : (isDark ? cs.outline : cs.onSurface.withOpacity(0.08)),
              width: selected ? 1.35 : 1.0,
            ),
          ),
          child: LayoutBuilder(
            builder: (context, c) {
              final veryNarrow = c.maxWidth < 340;

              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _avatarWithRank(
                    context,
                    ui,
                    d.avatarUrl,
                    d.initials,
                    rankText,
                    rc,
                    size: avatarSize,
                    selected: selected,
                    isDark: isDark,
                    cs: cs,
                  ),
                  SizedBox(width: ui.gap(6)),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
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
                                  color: cs.onSurface,
                                  fontSize: ui.font(
                                    ultraDense ? 10.0 : (dense ? 10.4 : 10.8),
                                  ),
                                  height: 1.0,
                                  letterSpacing: -0.16,
                                ),
                              ),
                            ),
                            SizedBox(width: ui.gap(4)),
                            _ratingPill(context, ui, d.rating, isDark: isDark, cs: cs),
                          ],
                        ),
                        SizedBox(height: ui.gap(4)),
                        SizedBox(
                          height: ultraDense ? 18 : 20,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            padding: EdgeInsets.zero,
                            children: [
                              _chipNx(
                                context,
                                ui: ui,
                                icon: _vehicleIconNx(vt),
                                text: vt.toLowerCase().contains('bike')
                                    ? 'Bike'
                                    : 'Car',
                                tone: isDark ? cs.primary : AppColors.primary,
                                strong: true,
                                isDark: isDark,
                                cs: cs,
                              ),
                              SizedBox(width: ui.gap(4)),
                              _chipNx(
                                context,
                                ui: ui,
                                icon: Icons.airline_seat_recline_normal_rounded,
                                text: '$seats',
                                tone: const Color(0xFF1A73E8),
                                isDark: isDark,
                                cs: cs,
                              ),
                              SizedBox(width: ui.gap(4)),
                              _chipNx(
                                context,
                                ui: ui,
                                icon: Icons.av_timer_rounded,
                                text: etaText,
                                tone: const Color(0xFFB8860B),
                                isDark: isDark,
                                cs: cs,
                              ),
                              SizedBox(width: ui.gap(4)),
                              _chipNx(
                                context,
                                ui: ui,
                                icon: Icons.route_rounded,
                                text: distText,
                                tone: isDark ? cs.primary : const Color(0xFF1E8E3E),
                                isDark: isDark,
                                cs: cs,
                              ),
                              if (d.carPlate.trim().isNotEmpty) ...[
                                SizedBox(width: ui.gap(4)),
                                _chipNx(
                                  context,
                                  ui: ui,
                                  icon: Icons.qr_code_rounded,
                                  text: d.carPlate.trim(),
                                  tone: const Color(0xFF6A5ACD),
                                  mono: true,
                                  isDark: isDark,
                                  cs: cs,
                                ),
                              ],
                              if (!veryNarrow && d.category.trim().isNotEmpty) ...[
                                SizedBox(width: ui.gap(4)),
                                _chipNx(
                                  context,
                                  ui: ui,
                                  icon: Icons.bolt_rounded,
                                  text: _shortCat(d.category),
                                  tone: isDark ? cs.primary : AppColors.primary,
                                  isDark: isDark,
                                  cs: cs,
                                ),
                              ],
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
                          _thumb(
                            context,
                            ui,
                            img,
                            vt,
                            size: thumbSize,
                            isDark: isDark,
                            cs: cs,
                          ),
                          if (selected) ...[
                            SizedBox(width: ui.gap(3)),
                            Icon(
                              Icons.check_circle_rounded,
                              size: ui.icon(13),
                              color: isDark ? cs.primary : AppColors.primary,
                            ),
                          ],
                        ],
                      ),
                      SizedBox(height: ui.gap(3)),
                      Text(
                        totalText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: cs.onSurface,
                          fontSize: ui.font(
                            ultraDense ? 10.0 : (dense ? 10.5 : 11.0),
                          ),
                          height: 1.0,
                          letterSpacing: -0.16,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  String _shortCat(String s) {
    final x = s.trim();
    if (x.length <= 8) return x;
    return '${x.substring(0, 8)}…';
  }

  String _fmtDistShort(double km) {
    if (km <= 0) return 'Near';
    if (km < 1) return '${(km * 1000).round()}m';
    return '${km.toStringAsFixed(1)}km';
  }

  Widget _ratingPill(BuildContext context, UIScale ui, double rating, {required bool isDark, required ColorScheme cs}) {
    final r = rating.clamp(0, 5).toDouble();

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(5),
        vertical: ui.inset(3),
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: const Color(0xFFFFD54F).withOpacity(0.14),
        border: Border.all(color: isDark ? const Color(0xFFFFD54F).withOpacity(0.5) : cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.star_rounded,
            size: ui.icon(9.5),
            color: const Color(0xFFFFD54F),
          ),
          SizedBox(width: ui.gap(2)),
          Text(
            r.toStringAsFixed(1),
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: isDark ? Colors.white : cs.onSurface.withOpacity(0.82),
              fontSize: ui.font(8.6),
              height: 1.0,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatarWithRank(
      BuildContext context,
      UIScale ui,
      String url,
      String initials,
      String rank,
      Color rc, {
        required double size,
        required bool selected,
        required bool isDark,
        required ColorScheme cs,
      }) {

    final borderColor = selected
        ? (isDark ? cs.primary.withOpacity(0.60) : AppColors.primary.withOpacity(0.40))
        : (isDark ? cs.outline : cs.onSurface.withOpacity(0.10));
    final bg = isDark ? cs.surfaceVariant : cs.onSurface.withOpacity(0.06);
    final u = _fixUrl(url);

    Widget avatarFallback() {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bg,
          border: Border.all(color: borderColor, width: 1.0),
        ),
        child: Center(
          child: Text(
            initials,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: isDark ? cs.onSurface : cs.onSurface.withOpacity(0.78),
              fontSize: ui.font(9.2),
            ),
          ),
        ),
      );
    }

    final avatar = (u.isEmpty)
        ? avatarFallback()
        : ClipOval(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: borderColor, width: 1.0),
        ),
        child: Image.network(
          u,
          fit: BoxFit.cover,
          cacheWidth:
          (size * MediaQuery.of(context).devicePixelRatio).round(),
          filterQuality: FilterQuality.low,
          errorBuilder: (_, __, ___) => avatarFallback(),
          loadingBuilder: (c, w, p) {
            if (p == null) return w;
            return Container(
              color: bg,
              child: Center(
                child: SizedBox(
                  width: ui.gap(10),
                  height: ui.gap(10),
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isDark ? cs.primary : AppColors.primary,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    return SizedBox(
      width: size + 2,
      height: size + 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: avatar),
          Positioned(
            right: -1,
            top: -1,
            child: Container(
              padding: EdgeInsets.all(ui.inset(2)),
              decoration: BoxDecoration(
                color: isDark ? cs.surface : Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: isDark ? cs.outline : cs.onSurface.withOpacity(0.10)),
              ),
              child: Icon(
                _rankIcon(rank),
                size: ui.icon(9),
                color: rc,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(
      BuildContext context,
      UIScale ui,
      String url,
      String vehicleType, {
        required double size,
        required bool isDark,
        required ColorScheme cs,
      }) {

    Widget fallback() {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: isDark ? cs.surfaceVariant : cs.onSurface.withOpacity(0.06),
          borderRadius: BorderRadius.circular(ui.radius(10)),
          border: Border.all(color: isDark ? cs.outline : cs.onSurface.withOpacity(0.10)),
        ),
        child: Center(
          child: Icon(
            _vehicleIcon(vehicleType),
            color: isDark ? cs.onSurfaceVariant : cs.onSurface.withOpacity(0.55),
            size: ui.icon(14),
          ),
        ),
      );
    }

    final u = _fixUrl(url);
    if (u.isEmpty) return fallback();

    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheW = (size * dpr).round();

    return ClipRRect(
      borderRadius: BorderRadius.circular(ui.radius(10)),
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
              color: isDark ? cs.surfaceVariant : cs.onSurface.withOpacity(0.06),
              child: Center(
                child: SizedBox(
                  width: ui.gap(10),
                  height: ui.gap(10),
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isDark ? cs.primary : AppColors.primary,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _loadingRow(BuildContext context, UIScale ui, {required bool isDark, required ColorScheme cs}) {
    return Container(
      margin: EdgeInsets.only(bottom: ui.gap(6)),
      padding: EdgeInsets.fromLTRB(
        ui.inset(10),
        ui.inset(8),
        ui.inset(10),
        ui.inset(8),
      ),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceVariant.withOpacity(0.5) : cs.surface,
        borderRadius: BorderRadius.circular(ui.radius(13)),
        border: Border.all(color: isDark ? cs.outline : cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: ui.gap(13),
            height: ui.gap(13),
            child: CircularProgressIndicator(
              strokeWidth: 2.0,
              valueColor: AlwaysStoppedAnimation<Color>(isDark ? cs.primary : AppColors.primary),
            ),
          ),
          SizedBox(width: ui.gap(8)),
          Expanded(
            child: Text(
              'Searching…',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: isDark ? cs.onSurface : cs.onSurface.withOpacity(0.78),
                fontSize: ui.font(10.2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context, UIScale ui, {required bool isDark, required ColorScheme cs}) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        ui.inset(12),
        ui.inset(12),
        ui.inset(12),
        ui.inset(12),
      ),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceVariant.withOpacity(0.5) : cs.surface,
        borderRadius: BorderRadius.circular(ui.radius(14)),
        border: Border.all(color: isDark ? cs.outline : cs.onSurface.withOpacity(0.08)),
      ),
      child: Column(
        children: [
          Icon(
            Icons.directions_car_filled_rounded,
            color: isDark ? cs.onSurfaceVariant : cs.onSurface.withOpacity(0.55),
            size: ui.icon(24),
          ),
          SizedBox(height: ui.gap(6)),
          Text(
            'No drivers nearby',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: cs.onSurface,
              fontSize: ui.font(10.8),
            ),
          ),
          SizedBox(height: ui.gap(4)),
          Text(
            'Try refresh in a moment.',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: isDark ? cs.onSurfaceVariant : cs.onSurface.withOpacity(0.60),
              fontSize: ui.font(9.0),
            ),
          ),
          SizedBox(height: ui.gap(8)),
          SizedBox(
            width: double.infinity,
            height: ui.gap(36),
            child: ElevatedButton(
              onPressed: () {
                setState(() => _resetStable(alsoClearSelection: true));
                widget.onRefresh();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark ? cs.primary : AppColors.primary,
                foregroundColor: isDark ? cs.onPrimary : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(ui.radius(12)),
                ),
                elevation: 0,
                padding: EdgeInsets.zero,
              ),
              child: Text(
                'Refresh',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: ui.font(10.2),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(
      BuildContext context,
      MediaQueryData mq,
      List<RideNearbyDriver> drivers,
      UIScale ui, {
        required bool dense,
        required double maxHeight,
        required bool isDark,
        required ColorScheme cs,
      }) {
    final selected = (_selectedDriverId != null)
        ? drivers
        .where((x) => x.id == _selectedDriverId)
        .toList(growable: false)
        : const <RideNearbyDriver>[];

    final driverSelected = selected.isNotEmpty;
    final bottomInset = _bottomInset(mq, ui, maxHeight);

    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          ui.inset(8),
          ui.inset(6),
          ui.inset(8),
          bottomInset,
        ),
        decoration: BoxDecoration(
          color: isDark ? cs.surface : Theme.of(context).cardColor,
          border: Border(
            top: BorderSide(color: isDark ? cs.outline : cs.onSurface.withOpacity(0.08)),
          ),
        ),
        child: SizedBox(
          width: double.infinity,
          height: ui.gap(dense ? 36 : 40),
          child: ElevatedButton(
            onPressed: driverSelected
                ? () async {
              final d = selected.first;

              setState(() => _fullyFrozen = true);

              final driverMap = _driverToMap(d);
              final offerMap = _offerMapFromDriver(d);

              final payload =
              await showModalBottomSheet<Map<String, dynamic>>(
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
                    userLocation: widget.userLocation,
                    pickupLocation: widget.pickupLocation,
                    dropLocation: widget.dropLocation,
                  );
                },
              );

              if (payload == null) return;

              final offer = RideOffer(
                id: 'driver-${d.id}',
                provider: 'PickMe',
                category: d.category.isNotEmpty
                    ? d.category
                    : (d.vehicleType.toLowerCase().contains('bike')
                    ? 'Bike'
                    : 'Car'),
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
              disabledBackgroundColor: isDark ? cs.surfaceVariant : cs.onSurface.withOpacity(0.10),
              disabledForegroundColor: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : cs.onSurface.withOpacity(0.40),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(ui.radius(14)),
              ),
              elevation: 0,
              padding: EdgeInsets.zero,
            ),
            child: Text(
              'Select driver',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: ui.font(dense ? 10.2 : 10.8),
              ),
            ),
          ),
        ),
      ),
    );
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
      'avatar_url': d.avatarUrl,
      'phone': d.phone,
      'nin': d.nin,
      'rank': d.rank,
      'completed_trips': d.completedTrips,
      'cancelled_trips': d.cancelledTrips,
      'incomplete_trips': d.incompleteTrips,
      'reviews_count': d.reviewsCount,
      'total_trips': d.totalTrips,
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
      'category':
      d.vehicleType.toLowerCase().contains('bike') ? 'Bike' : 'Car',
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

class _FromToMini extends StatelessWidget {
  final String origin;
  final String dest;
  final int count;
  final ColorScheme cs;
  final UIScale ui;
  final bool dense;
  final bool isDark;

  const _FromToMini({
    required this.origin,
    required this.dest,
    required this.count,
    required this.cs,
    required this.ui,
    required this.dense,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final h = dense ? 38.0 : 42.0;
    final treeW = dense ? 14.0 : 16.0;
    final gap = dense ? 6.0 : 8.0;
    final countW = ui.landscape ? 82.0 : 92.0;

    return SizedBox(
      height: h,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RouteTreeAligned(
            cs: cs,
            ui: ui,
            height: h,
            width: treeW,
            dense: dense,
            isDark: isDark,
          ),
          SizedBox(width: gap),
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: EdgeInsets.only(right: countW),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _LabeledLine(
                        label: 'FROM',
                        value: origin,
                        cs: cs,
                        ui: ui,
                        strong: true,
                        isDark: isDark,
                      ),
                      _LabeledLine(
                        label: 'TO',
                        value: dest,
                        cs: cs,
                        ui: ui,
                        strong: false,
                        isDark: isDark,
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: _NearbyPillMini(
                    count: count,
                    cs: cs,
                    ui: ui,
                    isDark: isDark,
                  ),
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
  final UIScale ui;
  final double height;
  final double width;
  final bool dense;
  final bool isDark;

  const _RouteTreeAligned({
    required this.cs,
    required this.ui,
    required this.height,
    required this.width,
    required this.dense,
    required this.isDark,
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
          _ProNode(
            color: start,
            glyph: Icons.my_location_rounded,
            size: dense ? 9.0 : 10.0,
            iconSize: dense ? 6.0 : 7.0,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: CustomPaint(
                painter: _DottedStemPainter(
                  color: isDark ? cs.onSurfaceVariant : cs.onSurface.withOpacity(0.22),
                ),
              ),
            ),
          ),
          _ProNode(
            color: end,
            glyph: Icons.place_rounded,
            size: dense ? 9.0 : 10.0,
            iconSize: dense ? 6.0 : 7.0,
          ),
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

  const _ProNode({
    required this.color,
    required this.glyph,
    required this.size,
    required this.iconSize,
  });

  @override
  Widget build(BuildContext context) {
    final inner = size - 2;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withOpacity(0.16),
      ),
      child: Center(
        child: Container(
          width: inner,
          height: inner,
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
            child: Icon(
              glyph,
              size: iconSize,
              color: Colors.white.withOpacity(0.95),
            ),
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
    const dashH = 2.0;
    const gap = 2.0;

    final x = size.width / 2;
    double y = 0;

    while (y < size.height) {
      final h = (y + dashH <= size.height) ? dashH : (size.height - y);
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, y + h / 2), width: 1.6, height: h),
        const Radius.circular(99),
      );
      canvas.drawRRect(rect, p);
      y += dashH + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DottedStemPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _LabeledLine extends StatelessWidget {
  final String label;
  final String value;
  final ColorScheme cs;
  final UIScale ui;
  final bool strong;
  final bool isDark;

  const _LabeledLine({
    required this.label,
    required this.value,
    required this.cs,
    required this.ui,
    required this.strong,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 27,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: ui.font(7.8),
              height: 1.0,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.30,
              color: isDark ? cs.onSurfaceVariant : cs.onSurface.withOpacity(0.42),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: ui.font(strong ? 9.8 : 9.2),
              height: 1.0,
              letterSpacing: -0.12,
              fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
              color: isDark ? cs.onSurface : cs.onSurface.withOpacity(strong ? 0.92 : 0.66),
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
  final UIScale ui;
  final bool isDark;

  const _NearbyPillMini({
    required this.count,
    required this.cs,
    required this.ui,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceVariant : cs.surface.withOpacity(0.88),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isDark ? cs.outline : AppColors.primary.withOpacity(0.22),
          width: 1,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: ui.inset(6),
          vertical: ui.inset(3),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.near_me_rounded,
              size: ui.icon(9),
              color: isDark ? cs.primary : AppColors.primary,
            ),
            SizedBox(width: ui.gap(3)),
            Text(
              '$count',
              style: TextStyle(
                fontSize: ui.font(8.4),
                height: 1.0,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.08,
                color: isDark ? cs.onSurface : cs.onSurface.withOpacity(0.88),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _vehicleIconNx(String vt) {
  final v = vt.toLowerCase();
  if (v.contains('bike') || v.contains('moto')) {
    return Icons.two_wheeler_rounded;
  }
  if (v.contains('bus') || v.contains('van')) {
    return Icons.airport_shuttle_rounded;
  }
  if (v.contains('lux') || v.contains('vip')) {
    return Icons.workspace_premium_rounded;
  }
  return Icons.directions_car_filled_rounded;
}

Widget _chipNx(
    BuildContext context, {
      required UIScale ui,
      required IconData icon,
      required String text,
      required Color tone,
      bool strong = false,
      bool mono = false,
      required bool isDark,
      required ColorScheme cs,
    }) {

  return DecoratedBox(
    decoration: BoxDecoration(
      color: tone.withOpacity(isDark ? 0.20 : 0.10),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: tone.withOpacity(isDark ? 0.35 : 0.20), width: 1),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(5),
        vertical: ui.inset(2.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: ui.icon(8.8),
            color: tone.withOpacity(0.95),
          ),
          SizedBox(width: ui.gap(3)),
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
              color: isDark ? cs.onSurface : cs.onSurface.withOpacity(0.86),
              fontSize: ui.font(7.8),
              height: 1.0,
              letterSpacing: -0.05,
              fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
            ),
          ),
        ],
      ),
    ),
  );
}