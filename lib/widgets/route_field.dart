// lib/screens/home/widgets/route_field.dart
// Single route input field (reusable for pickup/stop/destination).

import 'package:flutter/material.dart';
import '../../../themes/app_theme.dart';
import '../screens/state/home_models.dart';

class RouteField extends StatelessWidget {
  final RoutePoint point;
  final int index;
  final ValueChanged<String> onTyping;
  final ValueChanged<int> onFocused;
  final VoidCallback? onUseCurrent; // only for pickup
  final VoidCallback? onRemove;     // only for stop

  const RouteField({
    super.key,
    required this.point,
    required this.index,
    required this.onTyping,
    required this.onFocused,
    this.onUseCurrent,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6F7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE6E8EA)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: point.controller,
              focusNode: point.focus,
              onChanged: onTyping,
              onTap: () => onFocused(index),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: point.hint,
                hintStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 15),
              ),
              style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
          if (point.controller.text.isNotEmpty) ...[
            if (point.type == PointType.pickup && onUseCurrent != null)
              IconButton(
                icon: const Icon(Icons.my_location_rounded, size: 20),
                onPressed: onUseCurrent,
                tooltip: 'Use current',
                color: Colors.grey[600],
              ),
            if (point.type == PointType.stop && onRemove != null)
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20),
                onPressed: onRemove,
                tooltip: 'Remove',
                color: Colors.grey[600],
              ),
            if (point.latLng != null)
              const Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 20),
          ],
          const SizedBox(width: 12),
        ],
      ),
    );
  }
}
