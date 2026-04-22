// lib/widgets/icons_column.dart
// Vertical icons + connectors for pickup/stop/destination.

import 'package:flutter/material.dart';

// FIXED: Corrected the import path to step out of 'widgets' and into 'screens/state'
import '../screens/state/home_models.dart';

class IconsColumn extends StatelessWidget {
  final List<RoutePoint> points;
  const IconsColumn({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    final total = points.length * 2 - 1;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: List.generate(total, (i) {
        if (i.isEven) {
          final idx = i ~/ 2, p = points[idx];

          // Slightly higher opacity in dark mode gives a beautiful neon glow effect
          final bgOpacity = isDark ? 0.20 : 0.14;

          return Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(top: 14),
            decoration: BoxDecoration(
              color: p.type.color.withOpacity(bgOpacity),
              shape: BoxShape.circle,
              border: Border.all(
                color: p.type.color.withOpacity(isDark ? 0.8 : 1.0),
                width: 2,
              ),
            ),
            child: Icon(p.type.icon, size: 14, color: p.type.color),
          );
        } else {
          return Container(
            width: 2,
            height: 20,
            margin: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              // Uses a sleek dark outline in Dark Mode instead of bright hardcoded grey
              color: isDark ? cs.outline.withOpacity(0.5) : const Color(0xFFE0E0E0),
              borderRadius: BorderRadius.circular(1),
            ),
          );
        }
      }),
    );
  }
}