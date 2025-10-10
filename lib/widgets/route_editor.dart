// lib/screens/home/widgets/route_editor.dart
// Row that composes icons column + list of RouteField + side actions.

import 'package:flutter/material.dart';
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

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconsColumn(points: points),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            children: List.generate(points.length, (i) {
              final p = points[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: RouteField(
                  point: p,
                  index: i,
                  onTyping: onTyping,
                  onFocused: onFocused,
                  onUseCurrent: p.type == PointType.pickup ? onUseCurrentPickup : null,
                  onRemove:  p.type == PointType.stop   ? () => onRemoveStop(i) : null,
                ),
              );
            }),
          ),
        ),
        ActionButtons(
          canAddStop: points.length < 6,
          onAddStop: onAddStop,
          onSwap: onSwap,
        ),
      ],
    );
  }
}
