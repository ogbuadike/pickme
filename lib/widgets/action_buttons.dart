// lib/screens/home/widgets/action_buttons.dart
// Side action buttons: Add Stop + Swap (ultra-responsive, a11y & haptics)

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../themes/app_theme.dart';

class ActionButtons extends StatelessWidget {
  /// When false, the Add Stop button is visually disabled and ignores taps.
  final bool canAddStop;

  /// Called when the user taps "Add stop".
  final VoidCallback onAddStop;

  /// Called when the user taps "Swap".
  final VoidCallback onSwap;

  /// Optional: force horizontal or vertical layout. When null, layout adapts
  /// to device orientation (portrait = vertical, landscape = horizontal).
  final Axis? axis;

  /// Optional scaling override (e.g., for very dense layouts). If null, a smart
  /// scale is computed from the shortest screen side.
  final double? scale;

  const ActionButtons({
    super.key,
    required this.canAddStop,
    required this.onAddStop,
    required this.onSwap,
    this.axis,
    this.scale,
  });

  double _s(BuildContext c) {
    if (scale != null) return scale!;
    final sz = MediaQuery.of(c).size;
    final shortest = math.min(sz.width, sz.height);
    // Same scale model used across your widgets for visual consistency.
    return (shortest / 390.0).clamp(0.75, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final s = _s(context);
    final isLandscape = (axis ?? (MediaQuery.of(context).orientation == Orientation.landscape
        ? Axis.horizontal
        : Axis.vertical)) == Axis.horizontal;

    final children = <Widget>[
      _ActionCircleButton(
        key: const ValueKey('add_stop_btn'),
        s: s,
        tooltip: 'Add stop',
        icon: Icons.add_circle_outline,
        enabled: canAddStop,
        onTap: onAddStop,
      ),
      SizedBox(width: isLandscape ? 10 * s : 0, height: isLandscape ? 0 : 10 * s),
      _ActionCircleButton(
        key: const ValueKey('swap_btn'),
        s: s,
        tooltip: 'Swap pickup & destination',
        icon: Icons.swap_vert_rounded,
        enabled: true,
        onTap: onSwap,
      ),
    ];

    // Safe extra spacing at the top/bottom for thumb reach without being cramped.
    return Padding(
      padding: EdgeInsets.all(6 * s),
      child: isLandscape
          ? Row(mainAxisSize: MainAxisSize.min, children: children)
          : Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// A resilient circular action with haptics, tooltip, semantics, and tap throttling.
class _ActionCircleButton extends StatefulWidget {
  final double s;
  final String tooltip;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _ActionCircleButton({
    super.key,
    required this.s,
    required this.tooltip,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_ActionCircleButton> createState() => _ActionCircleButtonState();
}

class _ActionCircleButtonState extends State<_ActionCircleButton> {
  bool _pressed = false;
  bool _cooldown = false;

  Future<void> _handleTap() async {
    if (!widget.enabled || _cooldown) return;

    HapticFeedback.selectionClick();
    setState(() {
      _pressed = true;
      _cooldown = true; // prevent accidental double taps (e.g., add multiple stops)
    });

    // Fire after this frame to avoid gesture reentrancy around overlays.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onTap();
    });

    // Compact release & cooldown windows for snappy feel.
    await Future.delayed(const Duration(milliseconds: 110));
    if (mounted) setState(() => _pressed = false);

    await Future.delayed(const Duration(milliseconds: 180));
    if (mounted) setState(() => _cooldown = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = Theme.of(context).cardColor;
    final borderColor = isDark
        ? Colors.white.withOpacity(.10)
        : AppColors.mintBgLight.withOpacity(.28);

    final iconColor = widget.enabled
        ? AppColors.deep
        : AppColors.textSecondary.withOpacity(.45);

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.tooltip,
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 300),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: widget.enabled ? 1.0 : 0.55,
          child: AnimatedScale(
            scale: _pressed ? 0.94 : 1.0,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: Material(
              color: bg,
              shape: const CircleBorder(),
              elevation: widget.enabled ? 4 : 0,
              shadowColor:
              (isDark ? Colors.black : AppColors.primary).withOpacity(0.18),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.enabled ? _handleTap : null,
                child: Container(
                  width: math.max(38.0, 44 * s),
                  height: math.max(38.0, 44 * s),
                  decoration: ShapeDecoration(
                    shape: CircleBorder(
                      side: BorderSide(color: borderColor, width: 1.0),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(widget.icon, size: 20 * s, color: iconColor),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
