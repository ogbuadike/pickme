import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../driver/state/driver_models.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';

/// A ride offer shown to an online driver.
///
/// [isAccepting] shows the spinner on this card; [enabled] = false greys out
/// the buttons while another card's request is in flight. When [expiresAt] is
/// set a countdown bar is shown (the controller owns the actual expiry).
class IncomingRequestCard extends StatelessWidget {
  final RideJob ride;
  final UIScale uiScale;
  final bool isAccepting;
  final VoidCallback onAccept;
  final VoidCallback? onDecline;
  final bool enabled;
  final DateTime? expiresAt;
  final Duration offerWindow;
  final bool countdownPaused;

  /// Straight-line distance from the driver to the pickup, when known.
  final double? distanceToPickupMeters;

  const IncomingRequestCard({
    super.key,
    required this.ride,
    required this.uiScale,
    required this.isAccepting,
    required this.onAccept,
    this.onDecline,
    this.enabled = true,
    this.expiresAt,
    this.offerWindow = const Duration(seconds: 30),
    this.countdownPaused = false,
    this.distanceToPickupMeters,
  });

  static final NumberFormat _money = NumberFormat('#,##0.00', 'en_US');

  void _showFullImage(BuildContext context, String imageUrl) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.all(uiScale.inset(12)),
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(uiScale.radius(16)),
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_rounded, color: Colors.white, size: 48),
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white, size: 32),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _call(BuildContext context, String? phone) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final clean = (phone ?? '').replaceAll(RegExp(r'[^\d+]'), '');
    if (clean.isEmpty) {
      messenger?.showSnackBar(const SnackBar(content: Text('Phone number not available.')));
      return;
    }
    final ok = await launchUrl(Uri(scheme: 'tel', path: clean));
    if (!ok) messenger?.showSnackBar(const SnackBar(content: Text('Could not open the dialer.')));
  }

  static String _formatDistance(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final os = cs.onSurface;
    final isDark = theme.brightness == Brightness.dark;

    final rideType = ride.rideType;
    final displayTitle = rideType.replaceAll('_', ' ').toUpperCase();
    Color badgeColor = AppColors.primary;
    IconData typeIcon = Icons.local_taxi_rounded;
    if (ride.isDispatch) {
      badgeColor = Colors.brown.shade600;
      typeIcon = Icons.inventory_2_rounded;
    } else if (ride.isSendMe) {
      badgeColor = Colors.orange.shade600;
      typeIcon = Icons.shopping_bag_rounded;
    } else if (rideType == 'campus_ride') {
      badgeColor = Colors.blue.shade600;
      typeIcon = Icons.school_rounded;
    } else if (rideType == 'street_ride') {
      badgeColor = Colors.green.shade600;
      typeIcon = Icons.signpost_rounded;
    }

    final currency = ride.currency;
    final buttonsEnabled = enabled && !isAccepting;
    final image = ride.packageImage;
    final instructions = ride.instructions;
    final distance = distanceToPickupMeters;

    return Container(
      margin: EdgeInsets.only(bottom: uiScale.gap(16)),
      decoration: BoxDecoration(
        color: isDark ? cs.surface : Colors.white,
        borderRadius: BorderRadius.circular(uiScale.radius(20)),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4), width: 1.0),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (expiresAt != null)
            _OfferCountdown(
              key: ValueKey('countdown_${ride.id}'),
              expiresAt: expiresAt!,
              window: offerWindow,
              paused: countdownPaused || isAccepting,
              color: badgeColor,
            ),
          // ── 1. HEADER & BADGE ────────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(uiScale.inset(14), uiScale.inset(14), uiScale.inset(14), 0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(typeIcon, color: badgeColor, size: uiScale.icon(12)),
                      SizedBox(width: uiScale.gap(4)),
                      Text(displayTitle,
                          style: TextStyle(color: badgeColor, fontSize: uiScale.font(10), fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                    ],
                  ),
                ),
                const Spacer(),
                Text('$currency ${_money.format(ride.price)}',
                    style: TextStyle(color: os, fontSize: uiScale.font(16), fontWeight: FontWeight.w900)),
              ],
            ),
          ),

          // ── 2. CUSTOMER ──────────────────────────────────────────
          Padding(
            padding: EdgeInsets.all(uiScale.inset(14)),
            child: Row(
              children: [
                CircleAvatar(
                  radius: uiScale.radius(18),
                  backgroundColor: cs.surfaceContainerHighest,
                  child: Icon(Icons.person_rounded, color: os.withValues(alpha: 0.5), size: uiScale.icon(20)),
                ),
                SizedBox(width: uiScale.gap(12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ride.riderName.isNotEmpty ? ride.riderName : 'Customer',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: os, fontSize: uiScale.font(14), fontWeight: FontWeight.w800),
                      ),
                      Text(
                        [
                          if (distance != null) '${_formatDistance(distance)} to pickup',
                          ride.payMethod.toUpperCase(),
                        ].join(' · '),
                        style: TextStyle(color: os.withValues(alpha: 0.6), fontSize: uiScale.font(10), fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                if (ride.isSendMe && (ride.riderPhone ?? '').isNotEmpty)
                  Container(
                    margin: EdgeInsets.only(left: uiScale.gap(8)),
                    decoration: BoxDecoration(
                      color: Colors.green.shade600.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.green.shade600.withValues(alpha: 0.3), width: 1.5),
                    ),
                    child: IconButton(
                      tooltip: 'Call sender',
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints(minWidth: uiScale.icon(38), minHeight: uiScale.icon(38)),
                      icon: Icon(Icons.phone_rounded, color: Colors.green.shade700, size: uiScale.icon(18)),
                      onPressed: () => _call(context, ride.riderPhone),
                    ),
                  ),
              ],
            ),
          ),

          // ── 3. DISPATCH PACKAGE ──────────────────────────────────
          if (ride.isDispatch && image != null && image.isNotEmpty) ...[
            Padding(
              padding: EdgeInsets.symmetric(horizontal: uiScale.inset(14)),
              child: GestureDetector(
                onTap: () => _showFullImage(context, image),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(uiScale.radius(12)),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Image.network(
                        image,
                        width: double.infinity,
                        height: uiScale.gap(100),
                        fit: BoxFit.cover,
                        cacheHeight: 300,
                        errorBuilder: (_, __, ___) => Container(
                          height: uiScale.gap(100),
                          color: cs.surfaceContainerHighest,
                          child: const Center(child: Icon(Icons.inventory_2_rounded)),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                        child: const Icon(Icons.fullscreen_rounded, color: Colors.white, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: uiScale.gap(8)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: uiScale.inset(14)),
              child: Text(
                '${(ride.packageSize ?? 'PACKAGE').toUpperCase()} · ${ride.packageWeight.toStringAsFixed(1)}kg',
                style: TextStyle(color: os.withValues(alpha: 0.6), fontSize: uiScale.font(10), fontWeight: FontWeight.w800),
              ),
            ),
            SizedBox(height: uiScale.gap(12)),
          ],

          if (instructions != null && instructions.isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: uiScale.inset(14)),
              child: Container(
                padding: EdgeInsets.all(uiScale.inset(10)),
                decoration: BoxDecoration(
                  color: isDark ? Colors.black26 : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5), width: 0.5),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, size: uiScale.icon(14), color: os.withValues(alpha: 0.6)),
                    SizedBox(width: uiScale.gap(8)),
                    Expanded(
                      child: Text(
                        'Note: $instructions',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: os.withValues(alpha: 0.8), fontSize: uiScale.font(11), fontStyle: FontStyle.italic),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          SizedBox(height: uiScale.gap(12)),

          // ── 4. ROUTE ─────────────────────────────────────────────
          Padding(
            padding: EdgeInsets.symmetric(horizontal: uiScale.inset(14)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    Icon(Icons.radio_button_checked, color: badgeColor, size: uiScale.icon(14)),
                    Container(width: 2, height: uiScale.gap(25), color: os.withValues(alpha: 0.15)),
                    Icon(Icons.location_on, color: Colors.red.shade600, size: uiScale.icon(14)),
                  ],
                ),
                SizedBox(width: uiScale.gap(10)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(ride.pickupText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: os, fontSize: uiScale.font(12), fontWeight: FontWeight.w700)),
                      SizedBox(height: uiScale.gap(18)),
                      Text(ride.destText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: os, fontSize: uiScale.font(12), fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: uiScale.gap(16)),
          Divider(height: 1, thickness: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),

          // ── 5. EARNINGS & ACTIONS ────────────────────────────────
          Container(
            padding: EdgeInsets.all(uiScale.inset(14)),
            color: isDark ? Colors.black12 : Colors.grey.shade50,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('YOUR EARNINGS',
                            style: TextStyle(color: Colors.green.shade700, fontSize: uiScale.font(9), fontWeight: FontWeight.w900)),
                        Text('$currency ${_money.format(ride.driverEarnings)}',
                            style: TextStyle(color: Colors.green.shade700, fontSize: uiScale.font(14), fontWeight: FontWeight.w900)),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('APP FEE (${ride.appFeePercentage.toStringAsFixed(0)}%)',
                            style: TextStyle(color: os.withValues(alpha: 0.5), fontSize: uiScale.font(9), fontWeight: FontWeight.w800)),
                        Text('$currency ${_money.format(ride.appFee)}',
                            style: TextStyle(color: os.withValues(alpha: 0.7), fontSize: uiScale.font(13), fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ],
                ),
                SizedBox(height: uiScale.gap(16)),
                Row(
                  children: [
                    if (onDecline != null) ...[
                      SizedBox(
                        height: uiScale.gap(48),
                        child: OutlinedButton(
                          onPressed: buttonsEnabled ? onDecline : null,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: os.withValues(alpha: 0.8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(12))),
                          ),
                          child: Text('Decline', style: TextStyle(fontSize: uiScale.font(13), fontWeight: FontWeight.w800)),
                        ),
                      ),
                      SizedBox(width: uiScale.gap(10)),
                    ],
                    Expanded(
                      child: SizedBox(
                        height: uiScale.gap(48),
                        child: ElevatedButton(
                          onPressed: buttonsEnabled ? onAccept : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: badgeColor,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(12))),
                          ),
                          child: isAccepting
                              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                              : Text('Accept $displayTitle',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: uiScale.font(13), fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Thin progress bar + seconds label that drains until [expiresAt].
/// Purely visual; driven by an AnimationController (no periodic timers).
class _OfferCountdown extends StatefulWidget {
  final DateTime expiresAt;
  final Duration window;
  final bool paused;
  final Color color;

  const _OfferCountdown({super.key, required this.expiresAt, required this.window, required this.paused, required this.color});

  @override
  State<_OfferCountdown> createState() => _OfferCountdownState();
}

class _OfferCountdownState extends State<_OfferCountdown> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this);

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _OfferCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expiresAt != widget.expiresAt || oldWidget.paused != widget.paused || oldWidget.window != widget.window) {
      _sync();
    }
  }

  void _sync() {
    final windowMs = widget.window.inMilliseconds;
    final remaining = widget.expiresAt.difference(DateTime.now());
    final remainingMs = remaining.inMilliseconds.clamp(0, windowMs);
    _ctrl.value = windowMs == 0 ? 0 : remainingMs / windowMs;
    if (widget.paused || remainingMs == 0) {
      _ctrl.stop();
    } else {
      _ctrl.animateTo(0, duration: Duration(milliseconds: remainingMs), curve: Curves.linear);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final secs = (_ctrl.value * widget.window.inSeconds).ceil();
        final urgent = secs <= 5;
        final color = urgent ? Colors.red.shade600 : widget.color;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(
              value: _ctrl.value,
              minHeight: 4,
              color: color,
              backgroundColor: color.withValues(alpha: 0.12),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              child: Text(
                widget.paused ? 'Holding offer…' : 'Respond in ${secs}s',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: color),
              ),
            ),
          ],
        );
      },
    );
  }
}
