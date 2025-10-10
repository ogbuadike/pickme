// lib/screens/home/widgets/action_buttons.dart
// Side action buttons: Add stop + Swap.

import 'package:flutter/material.dart';
import '../../../themes/app_theme.dart';

class ActionButtons extends StatelessWidget {
  final bool canAddStop;
  final VoidCallback onAddStop;
  final VoidCallback onSwap;

  const ActionButtons({
    super.key,
    required this.canAddStop,
    required this.onAddStop,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        if (canAddStop)
          _circleBtn(icon: Icons.add_circle_outline, tip: 'Add stop', onTap: onAddStop),
        const SizedBox(height: 8),
        _circleBtn(icon: Icons.swap_vert_rounded, tip: 'Swap', onTap: onSwap),
      ],
    );
  }

  Widget _circleBtn({required IconData icon, required String tip, required VoidCallback onTap}) {
    return Material(
      color: Colors.white, shape: const CircleBorder(), elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 20, color: AppColors.deep)),
      ),
    );
  }
}
