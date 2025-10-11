// lib/screens/home/widgets/header_bar.dart
//
// Premium, responsive header:
// - Avatar (menu) + greeting
// - Notification action
// - Wallet action with subtle scanner/pulse animation
// - Consistent scaling via _ResponsiveMetrics
// - Safe avatar loading (no asset dependency)
// - Clean tooltips, a11y, haptics, and shadows

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../themes/app_theme.dart';

class HeaderBar extends StatefulWidget {
  final Map<String, dynamic>? user;
  final bool busyProfile;
  final VoidCallback onMenu;
  final VoidCallback onWallet;
  final VoidCallback onNotifications;

  const HeaderBar({
    super.key,
    required this.user,
    required this.busyProfile,
    required this.onMenu,
    required this.onWallet,
    required this.onNotifications,
  });

  @override
  State<HeaderBar> createState() => _HeaderBarState();
}

class _HeaderBarState extends State<HeaderBar> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  _ResponsiveMetrics _metricsOf(BuildContext context) {
    final mq = MediaQuery.of(context);
    final w = mq.size.width;
    final h = mq.size.height;
    final shortest = math.min(w, h);
    final base = (shortest / 390.0).clamp(0.75, 1.15);
    final textScale = mq.textScaleFactor.clamp(0.85, 1.25);
    return _ResponsiveMetrics(
      scale: base.toDouble(),
      textScale: textScale.toDouble(),
      isLandscape: mq.orientation == Orientation.landscape,
      safeTop: mq.padding.top,
    );
  }

  String? _safeAvatarUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final u = url.toLowerCase();
    if (!u.startsWith('http')) return null;
    if (u.contains('icon-library.com')) return null; // avoid noisy SSL
    return url;
  }

  @override
  Widget build(BuildContext context) {
    final m = _metricsOf(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final name = (widget.user?['user_lname'] ?? widget.user?['user_name'] ?? 'Rider').toString();
    final avatarUrl = _safeAvatarUrl(widget.user?['user_logo'] as String?);

    final textColor = isDark ? Colors.white : AppColors.textPrimary;
    final subColor  = isDark ? Colors.white.withOpacity(.80) : AppColors.textSecondary.withOpacity(.90);

    final bg   = isDark ? Colors.white.withOpacity(.06) : theme.cardColor;
    final brdr = isDark ? AppColors.outline.withOpacity(.18) : AppColors.mintBgLight.withOpacity(.30);

    return Padding(
      padding: EdgeInsets.fromLTRB(12 * m.scale, 6 * m.scale, 12 * m.scale, 6 * m.scale),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10 * m.scale, vertical: 6 * m.scale),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(26 * m.scale),
          border: Border.all(color: brdr, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? .22 : .08),
              blurRadius: 12 * m.scale,
              offset: Offset(0, 6 * m.scale),
            ),
          ],
        ),
        child: Row(
          children: [
            _AvatarButton(
              size: 36 * m.scale,
              networkUrl: avatarUrl,
              busy: widget.busyProfile,
              onTap: () {
                HapticFeedback.selectionClick();
                widget.onMenu();
              },
              metrics: m,
            ),
            SizedBox(width: 10 * m.scale),
            Expanded(child: _Greeting(name: name, textColor: textColor, subColor: subColor, metrics: m)),
            SizedBox(width: 6 * m.scale),
            _HeaderAction(
              tooltip: 'Notifications',
              icon: Icons.notifications_none_rounded,
              onTap: () {
                HapticFeedback.selectionClick();
                widget.onNotifications();
              },
              size: 34 * m.scale,
              metrics: m,
              isDark: isDark,
            ),
            SizedBox(width: 6 * m.scale),
            _WalletButton(
              tooltip: 'Fund account',
              onTap: () {
                HapticFeedback.selectionClick();
                widget.onWallet();
              },
              size: 34 * m.scale,
              metrics: m,
              isDark: isDark,
              pulseCtrl: _pulseCtrl,
              textColor: textColor,
            ),
          ],
        ),
      ),
    );
  }
}

class _ResponsiveMetrics {
  final double scale;
  final double textScale;
  final bool isLandscape;
  final double safeTop;
  const _ResponsiveMetrics({
    required this.scale,
    required this.textScale,
    required this.isLandscape,
    required this.safeTop,
  });
}

class _Greeting extends StatelessWidget {
  final String name;
  final Color textColor;
  final Color subColor;
  final _ResponsiveMetrics metrics;
  const _Greeting({
    required this.name,
    required this.textColor,
    required this.subColor,
    required this.metrics,
  });

  String _partOfDay() {
    final h = DateTime.now().hour;
    if (h < 12) return 'morning';
    if (h < 17) return 'afternoon';
    return 'evening';
  }

  @override
  Widget build(BuildContext context) {
    final tight = MediaQuery.of(context).size.width < 360;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!tight)
          Text(
            'Good ${_partOfDay()}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: subColor,
              fontSize: (9.5 * metrics.scale * metrics.textScale).clamp(8.0, 11.0),
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
            ),
          ),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: textColor,
            fontSize: (13 * metrics.scale * metrics.textScale).clamp(12.0, 16.0),
            fontWeight: FontWeight.w800,
            letterSpacing: -0.25,
          ),
        ),
      ],
    );
  }
}

class _AvatarButton extends StatelessWidget {
  final double size;
  final String? networkUrl;
  final bool busy;
  final VoidCallback onTap;
  final _ResponsiveMetrics metrics;
  const _AvatarButton({
    required this.size,
    required this.networkUrl,
    required this.busy,
    required this.onTap,
    required this.metrics,
  });

  @override
  Widget build(BuildContext context) {
    Widget avatarCore;
    if (networkUrl != null && networkUrl!.isNotEmpty) {
      avatarCore = ClipOval(
        child: Image.network(
          networkUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _PlaceholderAvatar(size: size),
        ),
      );
    } else {
      avatarCore = _PlaceholderAvatar(size: size);
    }

    return Semantics(
      button: true,
      label: 'Open menu',
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(.9), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(.18),
                    blurRadius: 8 * metrics.scale,
                    offset: Offset(0, 3.5 * metrics.scale),
                  ),
                ],
              ),
              child: avatarCore,
            ),
            if (busy)
              Positioned(
                right: -2.0 * metrics.scale,
                top: -2.0 * metrics.scale,
                child: Container(
                  width: 10.0 * metrics.scale,
                  height: 10.0 * metrics.scale,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.4),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primary.withOpacity(0.45),
                        blurRadius: 3.5 * metrics.scale,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlaceholderAvatar extends StatelessWidget {
  final double size;
  const _PlaceholderAvatar({required this.size});
  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: Colors.white.withOpacity(.7),
      child: const Icon(Icons.person, color: Colors.black54),
    );
  }
}

class _HeaderAction extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final _ResponsiveMetrics metrics;
  final bool isDark;
  final bool isScannerMode;
  final AnimationController? pulseCtrl;

  const _HeaderAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    required this.size,
    required this.metrics,
    required this.isDark,
    this.isScannerMode = false,
    this.pulseCtrl,
  });

  @override
  State<_HeaderAction> createState() => _HeaderActionState();
}

class _HeaderActionState extends State<_HeaderAction> with SingleTickerProviderStateMixin {
  late final AnimationController _scaleCtrl =
  AnimationController(vsync: this, duration: const Duration(milliseconds: 160));

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  void _down(TapDownDetails _) => _scaleCtrl.forward();
  void _up(TapUpDetails _) {
    _scaleCtrl.reverse();
    widget.onTap();
  }

  void _cancel() => _scaleCtrl.reverse();

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final bg = isDark ? Colors.white.withOpacity(.08) : Colors.white;
    final iconColor = isDark ? Colors.white : AppColors.deep;
    final borderColor = isDark ? Colors.white.withOpacity(.14) : AppColors.mintBgLight.withOpacity(.45);

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: GestureDetector(
        onTapDown: _down,
        onTapUp: _up,
        onTapCancel: _cancel,
        child: ScaleTransition(
          scale: Tween<double>(begin: 1, end: 0.86).animate(
            CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOut),
          ),
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(color: borderColor, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? .16 : .08),
                  blurRadius: 7 * widget.metrics.scale,
                  offset: Offset(0, 2.5 * widget.metrics.scale),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 18 * widget.metrics.scale, color: iconColor),
          ),
        ),
      ),
    );
  }
}

class _WalletButton extends StatefulWidget {
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  final _ResponsiveMetrics metrics;
  final bool isDark;
  final AnimationController pulseCtrl;
  final Color textColor;

  const _WalletButton({
    required this.tooltip,
    required this.onTap,
    required this.size,
    required this.metrics,
    required this.isDark,
    required this.pulseCtrl,
    required this.textColor,
  });

  @override
  State<_WalletButton> createState() => _WalletButtonState();
}

class _WalletButtonState extends State<_WalletButton> with SingleTickerProviderStateMixin {
  late final AnimationController _scaleCtrl =
  AnimationController(vsync: this, duration: const Duration(milliseconds: 160));

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  void _down(TapDownDetails _) => _scaleCtrl.forward();
  void _up(TapUpDetails _) {
    _scaleCtrl.reverse();
    widget.onTap();
  }

  void _cancel() => _scaleCtrl.reverse();

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final bg = isDark ? Colors.white.withOpacity(.08) : Colors.white;
    final borderColor = isDark ? Colors.white.withOpacity(.14) : AppColors.mintBgLight.withOpacity(.45);
    final iconColor = isDark ? Colors.white : AppColors.deep;

    final ringSize = widget.size * 0.64;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: GestureDetector(
        onTapDown: _down,
        onTapUp: _up,
        onTapCancel: _cancel,
        child: ScaleTransition(
          scale: Tween<double>(begin: 1, end: 0.86).animate(
            CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOut),
          ),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 9 * widget.metrics.scale, vertical: 5 * widget.metrics.scale),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12 * widget.metrics.scale),
              border: Border.all(color: borderColor, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? .16 : .08),
                  blurRadius: 7 * widget.metrics.scale,
                  offset: Offset(0, 2.5 * widget.metrics.scale),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: ringSize,
                  height: ringSize,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: widget.pulseCtrl,
                        builder: (context, _) {
                          final t = widget.pulseCtrl.value;
                          return Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.primary.withOpacity((1 - t) * 0.40),
                                width: 1.2,
                              ),
                            ),
                          );
                        },
                      ),
                      Icon(Icons.wallet_rounded, size: 16 * widget.metrics.scale, color: iconColor),
                    ],
                  ),
                ),
                SizedBox(width: 6 * widget.metrics.scale),
                Text(
                  'Wallet',
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: (12 * widget.metrics.scale * widget.metrics.textScale).clamp(11.0, 14.0),
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.1,
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
