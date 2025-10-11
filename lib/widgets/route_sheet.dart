import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../themes/app_theme.dart';
import '../screens/state/home_models.dart';

/// Premium, compact, responsive bottom sheet.
/// - Fixed height, orientation-aware
/// - CTA tap is always reliable (parent can refresh with [ctaKey])
/// - Portrait: list; Landscape/Foldables: smart grid
class RouteSheet extends StatefulWidget {
  /// Height of the app bottom navigation bar (used to pad sheet bottom)
  final double bottomNavHeight;

  /// Recent destinations to render
  final List<Suggestion> recentDestinations;

  /// Fired when user taps the CTA pill
  final VoidCallback onSearchTap;

  /// Fired when user taps a recent item
  final void Function(Suggestion) onRecentTap;

  /// Optional fresh key for the CTA button; parent can replace this key
  /// (e.g. after overlay closes) to guarantee a fresh gesture arena.
  final Key? ctaKey;

  /// Optional dynamic label for the CTA (e.g. "Set destination", "Add stop")
  final String? ctaLabel;

  /// Optional: show an auxiliary action in empty state (e.g. Use current location)
  final bool hasGps;
  final VoidCallback? onUseCurrentPickup;

  const RouteSheet({
    super.key,
    required this.bottomNavHeight,
    required this.recentDestinations,
    required this.onSearchTap,
    required this.onRecentTap,
    this.ctaKey,
    this.ctaLabel,
    this.hasGps = false,
    this.onUseCurrentPickup,
  });

  @override
  State<RouteSheet> createState() => _RouteSheetState();
}

class _RouteSheetState extends State<RouteSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  double _s(BuildContext c) {
    final sz = MediaQuery.of(c).size;
    final shortest = math.min(sz.width, sz.height);
    return (shortest / 390.0).clamp(0.75, 1.0);
  }

  bool _isLandscape(BuildContext c) =>
      MediaQuery.of(c).orientation == Orientation.landscape;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 280),
      vsync: this,
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final s = _s(context);
    final isLand = _isLandscape(context);
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Keyboard-aware & foldable-friendly sizing
    final kb = mq.viewInsets.bottom; // > 0 when keyboard visible
    final baseH = isLand
        ? (mq.size.height * 0.70).clamp(180.0, 380.0)
        : (mq.size.height * 0.40).clamp(240.0, 480.0);
    final h = (baseH - (kb > 0 ? 8.0 * s : 0.0)).clamp(180.0, 480.0);

    // Small hinge padding for foldables
    final hingePad = mq.displayFeatures.isEmpty ? EdgeInsets.zero : EdgeInsets.all(6 * s);

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: SizedBox(
          height: h,
          width: mq.size.width,
          child: ClipRRect(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20 * s)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16 * s, sigmaY: 16 * s),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: isDark ? bg.withOpacity(.95) : Colors.white.withOpacity(.97),
                  border: Border(
                    top: BorderSide(
                      color: AppColors.mintBgLight.withOpacity(.30),
                      width: 1,
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(isDark ? .25 : .10),
                      blurRadius: 24 * s,
                      offset: Offset(0, -8 * s),
                    ),
                  ],
                ),
                child: Padding(
                  // Map should handle its own padding; we keep sheet compact.
                  padding: EdgeInsets.fromLTRB(
                    16 * s,
                    12 * s,
                    16 * s,
                    widget.bottomNavHeight + mq.padding.bottom + 12,
                  ).add(hingePad),
                  child: isLand
                      ? _buildLandscape(s, context)
                      : _buildPortrait(s, context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPortrait(double s, BuildContext ctx) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: 12 * s),
          child: Text(
            'Street ride',
            style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
              fontSize: 14 * s,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
        ),
        _TapableTile(
          key: widget.ctaKey, // <— fresh key can be injected by parent
          s: s,
          label: widget.ctaLabel ?? 'Set destination',
          icon: Icons.search_rounded,
          onTap: widget.onSearchTap,
          badge: 'Now',
        ),
        SizedBox(height: 14 * s),
        Expanded(
          child: _RecentsList(
            s: s,
            items: widget.recentDestinations,
            onTap: widget.onRecentTap,
            isDark: Theme.of(ctx).brightness == Brightness.dark,
            emptyTrailing: (widget.hasGps && widget.onUseCurrentPickup != null)
                ? TextButton.icon(
              onPressed: widget.onUseCurrentPickup,
              icon: const Icon(Icons.my_location_rounded, size: 16),
              label: const Text('Use current location'),
            )
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildLandscape(double s, BuildContext ctx) {
    final w = MediaQuery.of(ctx).size.width;
    final crossAxisCount = (w / (220 * s)).clamp(2, 3).toInt();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 45,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.only(bottom: 10 * s),
                child: Text(
                  'Choose your\nadventure.',
                  style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                    fontSize: 13 * s,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.3,
                    height: 1.1,
                  ),
                ),
              ),
              _TapableTile(
                key: widget.ctaKey,
                s: s,
                label: widget.ctaLabel ?? 'Set destination',
                icon: Icons.search_rounded,
                onTap: widget.onSearchTap,
                badge: 'Now',
              ),
            ],
          ),
        ),
        SizedBox(width: 16 * s),
        Expanded(
          flex: 55,
          child: _RecentsGrid(
            s: s,
            items: widget.recentDestinations,
            onTap: widget.onRecentTap,
            isDark: Theme.of(ctx).brightness == Brightness.dark,
            crossAxisCount: crossAxisCount,
            emptyTrailing: (widget.hasGps && widget.onUseCurrentPickup != null)
                ? TextButton.icon(
              onPressed: widget.onUseCurrentPickup,
              icon: const Icon(Icons.my_location_rounded, size: 16),
              label: const Text('Use current location'),
            )
                : null,
          ),
        ),
      ],
    );
  }
}

class _TapableTile extends StatefulWidget {
  final double s;
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final String? badge;

  const _TapableTile({
    super.key,
    required this.s,
    required this.label,
    required this.icon,
    required this.onTap,
    this.badge,
  });

  @override
  State<_TapableTile> createState() => _TapableTileState();
}

class _TapableTileState extends State<_TapableTile> {
  bool _active = false;
  bool _isProcessing = false;

  void _press() {
    if (_isProcessing) return;
    _isProcessing = true;
    setState(() => _active = true);

    HapticFeedback.selectionClick();
    // Fire after this frame to avoid gesture reentrancy issues on overlays.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onTap());

    Future.delayed(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() => _active = false);
      _isProcessing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final h = math.max(44.0, 52 * widget.s);

    return Focus(
      canRequestFocus: true,
      child: Semantics(
        button: true,
        label: 'Search destination',
        child: Material(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16 * widget.s),
          child: InkWell(
            onTap: _press,
            borderRadius: BorderRadius.circular(16 * widget.s),
            child: AnimatedScale(
              scale: _active ? 0.96 : 1.0,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
              child: Container(
                height: h,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16 * widget.s),
                  border: Border.all(
                    color: AppColors.mintBgLight.withOpacity(0.2),
                    width: 1.2,
                  ),
                ),
                padding: EdgeInsets.symmetric(horizontal: 14 * widget.s),
                child: Row(
                  children: [
                    Icon(widget.icon, size: 20 * widget.s),
                    SizedBox(width: 10 * widget.s),
                    Expanded(
                      child: Text(
                        widget.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15 * widget.s,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                          color: AppColors.textPrimary.withOpacity(0.9),
                        ),
                      ),
                    ),
                    if (widget.badge != null)
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 7 * widget.s,
                          vertical: 3 * widget.s,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(5 * widget.s),
                        ),
                        child: Text(
                          widget.badge!,
                          style: TextStyle(
                            fontSize: 9 * widget.s,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Recents – List (portrait) & Grid (landscape)
// ─────────────────────────────────────────────────────────────────────────────

class _RecentsList extends StatelessWidget {
  final double s;
  final List<Suggestion> items;
  final void Function(Suggestion) onTap;
  final bool isDark;
  final Widget? emptyTrailing;

  const _RecentsList({
    required this.s,
    required this.items,
    required this.onTap,
    required this.isDark,
    this.emptyTrailing,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _Empty(s: s, trailing: emptyTrailing);
    }

    final cnt = math.min(items.length, 6);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _RecentsHeader(s: s, count: cnt),
        Expanded(
          child: RepaintBoundary(
            child: ListView.separated(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: cnt,
              separatorBuilder: (_, __) => SizedBox(height: 7 * s),
              itemBuilder: (_, i) => _RecentTile(
                key: ValueKey(items[i].placeId),
                s: s,
                item: items[i],
                isDark: isDark,
                onTap: () {
                  HapticFeedback.lightImpact();
                  onTap(items[i]);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RecentsGrid extends StatelessWidget {
  final double s;
  final int crossAxisCount;
  final List<Suggestion> items;
  final void Function(Suggestion) onTap;
  final bool isDark;
  final Widget? emptyTrailing;

  const _RecentsGrid({
    required this.s,
    required this.items,
    required this.onTap,
    required this.isDark,
    required this.crossAxisCount,
    this.emptyTrailing,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _Empty(s: s, trailing: emptyTrailing);
    }

    final cnt = math.min(items.length, 8);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _RecentsHeader(s: s, count: cnt),
        Expanded(
          child: RepaintBoundary(
            child: GridView.builder(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: cnt,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: 8 * s,
                mainAxisSpacing: 8 * s,
                childAspectRatio: 3.6,
              ),
              itemBuilder: (_, i) => _RecentTile(
                key: ValueKey(items[i].placeId),
                s: s,
                item: items[i],
                isDark: isDark,
                onTap: () {
                  HapticFeedback.lightImpact();
                  onTap(items[i]);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RecentsHeader extends StatelessWidget {
  final double s;
  final int count;

  const _RecentsHeader({required this.s, required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 2 * s, bottom: 10 * s),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(5 * s),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(6 * s),
            ),
            child: Icon(Icons.history_rounded, size: 12 * s, color: AppColors.primary),
          ),
          SizedBox(width: 8 * s),
          Text('Recent',
              style: TextStyle(
                  fontSize: 12 * s, fontWeight: FontWeight.w900, letterSpacing: -0.2)),
          const Spacer(),
          Text('$count',
              style: TextStyle(
                  fontSize: 11 * s, fontWeight: FontWeight.w800, color: AppColors.primary)),
        ],
      ),
    );
  }
}

class _RecentTile extends StatelessWidget {
  final double s;
  final Suggestion item;
  final bool isDark;
  final VoidCallback onTap;

  const _RecentTile({
    super.key,
    required this.s,
    required this.item,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Recent destination: ${item.mainText}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12 * s),
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 10 * s),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12 * s),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.08)
                    : AppColors.mintBgLight.withOpacity(0.2),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 32 * s,
                  height: 32 * s,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8 * s),
                    color: AppColors.mintBgLight.withOpacity(0.15),
                  ),
                  child: Icon(Icons.location_on_rounded,
                      size: 16 * s, color: AppColors.textPrimary),
                ),
                SizedBox(width: 11 * s),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.mainText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13 * s,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.1,
                        ),
                      ),
                      if (item.secondaryText.isNotEmpty) ...[
                        SizedBox(height: 2 * s),
                        Text(
                          item.secondaryText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11 * s,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textSecondary.withOpacity(0.7),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: 8 * s),
                Icon(Icons.chevron_right_rounded,
                    size: 16 * s, color: AppColors.textSecondary.withOpacity(0.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final double s;
  final Widget? trailing;

  const _Empty({required this.s, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24 * s),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: EdgeInsets.all(12 * s),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withOpacity(0.08),
              ),
              child: Icon(Icons.explore_off_rounded,
                  size: 24 * s, color: AppColors.primary.withOpacity(0.6)),
            ),
            SizedBox(height: 12 * s),
            Text('No Recent Trips',
                style: TextStyle(fontSize: 13 * s, fontWeight: FontWeight.w900)),
            SizedBox(height: 4 * s),
            Text(
              'Trips appear here',
              style: TextStyle(
                fontSize: 10 * s,
                color: AppColors.textSecondary.withOpacity(0.7),
              ),
            ),
            if (trailing != null) ...[
              SizedBox(height: 12 * s),
              trailing!,
            ]
          ],
        ),
      ),
    );
  }
}
