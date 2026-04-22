// lib/widgets/bottom_navigation_bar.dart
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';

/// TRANSPARENT FLOATING NAV BAR (glass, strokes only)
/// - Labels UNDER icons (always visible) for side items
/// - "Send Me" label hidden (hero only)
/// - Icons larger, centered; layout responsive & overflow-safe
/// - Unified active styling for Home/Rides/Dispatch/Profile
class CustomBottomNavBar extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final VoidCallback? onCenterAction;
  final List<int?> badges;

  const CustomBottomNavBar({
    Key? key,
    required this.currentIndex,
    required this.onTap,
    this.onCenterAction,
    this.badges = const [null, null, null, null, null],
  }) : super(key: key);

  @override
  State<CustomBottomNavBar> createState() => _CustomBottomNavBarState();
}

class _CustomBottomNavBarState extends State<CustomBottomNavBar>
    with TickerProviderStateMixin {
  late final AnimationController _wave =
  AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  late final AnimationController _pulse =
  AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);

  static const _labels = <String>[
    'Street Ride',
    'Campus Ride',
    'Send Me',
    'Dispatch',
    'Profile',
  ];

  @override
  void dispose() {
    _wave.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _select(int index) {
    HapticFeedback.lightImpact();
    _wave.forward(from: 0).then((_) => _wave.reverse());

    widget.onTap(index);

    if (index == 2 && widget.onCenterAction != null) {
      widget.onCenterAction!.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Responsive text sizing mapped securely to your UIScale engine
    final baseFontSize = uiScale.font(11.0);
    final selectedFontSize = uiScale.font(12.5);

    final baseLabel = TextStyle(fontSize: baseFontSize);
    final selectedLabelStyle = baseLabel.copyWith(
      fontSize: selectedFontSize,
      fontWeight: FontWeight.w900,
      color: isDark ? cs.onSurface : AppColors.textPrimary,
      letterSpacing: .2,
    );
    final unselectedLabelStyle = baseLabel.copyWith(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w700,
      color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
      letterSpacing: .15,
    );

    // FIXED: Uses public uiScale.inset() instead of private .scale()
    final kGlassH = uiScale.compact ? 72.0 : uiScale.inset(78.0);
    final kTotalH = uiScale.compact ? 110.0 : uiScale.inset(116.0);
    final kChip = uiScale.icon(38.0);
    final kIcon = uiScale.icon(22.0);
    final kHero = uiScale.icon(66.0);
    const int kCount = 5;

    final horizontalPadding = uiScale.inset(14.0);

    return SafeArea(
      top: false,
      child: SizedBox(
        height: kTotalH,
        child: Padding(
          padding: EdgeInsets.fromLTRB(horizontalPadding, 0, horizontalPadding, uiScale.inset(12)),
          child: LayoutBuilder(
            builder: (_, constraints) {
              final width = constraints.maxWidth;

              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.bottomCenter,
                children: [
                  // Rear plate shadow layer
                  Positioned(
                    bottom: uiScale.inset(8),
                    child: Container(
                      width: width,
                      height: kGlassH,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(uiScale.radius(26)),
                        border: Border.all(
                          color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(.55),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: isDark ? Colors.black.withOpacity(0.6) : AppColors.deep.withOpacity(.18),
                            blurRadius: 36,
                            offset: Offset(0, uiScale.inset(16)),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Raised inner bar (blur, stroke)
                  Positioned(
                    bottom: uiScale.inset(8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(uiScale.radius(24)),
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                        child: Container(
                          width: width,
                          height: kGlassH,
                          decoration: BoxDecoration(
                            color: isDark ? cs.surfaceVariant.withOpacity(0.75) : Colors.white.withOpacity(0.85),
                            borderRadius: BorderRadius.circular(uiScale.radius(24)),
                            border: Border.all(
                              color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(.85),
                              width: 1.2,
                            ),
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Subtle wave stroke
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: AnimatedBuilder(
                                    animation: _wave,
                                    builder: (_, __) => CustomPaint(
                                      painter: _LiquidWavePainter(
                                        progress: _wave.value,
                                        color: (isDark ? cs.primary : AppColors.primary).withOpacity(.15),
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              // Items row with proper flex
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: List.generate(kCount, (i) {
                                  if (i == 2) {
                                    return const Expanded(flex: 1, child: SizedBox());
                                  }

                                  final selected = i == widget.currentIndex;
                                  final badge = (i < widget.badges.length) ? widget.badges[i] : null;

                                  return Expanded(
                                    flex: 1,
                                    child: _SideItem(
                                      icon: _iconForIndex(i, selected, kIcon, isDark, cs),
                                      label: _labels[i],
                                      chipDiameter: kChip,
                                      selected: selected,
                                      selectedStyle: selectedLabelStyle,
                                      unselectedStyle: unselectedLabelStyle,
                                      badgeCount: badge,
                                      onTap: () => _select(i),
                                      glassHeight: kGlassH,
                                      uiScale: uiScale,
                                      isDark: isDark,
                                      cs: cs,
                                    ),
                                  );
                                }),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Center hero ("Send Me")
                  Positioned(
                    bottom: uiScale.inset(8),
                    left: 0,
                    right: 0,
                    child: _CenterHero(
                      active: widget.currentIndex == 2,
                      pulse: _pulse,
                      size: kHero,
                      onTap: () => _select(2),
                      isDark: isDark,
                      cs: cs,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _iconForIndex(int index, bool selected, double size, bool isDark, ColorScheme cs) {
    final Color iconColor = selected
        ? (isDark ? cs.onPrimary : AppColors.surface)
        : (isDark ? cs.onSurfaceVariant : AppColors.textSecondary);

    switch (index) {
      case 0:
        return SvgPicture.asset(
          'assets/icons/street_ride.svg',
          width: size,
          height: size,
          colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
        );
      case 1:
        return SvgPicture.asset(
          'assets/icons/campus_ride_monochrome.svg',
          width: size,
          height: size,
          colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
        );
      case 3:
        return SvgPicture.asset(
          'assets/icons/dispatch.svg',
          width: size,
          height: size,
          colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
        );
      case 4:
        return Icon(Icons.person_rounded, size: size, color: iconColor);
      default:
        return Icon(Icons.circle, size: size, color: iconColor);
    }
  }
}

class _SideItem extends StatelessWidget {
  final Widget icon;
  final String label;
  final bool selected;
  final TextStyle selectedStyle;
  final TextStyle unselectedStyle;
  final int? badgeCount;
  final double chipDiameter;
  final double glassHeight;
  final UIScale uiScale;
  final bool isDark;
  final ColorScheme cs;
  final VoidCallback onTap;

  const _SideItem({
    Key? key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.selectedStyle,
    required this.unselectedStyle,
    required this.onTap,
    required this.glassHeight,
    required this.uiScale,
    required this.isDark,
    required this.cs,
    this.badgeCount,
    this.chipDiameter = 38,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final chipColor = selected
        ? (isDark ? cs.primary : AppColors.primary)
        : Colors.transparent;

    final labelStyle = selected ? selectedStyle : unselectedStyle;

    final selectionMargin = uiScale.inset(4.0);
    final selectionPadding = uiScale.inset(4.0);
    final itemSpacing = uiScale.gap(2.0);

    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(uiScale.radius(18)),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          constraints: BoxConstraints(
            maxHeight: glassHeight - (selectionMargin * 2),
            maxWidth: double.infinity,
          ),
          margin: EdgeInsets.symmetric(
            horizontal: selectionMargin,
            vertical: selectionMargin,
          ),
          decoration: selected
              ? BoxDecoration(
            color: (isDark ? cs.primary : AppColors.primary).withOpacity(isDark ? 0.15 : .12),
            borderRadius: BorderRadius.circular(uiScale.radius(16)),
            border: Border.all(
              color: (isDark ? cs.primary : AppColors.primary).withOpacity(isDark ? 0.5 : .32),
              width: 1.2,
            ),
          )
              : null,
          child: Padding(
            padding: EdgeInsets.all(selected ? selectionPadding : 2.0),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 240),
                        constraints: BoxConstraints(
                          maxWidth: chipDiameter,
                          maxHeight: chipDiameter,
                          minWidth: chipDiameter * 0.9,
                          minHeight: chipDiameter * 0.9,
                        ),
                        decoration: BoxDecoration(
                          color: chipColor,
                          shape: BoxShape.circle,
                          boxShadow: selected
                              ? [
                            BoxShadow(
                              color: (isDark ? cs.primary : AppColors.primary).withOpacity(.35),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ]
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: icon,
                        ),
                      ),
                    ),
                    SizedBox(height: itemSpacing),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: labelStyle,
                          softWrap: false,
                        ),
                      ),
                    ),
                  ],
                ),
                if (badgeCount != null && badgeCount! > 0)
                  Positioned(
                    right: selected ? uiScale.inset(4) : uiScale.inset(8),
                    top: selected ? 0 : uiScale.inset(4),
                    child: _Badge(
                      count: badgeCount!,
                      uiScale: uiScale,
                      isDark: isDark,
                      cs: cs,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CenterHero extends StatelessWidget {
  final bool active;
  final AnimationController pulse;
  final double size;
  final VoidCallback onTap;
  final bool isDark;
  final ColorScheme cs;

  const _CenterHero({
    Key? key,
    required this.active,
    required this.pulse,
    required this.size,
    required this.onTap,
    required this.isDark,
    required this.cs,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final ringBase = size + 8;

    return AnimatedBuilder(
      animation: pulse,
      builder: (_, __) {
        final ringScale = 1.0 + (pulse.value * .06);
        final ringOpacity = active ? .22 : .14;

        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: ringBase * ringScale,
              height: ringBase * ringScale,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: (isDark ? cs.primary : AppColors.primary).withOpacity(ringOpacity),
                    blurRadius: 26,
                    spreadRadius: 2,
                  ),
                  BoxShadow(
                    color: isDark ? Colors.black.withOpacity(0.7) : AppColors.deep.withOpacity(.10),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTapDown: (_) => HapticFeedback.lightImpact(),
              onTap: onTap,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: isDark
                        ? [cs.primary, cs.secondary]
                        : [AppColors.primary, AppColors.secondary],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (isDark ? cs.primary : AppColors.primary).withOpacity(.30),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                  border: Border.all(
                    color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(.55),
                    width: 1,
                  ),
                ),
                child: _SendMeGlyph(isDark: isDark, cs: cs),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SendMeGlyph extends StatelessWidget {
  final bool isDark;
  final ColorScheme cs;

  const _SendMeGlyph({
    Key? key,
    required this.isDark,
    required this.cs,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Icon(Icons.location_on, color: isDark ? cs.onPrimary : AppColors.surface, size: 24),
        Positioned(
          right: 12,
          top: 12,
          child: Icon(Icons.directions_walk_sharp, color: isDark ? cs.onPrimary : AppColors.surface, size: 20),
        ),
      ],
    );
  }
}

class _LiquidWavePainter extends CustomPainter {
  final double progress;
  final Color color;

  _LiquidWavePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color;

    final path = Path();
    final midY = size.height * .62;
    const waveLen = 60.0;
    const amp = 4.0;

    path.moveTo(0, midY);
    for (double x = 0; x <= size.width; x += 1) {
      final y = midY + math.sin((x / waveLen + progress * 2 * math.pi)) * amp;
      path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _LiquidWavePainter old) =>
      old.progress != progress || old.color != color;
}

class _Badge extends StatelessWidget {
  final int count;
  final UIScale uiScale;
  final bool isDark;
  final ColorScheme cs;

  const _Badge({
    required this.count,
    required this.uiScale,
    required this.isDark,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    final txt = count > 99 ? '99+' : '$count';
    final fontSize = uiScale.font(9.0);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: uiScale.inset(6),
        vertical: uiScale.inset(2),
      ),
      constraints: BoxConstraints(
        minWidth: uiScale.inset(20),
        minHeight: uiScale.inset(16),
      ),
      decoration: BoxDecoration(
          color: isDark ? cs.error : AppColors.error,
          borderRadius: BorderRadius.circular(uiScale.radius(10)),
          border: Border.all(color: isDark ? cs.surface : AppColors.surface, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 4,
              offset: const Offset(0, 2),
            )
          ]
      ),
      child: Text(
        txt,
        style: TextStyle(
          color: isDark ? cs.onError : AppColors.onErrorColor,
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}