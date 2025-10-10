// lib/screens/home/widgets/icons_column.dart
// Vertical icons + connectors for pickup/stop/destination.

import 'package:flutter/material.dart';
import '../screens/state/home_models.dart';

class IconsColumn extends StatelessWidget {
  final List<RoutePoint> points;
  const IconsColumn({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    final total = points.length * 2 - 1;
    return Column(
      children: List.generate(total, (i) {
        if (i.isEven) {
          final idx = i ~/ 2, p = points[idx];
          return Container(
            width: 28, height: 28, margin: const EdgeInsets.only(top: 14),
            decoration: BoxDecoration(
              color: p.type.color.withOpacity(0.14),
              shape: BoxShape.circle,
              border: Border.all(color: p.type.color, width: 2),
            ),
            child: Icon(p.type.icon, size: 14, color: p.type.color),
          );
        } else {
          return Container(
            width: 2, height: 20, margin: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(color: const Color(0xFFE0E0E0), borderRadius: BorderRadius.circular(1)),
          );
        }
      }),
    );
  }
}
