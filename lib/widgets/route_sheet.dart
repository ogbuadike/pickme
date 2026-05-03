// lib/widgets/route_sheet.dart
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../screens/state/home_models.dart';

/// Premium, ultra-compact, production-safe route sheet.
/// - Uses UIScale everywhere
/// - Accepts dynamic titles and subtitles for full reusability across ride modes.
/// - Dynamic Shrink-Wrap: Eliminates empty bottom gaps by shrinking to fit content.
/// - Micro mode for very short screens / landscape / foldables
class RouteSheet extends StatefulWidget {
  final double bottomNavHeight;
  final List<Suggestion> recentDestinations;
  final VoidCallback onSearchTap;
  final void Function(Suggestion) onRecentTap;
  final Key? ctaKey;
  final String? ctaLabel;
  final bool hasGps;
  final VoidCallback? onUseCurrentPickup;

  final String sheetTitle;
  final String? sheetSubtitle;

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
    this.sheetTitle = 'Where to?',
    this.sheetSubtitle,
  });

  @override
  State<RouteSheet> createState() => _RouteSheetState();
}

class _RouteSheetState extends State<RouteSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 240),
      vsync: this,
    );

    _fade = CurvedAnimation(
      parent: _ctrl,
      curve: Curves.easeOutCubic,
    );

    _slide = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Curves.easeOutCubic,
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // Gives the sheet a flexible maximum boundary, but it will shrink if content is small
  double _sheetMaxHeight(MediaQueryData mq, UIScale ui) {
    final keyboard = mq.viewInsets.bottom;
    final h = mq.size.height;

    double target = ui.landscape ? h * 0.85 : h * 0.70;
    if (keyboard > 0) target -= ui.gap(6);

    final extraPadding = widget.sheetSubtitle != null ? 15.0 : 0.0;
    return target.clamp(250.0 + extraPadding, h * 0.90);
  }

  EdgeInsets _hingePadding(MediaQueryData mq, UIScale ui) {
    if (mq.displayFeatures.isEmpty) return EdgeInsets.zero;
    return EdgeInsets.all(ui.gap(4));
  }

  // Clean, logical bottom inset that prevents artificial massive gaps
  double _reservedBottomInset(MediaQueryData mq, UIScale ui) {
    final base = math.max(widget.bottomNavHeight, mq.padding.bottom);
    return base + ui.gap(16); // 16px of comfortable breathing room
  }

  Widget _optionalGpsAction(bool isDark, ColorScheme cs) {
    if (!widget.hasGps || widget.onUseCurrentPickup == null) {
      return const SizedBox.shrink();
    }

    return TextButton.icon(
      onPressed: widget.onUseCurrentPickup,
      icon: Icon(Icons.my_location_rounded, size: 16, color: isDark ? cs.primary : AppColors.primary),
      label: Text('Use current location', style: TextStyle(color: isDark ? cs.primary : AppColors.primary)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: Size.zero,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final ui = UIScale.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final maxHeight = _sheetMaxHeight(mq, ui);
    final reservedBottom = _reservedBottomInset(mq, ui);

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Container(
          width: mq.size.width,
          // BoxConstraints instead of fixed SizedBox allows it to shrink to fit!
          constraints: BoxConstraints(
            maxHeight: maxHeight,
            minHeight: 120, // Prevents collapsing completely
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(ui.radius(ui.landscape ? 18 : 24)),
            ),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: ui.reduceFx ? 8 : 16,
                sigmaY: ui.reduceFx ? 8 : 16,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: isDark
                      ? cs.surface.withOpacity(0.95)
                      : Colors.white.withOpacity(0.97),
                  border: Border(
                    top: BorderSide(
                      color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.30),
                      width: 1,
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(isDark ? 0.40 : 0.10),
                      blurRadius: ui.reduceFx ? 12 : 22,
                      offset: const Offset(0, -8),
                    ),
                  ],
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    ui.inset(ui.tiny ? 12 : 16),
                    ui.inset(ui.tiny ? 10 : 12),
                    ui.inset(ui.tiny ? 12 : 16),
                    reservedBottom,
                  ).add(_hingePadding(mq, ui)),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final maxH = constraints.maxHeight;
                      final maxW = constraints.maxWidth;

                      final useMicro = maxH < 150;
                      final useSplitLandscape = !useMicro &&
                          ui.landscape &&
                          maxW >= 640 &&
                          maxH >= 190;

                      if (useMicro) {
                        return _MicroLayout(
                          ui: ui, theme: theme, cs: cs, isDark: isDark,
                          ctaKey: widget.ctaKey, ctaLabel: widget.ctaLabel ?? 'Set destination',
                          recentDestinations: widget.recentDestinations,
                          onSearchTap: widget.onSearchTap, onRecentTap: widget.onRecentTap,
                          gpsAction: _optionalGpsAction(isDark, cs),
                        );
                      }

                      if (useSplitLandscape) {
                        return _LandscapeLayout(
                          ui: ui, theme: theme, cs: cs, isDark: isDark,
                          ctaKey: widget.ctaKey, ctaLabel: widget.ctaLabel ?? 'Set destination',
                          recentDestinations: widget.recentDestinations,
                          onSearchTap: widget.onSearchTap, onRecentTap: widget.onRecentTap,
                          gpsAction: _optionalGpsAction(isDark, cs),
                          sheetTitle: widget.sheetTitle, sheetSubtitle: widget.sheetSubtitle,
                        );
                      }

                      return _PortraitLayout(
                        ui: ui, theme: theme, cs: cs, isDark: isDark,
                        compact: maxH < 210,
                        ctaKey: widget.ctaKey, ctaLabel: widget.ctaLabel ?? 'Set destination',
                        recentDestinations: widget.recentDestinations,
                        onSearchTap: widget.onSearchTap, onRecentTap: widget.onRecentTap,
                        gpsAction: _optionalGpsAction(isDark, cs),
                        sheetTitle: widget.sheetTitle, sheetSubtitle: widget.sheetSubtitle,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PortraitLayout extends StatelessWidget {
  final UIScale ui;
  final ThemeData theme;
  final ColorScheme cs;
  final bool isDark;
  final bool compact;
  final Key? ctaKey;
  final String ctaLabel;
  final List<Suggestion> recentDestinations;
  final VoidCallback onSearchTap;
  final void Function(Suggestion) onRecentTap;
  final Widget gpsAction;
  final String sheetTitle;
  final String? sheetSubtitle;

  const _PortraitLayout({
    required this.ui, required this.theme, required this.cs,
    required this.isDark, required this.compact, required this.ctaKey,
    required this.ctaLabel, required this.recentDestinations,
    required this.onSearchTap, required this.onRecentTap,
    required this.gpsAction, required this.sheetTitle, this.sheetSubtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min, // Allows shrink-wrapping to eliminate empty gaps!
      children: [
        _SheetHandle(ui: ui, isDark: isDark, cs: cs),
        SizedBox(height: ui.gap(compact ? 6 : 8)),
        Align(
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sheetTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontSize: ui.font(compact ? 13.5 : 15.0), // Plumped up
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.25,
                  color: isDark ? cs.onSurface : AppColors.textPrimary,
                ),
              ),
              if (sheetSubtitle != null) ...[
                SizedBox(height: ui.gap(2)),
                Text(
                  sheetSubtitle!,
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: ui.font(11.5),
                    fontWeight: FontWeight.w600,
                    color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        SizedBox(height: ui.gap(compact ? 10 : 14)),
        _TapableTile(
          key: ctaKey, ui: ui, label: ctaLabel, icon: Icons.search_rounded,
          badge: 'Now', onTap: onSearchTap, isDark: isDark, cs: cs,
        ),
        SizedBox(height: ui.gap(compact ? 10 : 14)),

        // Flexible instead of Expanded allows the Column to shrink if items are few
        Flexible(
          child: _RecentsList(
            ui: ui, items: recentDestinations, onTap: onRecentTap,
            isDark: isDark, cs: cs, emptyTrailing: gpsAction,
          ),
        ),
      ],
    );
  }
}

class _LandscapeLayout extends StatelessWidget {
  final UIScale ui;
  final ThemeData theme;
  final ColorScheme cs;
  final bool isDark;
  final Key? ctaKey;
  final String ctaLabel;
  final List<Suggestion> recentDestinations;
  final VoidCallback onSearchTap;
  final void Function(Suggestion) onRecentTap;
  final Widget gpsAction;
  final String sheetTitle;
  final String? sheetSubtitle;

  const _LandscapeLayout({
    required this.ui, required this.theme, required this.cs, required this.isDark,
    required this.ctaKey, required this.ctaLabel, required this.recentDestinations,
    required this.onSearchTap, required this.onRecentTap, required this.gpsAction,
    required this.sheetTitle, this.sheetSubtitle,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final int crossAxisCount = width >= 1100 ? 3 : 2;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SheetHandle(ui: ui, isDark: isDark, cs: cs),
        SizedBox(height: ui.gap(6)),
        Flexible(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 42,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sheetTitle,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: ui.font(14),
                        fontWeight: FontWeight.w900,
                        color: isDark ? cs.onSurface : AppColors.textPrimary,
                      ),
                    ),
                    if (sheetSubtitle != null) ...[
                      SizedBox(height: ui.gap(2)),
                      Text(
                        sheetSubtitle!,
                        style: TextStyle(
                          fontSize: ui.font(11.5),
                          fontWeight: FontWeight.w600,
                          color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                        ),
                      ),
                    ],
                    SizedBox(height: ui.gap(12)),
                    _TapableTile(
                      key: ctaKey, ui: ui, label: ctaLabel, icon: Icons.search_rounded,
                      badge: 'Now', onTap: onSearchTap, isDark: isDark, cs: cs,
                    ),
                  ],
                ),
              ),
              SizedBox(width: ui.gap(16)),
              Expanded(
                flex: 58,
                child: _RecentsGrid(
                  ui: ui, items: recentDestinations, onTap: onRecentTap,
                  isDark: isDark, cs: cs, crossAxisCount: crossAxisCount, emptyTrailing: gpsAction,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MicroLayout extends StatelessWidget {
  final UIScale ui;
  final ThemeData theme;
  final ColorScheme cs;
  final bool isDark;
  final Key? ctaKey;
  final String ctaLabel;
  final List<Suggestion> recentDestinations;
  final VoidCallback onSearchTap;
  final void Function(Suggestion) onRecentTap;
  final Widget gpsAction;

  const _MicroLayout({
    required this.ui, required this.theme, required this.cs, required this.isDark,
    required this.ctaKey, required this.ctaLabel, required this.recentDestinations,
    required this.onSearchTap, required this.onRecentTap, required this.gpsAction,
  });

  @override
  Widget build(BuildContext context) {
    final showGpsAction = gpsAction is! SizedBox;

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      children: [
        _SheetHandle(ui: ui, isDark: isDark, cs: cs),
        SizedBox(height: ui.gap(6)),
        _TapableTile(
          key: ctaKey, ui: ui, label: ctaLabel, icon: Icons.search_rounded,
          badge: 'Now', onTap: onSearchTap, isDark: isDark, cs: cs,
        ),
        SizedBox(height: ui.gap(10)),
        if (recentDestinations.isNotEmpty) ...[
          _RecentsHeader(ui: ui, count: math.min(recentDestinations.length, 6), isDark: isDark, cs: cs),
          SizedBox(
            height: ui.landscape ? ui.gap(46) : ui.gap(56),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: math.min(recentDestinations.length, 6),
              separatorBuilder: (_, __) => SizedBox(width: ui.gap(8)),
              itemBuilder: (_, i) {
                final item = recentDestinations[i];
                return SizedBox(
                  width: math.max(160, MediaQuery.of(context).size.width * 0.46),
                  child: _MicroRecentTile(
                    ui: ui, item: item, isDark: isDark, cs: cs,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      onRecentTap(item);
                    },
                  ),
                );
              },
            ),
          ),
        ] else ...[
          if (showGpsAction) gpsAction,
        ],
      ],
    );
  }
}

class _SheetHandle extends StatelessWidget {
  final UIScale ui;
  final bool isDark;
  final ColorScheme cs;

  const _SheetHandle({required this.ui, required this.isDark, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: ui.landscape ? 44 : 50,
        height: 4,
        decoration: BoxDecoration(
          color: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : AppColors.textSecondary.withOpacity(0.22),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

class _TapableTile extends StatefulWidget {
  final UIScale ui;
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final String? badge;
  final bool isDark;
  final ColorScheme cs;

  const _TapableTile({
    super.key, required this.ui, required this.label, required this.icon,
    required this.onTap, required this.isDark, required this.cs, this.badge,
  });

  @override
  State<_TapableTile> createState() => _TapableTileState();
}

class _TapableTileState extends State<_TapableTile> {
  bool _pressed = false;
  bool _busy = false;

  Future<void> _handleTap() async {
    if (_busy) return;
    _busy = true;
    if (mounted) setState(() => _pressed = true);

    HapticFeedback.selectionClick();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onTap());

    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (mounted) setState(() => _pressed = false);
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    final ui = widget.ui;
    final isDark = widget.isDark;
    final cs = widget.cs;
    final height = math.max(48.0, ui.landscape ? ui.gap(46) : ui.gap(54));

    return Semantics(
      button: true,
      label: widget.label,
      child: Material(
        color: isDark ? cs.surfaceVariant.withOpacity(0.5) : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(ui.radius(16)),
        child: InkWell(
          borderRadius: BorderRadius.circular(ui.radius(16)),
          onTap: _handleTap,
          child: AnimatedScale(
            scale: _pressed ? 0.97 : 1.0,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: Container(
              height: height,
              padding: EdgeInsets.symmetric(horizontal: ui.inset(14)),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(ui.radius(16)),
                border: Border.all(
                  color: isDark ? cs.outline : AppColors.mintBgLight.withOpacity(0.35),
                  width: 1.0,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.icon,
                    size: ui.icon(20),
                    color: isDark ? cs.primary : AppColors.textPrimary.withOpacity(0.92),
                  ),
                  SizedBox(width: ui.gap(10)),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: ui.font(14.5),
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.15,
                        color: isDark ? cs.onSurface : AppColors.textPrimary.withOpacity(0.92),
                      ),
                    ),
                  ),
                  if (widget.badge != null) ...[
                    SizedBox(width: ui.gap(6)),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: ui.inset(8),
                        vertical: ui.inset(4),
                      ),
                      decoration: BoxDecoration(
                        color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(ui.radius(6)),
                      ),
                      child: Text(
                        widget.badge!,
                        style: TextStyle(
                          fontSize: ui.font(9.5),
                          fontWeight: FontWeight.w900,
                          color: isDark ? cs.primary : AppColors.primary,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentsList extends StatelessWidget {
  final UIScale ui;
  final List<Suggestion> items;
  final void Function(Suggestion) onTap;
  final bool isDark;
  final ColorScheme cs;
  final Widget emptyTrailing;

  const _RecentsList({
    required this.ui, required this.items, required this.onTap,
    required this.isDark, required this.cs, required this.emptyTrailing,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _Empty(ui: ui, isDark: isDark, cs: cs, trailing: emptyTrailing);
    }

    final count = math.min(items.length, 6);

    return Column(
      mainAxisSize: MainAxisSize.min, // Allows shrink wrap!
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _RecentsHeader(ui: ui, count: count, isDark: isDark, cs: cs),
        Flexible(
          child: RepaintBoundary(
            child: ListView.separated(
              shrinkWrap: true, // Crucial for stopping massive gaps
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: count,
              separatorBuilder: (_, __) => SizedBox(height: ui.gap(8)),
              itemBuilder: (_, i) {
                final item = items[i];
                return _RecentTile(
                  key: ValueKey(item.placeId),
                  ui: ui, item: item, isDark: isDark, cs: cs,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onTap(item);
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _RecentsGrid extends StatelessWidget {
  final UIScale ui;
  final int crossAxisCount;
  final List<Suggestion> items;
  final void Function(Suggestion) onTap;
  final bool isDark;
  final ColorScheme cs;
  final Widget emptyTrailing;

  const _RecentsGrid({
    required this.ui, required this.items, required this.onTap,
    required this.isDark, required this.cs, required this.crossAxisCount,
    required this.emptyTrailing,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _Empty(ui: ui, isDark: isDark, cs: cs, trailing: emptyTrailing);
    }

    final count = math.min(items.length, 8);

    return Column(
      mainAxisSize: MainAxisSize.min, // Allows shrink wrap!
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _RecentsHeader(ui: ui, count: count, isDark: isDark, cs: cs),
        Flexible(
          child: RepaintBoundary(
            child: GridView.builder(
              shrinkWrap: true, // Crucial for stopping massive gaps
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: count,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: ui.gap(8),
                mainAxisSpacing: ui.gap(8),
                childAspectRatio: ui.tiny ? 3.0 : 3.4,
              ),
              itemBuilder: (_, i) {
                final item = items[i];
                return _RecentTile(
                  key: ValueKey(item.placeId),
                  ui: ui, item: item, isDark: isDark, cs: cs,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onTap(item);
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _RecentsHeader extends StatelessWidget {
  final UIScale ui;
  final int count;
  final bool isDark;
  final ColorScheme cs;

  const _RecentsHeader({
    required this.ui, required this.count, required this.isDark, required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: ui.gap(2), bottom: ui.gap(10)),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(ui.gap(5)),
            decoration: BoxDecoration(
              color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.15),
              borderRadius: BorderRadius.circular(ui.radius(8)),
            ),
            child: Icon(
              Icons.history_rounded,
              size: ui.icon(14),
              color: isDark ? cs.primary : AppColors.primary,
            ),
          ),
          SizedBox(width: ui.gap(8)),
          Expanded(
            child: Text(
              'Recent Destinations',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: ui.font(12.5),
                fontWeight: FontWeight.w900,
                letterSpacing: -0.2,
                color: isDark ? cs.onSurface : AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── PLUMP, BREATHABLE RECENT TILE ──────────────────────────────────────────
class _RecentTile extends StatelessWidget {
  final UIScale ui;
  final Suggestion item;
  final bool isDark;
  final ColorScheme cs;
  final VoidCallback onTap;

  const _RecentTile({
    super.key, required this.ui, required this.item, required this.isDark,
    required this.cs, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasSecondary = item.secondaryText.isNotEmpty;

    return Semantics(
      button: true,
      label: 'Recent destination: ${item.mainText}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ui.radius(14)),
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(
              minHeight: ui.landscape ? 48 : 56, // Increased min height
            ),
            padding: EdgeInsets.symmetric(
              horizontal: ui.inset(12), // Increased padding
              vertical: ui.inset(12),
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(ui.radius(14)),
              border: Border.all(
                color: isDark ? cs.outline : AppColors.mintBgLight.withOpacity(0.28),
                width: 1.2,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: ui.gap(38), // Larger icon background
                  height: ui.gap(38),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(ui.radius(10)),
                    color: isDark ? cs.surfaceVariant : AppColors.mintBgLight.withOpacity(0.15),
                  ),
                  child: Icon(
                    Icons.location_on_rounded,
                    size: ui.icon(18), // Larger icon
                    color: isDark ? cs.primary : AppColors.textPrimary,
                  ),
                ),
                SizedBox(width: ui.gap(12)), // Better spacing
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
                          fontSize: ui.font(13.5), // Larger font
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.1,
                          color: isDark ? cs.onSurface : AppColors.textPrimary,
                        ),
                      ),
                      if (hasSecondary) ...[
                        SizedBox(height: ui.gap(2.5)),
                        Text(
                          item.secondaryText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: ui.font(11.5), // Larger secondary font
                            fontWeight: FontWeight.w600,
                            color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(0.80),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: ui.gap(6)),
                Icon(
                  Icons.chevron_right_rounded,
                  size: ui.icon(18),
                  color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(0.52),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MicroRecentTile extends StatelessWidget {
  final UIScale ui;
  final Suggestion item;
  final bool isDark;
  final ColorScheme cs;
  final VoidCallback onTap;

  const _MicroRecentTile({
    super.key, required this.ui, required this.item, required this.isDark,
    required this.cs, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isDark ? cs.surface : Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(ui.radius(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(ui.radius(12)),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: ui.inset(12),
            vertical: ui.inset(10),
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ui.radius(12)),
            border: Border.all(
              color: isDark ? cs.outline : AppColors.mintBgLight.withOpacity(0.20),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.history_rounded,
                size: ui.icon(16),
                color: isDark ? cs.primary : AppColors.primary,
              ),
              SizedBox(width: ui.gap(8)),
              Expanded(
                child: Text(
                  item.mainText.isNotEmpty ? item.mainText : item.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ui.font(12.5),
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.1,
                    color: isDark ? cs.onSurface : AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final UIScale ui;
  final bool isDark;
  final ColorScheme cs;
  final Widget trailing;

  const _Empty({
    required this.ui, required this.isDark, required this.cs, required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final hasTrailing = trailing is! SizedBox;

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: ui.inset(20), vertical: ui.inset(16)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.all(ui.inset(12)),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.12),
              ),
              child: Icon(
                Icons.explore_off_rounded,
                size: ui.icon(28),
                color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.90),
              ),
            ),
            SizedBox(height: ui.gap(12)),
            Text(
              'No Recent Trips',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: ui.font(13.5),
                fontWeight: FontWeight.w900,
                color: isDark ? cs.onSurface : AppColors.textPrimary,
              ),
            ),
            SizedBox(height: ui.gap(4)),
            Text(
              'Your destination history will appear here once you start riding.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: ui.font(11.5),
                height: 1.4,
                color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(0.80),
              ),
            ),
            if (hasTrailing) ...[
              SizedBox(height: ui.gap(16)),
              trailing,
            ],
          ],
        ),
      ),
    );
  }
}