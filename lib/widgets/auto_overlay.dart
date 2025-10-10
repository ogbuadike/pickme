// lib/screens/home/widgets/auto_overlay.dart
// Advanced full-screen overlay with enhanced UI/UX
//
// ✅ Close button collapses overlay via onClose (shows RouteSheet underneath)
// ✅ Swap works in overlay: uses onSwap if provided, else performs safe local swap
// ✅ Maintains theme (AppTheme/AppColors) and your existing RouteEditor/SuggestionList contracts

import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../themes/app_theme.dart';
import '../screens/state/home_models.dart';   // ✅ correct relative path
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

  /// These are optional in HomePage. If not supplied, we provide safe fallbacks.
  final VoidCallback? onClose; // collapse overlay to reveal RouteSheet
  final VoidCallback? onSwap;  // swap pickup/destination in parent

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
    this.onClose,
    this.onSwap,
  });

  @override
  State<AutoOverlay> createState() => _AutoOverlayState();
}

class _AutoOverlayState extends State<AutoOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _cardCtl;
  late final AnimationController _blurCtl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  late final Animation<double> _blur;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _cardCtl = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));
    _blurCtl = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
    _fade = CurvedAnimation(parent: _cardCtl, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(begin: const Offset(0, -0.03), end: Offset.zero)
        .animate(CurvedAnimation(parent: _cardCtl, curve: Curves.easeOutCubic));
    _blur = Tween<double>(begin: 0, end: 10)
        .animate(CurvedAnimation(parent: _blurCtl, curve: Curves.easeOut));
    _cardCtl.forward();
    _blurCtl.forward();
  }

  @override
  void dispose() {
    _cardCtl.dispose();
    _blurCtl.dispose();
    super.dispose();
  }

  Future<void> _handleClose() async {
    if (_closing) return;
    _closing = true;
    HapticFeedback.lightImpact();
    await Future.wait([_cardCtl.reverse(), _blurCtl.reverse()]);
    if (!mounted) return;
    // Tell parent to collapse overlay → RouteSheet is already underneath.
    widget.onClose?.call();
  }

  void _swap() {
    HapticFeedback.selectionClick();
    if (widget.onSwap != null) {
      widget.onSwap!.call();
      return;
    }
    // Fallback: safe local swap (mutates shared points list so HomePage sees changes)
    if (widget.points.length < 2) return;
    final a = widget.points.first;
    final b = widget.points.last;
    final ll = a.latLng, id = a.placeId, txt = a.controller.text, cur = a.isCurrent;
    a
      ..latLng = b.latLng
      ..placeId = b.placeId
      ..controller.text = b.controller.text
      ..isCurrent = false;
    b
      ..latLng = ll
      ..placeId = id
      ..controller.text = txt
      ..isCurrent = cur;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final double top = widget.safeTop + 74; // below header
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      bottom: widget.bottomPadding,
      child: FadeTransition(
        opacity: _fade,
        child: AnimatedBuilder(
          animation: _blur,
          builder: (_, __) => BackdropFilter(
            filter: ImageFilter.blur(sigmaX: _blur.value, sigmaY: _blur.value),
            child: Container(
              // Subtle vertical glass gradient
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Theme.of(context).scaffoldBackgroundColor.withOpacity(.98),
                    Theme.of(context).scaffoldBackgroundColor.withOpacity(.96),
                  ],
                ),
              ),
              child: SlideTransition(position: _slide, child: _buildBody(context)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final t = Theme.of(context).textTheme;

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              // Close → collapse overlay
              Material(
                color: AppColors.primary.withOpacity(.10),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: _handleClose,
                  borderRadius: BorderRadius.circular(12),
                  child: const SizedBox(
                    width: 42,
                    height: 42,
                    child: Icon(Icons.close_rounded, color: AppColors.primary, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Plan your route',
                        style: t.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: AppColors.textPrimary,
                        )),
                    const SizedBox(height: 2),
                    Text('Search streets & places near you',
                        style: t.labelMedium?.copyWith(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        )),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _swap,
                icon: const Icon(Icons.swap_vert_rounded, size: 18),
                label: const Text('Swap'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  side: BorderSide(color: AppColors.mintBgLight),
                  foregroundColor: AppColors.textPrimary,
                  shape: const StadiumBorder(),
                ),
              ),
            ],
          ),
        ),

        // Route editor card
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.mintBgLight),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.06),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: RouteEditor(
                points: widget.points,
                onTyping: widget.onTyping,
                onFocused: widget.onFocused,
                onAddStop: () {}, // overlay keeps add-stop minimal; add via sheet
                onRemoveStop: (_) {},
                onSwap: _swap,
                onUseCurrentPickup: widget.onUseCurrentPickup,
              ),
            ),
          ),
        ),

        // Status (Places)
        if (widget.autoStatus != null && widget.autoStatus != 'OK')
          _statusBanner(widget.autoStatus!, widget.autoError),

        const Divider(height: 1),

        // Suggestions
        Expanded(
          child: widget.isTyping
              ? const Center(child: CircularProgressIndicator())
              : SuggestionList(
            suggestions: widget.suggestions,
            recents: widget.recents,
            showUseCurrent: widget.hasGps && widget.activeIndex == 0,
            onUseCurrentTap:
            widget.hasGps ? widget.onUseCurrentPickup : null,
            onTap: widget.onSelectSuggestion,
            fmtDistance: widget.fmtDistance,
          ),
        ),

        // CTA
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8, top: 2),
                child: Text(
                  'powered by Google',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.grey[500],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    widget.onSearchRides();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: const StadiumBorder(),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search, size: 20),
                      SizedBox(width: 8),
                      Text('Search rides',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusBanner(String status, String? err) {
    final msg = 'Places: $status${err != null ? ' — $err' : ''}';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3CD),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFE69C)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Color(0xFF856404), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(
                color: Color(0xFF856404),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
