// lib/screens/home/widgets/locate_fab.dart
// Simple floating "my location" button.

import 'package:flutter/material.dart';
import '../../../themes/app_theme.dart';

class LocateFab extends StatelessWidget {
  final VoidCallback onTap;
  const LocateFab({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 12, offset: const Offset(0, 4)),
      ]),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const SizedBox(
            width: 56, height: 56,
            child: Icon(Icons.my_location_rounded, color: AppColors.primary, size: 26),
          ),
        ),
      ),
    );
  }
}
