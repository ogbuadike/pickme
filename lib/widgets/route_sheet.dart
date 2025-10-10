// lib/screens/home/widgets/route_sheet.dart
// Advanced bottom sheet — glassy panel + Route editor + stats + CTA
//
// ✅ Keeps your callbacks and data model
// ✅ Clean swap parity with overlay (uses onSwap)
// ✅ Preserves AppTheme visuals and padding around bottom nav

import 'dart:ui';
import 'package:flutter/material.dart';

import '../../../themes/app_theme.dart';
import '../screens/state/home_models.dart';     // ✅ correct relative path
import 'route_editor.dart';
import 'trip_stats.dart';

class RouteSheet extends StatelessWidget {
  final List<RoutePoint> points;
  final double bottomNavHeight;
  final String? distanceText;
  final String? durationText;
  final double? fare;

  final ValueChanged<String> onTyping;
  final ValueChanged<int> onFocused;
  final VoidCallback onAddStop;
  final void Function(int idx) onRemoveStop;
  final VoidCallback onSwap;
  final VoidCallback onUseCurrentPickup;
  final VoidCallback onSearchRides;

  const RouteSheet({
    super.key,
    required this.points,
    required this.bottomNavHeight,
    required this.distanceText,
    required this.durationText,
    required this.fare,
    required this.onTyping,
    required this.onFocused,
    required this.onAddStop,
    required this.onRemoveStop,
    required this.onSwap,
    required this.onUseCurrentPickup,
    required this.onSearchRides,
  });

  bool get _hasStats => distanceText != null && durationText != null;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bg.withOpacity(.92),
            border: Border(top: BorderSide(color: AppColors.mintBgLight)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.10),
                blurRadius: 24,
                offset: const Offset(0, -10),
              ),
            ],
          ),
          child: Column(
            children: [
              _dragHeader(),
              _titleBar(context),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(16, 10, 16, bottomNavHeight + 20),
                  child: Column(
                    children: [
                      _editorCard(context),
                      if (_hasStats) ...[
                        const SizedBox(height: 12),
                        _statsCard(),
                      ],
                      const SizedBox(height: 12),
                      _ctaButton(),
                      if (fare != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Est. fare ~ ₦${fare!.toStringAsFixed(0)}',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: AppColors.deep,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────── UI sections ─────────────────

  Widget _dragHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const Spacer(),
          const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.black54),
        ],
      ),
    );
  }

  Widget _titleBar(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Row(
        children: [
          Text(
            'Your route',
            style: t.headlineMedium?.copyWith(
              fontWeight: FontWeight.w900,
              fontSize: 20,
            ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: onSwap,
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
    );
  }

  Widget _editorCard(BuildContext context) {
    return DecoratedBox(
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
          points: points,
          onTyping: onTyping,
          onFocused: onFocused,
          onAddStop: onAddStop,
          onRemoveStop: onRemoveStop,
          onSwap: onSwap,
          onUseCurrentPickup: onUseCurrentPickup,
        ),
      ),
    );
  }

  Widget _statsCard() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(.98),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.mintBgLight),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: TripStats(
          distanceText: distanceText!,
          durationText: durationText!,
        ),
      ),
    );
  }

  Widget _ctaButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: onSearchRides,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: const Text(
          'Search rides',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
