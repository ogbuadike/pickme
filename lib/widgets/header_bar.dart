// lib/screens/home/widgets/header_bar.dart
//
// ─── PRODUCTION-GRADE HEADER BAR ───────────────────────────────────────────
//  • Self-contained active-task detection via SharedPreferences ride cache.
//    Zero prop-drilling required — reads the EXACT same cache key that
//    RideHistoryScreen writes, so the alert appears instantly on mount.
//  • Reactive: refreshes whenever the widget is rebuilt (tab switch, resume)
//    and every 15 seconds via a background ticker for live accuracy.
//  • Red pulsing ALERT PILL replaces notification icon when tasks are pending.
//  • Retains all original functionality: avatar, greeting, wallet button.
//  • Full a11y, haptics, responsive scaling, dark/light theming.
// ────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../themes/app_theme.dart';
import '../routes/routes.dart';

// ─── Active status set — mirrors RideHistoryScreen exactly ───────────────────
const _kActiveStatuses = {
  'searching',
  'accepted',
  'enroute_pickup',
  'arrived_pickup',
  'in_progress',
  'in_ride',
  'driver_arriving',
  'driver_assigned',
  'arrived_destination',
};

// ─── Cache refresh interval ───────────────────────────────────────────────────
const _kRefreshInterval = Duration(seconds: 15);

// ─── Default logo fallback ────────────────────────────────────────────────────
const _kDefaultLogoUrl = 'https://phantomphones.store/pick_me/img/logo.png';

// ═════════════════════════════════════════════════════════════════════════════
//  HeaderBar
// ═════════════════════════════════════════════════════════════════════════════
class HeaderBar extends StatefulWidget {
  final Map<String, dynamic>? user;
  final bool busyProfile;

  /// Optional external override. When null (default), HeaderBar derives the
  /// value autonomously from the SharedPreferences ride cache.
  final bool? hasActiveTask;

  final VoidCallback onMenu;
  final VoidCallback onWallet;
  final VoidCallback onNotifications;

  const HeaderBar({
    super.key,
    required this.user,
    required this.busyProfile,
    this.hasActiveTask,               // optional override
    required this.onMenu,
    required this.onWallet,
    required this.onNotifications,
  });

  @override
  State<HeaderBar> createState() => _HeaderBarState();
}

class _HeaderBarState extends State<HeaderBar>
    with SingleTickerProviderStateMixin {

  // ── Animation ──────────────────────────────────────────────────────────────
  late final AnimationController _pulseCtrl;

  // ── Derived active-task state ──────────────────────────────────────────────
  bool _derivedHasActiveTask = false;
  int  _activeTaskCount       = 0;
  Timer? _refreshTimer;

  // ── Unified resolved flag ──────────────────────────────────────────────────
  bool get _hasActiveTask =>
      widget.hasActiveTask ?? _derivedHasActiveTask;

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    // Immediate cache read — no await spinner; UI renders default then snaps.
    _refreshFromCache();

    // Periodic background refresh for live accuracy.
    _refreshTimer = Timer.periodic(_kRefreshInterval, (_) {
      if (mounted) _refreshFromCache();
    });
  }

  @override
  void didUpdateWidget(HeaderBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-check whenever parent rebuilds (e.g. tab switch returns to home).
    _refreshFromCache();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _refreshTimer?.cancel();
    super.dispose();
  }

  // ─── Cache reader ────────────────────────────────────────────────────────
  Future<void> _refreshFromCache() async {
    // Only runs the autonomous path when parent hasn't provided an override.
    if (widget.hasActiveTask != null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final isDriver = prefs.getBool('user_is_driver') ?? false;
      final cacheKey = 'ride_history_${isDriver ? "driver" : "rider"}';
      final raw = prefs.getString(cacheKey);

      if (raw == null || raw.isEmpty) {
        _applyTaskState(false, 0);
        return;
      }

      final decoded = jsonDecode(raw) as List<dynamic>;
      int count = 0;
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final s = (item['status'] ?? '').toString().toLowerCase();
          if (_kActiveStatuses.contains(s)) count++;
        }
      }

      _applyTaskState(count > 0, count);
    } catch (_) {
      // Silently fail — never crash the header.
    }
  }

  void _applyTaskState(bool hasTask, int count) {
    if (!mounted) return;
    if (_derivedHasActiveTask == hasTask && _activeTaskCount == count) return;
    setState(() {
      _derivedHasActiveTask = hasTask;
      _activeTaskCount       = count;
    });
  }

  // ─── Metrics ──────────────────────────────────────────────────────────────
  _ResponsiveMetrics _metricsOf(BuildContext context) {
    final mq = MediaQuery.of(context);
    final shortest = math.min(mq.size.width, mq.size.height);
    final base = (shortest / 390.0).clamp(0.75, 1.15);
    return _ResponsiveMetrics(
      scale:       base.toDouble(),
      textScale:   mq.textScaleFactor.clamp(0.85, 1.25).toDouble(),
      isLandscape: mq.orientation == Orientation.landscape,
      safeTop:     mq.padding.top,
    );
  }

  // ─── Avatar URL sanitiser ─────────────────────────────────────────────────
  String? _safeAvatarUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final u = url.toLowerCase();
    if (!u.startsWith('http')) return null;
    if (u.contains('icon-library.com')) return null;
    return url;
  }

  // ─── Navigation ───────────────────────────────────────────────────────────
  void _openRideHistory() {
    HapticFeedback.heavyImpact();
    Navigator.pushNamed(context, AppRoutes.rideHistory).then((_) {
      // Refresh after returning — status may have changed.
      _refreshFromCache();
    });
  }

  // ─── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final m      = _metricsOf(context);
    final theme  = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs     = theme.colorScheme;

    final name      = (widget.user?['user_lname'] ??
        widget.user?['user_name'] ?? 'Rider').toString();
    final avatarUrl = _safeAvatarUrl(widget.user?['user_logo'] as String?);

    final textColor = isDark ? cs.onSurface       : AppColors.textPrimary;
    final subColor  = isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(.90);
    final bg        = isDark ? cs.surface          : theme.cardColor;
    final brdr      = isDark ? cs.outline          : AppColors.mintBgLight.withOpacity(.30);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        12 * m.scale, 6 * m.scale, 12 * m.scale, 6 * m.scale,
      ),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 10 * m.scale, vertical: 6 * m.scale,
        ),
        decoration: BoxDecoration(
          color:        bg,
          borderRadius: BorderRadius.circular(26 * m.scale),
          border:       Border.all(color: brdr, width: 1),
          boxShadow: [
            BoxShadow(
              color:      Colors.black.withOpacity(isDark ? .40 : .08),
              blurRadius: 12 * m.scale,
              offset:     Offset(0, 6 * m.scale),
            ),
          ],
        ),
        child: Row(
          children: [
            // ── Avatar / Menu ──────────────────────────────────────────────
            _AvatarButton(
              size:       36 * m.scale,
              networkUrl: avatarUrl,
              busy:       widget.busyProfile,
              onTap: () {
                HapticFeedback.selectionClick();
                widget.onMenu();
              },
              metrics: m,
              isDark:  isDark,
              cs:      cs,
            ),
            SizedBox(width: 10 * m.scale),

            // ── Greeting ───────────────────────────────────────────────────
            Expanded(
              child: _Greeting(
                name:      name,
                textColor: textColor,
                subColor:  subColor,
                metrics:   m,
              ),
            ),
            SizedBox(width: 6 * m.scale),

            // ── ALERT PILL  ↔  Notification icon (mutually exclusive) ──────
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              switchInCurve:  Curves.elasticOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: anim,
                child: FadeTransition(opacity: anim, child: child),
              ),
              child: _hasActiveTask
                  ? _ActiveTaskAlertPill(
                key:        const ValueKey('alert_pill'),
                onTap:      _openRideHistory,
                activeCount: _activeTaskCount,
                height:     34 * m.scale,
                metrics:    m,
                pulseCtrl:  _pulseCtrl,
              )
                  : _HeaderAction(
                key:     const ValueKey('notif_btn'),
                tooltip: 'Ride History',
                icon:    Icons.notifications_none_rounded,
                onTap: () {
                  HapticFeedback.selectionClick();
                  _openRideHistory();
                },
                size:    34 * m.scale,
                metrics: m,
                isDark:  isDark,
                cs:      cs,
              ),
            ),

            SizedBox(width: 6 * m.scale),

            // ── Wallet ─────────────────────────────────────────────────────
            _WalletButton(
              tooltip:   'Fund account',
              onTap: () {
                HapticFeedback.selectionClick();
                widget.onWallet();
              },
              size:      34 * m.scale,
              metrics:   m,
              isDark:    isDark,
              cs:        cs,
              pulseCtrl: _pulseCtrl,
              textColor: textColor,
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  Responsive Metrics
// ═════════════════════════════════════════════════════════════════════════════
class _ResponsiveMetrics {
  final double scale;
  final double textScale;
  final bool   isLandscape;
  final double safeTop;

  const _ResponsiveMetrics({
    required this.scale,
    required this.textScale,
    required this.isLandscape,
    required this.safeTop,
  });
}

// ═════════════════════════════════════════════════════════════════════════════
//  Greeting
// ═════════════════════════════════════════════════════════════════════════════
class _Greeting extends StatelessWidget {
  final String             name;
  final Color              textColor;
  final Color              subColor;
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
      mainAxisSize:       MainAxisSize.min,
      children: [
        if (!tight)
          Text(
            'Good ${_partOfDay()}',
            maxLines:  1,
            overflow:  TextOverflow.ellipsis,
            style: TextStyle(
              color:       subColor,
              fontSize:    (9.5 * metrics.scale * metrics.textScale).clamp(8.0, 11.0),
              fontWeight:  FontWeight.w600,
              letterSpacing: -0.1,
            ),
          ),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color:         textColor,
            fontSize:      (13 * metrics.scale * metrics.textScale).clamp(12.0, 16.0),
            fontWeight:    FontWeight.w800,
            letterSpacing: -0.25,
          ),
        ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  Avatar Button
// ═════════════════════════════════════════════════════════════════════════════
class _AvatarButton extends StatelessWidget {
  final double             size;
  final String?            networkUrl;
  final bool               busy;
  final VoidCallback       onTap;
  final _ResponsiveMetrics metrics;
  final bool               isDark;
  final ColorScheme        cs;

  const _AvatarButton({
    required this.size,
    required this.networkUrl,
    required this.busy,
    required this.onTap,
    required this.metrics,
    required this.isDark,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    Widget avatarCore = networkUrl != null && networkUrl!.isNotEmpty
        ? ClipOval(
      child: Image.network(
        networkUrl!,
        width:   size,
        height:  size,
        fit:     BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            _PlaceholderAvatar(size: size, isDark: isDark, cs: cs),
      ),
    )
        : _PlaceholderAvatar(size: size, isDark: isDark, cs: cs);

    return Semantics(
      button: true,
      label:  'Open menu',
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width:  size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isDark ? cs.primary : Colors.white.withOpacity(.9),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color:      Colors.black.withOpacity(isDark ? .40 : .18),
                    blurRadius: 8 * metrics.scale,
                    offset:     Offset(0, 3.5 * metrics.scale),
                  ),
                ],
              ),
              child: avatarCore,
            ),
            if (busy)
              Positioned(
                right: -2.0 * metrics.scale,
                top:   -2.0 * metrics.scale,
                child: Container(
                  width:  10.0 * metrics.scale,
                  height: 10.0 * metrics.scale,
                  decoration: BoxDecoration(
                    color:  isDark ? cs.primary : AppColors.primary,
                    shape:  BoxShape.circle,
                    border: Border.all(
                      color: isDark ? cs.surface : Colors.white,
                      width: 1.4,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (isDark ? cs.primary : AppColors.primary)
                            .withOpacity(0.45),
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
  final double      size;
  final bool        isDark;
  final ColorScheme cs;

  const _PlaceholderAvatar({
    required this.size,
    required this.isDark,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius:          size / 2,
      backgroundColor: isDark ? cs.surfaceVariant : Colors.white.withOpacity(.7),
      child: Icon(
        Icons.person,
        color: isDark ? cs.onSurfaceVariant : Colors.black54,
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  Active Task Alert Pill  ← THE CORE INNOVATION
//
//  Replaces the notification icon when pending rides exist.
//  • Sinusoidal red pulse on background + glow shadow.
//  • Count badge when >1 active task.
//  • Press scale feedback.
//  • Animated entry via AnimatedSwitcher in parent.
// ═════════════════════════════════════════════════════════════════════════════
class _ActiveTaskAlertPill extends StatefulWidget {
  final VoidCallback       onTap;
  final int                activeCount;
  final double             height;
  final _ResponsiveMetrics metrics;
  final AnimationController pulseCtrl;

  const _ActiveTaskAlertPill({
    super.key,
    required this.onTap,
    required this.activeCount,
    required this.height,
    required this.metrics,
    required this.pulseCtrl,
  });

  @override
  State<_ActiveTaskAlertPill> createState() => _ActiveTaskAlertPillState();
}

class _ActiveTaskAlertPillState extends State<_ActiveTaskAlertPill>
    with SingleTickerProviderStateMixin {

  late final AnimationController _pressCtrl = AnimationController(
    vsync:    this,
    duration: const Duration(milliseconds: 140),
  );

  @override
  void dispose() {
    _pressCtrl.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) => _pressCtrl.forward();
  void _onTapUp(TapUpDetails _) {
    _pressCtrl.reverse();
    widget.onTap();
  }
  void _onTapCancel() => _pressCtrl.reverse();

  @override
  Widget build(BuildContext context) {
    final m = widget.metrics;

    return Semantics(
      button: true,
      label:  'Pending task — tap to view ride history',
      child: Tooltip(
        message:       'You have ${widget.activeCount} pending task${widget.activeCount > 1 ? "s" : ""} — tap to manage',
        preferBelow:   true,
        waitDuration:  const Duration(milliseconds: 300),
        child: GestureDetector(
          onTapDown:   _onTapDown,
          onTapUp:     _onTapUp,
          onTapCancel: _onTapCancel,
          child: ScaleTransition(
            scale: Tween<double>(begin: 1.0, end: 0.88).animate(
              CurvedAnimation(parent: _pressCtrl, curve: Curves.easeOut),
            ),
            child: AnimatedBuilder(
              animation: widget.pulseCtrl,
              builder: (context, _) {
                // Smooth sinusoidal pulse — 0..1..0
                final pulse = math.sin(widget.pulseCtrl.value * math.pi);

                return Container(
                  height:  widget.height,
                  padding: EdgeInsets.symmetric(horizontal: 10 * m.scale),
                  decoration: BoxDecoration(
                    // Interpolate between two red shades
                    color: Color.lerp(
                      const Color(0xFFDC2626),   // red-600
                      const Color(0xFFEF4444),   // red-500 brighter
                      pulse,
                    ),
                    borderRadius: BorderRadius.circular(12 * m.scale),
                    border: Border.all(
                      color: Colors.red.shade200.withOpacity(0.55 + 0.25 * pulse),
                      width: 1.5,
                    ),
                    boxShadow: [
                      // Inner soft glow
                      BoxShadow(
                        color:       Colors.red.withOpacity(0.30 + 0.35 * pulse),
                        blurRadius:  6 + 10 * pulse,
                        spreadRadius: 0 + 2 * pulse,
                      ),
                      // Outer dramatic halo at peak pulse
                      BoxShadow(
                        color:       Colors.redAccent.withOpacity(0.15 * pulse),
                        blurRadius:  20 * pulse,
                        spreadRadius: 4 * pulse,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Animated warning icon — scales subtly with pulse
                      Transform.scale(
                        scale: 1.0 + 0.08 * pulse,
                        child: Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.white,
                          size:  16 * m.scale,
                        ),
                      ),
                      SizedBox(width: 5 * m.scale),
                      Text(
                        'PENDING',
                        style: TextStyle(
                          color:         Colors.white,
                          fontWeight:    FontWeight.w900,
                          fontSize:      (11 * m.scale * m.textScale).clamp(10.0, 13.0),
                          letterSpacing: 0.6,
                        ),
                      ),
                      // Count badge — only shown when >1
                      if (widget.activeCount > 1) ...[
                        SizedBox(width: 5 * m.scale),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 5 * m.scale,
                            vertical:   1.5 * m.scale,
                          ),
                          decoration: BoxDecoration(
                            color:        Colors.white.withOpacity(0.25),
                            borderRadius: BorderRadius.circular(20),
                            border:       Border.all(
                              color: Colors.white.withOpacity(0.50),
                              width: 1,
                            ),
                          ),
                          child: Text(
                            '${widget.activeCount}',
                            style: TextStyle(
                              color:         Colors.white,
                              fontWeight:    FontWeight.w900,
                              fontSize:      (9.5 * m.scale).clamp(8.5, 11.0),
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  Header Action (Notification icon — shown when no active tasks)
// ═════════════════════════════════════════════════════════════════════════════
class _HeaderAction extends StatefulWidget {
  final String             tooltip;
  final IconData           icon;
  final VoidCallback       onTap;
  final double             size;
  final _ResponsiveMetrics metrics;
  final bool               isDark;
  final ColorScheme        cs;

  const _HeaderAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onTap,
    required this.size,
    required this.metrics,
    required this.isDark,
    required this.cs,
  });

  @override
  State<_HeaderAction> createState() => _HeaderActionState();
}

class _HeaderActionState extends State<_HeaderAction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scaleCtrl = AnimationController(
    vsync:    this,
    duration: const Duration(milliseconds: 160),
  );

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  void _down(TapDownDetails _) => _scaleCtrl.forward();
  void _up(TapUpDetails _) { _scaleCtrl.reverse(); widget.onTap(); }
  void _cancel() => _scaleCtrl.reverse();

  @override
  Widget build(BuildContext context) {
    final bg          = widget.isDark ? widget.cs.surfaceVariant : Colors.white;
    final iconColor   = widget.isDark ? widget.cs.primary        : AppColors.deep;
    final borderColor = widget.isDark
        ? widget.cs.outline
        : AppColors.mintBgLight.withOpacity(.45);

    return Tooltip(
      message:      widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: GestureDetector(
        onTapDown:   _down,
        onTapUp:     _up,
        onTapCancel: _cancel,
        child: ScaleTransition(
          scale: Tween<double>(begin: 1, end: 0.86).animate(
            CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOut),
          ),
          child: Container(
            width:  widget.size,
            height: widget.size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color:  bg,
              shape:  BoxShape.circle,
              border: Border.all(color: borderColor, width: 1),
              boxShadow: [
                BoxShadow(
                  color:      Colors.black.withOpacity(widget.isDark ? .40 : .08),
                  blurRadius: 7 * widget.metrics.scale,
                  offset:     Offset(0, 2.5 * widget.metrics.scale),
                ),
              ],
            ),
            child: Icon(
              widget.icon,
              size:  18 * widget.metrics.scale,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  Wallet Button
// ═════════════════════════════════════════════════════════════════════════════
class _WalletButton extends StatefulWidget {
  final String             tooltip;
  final VoidCallback       onTap;
  final double             size;
  final _ResponsiveMetrics metrics;
  final bool               isDark;
  final ColorScheme        cs;
  final AnimationController pulseCtrl;
  final Color              textColor;

  const _WalletButton({
    required this.tooltip,
    required this.onTap,
    required this.size,
    required this.metrics,
    required this.isDark,
    required this.cs,
    required this.pulseCtrl,
    required this.textColor,
  });

  @override
  State<_WalletButton> createState() => _WalletButtonState();
}

class _WalletButtonState extends State<_WalletButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scaleCtrl = AnimationController(
    vsync:    this,
    duration: const Duration(milliseconds: 160),
  );

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  void _down(TapDownDetails _) => _scaleCtrl.forward();
  void _up(TapUpDetails _) { _scaleCtrl.reverse(); widget.onTap(); }
  void _cancel() => _scaleCtrl.reverse();

  @override
  Widget build(BuildContext context) {
    final bg          = widget.isDark ? widget.cs.surfaceVariant : Colors.white;
    final borderColor = widget.isDark
        ? widget.cs.outline
        : AppColors.mintBgLight.withOpacity(.45);
    final iconColor   = widget.isDark ? widget.cs.primary : AppColors.deep;
    final ringSize    = widget.size * 0.64;

    return Tooltip(
      message:      widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: GestureDetector(
        onTapDown:   _down,
        onTapUp:     _up,
        onTapCancel: _cancel,
        child: ScaleTransition(
          scale: Tween<double>(begin: 1, end: 0.86).animate(
            CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOut),
          ),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: 9 * widget.metrics.scale,
              vertical:   5 * widget.metrics.scale,
            ),
            decoration: BoxDecoration(
              color:        bg,
              borderRadius: BorderRadius.circular(12 * widget.metrics.scale),
              border:       Border.all(color: borderColor, width: 1),
              boxShadow: [
                BoxShadow(
                  color:      Colors.black.withOpacity(widget.isDark ? .40 : .08),
                  blurRadius: 7 * widget.metrics.scale,
                  offset:     Offset(0, 2.5 * widget.metrics.scale),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width:  ringSize,
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
                              shape:  BoxShape.circle,
                              border: Border.all(
                                color: (widget.isDark
                                    ? widget.cs.primary
                                    : AppColors.primary)
                                    .withOpacity((1 - t) * 0.40),
                                width: 1.2,
                              ),
                            ),
                          );
                        },
                      ),
                      Icon(
                        Icons.wallet_rounded,
                        size:  16 * widget.metrics.scale,
                        color: iconColor,
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 6 * widget.metrics.scale),
                Text(
                  'Wallet',
                  style: TextStyle(
                    color:         widget.textColor,
                    fontSize:      (12 * widget.metrics.scale * widget.metrics.textScale)
                        .clamp(11.0, 14.0),
                    fontWeight:    FontWeight.w800,
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