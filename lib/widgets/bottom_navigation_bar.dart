// lib/widgets/bottom_navigation_bar.dart
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';

/// TRANSPARENT FLOATING NAV BAR (glass, strokes only)
/// - Responsive to User vs Driver modes
/// - Labels UNDER icons (always visible) for side items
/// - Center hero button adapts to "SEND" or "HOME"
/// - Icons larger, centered; layout responsive & overflow-safe
/// - Unified active styling
class CustomBottomNavBar extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final VoidCallback? onCenterAction;
  final List<int?> badges;
  final bool isDriver; // <-- NEW: Determines which menu to show

  const CustomBottomNavBar({
    Key? key,
    required this.currentIndex,
    required this.onTap,
    this.onCenterAction,
    this.badges = const [null, null, null, null, null],
    this.isDriver = false, // Defaults to user if not provided
  }) : super(key: key);

  @override
  State<CustomBottomNavBar> createState() => _CustomBottomNavBarState();
}

class _CustomBottomNavBarState extends State<CustomBottomNavBar>
    with TickerProviderStateMixin {
  late final AnimationController _wave =
  AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  late final AnimationController _pulse =
  AnimationController(vsync: this, duration: const Duration(milliseconds: 3500))
    ..repeat(reverse: true);

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

    // Dynamically set labels based on user type
    final labels = widget.isDriver
        ? ['My Ride', 'Transaction', 'Home', 'Settings', 'Profile']
        : ['Street Ride', 'Campus Ride', 'Send Me', 'Dispatch', 'Profile'];

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
                                      icon: _iconForIndex(i, selected, kIcon, isDark, cs, widget.isDriver),
                                      label: labels[i],
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

                  // 💎 MATURE, PREMIUM CENTER HERO (Adapts to Send or Home)
                  Positioned(
                    bottom: uiScale.inset(8),
                    left: 0,
                    right: 0,
                    child: _PremiumCenterHero(
                      active: widget.currentIndex == 2,
                      pulse: _pulse,
                      size: kHero,
                      label: widget.isDriver ? 'HOME' : 'SEND',
                      iconData: widget.isDriver ? Icons.space_dashboard_rounded : Icons.near_me_rounded,
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

  Widget _iconForIndex(int index, bool selected, double size, bool isDark, ColorScheme cs, bool isDriver) {
    final Color iconColor = selected
        ? (isDark ? cs.onPrimary : AppColors.surface)
        : (isDark ? cs.onSurfaceVariant : AppColors.textSecondary);

    // DRIVER ICONS
    if (isDriver) {
      switch (index) {
        case 0:
          return Icon(Icons.local_taxi_rounded, size: size, color: iconColor);
        case 1:
          return Icon(Icons.receipt_long_rounded, size: size, color: iconColor);
        case 3:
          return Icon(Icons.settings_rounded, size: size, color: iconColor);
        case 4:
          return Icon(Icons.person_rounded, size: size, color: iconColor);
        default:
          return Icon(Icons.circle, size: size, color: iconColor);
      }
    }
    // USER ICONS
    else {
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

// ---------------------------------------------------------
// THE MATURE & PREMIUM CENTER HERO (DYNAMIC)
// ---------------------------------------------------------

class _PremiumCenterHero extends StatefulWidget {
  final bool active;
  final AnimationController pulse;
  final double size;
  final String label;
  final IconData iconData;
  final VoidCallback onTap;
  final bool isDark;
  final ColorScheme cs;

  const _PremiumCenterHero({
    Key? key,
    required this.active,
    required this.pulse,
    required this.size,
    required this.label,
    required this.iconData,
    required this.onTap,
    required this.isDark,
    required this.cs,
  }) : super(key: key);

  @override
  State<_PremiumCenterHero> createState() => _PremiumCenterHeroState();
}

class _PremiumCenterHeroState extends State<_PremiumCenterHero>
    with SingleTickerProviderStateMixin {

  late AnimationController _radarCtrl;

  @override
  void initState() {
    super.initState();
    _radarCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3500),
    );
    if (widget.active) _radarCtrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _PremiumCenterHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _radarCtrl.repeat();
    } else if (!widget.active && oldWidget.active) {
      _radarCtrl.stop();
    }
  }

  @override
  void dispose() {
    _radarCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = widget.isDark ? widget.cs.primary : AppColors.primary;

    return AnimatedBuilder(
      animation: Listenable.merge([widget.pulse, _radarCtrl]),
      builder: (_, __) {
        final scaleBase = widget.active ? 1.05 : 1.0;
        final breath = widget.active ? (widget.pulse.value * 0.03) : 0.0;
        final currentScale = scaleBase + breath;

        final ring1Scale = 1.0 + (widget.pulse.value * 0.4);
        final ring1Opacity = widget.active ? (1.0 - widget.pulse.value) * 0.3 : 0.0;

        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // 🌟 1. ELEGANT SONAR RIPPLES
            if (widget.active) ...[
              Transform.scale(
                scale: ring1Scale,
                child: Container(
                  width: widget.size * 1.5,
                  height: widget.size * 1.5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: primaryColor.withOpacity(ring1Opacity),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              Container(
                width: widget.size * 1.3,
                height: widget.size * 1.3,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withOpacity(0.25),
                      blurRadius: 40,
                      spreadRadius: 8,
                    ),
                  ],
                ),
              ),
            ],

            // 💎 2. MAIN BUTTON
            GestureDetector(
              onTapDown: (_) => HapticFeedback.mediumImpact(),
              onTap: widget.onTap,
              child: Transform.scale(
                scale: currentScale,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.isDark ? const Color(0xFF1A1A1A) : Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(widget.isDark ? 0.6 : 0.15),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                    border: Border.all(
                      color: widget.isDark
                          ? widget.cs.outline.withOpacity(0.3)
                          : AppColors.mintBgLight,
                      width: 1.5,
                    ),
                  ),
                  child: ClipOval(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // 📡 3. RADAR SWEEP
                        if (widget.active)
                          Transform.rotate(
                            angle: _radarCtrl.value * 2 * math.pi,
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: SweepGradient(
                                  colors: [
                                    Colors.transparent,
                                    primaryColor.withOpacity(0.05),
                                    primaryColor.withOpacity(0.4),
                                    Colors.transparent,
                                  ],
                                  stops: const [0.0, 0.5, 0.95, 1.0],
                                ),
                              ),
                            ),
                          ),

                        // 🎯 4. DYNAMIC ICON & TEXT
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(height: 2),
                            Stack(
                              alignment: Alignment.center,
                              children: [
                                if (widget.active)
                                  Icon(
                                    widget.iconData,
                                    size: 28,
                                    color: primaryColor.withOpacity(0.6),
                                  ).wrapWithBlur(sigma: 4),

                                Icon(
                                  widget.iconData,
                                  size: 28,
                                  color: widget.active
                                      ? primaryColor
                                      : (widget.isDark ? widget.cs.onSurfaceVariant : AppColors.textSecondary),
                                ),
                              ],
                            ),

                            const SizedBox(height: 4),

                            Text(
                              widget.label,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2.5,
                                color: widget.active
                                    ? primaryColor
                                    : (widget.isDark ? widget.cs.onSurfaceVariant : AppColors.textSecondary),
                              ),
                            ),
                          ],
                        ),

                        // 🪞 5. TOP GLASS REFLECTION
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: widget.size * 0.4,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white.withOpacity(widget.isDark ? 0.1 : 0.4),
                                  Colors.white.withOpacity(0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// Extension to cleanly apply blur
extension WidgetBlurExtension on Widget {
  Widget wrapWithBlur({double sigma = 2.0}) {
    return ImageFilterWidget(sigma: sigma, child: this);
  }
}

class ImageFilterWidget extends StatelessWidget {
  final double sigma;
  final Widget child;

  const ImageFilterWidget({Key? key, required this.sigma, required this.child}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: child,
    );
  }
}

// ---------------------------------------------------------
// EXISTING PAINTERS AND WIDGETS
// ---------------------------------------------------------

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