// lib/widgets/bottom_navigation_bar.dart
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../themes/app_theme.dart';
import '../routes/routes.dart';

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

  /// Navigation behavior preserved (plus onTap to parent).
  void _select(int index) {
    widget.onTap(index);

    if (index == 2 && widget.onCenterAction != null) {
      widget.onCenterAction!.call();
    }

    switch (index) {
      case 0:
        Navigator.of(context).pushReplacementNamed(AppRoutes.home);
        break;
      case 1:
        Navigator.of(context).pushReplacementNamed(AppRoutes.history);
        break;
      case 2:
      // handled by onCenterAction (if provided)
        break;
      case 3:
      // Add when route is ready:
      // Navigator.of(context).pushReplacementNamed(AppRoutes.dispatch);
        break;
      case 4:
        Navigator.pushNamed(context, AppRoutes.profile);
        break;
    }

    HapticFeedback.lightImpact();
    _wave.forward(from: 0).then((_) => _wave.reverse());
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final screenWidth = MediaQuery.of(context).size.width;

    // Responsive text sizing based on screen width
    final isSmallScreen = screenWidth < 360;
    final isMediumScreen = screenWidth >= 360 && screenWidth < 414;

    // Adjust label sizes responsively
    final baseFontSize = isSmallScreen ? 10.0 : (isMediumScreen ? 11.0 : 12.0);
    final selectedFontSize = isSmallScreen ? 11.0 : (isMediumScreen ? 12.0 : 13.0);

    final baseLabel = (t.labelMedium ?? TextStyle(fontSize: baseFontSize));
    final selectedLabelStyle = baseLabel.copyWith(
      fontSize: selectedFontSize,
      fontWeight: FontWeight.w900,
      color: AppColors.textPrimary,
      letterSpacing: .2,
    );
    final unselectedLabelStyle = baseLabel.copyWith(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w700,
      color: AppColors.textSecondary,
      letterSpacing: .15,
    );

    // Responsive sizes
    final kGlassH = isSmallScreen ? 72.0 : 78.0;
    final kTotalH = isSmallScreen ? 110.0 : 116.0;
    final kChip = isSmallScreen ? 34.0 : (isMediumScreen ? 36.0 : 38.0);
    final kIcon = isSmallScreen ? 20.0 : (isMediumScreen ? 21.0 : 22.0);
    final kHero = isSmallScreen ? 60.0 : (isMediumScreen ? 64.0 : 66.0);
    const int kCount = 5;

    // Responsive padding
    final horizontalPadding = isSmallScreen ? 10.0 : 14.0;

    return SafeArea(
      top: false,
      child: SizedBox(
        height: kTotalH,
        child: Padding(
          padding: EdgeInsets.fromLTRB(horizontalPadding, 0, horizontalPadding, 12),
          child: LayoutBuilder(
            builder: (_, constraints) {
              final width = constraints.maxWidth;

              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.bottomCenter,
                children: [
                  // Rear plate (transparent, stroke + drop)
                  Positioned(
                    bottom: 8,
                    child: Container(
                      width: width,
                      height: kGlassH,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(
                          color: AppColors.mintBgLight.withOpacity(.55),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.deep.withOpacity(.18),
                            blurRadius: 36,
                            offset: const Offset(0, 16),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Raised inner bar (blur, stroke)
                  Positioned(
                    bottom: 8,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: Container(
                          width: width,
                          height: kGlassH,
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: AppColors.mintBgLight.withOpacity(.85),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.deep.withOpacity(.10),
                                blurRadius: 18,
                                offset: const Offset(0, 6),
                              ),
                            ],
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
                                        color: AppColors.primary.withOpacity(.08),
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
                                    // Center spacer for hero button - use Expanded with flex
                                    return Expanded(
                                      flex: 1,
                                      child: SizedBox(),
                                    );
                                  }

                                  final selected = i == widget.currentIndex;
                                  final badge = (i < widget.badges.length) ? widget.badges[i] : null;

                                  // Use Expanded for responsive width
                                  return Expanded(
                                    flex: 1,
                                    child: _SideItem(
                                      icon: _iconForIndex(i, selected, kIcon),
                                      label: _labels[i],
                                      chipDiameter: kChip,
                                      selected: selected,
                                      selectedStyle: selectedLabelStyle,
                                      unselectedStyle: unselectedLabelStyle,
                                      badgeCount: badge,
                                      onTap: () => _select(i),
                                      glassHeight: kGlassH,
                                      isSmallScreen: isSmallScreen,
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

                  // Center hero ("Send Me") — label intentionally hidden
                  Positioned(
                    bottom: 8,
                    left: 0,
                    right: 0,
                    child: _CenterHero(
                      active: widget.currentIndex == 2,
                      pulse: _pulse,
                      size: kHero,
                      onTap: () => _select(2),
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

  /// Icon per index (SVGs recolored; fallback to Material when missing).
  Widget _iconForIndex(int index, bool selected, double size) {
    final Color iconColor = selected ? AppColors.surface : AppColors.textSecondary;

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

/// Side item: centered; label always visible under icon.
/// Active: primary chip + white icon; bold label.
/// Selection box integrated with proper padding.
class _SideItem extends StatelessWidget {
  final Widget icon;
  final String label;
  final bool selected;
  final TextStyle selectedStyle;
  final TextStyle unselectedStyle;
  final int? badgeCount;
  final double chipDiameter;
  final double glassHeight;
  final bool isSmallScreen;
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
    this.isSmallScreen = false,
    this.badgeCount,
    this.chipDiameter = 38,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final chipColor = selected ? AppColors.primary : AppColors.mintBgLight;
    final labelStyle = selected ? selectedStyle : unselectedStyle;

    // Responsive padding & margin
    final selectionMargin = isSmallScreen ? 3.0 : 5.0;
    final selectionPadding = isSmallScreen ? 3.0 : 5.0;
    final itemSpacing = isSmallScreen ? 2.0 : 4.0;

    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
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
            color: AppColors.primary.withOpacity(.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.primary.withOpacity(.32),
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
                    // Centered icon chip with flexible sizing
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
                              color: AppColors.primary.withOpacity(.25),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
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
                    // Label with proper constraints and flexible text
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
                // Badge positioning responsive
                if (badgeCount != null && badgeCount! > 0)
                  Positioned(
                    right: selected
                        ? (isSmallScreen ? 4 : 8)
                        : (isSmallScreen ? 8 : 12),
                    top: selected
                        ? (isSmallScreen ? 0 : 2)
                        : (isSmallScreen ? 4 : 6),
                    child: _Badge(
                      count: badgeCount!,
                      isSmallScreen: isSmallScreen,
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

/// Center hero: floating gradient button (label intentionally hidden).
class _CenterHero extends StatelessWidget {
  final bool active;
  final AnimationController pulse;
  final double size;
  final VoidCallback onTap;

  const _CenterHero({
    Key? key,
    required this.active,
    required this.pulse,
    required this.size,
    required this.onTap,
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
                    color: AppColors.primary.withOpacity(ringOpacity),
                    blurRadius: 26,
                    spreadRadius: 2,
                  ),
                  BoxShadow(
                    color: AppColors.deep.withOpacity(.10),
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
                  gradient: const LinearGradient(
                    colors: [AppColors.primary, AppColors.secondary],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withOpacity(.30),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                  border: Border.all(
                    color: AppColors.mintBgLight.withOpacity(.55),
                    width: 1,
                  ),
                ),
                child: const _SendMeGlyph(),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// "Send Me" glyph: location target + outbound motion.
class _SendMeGlyph extends StatelessWidget {
  const _SendMeGlyph({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: const [
        Icon(Icons.location_on, color: AppColors.surface, size: 22),
        Positioned(
          right: 10,
          top: 10,
          child: Icon(Icons.directions_walk_sharp, color: AppColors.surface, size: 20),
        ),
      ],
    );
  }
}

/// Thin sine wave stroke for subtle motion (no fill)
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

/// Badge using only AppColors with responsive sizing
class _Badge extends StatelessWidget {
  final int count;
  final bool isSmallScreen;

  const _Badge({
    required this.count,
    this.isSmallScreen = false,
  });

  @override
  Widget build(BuildContext context) {
    final txt = count > 99 ? '99+' : '$count';
    final fontSize = isSmallScreen ? 9.0 : 10.0;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isSmallScreen ? 4 : 6,
        vertical: isSmallScreen ? 1 : 2,
      ),
      constraints: BoxConstraints(
        minWidth: isSmallScreen ? 16 : 20,
        minHeight: isSmallScreen ? 14 : 16,
      ),
      decoration: BoxDecoration(
        color: AppColors.error,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surface, width: 1),
      ),
      child: Text(
        txt,
        style: (Theme.of(context).textTheme.labelSmall ??
            AppTextStyles.caption.copyWith(fontSize: fontSize))
            .copyWith(
          color: AppColors.onErrorColor,
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}