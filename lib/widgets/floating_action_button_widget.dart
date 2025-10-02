import 'package:flutter/material.dart';

// A reusable custom floating action button widget
class CustomFloatingActionButton extends StatelessWidget {
  final IconData icon; // Icon to display on the button
  final String label; // Text label of the button
  final Color color; // Background color of the button
  final VoidCallback onPressed; // Action when button is pressed

  const CustomFloatingActionButton({
    Key? key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: onPressed,
      icon: Icon(
        icon,
        color: Colors.white,
        size: 18, // Smaller icon
      ),
      label: Text(
        label,
        style: const TextStyle(
          fontSize: 12, // Smaller font size
          fontWeight: FontWeight.bold,
        ),
      ),
      backgroundColor: color,
      elevation: 2, // Reduced elevation
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8), // Slightly rounded corners
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, // Compact size
    );
  }
}