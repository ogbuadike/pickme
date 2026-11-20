// lib/widgets/locate_fab.dart
// Floating "my location" button. [active] = camera is following the user.

import 'package:flutter/material.dart';
import '../themes/app_theme.dart';

class LocateFab extends StatelessWidget {
  final VoidCallback onTap;

  /// When true the icon is filled (camera follows the user), otherwise it is
  /// an outline hinting that tapping recenters.
  final bool active;

  const LocateFab({super.key, required this.onTap, this.active = false});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final bg = isDark ? cs.surfaceContainerHighest : Colors.white;
    final fg = isDark ? cs.primary : AppColors.primary;
    return Semantics(
      button: true,
      label: 'Show my location',
      child: Container(
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle, boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 12, offset: const Offset(0, 4)),
        ]),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 56,
              height: 56,
              child: Icon(active ? Icons.my_location_rounded : Icons.location_searching_rounded, color: fg, size: 26),
            ),
          ),
        ),
      ),
    );
  }
}
