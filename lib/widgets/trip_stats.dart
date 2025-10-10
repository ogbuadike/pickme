// lib/screens/home/widgets/trip_stats.dart
// Compact chip displaying distance + duration.

import 'package:flutter/material.dart';
import '../../../themes/app_theme.dart';

class TripStats extends StatelessWidget {
  final String distanceText;
  final String durationText;
  const TripStats({super.key, required this.distanceText, required this.durationText});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(0.95),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.mintBgLight),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.route_rounded, color: AppColors.primary, size: 20),
        const SizedBox(width: 8),
        Text('$distanceText • $durationText',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      ]),
    );
  }
}
