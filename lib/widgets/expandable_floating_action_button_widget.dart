import 'package:flutter/material.dart';

// A reusable expandable floating action button widget
class ExpandableFloatingActionButton extends StatefulWidget {
  final List<Widget> floatingActionButtons; // List of floating action buttons to expand
  final Color mainButtonColor; // Color of the main FAB
  final IconData collapsedIcon; // Icon when the FAB is collapsed
  final IconData expandedIcon; // Icon when the FAB is expanded
  final Animation<double> animation; // Animation to control the button's appearance
  final VoidCallback? onToggle; // Optional callback when the main FAB is toggled

  const ExpandableFloatingActionButton({
    Key? key,
    required this.floatingActionButtons,
    required this.mainButtonColor,
    required this.collapsedIcon,
    required this.expandedIcon,
    required this.animation,
    this.onToggle, // Optional toggle action
  }) : super(key: key);

  @override
  _ExpandableFloatingActionButtonState createState() =>
      _ExpandableFloatingActionButtonState();
}

class _ExpandableFloatingActionButtonState
    extends State<ExpandableFloatingActionButton> {
  bool _isExpanded = false; // Track whether the FAB is expanded or collapsed

  // Method to toggle the expansion of the FABs
  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
    });
    if (widget.onToggle != null) {
      widget.onToggle!(); // Call the optional toggle action
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min, // Limit the size to minimum for buttons
      children: [
        // Use the provided animation for scaling
        ScaleTransition(
          scale: widget.animation,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: widget.floatingActionButtons.map((button) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0), // Reduced spacing
                child: button,
              );
            }).toList(),
          ),
        ),
        // Main Floating Action Button
        FloatingActionButton(
          onPressed: _toggleExpanded, // Toggle button state
          backgroundColor: widget.mainButtonColor, // Set main button color
          mini: true, // Use a smaller FAB
          child: Icon(
            _isExpanded ? widget.expandedIcon : widget.collapsedIcon, // Toggle icon
            color: Colors.white,
            size: 20, // Smaller icon
          ),
        ),
      ],
    );
  }
}