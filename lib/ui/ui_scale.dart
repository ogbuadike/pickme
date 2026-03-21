// lib/ui/ui_scale.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';

@immutable
class UIScale {
  const UIScale._(this.mq);

  final MediaQueryData mq;

  static UIScale of(BuildContext context) {
    return UIScale._(MediaQuery.of(context));
  }

  Size get size => mq.size;
  EdgeInsets get safePadding => mq.padding;
  EdgeInsets get viewInsets => mq.viewInsets;

  double get width => size.width;
  double get height => size.height;
  double get shortest => math.min(width, height);
  double get longest => math.max(width, height);

  bool get landscape => width > height;
  bool get tablet => shortest >= 600;

  bool get tiny => shortest < 360 || height < 690;
  bool get compact => shortest < 390 || height < 760;

  // Auth screens: only split when there is real room.
  bool get useSplitAuth => landscape && width >= 900 && height >= 560;

  // Onboarding needs more room because header/footer/card all compete.
  bool get useSplitOnboarding => landscape && width >= 960 && height >= 600;

  // Reduce expensive blur / shimmer / particle load on tight screens.
  bool get reduceFx => tiny || compact || height < 720;

  double _scale(
      double value, {
        double minFactor = 0.78,
        double maxFactor = 1.18,
      }) {
    final widthFactor = width / 390.0;
    final heightFactor = height / 844.0;
    final factor = ((widthFactor * 0.68) + (heightFactor * 0.32))
        .clamp(minFactor, maxFactor);
    return value * factor;
  }

  double font(double value) => _scale(value, minFactor: 0.84, maxFactor: 1.12);
  double gap(double value) => _scale(value, minFactor: 0.70, maxFactor: 1.10);
  double inset(double value) => _scale(value, minFactor: 0.68, maxFactor: 1.12);
  double radius(double value) => _scale(value, minFactor: 0.78, maxFactor: 1.08);
  double icon(double value) => _scale(value, minFactor: 0.82, maxFactor: 1.08);

  double blur(double value) => reduceFx ? value * 0.55 : value;

  EdgeInsets get screenPadding => EdgeInsets.symmetric(
    horizontal: tablet ? inset(44) : tiny ? inset(14) : inset(22),
    vertical: tiny ? inset(12) : inset(18),
  );

  double get authCardMaxWidth => tablet ? 520 : compact ? 380 : 420;
  double get cardRadius => compact ? radius(20) : radius(24);
  double get buttonHeight => compact ? 48 : 52;
  double get inputVerticalPadding => compact ? inset(12) : inset(16);
  double get compactLogoSize => compact ? 68 : 84;
  double get heroLogoSize => tablet ? 140 : compact ? 92 : 120;
}