// lib/screens/home/widgets/route_field.dart
// Single route input field with inline suffix actions (Use current / Remove X)
// Stronger, always-visible outline + bolder focus state.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../themes/app_theme.dart';
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // ⬇️ More visible borders (both themes)
    final Color baseBorder = isDark
        ? Colors.white.withOpacity(.28)          // was .10
        : AppColors.mintBgLight.withOpacity(.58); // was .28

    final Color focusBorder = isDark
        ? Colors.white.withOpacity(.70)
        : AppColors.mintBgLight.withOpacity(.95);

    final showCheck = widget.point.latLng != null;
    final isStop = widget.point.type == PointType.stop && widget.onRemove != null;
    final canUseCurrent = widget.point.type == PointType.pickup && widget.onUseCurrent != null;

    final suffix = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showCheck) ...[
          Icon(Icons.check_circle_rounded, size: 18 * s, color: AppColors.primary),
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
                color: AppColors.primary,
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
                color: AppColors.textSecondary.withOpacity(.85),
              ),
            ),
          ),
        ],
      ],
    );

    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(14 * s),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14 * s),
          border: Border.all(
            color: _focus.hasFocus ? focusBorder : baseBorder,
            width: _focus.hasFocus ? 2.0 : 1.6, // ⬅️ thicker, crisper
          ),
          // Subtle lift for separation from background (keeps your design)
          boxShadow: [
            BoxShadow(
              color: (isDark ? Colors.black : Colors.black).withOpacity(0.06),
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
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 14 * s,
            letterSpacing: -0.1,
          ),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: 8 * s),
            labelText: _label(),
            labelStyle: TextStyle(
              fontSize: 11 * s,
              fontWeight: FontWeight.w800,
              color: AppColors.textSecondary.withOpacity(.9),
              letterSpacing: -0.2,
            ),
            hintText: widget.point.hint,
            hintStyle: TextStyle(
              color: AppColors.textSecondary.withOpacity(.65),
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
