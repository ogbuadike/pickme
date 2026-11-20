// lib/widgets/ride_market_sheet.dart
//
// "Select a driver" sheet for Street Ride and Campus Ride.
//
//  * Stable list: first batch is ranked once (rating > rank > ETA > distance),
//    later arrivals are appended, so rows never jump under the rider's finger.
//    Data of listed drivers (position, price, ETA) stays live; drivers that
//    disappear from the feed are dropped, except the selected one which is
//    shown as "Unavailable" so the rider is never sent to book a busy driver.
//  * Work happens only when the feed actually changed (signature check) -
//    no setState from didUpdateWidget, no rebuild storms while polling.
//  * Booking is single-flight: the CTA is disabled from the first tap until
//    onBook completes.
//  * Fare shown == fare booked (route distance x driver tariff, whole naira).

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/geo_point.dart';
import '../services/ride_market_service.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import 'driver_details_sheet.dart';
import 'ride_market/driver_card.dart';
import 'ride_market/money.dart';
import 'ride_market/ride_nearby_driver.dart';

export 'ride_market/ride_nearby_driver.dart' show RideNearbyDriver;

class RideMarketSheet extends StatefulWidget {
  final double bottomNavHeight;
  final String originText;
  final String destinationText;
  final String? distanceText;
  final String? durationText;
  final double? tripDistanceKm;
  final int driversNearbyCount;
  final List<dynamic>? drivers;

  /// Kept for API compatibility; the market lists drivers (each driver is an
  /// offer with its own tariff).
  final List<RideOffer> offers;
  final bool loading;
  final GeoPoint? userLocation;
  final GeoPoint? pickupLocation;
  final GeoPoint? dropLocation;
  final VoidCallback onRefresh;
  final VoidCallback onCancel;

  /// May return a Future; the sheet stays locked until it completes.
  final FutureOr<void> Function(RideNearbyDriver driver, RideOffer offer) onBook;

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

enum _Filter { all, car, keke, bike }

extension on _Filter {
  String get label => const <String>['All', 'Car', 'Ke-ke', 'Bike'][index];
  String get plural => const <String>['drivers', 'cars', 'ke-kes', 'bikes'][index];
  IconData get icon => const <IconData>[
        Icons.apps_rounded,
        Icons.directions_car_rounded,
        Icons.electric_rickshaw_rounded,
        Icons.two_wheeler_rounded,
      ][index];
  bool matches(RideNearbyDriver d) {
    switch (this) {
      case _Filter.all:
        return true;
      case _Filter.car:
        return vehicleClassOf(d.vehicleType) == VehicleClass.car;
      case _Filter.keke:
        return vehicleClassOf(d.vehicleType) == VehicleClass.keke;
      case _Filter.bike:
        return vehicleClassOf(d.vehicleType) == VehicleClass.bike;
    }
  }
}

class _RideMarketSheetState extends State<RideMarketSheet> {
  // Stable ordering + live data.
  final List<String> _order = <String>[];
  final Map<String, RideNearbyDriver> _byId = <String, RideNearbyDriver>{};
  String _feedSignature = '';
  List<RideNearbyDriver> _visible = const <RideNearbyDriver>[];

  _Filter _filter = _Filter.all;
  String? _selectedDriverId;
  String? _unavailableSelectedId;
  bool _busy = false;

  // ── Distance ──────────────────────────────────────────────────────────────
  double get _tripKm {
    final double? km = widget.tripDistanceKm;
    if (km != null && km.isFinite && km > 0) return km;
    return _parseDistanceKm(widget.distanceText ?? '');
  }

  static double _parseDistanceKm(String s) {
    final String t = s.trim().toLowerCase().replaceAll(',', '');
    if (t.isEmpty) return 0;
    final String? numStr = RegExp(r'([\d.]+)').firstMatch(t)?.group(1);
    final double v = numStr == null ? 0.0 : (double.tryParse(numStr) ?? 0.0);
    if (v <= 0) return 0;
    if (t.contains('km')) return v;
    if (RegExp(r'\d\s*m\b').hasMatch(t)) return v / 1000.0;
    return v;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _reconcile();
  }

  @override
  void didUpdateWidget(covariant RideMarketSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool routeChanged = oldWidget.originText != widget.originText ||
        oldWidget.destinationText != widget.destinationText ||
        oldWidget.tripDistanceKm != widget.tripDistanceKm ||
        oldWidget.distanceText != widget.distanceText;
    if (routeChanged) _resetStable(alsoClearSelection: true);
    // build() runs right after didUpdateWidget - no setState needed.
    _reconcile();
  }

  // ── Ranking ───────────────────────────────────────────────────────────────
  static int _rankWeight(String r) {
    final String x = r.trim().toLowerCase();
    if (x.contains('diamond')) return 6;
    if (x.contains('platinum')) return 5;
    if (x.contains('gold')) return 4;
    if (x.contains('silver')) return 3;
    if (x.contains('bronze')) return 2;
    if (x.contains('verified')) return 1;
    return 0;
  }

  static double _safeRating(double r) => r.isNaN || r.isInfinite ? 0 : r.clamp(0, 5).toDouble();

  static int _compareDrivers(RideNearbyDriver a, RideNearbyDriver b) {
    final int c1 = _safeRating(b.rating).compareTo(_safeRating(a.rating));
    if (c1 != 0) return c1;
    final int c2 = _rankWeight(b.rankLabel).compareTo(_rankWeight(a.rankLabel));
    if (c2 != 0) return c2;
    final int c3 = a.etaMin.compareTo(b.etaMin);
    if (c3 != 0) return c3;
    final int c4 = a.distanceKm.compareTo(b.distanceKm);
    if (c4 != 0) return c4;
    return a.id.compareTo(b.id);
  }

  // ── Stable list management ────────────────────────────────────────────────
  void _resetStable({bool alsoClearSelection = false}) {
    _order.clear();
    _byId.clear();
    _feedSignature = '';
    _visible = const <RideNearbyDriver>[];
    if (alsoClearSelection) {
      _selectedDriverId = null;
      _unavailableSelectedId = null;
    }
  }

  void _reconcile() {
    final List<dynamic> raw = widget.drivers ?? const <dynamic>[];
    final List<RideNearbyDriver> incoming = <RideNearbyDriver>[];
    final Set<String> seen = <String>{};
    for (final dynamic x in raw) {
      final RideNearbyDriver d = RideNearbyDriver.from(x);
      if (d.id.isEmpty || !seen.add(d.id)) continue;
      incoming.add(d);
    }

    final String sig = incoming.map((RideNearbyDriver d) => d.signature).join(';');
    if (sig == _feedSignature && _visible.isNotEmpty == incoming.isNotEmpty) {
      _recomputeVisible();
      return;
    }
    _feedSignature = sig;

    final Map<String, RideNearbyDriver> fresh = <String, RideNearbyDriver>{
      for (final RideNearbyDriver d in incoming) d.id: d,
    };

    // Drop drivers that left the feed (busy / offline / out of radius),
    // except the selected one which is flagged instead of silently vanishing.
    final String? sel = _selectedDriverId;
    _order.removeWhere((String id) => !fresh.containsKey(id) && id != sel);
    _byId.removeWhere((String id, _) => !fresh.containsKey(id) && id != sel);
    _unavailableSelectedId = (sel != null && !fresh.containsKey(sel)) ? sel : null;

    // Update data in place, append newcomers (ranked among themselves).
    final List<RideNearbyDriver> newcomers = <RideNearbyDriver>[];
    for (final RideNearbyDriver d in incoming) {
      if (_byId.containsKey(d.id)) {
        _byId[d.id] = d;
      } else {
        _byId[d.id] = d;
        newcomers.add(d);
      }
    }
    newcomers.sort(_compareDrivers);
    _order.addAll(newcomers.map((RideNearbyDriver d) => d.id));
    _recomputeVisible();
  }

  void _recomputeVisible() {
    _visible = <RideNearbyDriver>[
      for (final String id in _order)
        if (_byId[id] != null && _filter.matches(_byId[id]!)) _byId[id]!,
    ];
  }

  RideNearbyDriver? get _selected {
    final String? id = _selectedDriverId;
    if (id == null) return null;
    final RideNearbyDriver? d = _byId[id];
    if (d == null || !_filter.matches(d)) return null;
    return d;
  }

  bool get _selectedUnavailable => _selectedDriverId != null && _selectedDriverId == _unavailableSelectedId;

  String _totalText(RideNearbyDriver d) {
    final double total = d.fareFor(_tripKm);
    return total > 0 ? formatMoney(total, currency: d.currency) : '—';
  }

  double _sheetMaxHeight(MediaQueryData mq, UIScale uiScale) {
    final double h = mq.size.height;
    if (uiScale.landscape) return (h * 0.85).clamp(220.0, 500.0);
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
      barrierColor: Colors.black.withValues(alpha: isDark ? 0.75 : 0.5),
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
                          ? cs.surface.withValues(alpha: 0.88)
                          : Colors.white.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(uiScale.radius(20)),
                      border: Border.all(color: cs.error.withValues(alpha: 0.3), width: 1.2),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
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
                              color: cs.error.withValues(alpha: 0.12)),
                          child: Icon(Icons.warning_amber_rounded,
                              size: uiScale.icon(24), color: cs.error),
                        ),
                        SizedBox(height: uiScale.gap(14)),
                        Text(
                          'Cancel this request?',
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
                          'This stops looking for drivers and clears your destination.',
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
    final MediaQueryData mq = MediaQuery.of(context);
    final UIScale uiScale = UIScale.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool isDark = theme.brightness == Brightness.dark;
    final List<RideNearbyDriver> drivers = _visible;

    return Align(
      alignment: Alignment.bottomCenter,
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(22))),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(maxHeight: _sheetMaxHeight(mq, uiScale)),
            decoration: BoxDecoration(
              color: isDark ? cs.surface.withValues(alpha: 0.92) : Colors.white.withValues(alpha: 0.97),
              borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(22))),
              border: Border(
                top: BorderSide(
                  color: isDark ? cs.outline.withValues(alpha: 0.4) : AppColors.mintBgLight.withValues(alpha: 0.3),
                ),
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.10),
                  blurRadius: uiScale.reduceFx ? 12 : 22,
                  offset: const Offset(0, -8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(height: uiScale.gap(6)),
                Container(
                  width: uiScale.landscape ? 40 : 46,
                  height: 4.0,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: isDark
                        ? cs.onSurfaceVariant.withValues(alpha: 0.45)
                        : AppColors.textSecondary.withValues(alpha: 0.20),
                  ),
                ),
                SizedBox(height: uiScale.gap(4)),
                _buildTopBar(context, uiScale, isDark: isDark, cs: cs),
                _buildRouteStrip(uiScale, count: drivers.length, isDark: isDark, cs: cs),
                SizedBox(height: uiScale.gap(8)),
                _buildFilterStrip(uiScale, isDark: isDark, cs: cs),
                SizedBox(height: uiScale.gap(4)),
                Flexible(child: _buildContent(context, drivers, uiScale, isDark: isDark, cs: cs)),
                _buildBottomBar(context, mq, uiScale, isDark: isDark, cs: cs),
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
            onTap: _busy ? () {} : () => _handleCancelAction(context, ui, isDark, cs),
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
            onTap: _busy
                ? () {}
                : () {
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
  Widget _buildRouteStrip(UIScale ui, {required int count, required bool isDark, required ColorScheme cs}) {
    final String origin = widget.originText.trim().isEmpty ? 'Pickup' : widget.originText.trim();
    final String dest = widget.destinationText.trim().isEmpty ? 'Destination' : widget.destinationText.trim();
    final Color primary = isDark ? cs.primary : AppColors.primary;
    final TextStyle placeStyle = TextStyle(
      fontWeight: FontWeight.w700,
      fontSize: ui.font(10.5),
      color: isDark ? cs.onSurface : AppColors.textPrimary,
      height: 1.0,
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(10)),
      child: Container(
        height: 38,
        padding: EdgeInsets.symmetric(horizontal: ui.inset(10)),
        decoration: BoxDecoration(
          color: isDark ? cs.surfaceContainerHighest.withValues(alpha: 0.28) : Colors.black.withValues(alpha: 0.025),
          borderRadius: BorderRadius.circular(ui.radius(10)),
          border: Border.all(
            color: isDark ? cs.outline.withValues(alpha: 0.35) : AppColors.mintBgLight.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          children: <Widget>[
            Container(width: 7, height: 7, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF1A73E8))),
            SizedBox(width: ui.gap(5)),
            Expanded(child: Text(origin, maxLines: 1, overflow: TextOverflow.ellipsis, style: placeStyle)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: ui.gap(5)),
              child: Icon(Icons.arrow_forward_rounded,
                  size: ui.icon(11), color: isDark ? cs.onSurfaceVariant.withValues(alpha: 0.5) : Colors.black26),
            ),
            Container(width: 7, height: 7, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF1E8E3E))),
            SizedBox(width: ui.gap(5)),
            Expanded(child: Text(dest, maxLines: 1, overflow: TextOverflow.ellipsis, style: placeStyle)),
            SizedBox(width: ui.gap(6)),
            Container(
              padding: EdgeInsets.symmetric(horizontal: ui.inset(6), vertical: ui.inset(3)),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: primary.withValues(alpha: 0.28)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.radar_rounded, size: ui.icon(8.5), color: primary),
                  SizedBox(width: ui.gap(3)),
                  Text('$count',
                      style: TextStyle(fontSize: ui.font(8.5), fontWeight: FontWeight.w900, color: primary, height: 1.0)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Vehicle Filter Strip ─────────────────────────────────────────────────
  Widget _buildFilterStrip(UIScale ui, {required bool isDark, required ColorScheme cs}) {
    final Color primary = isDark ? cs.primary : AppColors.primary;
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: ui.inset(10)),
        itemCount: _Filter.values.length,
        separatorBuilder: (_, __) => SizedBox(width: ui.gap(6)),
        itemBuilder: (_, int i) {
          final _Filter f = _Filter.values[i];
          final bool selected = _filter == f;
          final Color fg = selected ? primary : (isDark ? cs.onSurfaceVariant : AppColors.textSecondary);
          return GestureDetector(
            onTap: () {
              if (_filter == f) return;
              HapticFeedback.selectionClick();
              setState(() {
                _filter = f;
                _recomputeVisible();
                if (_selected == null) _selectedDriverId = null;
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: EdgeInsets.symmetric(horizontal: ui.inset(12)),
              decoration: BoxDecoration(
                color: selected
                    ? primary.withValues(alpha: 0.12)
                    : (isDark ? cs.surfaceContainerHighest.withValues(alpha: 0.3) : Colors.black.withValues(alpha: 0.03)),
                borderRadius: BorderRadius.circular(ui.radius(10)),
                border: Border.all(
                  color: selected
                      ? primary
                      : (isDark ? cs.outline.withValues(alpha: 0.3) : AppColors.mintBgLight.withValues(alpha: 0.5)),
                ),
              ),
              alignment: Alignment.center,
              child: Row(
                children: <Widget>[
                  Icon(f.icon, size: ui.icon(14), color: fg),
                  SizedBox(width: ui.gap(5)),
                  Text(
                    f.label,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
                      fontSize: ui.font(11.5),
                      letterSpacing: -0.2,
                      color: fg,
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
  Widget _buildContent(BuildContext context, List<RideNearbyDriver> drivers, UIScale ui,
      {required bool isDark, required ColorScheme cs}) {
    final bool showEmpty = !widget.loading && drivers.isEmpty;
    final bool showLoading = widget.loading && drivers.isEmpty;
    return RepaintBoundary(
      child: ListView.builder(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(ui.inset(10), ui.gap(4), ui.inset(10), ui.gap(4)),
        shrinkWrap: true,
        itemCount: (showEmpty || showLoading) ? 1 : drivers.length,
        itemBuilder: (BuildContext context, int i) {
          if (showEmpty) return _buildEmptyState(context, ui, isDark: isDark, cs: cs);
          if (showLoading) return _buildLoadingRow(context, ui, isDark: isDark, cs: cs);
          final RideNearbyDriver d = drivers[i];
          return Padding(
            key: ValueKey<String>(d.id),
            padding: EdgeInsets.only(bottom: ui.gap(5)),
            child: DriverCard(
              driver: d,
              selected: _selectedDriverId == d.id,
              unavailable: _unavailableSelectedId == d.id,
              totalText: _totalText(d),
              onTap: _busy
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      setState(() => _selectedDriverId = d.id);
                    },
            ),
          );
        },
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
            ? cs.surfaceContainerHighest.withValues(alpha: 0.28)
            : Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(ui.radius(11)),
        border: Border.all(
            color: isDark
                ? cs.outline.withValues(alpha: 0.28)
                : Colors.black.withValues(alpha: 0.05)),
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
  Widget _buildEmptyState(BuildContext context, UIScale ui, {required bool isDark, required ColorScheme cs}) {
    final bool hasOthers = _byId.isNotEmpty && _filter != _Filter.all;
    final String emptyMsg = hasOthers ? 'No ${_filter.plural} available' : 'No drivers available nearby';

    return Padding(
      padding: EdgeInsets.symmetric(vertical: ui.gap(16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            padding: EdgeInsets.all(ui.inset(10)),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? cs.surface : Colors.white,
              boxShadow: <BoxShadow>[
                BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
              ],
            ),
            child: Icon(Icons.directions_car_filled_rounded,
                color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, size: ui.icon(22)),
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
            hasOthers ? 'Try another vehicle type.' : 'We keep looking - you can also refresh.',
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
                if (hasOthers) {
                  setState(() {
                    _filter = _Filter.all;
                    _recomputeVisible();
                  });
                  return;
                }
                setState(() => _resetStable(alsoClearSelection: true));
                widget.onRefresh();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark ? cs.primary : AppColors.primary,
                foregroundColor: isDark ? cs.onPrimary : Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ui.radius(10))),
                elevation: 0,
                padding: EdgeInsets.symmetric(horizontal: ui.inset(24)),
              ),
              child: Text(hasOthers ? 'Show all' : 'Refresh',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: ui.font(11.5))),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Bottom bar (CTA) ─────────────────────────────────────────────────────
  Future<void> _onContinue(RideNearbyDriver d) async {
    if (_busy) return;
    HapticFeedback.selectionClick();
    setState(() => _busy = true);
    try {
      final double total = d.fareFor(_tripKm);
      final Map<String, dynamic>? payload = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => DriverDetailsSheet(
          driver: _driverToMap(d, total),
          offer: _offerMapFromDriver(d, total),
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
      if (!mounted || payload == null) return;

      // The driver may have gone busy/offline while the details were open.
      final RideNearbyDriver latest = _byId[d.id] ?? d;
      if (_unavailableSelectedId == d.id) return;
      final double finalTotal = latest.fareFor(_tripKm);

      final RideOffer offer = RideOffer(
        id: 'driver-${latest.id}',
        provider: 'PickMe',
        category: latest.category.isNotEmpty ? latest.category : vehicleLabelOf(latest.vehicleType),
        etaToPickupMin: latest.etaMin,
        price: finalTotal.round(),
        surge: false,
        driverName: latest.name,
        rating: latest.rating,
        carPlate: latest.carPlate,
        seats: latest.seats,
        currency: latest.currency,
        pricePerKm: latest.pricePerKm,
        baseFare: latest.baseFare,
        estimatedTotal: finalTotal,
        vehicleType: latest.vehicleType,
        driverId: latest.id,
      );
      await widget.onBook(latest, offer);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildBottomBar(BuildContext context, MediaQueryData mq, UIScale ui,
      {required bool isDark, required ColorScheme cs}) {
    final RideNearbyDriver? selected = _selected;
    final bool unavailable = _selectedUnavailable;
    final bool enabled = selected != null && !unavailable && !_busy && selected.fareFor(_tripKm) > 0;

    final double bottomSafe = math.max(mq.padding.bottom, ui.inset(12));
    final double buttonH = math.max(44.0, ui.landscape ? ui.gap(40) : ui.gap(46));

    String label;
    if (_busy) {
      label = 'Please wait…';
    } else if (selected == null) {
      label = 'Select a driver to continue';
    } else if (unavailable) {
      label = 'Driver no longer available - pick another';
    } else if (selected.fareFor(_tripKm) <= 0) {
      label = 'Fare unavailable for this driver';
    } else {
      label = 'Continue with ${selected.name.split(' ').first}';
    }

    return Container(
      padding: EdgeInsets.fromLTRB(ui.inset(16), ui.inset(10), ui.inset(16), bottomSafe + ui.inset(6)),
      decoration: BoxDecoration(
        color: isDark ? cs.surface.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.95),
        border: Border(
          top: BorderSide(color: isDark ? cs.outline.withValues(alpha: 0.35) : Colors.black.withValues(alpha: 0.04)),
        ),
      ),
      child: SizedBox(
        width: double.infinity,
        height: buttonH,
        child: ElevatedButton(
          onPressed: enabled ? () => _onContinue(selected) : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: isDark ? cs.primary : AppColors.primary,
            foregroundColor: isDark ? cs.onPrimary : Colors.white,
            disabledBackgroundColor: isDark ? cs.surfaceContainerHighest : AppColors.mintBgLight,
            disabledForegroundColor:
                isDark ? cs.onSurfaceVariant.withValues(alpha: 0.5) : AppColors.textSecondary.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ui.radius(14))),
            elevation: enabled ? 3 : 0,
          ),
          child: _busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: isDark ? cs.onPrimary : AppColors.primary),
                )
              : Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: ui.font(13.5), letterSpacing: -0.1),
                ),
        ),
      ),
    );
  }

  // ── Map helpers (DriverDetailsSheet contract) ─────────────────────────────
  Map<String, dynamic> _driverToMap(RideNearbyDriver d, double total) => <String, dynamic>{
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
        'estimated_total': total,
        'trip_km': _tripKm,
      };

  Map<String, dynamic> _offerMapFromDriver(RideNearbyDriver d, double total) => <String, dynamic>{
        'id': 'driver-${d.id}',
        'provider': 'PickMe',
        'category': vehicleLabelOf(d.vehicleType),
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
                ? cs.surfaceContainerHighest.withValues(alpha: 0.45)
                : AppColors.mintBgLight.withValues(alpha: 0.45),
            shape: BoxShape.circle,
            border: Border.all(
                color: isDark
                    ? cs.outline.withValues(alpha: 0.35)
                    : Colors.black.withValues(alpha: 0.05)),
          ),
          child: Icon(icon,
              size: ui.icon(15),
              color: isDark ? cs.onSurface : AppColors.textPrimary),
        ),
      ),
    );
  }
}
