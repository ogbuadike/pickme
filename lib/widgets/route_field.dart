// lib/widgets/route_field.dart
// Single route input field with inline suffix actions (Use current / Remove X)
// Stronger, always-visible outline + bolder focus state.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// FIXED: Corrected import paths to match lib/widgets/ folder placement
import '../themes/app_theme.dart';
import '../screens/state/home_models.dart';

class RouteField extends StatefulWidget {
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
  State<RouteField> createState() => _RouteFieldState();
}

class _RouteFieldState extends State<RouteField> {
  late TextEditingController _ctl = widget.point.controller;
  late FocusNode _focus = widget.point.focus;

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_onCtlChanged);
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant RouteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.point.controller != widget.point.controller) {
      oldWidget.point.controller.removeListener(_onCtlChanged);
      _ctl = widget.point.controller..addListener(_onCtlChanged);
    }
    if (oldWidget.point.focus != widget.point.focus) {
      oldWidget.point.focus.removeListener(_onFocusChanged);
      _focus = widget.point.focus..addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    _ctl.removeListener(_onCtlChanged);
    _focus.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onCtlChanged() {
    if (mounted) setState(() {});
  }

  void _onFocusChanged() {
    if (_focus.hasFocus) widget.onFocused(widget.index);
    if (mounted) setState(() {}); // refresh outline weight/color
  }

  double _s(BuildContext c) {
    final sz = MediaQuery.of(c).size;
    final shortest = math.min(sz.width, sz.height);
    return (shortest / 390.0).clamp(0.75, 1.0);
  }

  String _label() {
    switch (widget.point.type) {
      case PointType.pickup:
        return 'Pickup';
      case PointType.destination:
        return 'Destination';
      case PointType.stop:
        return 'Stop';
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    // ⬇️ More visible borders (OLED optimized)
    final Color baseBorder = isDark
        ? cs.outline.withOpacity(0.5)            // Sleek grey line in dark mode
        : AppColors.mintBgLight.withOpacity(.58);

    final Color focusBorder = isDark
        ? cs.primary                             // Neon green glow when focused
        : AppColors.mintBgLight.withOpacity(.95);

    final showCheck = widget.point.latLng != null;
    final isStop = widget.point.type == PointType.stop && widget.onRemove != null;
    final canUseCurrent = widget.point.type == PointType.pickup && widget.onUseCurrent != null;

    final suffix = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showCheck) ...[
          Icon(Icons.check_circle_rounded, size: 18 * s, color: isDark ? cs.primary : AppColors.primary),
          SizedBox(width: 6 * s),
        ],
        if (canUseCurrent)
          TextButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              widget.onUseCurrent!.call();
            },
            style: TextButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 6 * s),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Use current',
              style: TextStyle(
                fontSize: 11 * s,
                fontWeight: FontWeight.w800,
                color: isDark ? cs.primary : AppColors.primary,
                letterSpacing: -0.1,
              ),
            ),
          ),
        if (isStop) ...[
          SizedBox(width: 4 * s),
          Tooltip(
            message: 'Remove stop',
            waitDuration: const Duration(milliseconds: 300),
            child: InkResponse(
              onTap: () {
                HapticFeedback.lightImpact();
                widget.onRemove!.call();
              },
              radius: 16 * s,
              child: Icon(
                Icons.close_rounded,
                size: 18 * s,
                // Highly visible grey in dark mode
                color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(.85),
              ),
            ),
          ),
        ],
      ],
    );

    return Material(
      // We use transparent here so the animated container handles the color
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14 * s),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          // Use Surface Variant (dark grey) in dark mode to lift it off the black background
          color: isDark ? cs.surfaceVariant : theme.cardColor,
          borderRadius: BorderRadius.circular(14 * s),
          border: Border.all(
            color: _focus.hasFocus ? focusBorder : baseBorder,
            width: _focus.hasFocus ? 2.0 : 1.6, // thicker, crisper
          ),
          // Subtle lift for separation from background
          boxShadow: [
            BoxShadow(
              color: isDark ? Colors.black.withOpacity(0.5) : Colors.black.withOpacity(0.06),
              blurRadius: 8 * s,
              offset: Offset(0, 2 * s),
            ),
          ],
        ),
        padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 6 * s),
        child: TextField(
          controller: _ctl,
          focusNode: _focus,
          onChanged: widget.onTyping,
          onTap: () => widget.onFocused(widget.index),
          textInputAction: TextInputAction.search,
          // FIXED: The typed text is now pure white in dark mode
          style: TextStyle(
            color: isDark ? cs.onSurface : AppColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 14 * s,
            letterSpacing: -0.1,
          ),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: 8 * s),
            labelText: _label(),
            // FIXED: The label text is now crisp grey in dark mode
            labelStyle: TextStyle(
              fontSize: 11 * s,
              fontWeight: FontWeight.w800,
              color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(.9),
              letterSpacing: -0.2,
            ),
            hintText: widget.point.hint,
            // FIXED: The hint placeholder text is now crisp grey in dark mode
            hintStyle: TextStyle(
              color: isDark ? cs.onSurfaceVariant.withOpacity(0.8) : AppColors.textSecondary.withOpacity(.65),
              fontSize: 13 * s,
            ),
            suffixIcon: suffix,
            suffixIconConstraints: BoxConstraints(
              minHeight: 20 * s,
              minWidth: 0,
            ),
          ),
        ),
      ),
    );
  }
}