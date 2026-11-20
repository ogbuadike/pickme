// lib/widgets/ride_market/driver_card.dart
//
// One row of the ride market list. Stateless + keyed by driver id so a poll
// tick only rebuilds rows whose data actually changed.
import 'package:flutter/material.dart';

import '../../themes/app_theme.dart';
import '../../ui/ui_scale.dart';
import 'ride_nearby_driver.dart';

IconData rankIconOf(String r) {
  final String x = r.trim().toLowerCase();
  if (x.contains('platinum') || x.contains('diamond')) return Icons.workspace_premium_rounded;
  if (x.contains('gold')) return Icons.emoji_events_rounded;
  if (x.contains('silver')) return Icons.military_tech_rounded;
  if (x.contains('bronze')) return Icons.military_tech_outlined;
  return Icons.verified_rounded;
}

Color rankColorOf(String r, bool isDark, ColorScheme cs) {
  final String x = r.trim().toLowerCase();
  if (x.contains('platinum') || x.contains('diamond')) return const Color(0xFF6A5ACD);
  if (x.contains('gold')) return const Color(0xFFB8860B);
  if (x.contains('silver')) return const Color(0xFF607D8B);
  if (x.contains('bronze')) return const Color(0xFF8D6E63);
  return isDark ? cs.primary : const Color(0xFF1E8E3E);
}

String _fmtDistShort(double km) {
  if (km <= 0) return 'Near';
  if (km < 1) return '${(km * 1000).round()}m';
  return '${km.toStringAsFixed(1)}km';
}

class DriverCard extends StatelessWidget {
  final RideNearbyDriver driver;
  final bool selected;
  final bool unavailable;
  final String totalText;
  final VoidCallback? onTap;

  const DriverCard({
    super.key,
    required this.driver,
    required this.selected,
    required this.totalText,
    this.unavailable = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final UIScale ui = UIScale.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool isDark = theme.brightness == Brightness.dark;
    final Color primary = isDark ? cs.primary : AppColors.primary;

    final RideNearbyDriver d = driver;
    final String rankText = d.rankLabel;
    final String vt = d.vehicleType.trim().isEmpty ? 'car' : d.vehicleType.trim();
    final int seats = vehicleClassOf(vt) == VehicleClass.bike ? 1 : (d.seats <= 0 ? 4 : d.seats);
    final String etaText = d.etaMin <= 0 ? '1m' : '${d.etaMin}m';
    final String img = d.imagesEffective.isNotEmpty ? d.imagesEffective.first : '';
    final Color textColor = isDark ? cs.onSurface : AppColors.textPrimary;

    final Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.symmetric(horizontal: ui.inset(10), vertical: ui.inset(8)),
      decoration: BoxDecoration(
        color: selected
            ? (isDark ? cs.primary.withValues(alpha: 0.11) : AppColors.primary.withValues(alpha: 0.055))
            : (isDark ? cs.surfaceContainerHighest.withValues(alpha: 0.28) : Colors.white),
        borderRadius: BorderRadius.circular(ui.radius(13)),
        border: Border.all(
          color: selected
              ? primary
              : (isDark ? cs.outline.withValues(alpha: 0.28) : AppColors.mintBgLight.withValues(alpha: 0.55)),
          width: selected ? 1.5 : 1.0,
        ),
        boxShadow: selected
            ? <BoxShadow>[BoxShadow(color: primary.withValues(alpha: 0.14), blurRadius: 10, offset: const Offset(0, 4))]
            : null,
      ),
      child: Row(
        children: <Widget>[
          _AvatarWithRank(
            url: d.avatarUrl,
            initials: d.initials,
            rank: rankText,
            size: 30,
            selected: selected,
          ),
          SizedBox(width: ui.gap(8)),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        d.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: textColor,
                          fontSize: ui.font(12.5),
                          height: 1.0,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    SizedBox(width: ui.gap(4)),
                    _RatingPill(rating: d.rating),
                  ],
                ),
                SizedBox(height: ui.gap(5)),
                SizedBox(
                  height: 18,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.zero,
                    children: <Widget>[
                      _Chip(icon: vehicleIconOf(vt), text: vehicleLabelOf(vt), tone: primary),
                      SizedBox(width: ui.gap(4)),
                      _Chip(
                        icon: Icons.airline_seat_recline_normal_rounded,
                        text: '$seats',
                        tone: const Color(0xFF1A73E8),
                      ),
                      SizedBox(width: ui.gap(4)),
                      _Chip(icon: Icons.av_timer_rounded, text: etaText, tone: const Color(0xFFB8860B)),
                      SizedBox(width: ui.gap(4)),
                      _Chip(
                        icon: Icons.route_rounded,
                        text: _fmtDistShort(d.distanceKm),
                        tone: isDark ? cs.primary : const Color(0xFF1E8E3E),
                      ),
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
            children: <Widget>[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _VehicleThumb(url: img, vehicleType: vt, size: 28),
                  if (selected) ...<Widget>[
                    SizedBox(width: ui.gap(4)),
                    Icon(Icons.check_circle_rounded, size: ui.icon(13), color: primary),
                  ],
                ],
              ),
              SizedBox(height: ui.gap(4)),
              Text(
                unavailable ? 'Unavailable' : totalText,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: unavailable ? cs.error : textColor,
                  fontSize: ui.font(unavailable ? 10 : 13),
                  height: 1.0,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      selected: selected,
      label: '${d.name}, ${vehicleLabelOf(vt)}, $etaText away, $totalText',
      child: Opacity(
        opacity: unavailable ? 0.55 : 1.0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: unavailable ? null : onTap,
            borderRadius: BorderRadius.circular(ui.radius(13)),
            child: card,
          ),
        ),
      ),
    );
  }
}

class _AvatarWithRank extends StatelessWidget {
  final String url;
  final String initials;
  final String rank;
  final double size;
  final bool selected;

  const _AvatarWithRank({
    required this.url,
    required this.initials,
    required this.rank,
    required this.size,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final UIScale ui = UIScale.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool isDark = theme.brightness == Brightness.dark;
    final Color borderColor =
        selected ? (isDark ? cs.primary : AppColors.primary) : (isDark ? cs.outline.withValues(alpha: 0.35) : Colors.black12);
    final Color bg = isDark ? cs.surfaceContainerHighest : AppColors.mintBgLight.withValues(alpha: 0.5);
    final int cachePx = (size * MediaQuery.devicePixelRatioOf(context)).round();

    final Widget fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bg,
        border: Border.all(color: borderColor, width: selected ? 1.5 : 1.0),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          fontWeight: FontWeight.w900,
          color: isDark ? cs.onSurface : AppColors.textPrimary,
          fontSize: ui.font(10),
        ),
      ),
    );

    final Widget avatar = url.isEmpty
        ? fallback
        : ClipOval(
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(color: bg, border: Border.all(color: borderColor, width: selected ? 1.5 : 1.0)),
              child: Image.network(
                url,
                fit: BoxFit.cover,
                cacheWidth: cachePx,
                cacheHeight: cachePx,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => fallback,
              ),
            ),
          );

    return SizedBox(
      width: size + 2,
      height: size + 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(child: avatar),
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: EdgeInsets.all(ui.inset(2)),
              decoration: BoxDecoration(
                color: isDark ? cs.surface : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: isDark ? cs.outline : Colors.black12),
              ),
              child: Icon(rankIconOf(rank), size: ui.icon(7.5), color: rankColorOf(rank, isDark, cs)),
            ),
          ),
        ],
      ),
    );
  }
}

class _VehicleThumb extends StatelessWidget {
  final String url;
  final String vehicleType;
  final double size;

  const _VehicleThumb({required this.url, required this.vehicleType, required this.size});

  @override
  Widget build(BuildContext context) {
    final UIScale ui = UIScale.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool isDark = theme.brightness == Brightness.dark;
    final int cachePx = (size * MediaQuery.devicePixelRatioOf(context)).round();

    final Widget fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceContainerHighest : AppColors.mintBgLight.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(ui.radius(7)),
        border: Border.all(color: isDark ? cs.outline.withValues(alpha: 0.35) : Colors.black12),
      ),
      alignment: Alignment.center,
      child: Icon(
        vehicleIconOf(vehicleType),
        color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withValues(alpha: 0.6),
        size: ui.icon(12),
      ),
    );
    if (url.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(ui.radius(7)),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          cacheWidth: cachePx,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => fallback,
        ),
      ),
    );
  }
}

class _RatingPill extends StatelessWidget {
  final double rating;
  const _RatingPill({required this.rating});

  @override
  Widget build(BuildContext context) {
    final UIScale ui = UIScale.of(context);
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final double r = (rating.isFinite ? rating : 0).clamp(0, 5).toDouble();
    return Container(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(5), vertical: ui.inset(2.5)),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: const Color(0xFFFFD54F).withValues(alpha: 0.14),
        border: Border.all(color: const Color(0xFFFFD54F).withValues(alpha: 0.38)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.star_rounded, size: ui.icon(9.0), color: const Color(0xFFFFC107)),
          SizedBox(width: ui.gap(2)),
          Text(
            r <= 0 ? 'New' : r.toStringAsFixed(1),
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: isDark ? Colors.white : AppColors.textPrimary.withValues(alpha: 0.9),
              fontSize: ui.font(8.5),
              height: 1.0,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color tone;

  const _Chip({required this.icon, required this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    final UIScale ui = UIScale.of(context);
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(5.5), vertical: ui.inset(2)),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: isDark ? 0.14 : 0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withValues(alpha: isDark ? 0.38 : 0.14), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: ui.icon(8.5), color: tone),
          SizedBox(width: ui.gap(3)),
          Text(
            text,
            maxLines: 1,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: isDark ? theme.colorScheme.onSurface : AppColors.textPrimary,
              fontSize: ui.font(8.5),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}
