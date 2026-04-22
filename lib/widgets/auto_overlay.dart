// lib/widgets/auto_overlay.dart
// Full-screen autocomplete overlay — tuned to avoid jank while typing.

import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../themes/app_theme.dart';
import '../services/perf_profile.dart';
import '../screens/state/home_models.dart';
import 'route_editor.dart';
import 'suggestion_list.dart';

class AutoOverlay extends StatefulWidget {
  final double safeTop;
  final double bottomPadding;

  final String? autoStatus;
  final String? autoError;
  final bool isTyping;

  final int activeIndex;
  final List<RoutePoint> points;
  final List<Suggestion> suggestions;
  final List<Suggestion> recents;

  final bool hasGps;
  final VoidCallback onUseCurrentPickup;

  final ValueChanged<String> onTyping;
  final ValueChanged<int> onFocused;
  final void Function(Suggestion s) onSelectSuggestion;

  final VoidCallback onAddStop;
  final void Function(int idx) onRemoveStop;

  final VoidCallback? onClose;
  final VoidCallback? onSwap;

  final String Function(int meters) fmtDistance;

  const AutoOverlay({
    super.key,
    required this.safeTop,
    required this.bottomPadding,
    required this.autoStatus,
    required this.autoError,
    required this.isTyping,
    required this.activeIndex,
    required this.points,
    required this.suggestions,
    required this.recents,
    required this.hasGps,
    required this.onUseCurrentPickup,
    required this.onTyping,
    required this.onFocused,
    required this.onSelectSuggestion,
    required this.fmtDistance,
    required this.onAddStop,
    required this.onRemoveStop,
    this.onClose,
    this.onSwap,
  });

  @override
  State<AutoOverlay> createState() => _AutoOverlayState();
}

class _AutoOverlayState extends State<AutoOverlay>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _mainCtl;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  late final Animation<Offset> _slide;

  bool _closing = false;
  bool _swapPressed = false;

  double _s(BuildContext c) {
    final sz = MediaQuery.of(c).size;
    final d = math.min(sz.width, sz.height);
    return (d / 390.0).clamp(0.75, 1.0);
  }

  bool _isLandscape(BuildContext c) =>
      MediaQuery.of(c).orientation == Orientation.landscape;

  @override
  void initState() {
    super.initState();
    // Tighten budgets globally while overlay is in front (less battery, no jank)
    Perf.I.setOverlayOpen(true);

    _mainCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );

    _fade = CurvedAnimation(parent: _mainCtl, curve: Curves.easeOutCubic);
    _scale = Tween<double>(begin: 0.985, end: 1.0)
        .animate(CurvedAnimation(parent: _mainCtl, curve: Curves.easeOut));
    _slide = Tween<Offset>(begin: const Offset(0, -0.01), end: Offset.zero)
        .animate(CurvedAnimation(parent: _mainCtl, curve: Curves.easeOutCubic));

    _mainCtl.forward();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _mainCtl.dispose();
    WidgetsBinding.instance.removeObserver(this);
    // Restore budgets
    Perf.I.setOverlayOpen(false);
    super.dispose();
  }

  @override
  Future<bool> didPopRoute() async {
    await _handleClose();
    return true;
  }

  Future<void> _handleClose() async {
    if (_closing) return;
    setState(() => _closing = true);
    HapticFeedback.lightImpact();

    await _mainCtl.reverse();
    if (!mounted) return;

    FocusManager.instance.primaryFocus?.unfocus();
    await Future.delayed(const Duration(milliseconds: 20));
    widget.onClose?.call();
  }

  Future<void> _handleSwap() async {
    if (_swapPressed) return;
    setState(() => _swapPressed = true);
    HapticFeedback.selectionClick();

    if (widget.onSwap != null) {
      widget.onSwap!.call();
    } else {
      _performLocalSwap();
    }
    await Future.delayed(const Duration(milliseconds: 100));
    if (mounted) setState(() => _swapPressed = false);
  }

  void _performLocalSwap() {
    if (widget.points.length < 2) return;
    final a = widget.points.first;
    final b = widget.points.last;

    final latLng = a.latLng;
    final placeId = a.placeId;
    final text = a.controller.text;
    final cur = a.isCurrent;

    a
      ..latLng = b.latLng
      ..placeId = b.placeId
      ..controller.text = b.controller.text
      ..isCurrent = false;

    b
      ..latLng = latLng
      ..placeId = placeId
      ..controller.text = text
      ..isCurrent = cur;

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final cs = Theme.of(context).colorScheme;

    // NB: We intentionally avoid BackdropFilter blur here (it can be expensive
    // on low-end GPUs). The gradient gives depth without cost.
    final content = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [bg.withOpacity(.99), bg.withOpacity(.98), bg.withOpacity(.97)]
              : [bg.withOpacity(.995), bg.withOpacity(.985), bg.withOpacity(.975)],
        ),
      ),
      child: ScaleTransition(
        scale: _scale,
        child: SlideTransition(
          position: _slide,
          child: _buildContent(context, isDark, cs),
        ),
      ),
    );

    return SizedBox.expand(
      child: FadeTransition(
        opacity: _fade,
        child: content,
      ),
    );
  }

  Widget _buildContent(BuildContext context, bool isDark, ColorScheme cs) {
    return SafeArea(
      child: _isLandscape(context)
          ? _buildLandscapeLayout(isDark, cs)
          : _buildPortraitLayout(isDark, cs),
    );
  }

  Widget _buildPortraitLayout(bool isDark, ColorScheme cs) {
    final s = _s(context);

    return Column(
      children: [
        _buildPremiumHeader(context, isDark, cs),
        Expanded(
          child: RepaintBoundary(
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16 * s, 0, 16 * s, 8 * s),
                  sliver: SliverToBoxAdapter(child: _buildRouteCard(context, isDark, cs)),
                ),
                if (widget.autoStatus != null && widget.autoStatus != 'OK')
                  SliverPadding(
                    padding: EdgeInsets.only(left: 16 * s, right: 16 * s, top: 8 * s),
                    sliver: SliverToBoxAdapter(child: _buildStatusBanner(isDark, cs)),
                  ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: 16 * s),
                  sliver: SliverToBoxAdapter(child: _buildDivider(isDark, cs)),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(12 * s, 0, 12 * s, widget.bottomPadding + 10),
                  sliver: SliverToBoxAdapter(child: _buildSuggestions(isDark, cs)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLandscapeLayout(bool isDark, ColorScheme cs) {
    final s = _s(context);
    return Column(
      children: [
        _buildPremiumHeader(context, isDark, cs),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 45,
                child: RepaintBoundary(
                  child: CustomScrollView(
                    physics: const BouncingScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(16 * s, 8 * s, 16 * s, 12 * s),
                        sliver: SliverToBoxAdapter(child: _buildRouteCard(context, isDark, cs)),
                      ),
                      if (widget.autoStatus != null && widget.autoStatus != 'OK')
                        const SliverToBoxAdapter(child: SizedBox(height: 6)),
                      if (widget.autoStatus != null && widget.autoStatus != 'OK')
                        SliverPadding(
                          padding: EdgeInsets.symmetric(horizontal: 16 * s),
                          sliver: SliverToBoxAdapter(child: _buildStatusBanner(isDark, cs)),
                        ),
                    ],
                  ),
                ),
              ),
              Container(width: 1, color: isDark ? cs.outline : AppColors.mintBgLight.withOpacity(.2)),
              Expanded(
                flex: 55,
                child: RepaintBoundary(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12 * s),
                    child: _buildSuggestions(isDark, cs),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPremiumHeader(BuildContext context, bool isDark, ColorScheme cs) {
    final t = Theme.of(context).textTheme;
    final s = _s(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(16 * s, 12 * s, 16 * s, 10 * s),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'Close search overlay',
            child: Material(
              color: (isDark ? cs.primary : AppColors.primary).withOpacity(.12),
              borderRadius: BorderRadius.circular(14 * s),
              child: InkWell(
                onTap: _handleClose,
                borderRadius: BorderRadius.circular(14 * s),
                splashColor: (isDark ? cs.primary : AppColors.primary).withOpacity(.2),
                child: Container(
                  width: 44 * s,
                  height: 44 * s,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14 * s),
                    border: Border.all(
                      color: (isDark ? cs.primary : AppColors.primary).withOpacity(.2),
                      width: 1.2,
                    ),
                  ),
                  child: Icon(Icons.close_rounded, color: isDark ? cs.primary : AppColors.primary, size: 22 * s),
                ),
              ),
            ),
          ),
          SizedBox(width: 12 * s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(5 * s),
                      decoration: BoxDecoration(
                        color: (isDark ? cs.primary : AppColors.primary).withOpacity(.10),
                        borderRadius: BorderRadius.circular(6 * s),
                      ),
                      child: Icon(Icons.explore_rounded,
                          color: isDark ? cs.primary : AppColors.primary, size: 14 * s),
                    ),
                    SizedBox(width: 6 * s),
                    Expanded(
                      child: Text(
                        'Plan Your Route',
                        style: t.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          fontSize: 18 * s,
                          letterSpacing: -0.3,
                          height: 1.1,
                          color: isDark ? cs.onSurface : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 3 * s),
                Text(
                  'Search places & addresses near you',
                  style: t.bodySmall?.copyWith(
                    color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                    fontSize: 11 * s,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 10 * s),
          Semantics(
            button: true,
            label: 'Swap pickup and destination',
            child: AnimatedScale(
              scale: _swapPressed ? 0.92 : 1.0,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutBack,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _handleSwap,
                  borderRadius: BorderRadius.circular(12 * s),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 8 * s),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.swap_vert_rounded,
                            size: 18 * s, color: isDark ? cs.onSurface : AppColors.textPrimary.withOpacity(.9)),
                        SizedBox(width: 6 * s),
                        Text('Swap',
                            style: TextStyle(
                              fontSize: 13 * s,
                              fontWeight: FontWeight.w800,
                              color: isDark ? cs.onSurface : AppColors.textPrimary.withOpacity(.9),
                            )),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteCard(BuildContext context, bool isDark, ColorScheme cs) {
    final s = _s(context);
    return Container(
      decoration: BoxDecoration(
        color: isDark ? cs.surface : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18 * s),
        border: Border.all(color: isDark ? cs.outline : AppColors.mintBgLight.withOpacity(.3), width: 1),
        boxShadow: [
          BoxShadow(color: isDark ? Colors.black.withOpacity(0.5) : Colors.black.withOpacity(.06), blurRadius: 10, offset: Offset(0, 4 * s)),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(14 * s),
        child: RouteEditor(
          key: ValueKey<int>(widget.points.length),
          points: widget.points,
          onTyping: widget.onTyping,
          onFocused: widget.onFocused,
          onAddStop: widget.onAddStop,
          onRemoveStop: widget.onRemoveStop,
          onSwap: _handleSwap,
          onUseCurrentPickup: widget.onUseCurrentPickup,
        ),
      ),
    );
  }

  Widget _buildStatusBanner(bool isDark, ColorScheme cs) {
    final msg = 'Places: ${widget.autoStatus}${widget.autoError != null ? ' — ${widget.autoError}' : ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? cs.errorContainer : const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? cs.error : const Color(0xFFFFE69C), width: 1),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: isDark ? cs.onErrorContainer : const Color(0xFF856404), size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(
                color: isDark ? cs.onErrorContainer : const Color(0xFF856404),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider(bool isDark, ColorScheme cs) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.transparent, isDark ? cs.outline : AppColors.mintBgLight.withOpacity(.3), Colors.transparent],
        ),
      ),
    );
  }

  Widget _buildSuggestions(bool isDark, ColorScheme cs) {
    if (widget.isTyping) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 3, color: isDark ? cs.primary : AppColors.primary)),
            const SizedBox(height: 14),
            Text('Searching places...', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? cs.onSurface : AppColors.textPrimary)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: _SuggestionsHost(fmtDistance: widget.fmtDistance),
    );
  }
}

// Lightweight leaf so we don't rebuild heavy parent while typing.
class _SuggestionsHost extends StatelessWidget {
  final String Function(int meters) fmtDistance;
  const _SuggestionsHost({required this.fmtDistance});

  @override
  Widget build(BuildContext context) {
    final overlay = context.findAncestorStateOfType<_AutoOverlayState>()!;
    return SuggestionList(
      suggestions: overlay.widget.suggestions,
      recents: overlay.widget.recents,
      showUseCurrent: overlay.widget.hasGps && overlay.widget.activeIndex == 0,
      onUseCurrentTap: overlay.widget.hasGps ? overlay.widget.onUseCurrentPickup : null,
      onTap: (s) {
        HapticFeedback.selectionClick();
        // Selecting a suggestion closes overlay in HomePage and
        // immediately computes route + opens ride market.
        overlay.widget.onSelectSuggestion(s);
      },
      fmtDistance: fmtDistance,
    );
  }
}