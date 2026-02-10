// lib/widgets/driver_details_sheet.dart
//
// Separate bottom sheet: shows full driver detail + vehicle images slider + stats.
// Uses intl NumberFormat (no duplicate class names).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../themes/app_theme.dart';

class DriverDetailsSheet extends StatefulWidget {
  final Map<String, dynamic> driver;
  final Map<String, dynamic> offer;

  final String originText;
  final String destinationText;
  final String? distanceText;
  final String? durationText;
  final double tripDistanceKm;

  final VoidCallback onConfirm;

  const DriverDetailsSheet({
    super.key,
    required this.driver,
    required this.offer,
    required this.originText,
    required this.destinationText,
    required this.distanceText,
    required this.durationText,
    required this.tripDistanceKm,
    required this.onConfirm,
  });

  @override
  State<DriverDetailsSheet> createState() => _DriverDetailsSheetState();
}

class _DriverDetailsSheetState extends State<DriverDetailsSheet> {
  final _moneyFmt = NumberFormat.decimalPattern();
  late final PageController _pageCtrl;
  int _page = 0;

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
      return v.map((e) => e.toString()).where((x) => x.trim().isNotEmpty).toList();
    }
    final s = v.toString().trim();
    if (s.isEmpty) return const [];
    return s.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
  }

  IconData _vehicleIcon(String t) {
    final x = t.trim().toLowerCase();
    if (x.contains('bike')) return Icons.two_wheeler_rounded;
    return Icons.directions_car_rounded;
  }

  Color _rankColor(String r) {
    final x = r.trim().toLowerCase();
    if (x.contains('platinum')) return const Color(0xFF6A5ACD);
    if (x.contains('gold')) return const Color(0xFFB8860B);
    if (x.contains('silver')) return const Color(0xFF607D8B);
    if (x.contains('bronze')) return const Color(0xFF8D6E63);
    return AppColors.primary;
  }

  String _currency() {
    final c = _s(widget.offer['currency'], 'NGN').toUpperCase();
    if (c == 'NGN') return '₦';
    if (c == 'USD') return '\$';
    return c;
  }

  double _perKmPrice() {
    final v = _num(widget.offer['price_per_km'], -1).toDouble();
    if (v >= 0) return v;
    return _num(widget.offer['price'], 0).toDouble();
  }

  double _totalTripPrice() {
    final perKm = _perKmPrice();
    final km = widget.tripDistanceKm;
    if (km > 0) return perKm * km;
    return perKm;
  }

  Future<void> _copy(String label, String value) async {
    final v = value.trim();
    if (v.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: v));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied'), duration: const Duration(milliseconds: 900)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cs = Theme.of(context).colorScheme;

    final name = _s(widget.driver['name'], 'Driver');
    final category = _s(widget.driver['category'], '');
    final rating = _num(widget.driver['rating'], 0).toDouble();

    final phone = _s(widget.driver['phone'], '');
    final nin = _s(widget.driver['nin'], '');
    final rank = _s(widget.driver['rank'], '').trim().isEmpty ? 'Verified' : _s(widget.driver['rank'], 'Verified').trim();

    final vehicleType = _s(widget.driver['vehicle_type'], 'car');
    final seats = vehicleType.toLowerCase().contains('bike') ? 1 : _num(widget.driver['seats'], 4).toInt();
    final desc = _s(widget.driver['vehicle_description'], '');

    final avatar = _s(widget.driver['avatar_url'], '');
    final plate = _s(widget.driver['car_plate'], '');

    final imgs = (() {
      final a = _stringList(widget.driver['vehicle_images']);
      if (a.isNotEmpty) return a;
      final single = _s(widget.driver['car_image_url'], '');
      if (single.trim().isNotEmpty) return <String>[single.trim()];
      return <String>[];
    })();

    final completed = _num(widget.driver['completed_trips'], 0).toInt();
    final cancelled = _num(widget.driver['cancelled_trips'], 0).toInt();
    final incomplete = _num(widget.driver['incomplete_trips'], 0).toInt();
    final reviews = _num(widget.driver['reviews_count'], 0).toInt();
    final totalTrips = _num(widget.driver['total_trips'], 0).toInt();

    final cur = _currency();
    final totalPrice = _totalTripPrice();
    final perKm = _perKmPrice();

    final origin = widget.originText.trim().isEmpty ? 'Pickup' : widget.originText.trim();
    final dest = widget.destinationText.trim().isEmpty ? 'Destination' : widget.destinationText.trim();
    final dist = widget.distanceText ?? '--';
    final dur = widget.durationText ?? '--';

    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(maxHeight: mq.size.height * 0.86),
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
              Container(
                width: 54,
                height: 5,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), color: cs.onSurface.withOpacity(0.18)),
              ),
              const SizedBox(height: 8),

              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    Expanded(
                      child: Text(
                        'Driver information',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.90)),
                      ),
                    ),
                    IconButton(
                      onPressed: () {},
                      icon: const Icon(Icons.shield_rounded),
                      tooltip: 'Safety',
                    ),
                  ],
                ),
              ),

              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    // route mini (blue/green dots)
                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
                      ),
                      child: Row(
                        children: [
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
                                    style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.88))),
                                const SizedBox(height: 4),
                                Text(dest, maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurface.withOpacity(0.60))),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _pill(cs, Icons.schedule_rounded, dur),
                                    _pill(cs, Icons.straighten_rounded, dist),
                                    _pill(cs, Icons.price_change_rounded, '$cur${_moneyFmt.format(totalPrice.round())}'),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 10),

                    // driver hero
                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
                      ),
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
                                      child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.92))),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: _rankColor(rank).withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(999),
                                        border: Border.all(color: _rankColor(rank).withOpacity(0.20)),
                                      ),
                                      child: Text(rank, style: TextStyle(fontWeight: FontWeight.w900, color: _rankColor(rank), fontSize: 11)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    if (category.isNotEmpty) _chip(cs, Icons.local_taxi_rounded, category),
                                    _chip(cs, _vehicleIcon(vehicleType), '${vehicleType.toLowerCase().contains('bike') ? 'Bike' : 'Car'} • $seats'),
                                    if (plate.isNotEmpty) _chip(cs, Icons.confirmation_number_rounded, plate),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                _stars(cs, rating),
                              ],
                            ),
                          )
                        ],
                      ),
                    ),

                    const SizedBox(height: 10),

                    if (imgs.isNotEmpty) ...[
                      _imagesSlider(cs, imgs),
                      const SizedBox(height: 10),
                    ],

                    if (desc.trim().isNotEmpty)
                      Container(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                        decoration: BoxDecoration(
                          color: cs.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: cs.onSurface.withOpacity(0.08)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_rounded, color: cs.onSurface.withOpacity(0.60)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                desc,
                                style: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurface.withOpacity(0.78), height: 1.25),
                              ),
                            )
                          ],
                        ),
                      ),

                    const SizedBox(height: 10),

                    Row(
                      children: [
                        Expanded(child: _actionCard(cs, 'Phone', phone.isEmpty ? '—' : phone, Icons.call_rounded, onTap: phone.isEmpty ? null : () => _copy('Phone', phone))),
                        const SizedBox(width: 8),
                        Expanded(child: _actionCard(cs, 'NIN', nin.isEmpty ? '—' : nin, Icons.badge_rounded, onTap: nin.isEmpty ? null : () => _copy('NIN', nin))),
                      ],
                    ),

                    const SizedBox(height: 10),

                    Text('Performance', style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.88))),
                    const SizedBox(height: 8),

                    Row(
                      children: [
                        Expanded(child: _stat(cs, 'Completed', '$completed', Icons.check_circle_rounded)),
                        const SizedBox(width: 8),
                        Expanded(child: _stat(cs, 'Cancelled', '$cancelled', Icons.block_rounded)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _stat(cs, 'Incomplete', '$incomplete', Icons.timelapse_rounded)),
                        const SizedBox(width: 8),
                        Expanded(child: _stat(cs, 'Reviews', '$reviews', Icons.reviews_rounded)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _stat(cs, 'Total trips', '$totalTrips', Icons.verified_rounded),

                    const SizedBox(height: 12),

                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.receipt_long_rounded, color: cs.onSurface.withOpacity(0.60)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Trip price', style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.88))),
                                const SizedBox(height: 4),
                                Text(
                                  widget.tripDistanceKm > 0
                                      ? '$cur${_moneyFmt.format(perKm.round())}/km × ${widget.tripDistanceKm.toStringAsFixed(1)} km'
                                      : '$cur${_moneyFmt.format(perKm.round())}/km',
                                  style: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurface.withOpacity(0.65)),
                                ),
                              ],
                            ),
                          ),
                          Text('$cur${_moneyFmt.format(totalPrice.round())}',
                              style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.90))),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

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
                      onPressed: widget.onConfirm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      child: const Text('Confirm ride', style: TextStyle(fontWeight: FontWeight.w900)),
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

  // --- widgets

  Widget _pill(ColorScheme cs, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.04),
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

  Widget _chip(ColorScheme cs, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.04),
        borderRadius: BorderRadius.circular(999),
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
        child: Center(child: Text(initials, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.78)))),
      );
    }

    if (u.isEmpty) return fallback();

    return ClipOval(
      child: SizedBox(
        width: 54,
        height: 54,
        child: Image.network(
          u,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, __, ___) => fallback(),
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
                final u = imgs[i].trim();
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
                      child: Center(
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

  Widget _actionCard(ColorScheme cs, String title, String value, IconData icon, {VoidCallback? onTap}) {
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
                color: AppColors.primary.withOpacity(0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primary.withOpacity(0.18)),
              ),
              child: Icon(icon, color: AppColors.primary, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.70), fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.90))),
                ],
              ),
            ),
            if (onTap != null) Icon(Icons.copy_rounded, color: cs.onSurface.withOpacity(0.55), size: 18),
          ],
        ),
      ),
    );
  }

  Widget _stat(ColorScheme cs, String title, String v, IconData icon) {
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
              color: cs.onSurface.withOpacity(0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.onSurface.withOpacity(0.10)),
            ),
            child: Icon(icon, color: cs.onSurface.withOpacity(0.65), size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.70), fontSize: 12)),
                const SizedBox(height: 4),
                Text(v, style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.90), fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stars(ColorScheme cs, double rating) {
    final r = rating.clamp(0, 5);
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
        Text(r.toStringAsFixed(2), style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface.withOpacity(0.80), fontSize: 12)),
      ],
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
