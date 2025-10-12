// Full-screen autocomplete overlay (overflow-safe, tiny scale)

import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../themes/app_theme.dart';
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
  final VoidCallback onSearchRides;

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
    required this.onSearchRides,
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
  late final AnimationController _blurCtl;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  late final Animation<Offset> _slide;
  late final Animation<double> _blur;

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
    _mainCtl =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
    _blurCtl =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 480));

    _fade = CurvedAnimation(parent: _mainCtl, curve: Curves.easeOutCubic);
    _scale = Tween<double>(begin: 0.92, end: 1.0)
        .animate(CurvedAnimation(parent: _mainCtl, curve: Curves.easeOutBack));
    _slide = Tween<Offset>(begin: const Offset(0, -0.05), end: Offset.zero)
        .animate(CurvedAnimation(parent: _mainCtl, curve: Curves.easeOutCubic));
    _blur = Tween<double>(begin: 0, end: 16)
        .animate(CurvedAnimation(parent: _blurCtl, curve: Curves.easeOut));

    _mainCtl.forward();
    _blurCtl.forward();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _mainCtl.dispose();
    _blurCtl.dispose();
    WidgetsBinding.instance.removeObserver(this);
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

    await Future.wait([_mainCtl.reverse(), _blurCtl.reverse()]);
    if (!mounted) return;

    FocusManager.instance.primaryFocus?.unfocus();
    await Future.delayed(const Duration(milliseconds: 50));
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

    await Future.delayed(const Duration(milliseconds: 150));
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

    return Positioned.fill(
      child: FadeTransition(
        opacity: _fade,
        child: AnimatedBuilder(
          animation: _blur,
          builder: (context, _) => BackdropFilter(
            filter: ImageFilter.blur(sigmaX: _blur.value, sigmaY: _blur.value),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? [bg.withOpacity(.98), bg.withOpacity(.96), bg.withOpacity(.94)]
                      : [bg.withOpacity(.99), bg.withOpacity(.98), bg.withOpacity(.97)],
                ),
              ),
              child: ScaleTransition(
                scale: _scale,
                child: SlideTransition(
                  position: _slide,
                  child: _buildContent(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    return SafeArea(
      child: _isLandscape(context)
          ? _buildLandscapeLayout()
          : _buildPortraitLayout(),
    );
  }

  Widget _buildPortraitLayout() {
    final s = _s(context);

    return Column(
      children: [
        _buildPremiumHeader(context),
        Expanded(
          child: RepaintBoundary(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(16 * s, 0, 16 * s, 8 * s),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildRouteCard(context),
                  if (widget.autoStatus != null && widget.autoStatus != 'OK')
                    Padding(
                      padding: EdgeInsets.only(top: 8 * s),
                      child: _buildStatusBanner(),
                    ),
                  _buildDivider(),
                  _buildSuggestions(),
                ],
              ),
            ),
          ),
        ),
        _buildFooter(context),
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    return Column(
      children: [
        _buildPremiumHeader(context),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 45,
                child: RepaintBoundary(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildRouteCard(context),
                        if (widget.autoStatus != null && widget.autoStatus != 'OK')
                          _buildStatusBanner(),
                      ],
                    ),
                  ),
                ),
              ),
              Container(width: 1, color: AppColors.mintBgLight.withOpacity(.2)),
              Expanded(
                flex: 55,
                child: RepaintBoundary(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: _buildSuggestions(),
                  ),
                ),
              ),
            ],
          ),
        ),
        _buildFooter(context),
      ],
    );
  }

  Widget _buildPremiumHeader(BuildContext context) {
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
              color: AppColors.primary.withOpacity(.12),
              borderRadius: BorderRadius.circular(14 * s),
              child: InkWell(
                onTap: _handleClose,
                borderRadius: BorderRadius.circular(14 * s),
                splashColor: AppColors.primary.withOpacity(.2),
                child: Container(
                  width: 44 * s,
                  height: 44 * s,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14 * s),
                    border: Border.all(
                      color: AppColors.primary.withOpacity(.2),
                      width: 1.5,
                    ),
                  ),
                  child: Icon(Icons.close_rounded, color: AppColors.primary, size: 22 * s),
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
                        gradient: LinearGradient(
                          colors: [
                            AppColors.primary.withOpacity(.15),
                            AppColors.primary.withOpacity(.08),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(6 * s),
                      ),
                      child: Icon(Icons.explore_rounded,
                          color: AppColors.primary, size: 14 * s),
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
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 3 * s),
                Text(
                  'Search places & addresses near you',
                  style: t.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
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
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutBack,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _handleSwap,
                  borderRadius: BorderRadius.circular(12 * s),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 9 * s),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppColors.mintBgLight.withOpacity(.18),
                          AppColors.mintBgLight.withOpacity(.10),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12 * s),
                      border: Border.all(
                        color: AppColors.mintBgLight.withOpacity(.4),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.mintBgLight.withOpacity(.1),
                          blurRadius: 6,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.swap_vert_rounded,
                            size: 18 * s, color: AppColors.textPrimary.withOpacity(.9)),
                        SizedBox(width: 5 * s),
                        Text('Swap',
                            style: TextStyle(
                              fontSize: 13 * s,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary.withOpacity(.9),
                              letterSpacing: -0.1,
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

  Widget _buildRouteCard(BuildContext context) {
    final s = _s(context);

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18 * s),
        border: Border.all(color: AppColors.mintBgLight.withOpacity(.3), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(.08),
            blurRadius: 16,
            offset: Offset(0, 6 * s),
            spreadRadius: 0,
          ),
          BoxShadow(
            color: Colors.black.withOpacity(.04),
            blurRadius: 12,
            offset: Offset(0, 2 * s),
          ),
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

  Widget _buildStatusBanner() {
    final s = _s(context);
    final msg =
        'Places: ${widget.autoStatus}${widget.autoError != null ? ' — ${widget.autoError}' : ''}';

    return Container(
      margin: EdgeInsets.fromLTRB(0, 0, 0, 6 * s),
      padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 10 * s),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFFFFF3CD), Color(0xFFFFF8E1)]),
        borderRadius: BorderRadius.circular(12 * s),
        border: Border.all(color: const Color(0xFFFFE69C), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFFE69C).withOpacity(.2),
            blurRadius: 6,
            offset: Offset(0, 3 * s),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(6 * s),
            decoration: BoxDecoration(
              color: const Color(0xFF856404).withOpacity(.15),
              borderRadius: BorderRadius.circular(8 * s),
            ),
            child: const Icon(Icons.info_outline_rounded,
                color: Color(0xFF856404), size: 16),
          ),
          SizedBox(width: 10 * s),
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(
                color: Color(0xFF856404),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.1,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            AppColors.mintBgLight.withOpacity(.3),
            Colors.transparent,
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestions() {
    if (widget.isTyping) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 3)),
            SizedBox(height: 14),
            Text('Searching places...',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SuggestionList(
        suggestions: widget.suggestions,
        recents: widget.recents,
        showUseCurrent: widget.hasGps && widget.activeIndex == 0,
        onUseCurrentTap: widget.hasGps ? widget.onUseCurrentPickup : null,
        onTap: (s) {
          HapticFeedback.selectionClick();
          widget.onSelectSuggestion(s);
        },
        fmtDistance: widget.fmtDistance,
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final s = _s(context);
    final canSearch = widget.points.length >= 2 &&
        widget.points.first.latLng != null &&
        widget.points.last.latLng != null;

    return Container(
      padding: EdgeInsets.fromLTRB(16 * s, 10 * s, 16 * s, widget.bottomPadding + 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Theme.of(context).scaffoldBackgroundColor.withOpacity(.0),
            Theme.of(context).scaffoldBackgroundColor.withOpacity(.98),
          ],
        ),
        border: Border(
          top: BorderSide(color: AppColors.mintBgLight.withOpacity(.2), width: 1),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: canSearch
              ? () {
            HapticFeedback.mediumImpact();
            widget.onSearchRides();
          }
              : null,
          borderRadius: BorderRadius.circular(16 * s),
          splashColor: Colors.white.withOpacity(.25),
          child: Ink(
            height: 52 * s,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: canSearch
                    ? [AppColors.primary, AppColors.primary.withOpacity(.85)]
                    : [Colors.grey[350]!, Colors.grey[400]!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16 * s),
              boxShadow: canSearch
                  ? [
                BoxShadow(
                  color: AppColors.primary.withOpacity(.4),
                  blurRadius: 24,
                  offset: Offset(0, 10 * s),
                  spreadRadius: 0,
                ),
                BoxShadow(
                  color: AppColors.primary.withOpacity(.2),
                  blurRadius: 40,
                  offset: Offset(0, 20 * s),
                ),
              ]
                  : [],
            ),
            child: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.search_rounded, color: Colors.white, size: 20),
                  SizedBox(width: 10 * s),
                  Text(
                    'Search Rides',
                    style: TextStyle(
                      fontSize: 16 * s,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: -0.2,
                    ),
                  ),
                  if (canSearch) ...[
                    SizedBox(width: 6 * s),
                    const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 18),
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
