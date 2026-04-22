// lib/widgets/route_editor.dart
// Row that composes icons column + list of RouteField + side actions.
// Uses extra breathing room between fields.

import 'dart:math' as math;
import 'package:flutter/material.dart';

// FIXED: Corrected the import path to properly locate your models!
import '../screens/state/home_models.dart';
import 'icons_column.dart';
import 'route_field.dart';
import 'action_buttons.dart';

class RouteEditor extends StatelessWidget {
  final List<RoutePoint> points;
  final ValueChanged<String> onTyping;
  final ValueChanged<int> onFocused;
  final VoidCallback onAddStop;
  final void Function(int idx) onRemoveStop;
  final VoidCallback onSwap;
  final VoidCallback onUseCurrentPickup;

  const RouteEditor({
    super.key,
    required this.points,
    required this.onTyping,
    required this.onFocused,
    required this.onAddStop,
    required this.onRemoveStop,
    required this.onSwap,
    required this.onUseCurrentPickup,
  });

  double _s(BuildContext c) {
    final sz = MediaQuery.of(c).size;
    final shortest = math.min(sz.width, sz.height);
    return (shortest / 390.0).clamp(0.75, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final s = _s(context);

    // Pass the isDark context down to child widgets if they need it
    final children = <Widget>[];
    for (int i = 0; i < points.length; i++) {
      final p = points[i];
      children.add(
        Padding(
          key: ValueKey('rf_${i}_${points.length}'),
          padding: EdgeInsets.only(bottom: i == points.length - 1 ? 0 : 14 * s),
          child: RouteField(
            key: ValueKey('route_field_${i}_${points.length}'),
            point: p,
            index: i,
            onTyping: onTyping,
            onFocused: onFocused,
            onUseCurrent: p.type == PointType.pickup ? onUseCurrentPickup : null,
            onRemove:  p.type == PointType.stop   ? () => onRemoveStop(i) : null,
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconsColumn(points: points),
        SizedBox(width: 12 * s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
        SizedBox(width: 8 * s),
        ActionButtons(
          canAddStop: points.length < 6,
          onAddStop: onAddStop,
          onSwap: onSwap,
        ),
      ],
    );
  }
}