// lib/driver/widgets/active_ride_card.dart
//
// Bottom panel for the driver's current job: who/where, earnings and the one
// legal next step (state machine in driver_models.dart). Actions are pinned
// below the scrollable details so they never scroll out of reach.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;
import 'package:url_launcher/url_launcher.dart';

import '../../themes/app_theme.dart';
import '../../ui/ui_scale.dart';
import '../state/driver_models.dart';

class ActiveRideCard extends StatelessWidget {
  final RideJob ride;
  final UIScale uiScale;
  final double maxHeight;

  /// Action currently in flight (spinner + all buttons disabled).
  final DriverRideAction? pendingAction;
  final bool otpVerified;
  final ValueChanged<DriverRideAction> onAction;
  final VoidCallback onNavigate;

  const ActiveRideCard({
    super.key,
    required this.ride,
    required this.uiScale,
    required this.maxHeight,
    required this.pendingAction,
    required this.otpVerified,
    required this.onAction,
    required this.onNavigate,
  });

  static final intl.NumberFormat _money = intl.NumberFormat('#,##0.00', 'en_US');

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
                child: Image.network(imageUrl, fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_rounded, color: Colors.white, size: 48)),
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

  String _primaryLabel(DriverRideAction action) {
    switch (action) {
      case DriverRideAction.arrivedPickup:
        return ride.isLogistics ? 'Arrived at pickup' : 'Arrived for rider';
      case DriverRideAction.startTrip:
        return ride.isLogistics ? 'Package collected · start' : 'Start trip';
      case DriverRideAction.arrivedDestination:
        return 'Arrived at destination';
      case DriverRideAction.complete:
        return ride.requiresDeliveryOtp && !otpVerified ? 'Verify PIN & complete' : 'Complete trip';
      case DriverRideAction.cancel:
        return 'Cancel trip';
    }
  }

  IconData _primaryIcon(DriverRideAction action) {
    switch (action) {
      case DriverRideAction.arrivedPickup:
        return Icons.where_to_vote_rounded;
      case DriverRideAction.startTrip:
        return Icons.play_arrow_rounded;
      case DriverRideAction.arrivedDestination:
        return Icons.flag_rounded;
      case DriverRideAction.complete:
        return ride.requiresDeliveryOtp && !otpVerified ? Icons.pin_rounded : Icons.check_circle_rounded;
      case DriverRideAction.cancel:
        return Icons.close_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final os = cs.onSurface;
    final isDark = theme.brightness == Brightness.dark;
    final status = ride.rideStatus;

    final rawType = ride.rideType;
    final isDispatch = ride.isDispatch;
    final isSendMe = ride.isSendMe;
    final displayTitle = rawType.replaceAll('_', ' ').toUpperCase();
    Color badgeColor = AppColors.primary;
    IconData typeIcon = Icons.local_taxi_rounded;
    if (isDispatch) {
      badgeColor = Colors.brown.shade600;
      typeIcon = Icons.inventory_2_rounded;
    } else if (isSendMe) {
      badgeColor = Colors.orange.shade600;
      typeIcon = Icons.shopping_bag_rounded;
    } else if (rawType == 'campus_ride') {
      badgeColor = Colors.blue.shade600;
      typeIcon = Icons.school_rounded;
    } else if (rawType == 'street_ride') {
      badgeColor = Colors.green.shade600;
      typeIcon = Icons.signpost_rounded;
    }

    final originLabel = isDispatch ? 'SENDER' : (isSendMe ? 'REQUESTER / CUSTOMER' : 'RIDER');
    final destLabel = isDispatch ? 'RECEIVER' : (isSendMe ? 'TASK DESTINATION' : 'DROPOFF POINT');
    final riderPhone = ride.riderPhone ?? '';
    final receiverPhone = ride.recipientPhone ?? '';
    final showReceiverCall = ride.isLogistics && receiverPhone.isNotEmpty && receiverPhone != riderPhone;
    final currency = ride.currency;
    final payMethod = ride.payMethod.toUpperCase();
    final isWallet = payMethod == 'WALLET';
    final image = ride.packageImage;
    final instructions = ride.instructions;

    final primary = status.primaryAction;
    final busy = pendingAction != null;
    final canCancel = status.allows(DriverRideAction.cancel);

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: isDark ? cs.surface : Colors.white,
        borderRadius: BorderRadius.circular(uiScale.radius(24)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 20, offset: const Offset(0, 8))],
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3), width: 1.0),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(uiScale.inset(16), uiScale.inset(16), uiScale.inset(16), uiScale.inset(8)),
              physics: const BouncingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Header ────────────────────────────────────
                  Row(
                    children: [
                      Expanded(
                        child: Text('Active $displayTitle',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: os, fontSize: uiScale.font(14), fontWeight: FontWeight.w900, letterSpacing: 0.3)),
                      ),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: uiScale.inset(10), vertical: uiScale.inset(4)),
                        decoration: BoxDecoration(color: badgeColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(typeIcon, color: badgeColor, size: uiScale.icon(12)),
                          SizedBox(width: uiScale.gap(6)),
                          Text(status.label, style: TextStyle(color: badgeColor, fontSize: uiScale.font(10), fontWeight: FontWeight.w800)),
                        ]),
                      ),
                    ],
                  ),

                  if (ride.requiresDeliveryOtp) ...[
                    SizedBox(height: uiScale.gap(12)),
                    Container(
                      padding: EdgeInsets.all(uiScale.inset(8)),
                      decoration: BoxDecoration(
                        color: (otpVerified ? Colors.green : Colors.orange).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(uiScale.radius(8)),
                      ),
                      child: Row(children: [
                        Icon(otpVerified ? Icons.verified_rounded : Icons.shield_rounded,
                            color: otpVerified ? Colors.green.shade700 : Colors.orange.shade700, size: uiScale.icon(14)),
                        SizedBox(width: uiScale.gap(8)),
                        Expanded(
                          child: Text(
                            otpVerified
                                ? 'Delivery PIN verified. Complete the drop-off.'
                                : 'Collect the recipient\'s secure PIN at the destination to complete.',
                            style: TextStyle(
                                color: otpVerified ? Colors.green.shade800 : Colors.orange.shade800,
                                fontSize: uiScale.font(10),
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ]),
                    ),
                  ],

                  SizedBox(height: uiScale.gap(16)),

                  if (isDispatch && image != null && image.isNotEmpty) ...[
                    GestureDetector(
                      onTap: () => _showFullImage(context, image),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(uiScale.radius(12)),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Image.network(
                              image,
                              width: double.infinity,
                              height: uiScale.gap(120),
                              fit: BoxFit.cover,
                              cacheHeight: 360,
                              errorBuilder: (_, __, ___) => Container(
                                  height: uiScale.gap(120), color: cs.surfaceContainerHighest, child: const Center(child: Icon(Icons.inventory_2_rounded))),
                            ),
                            Container(
                                padding: const EdgeInsets.all(8),
                                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                child: const Icon(Icons.fullscreen_rounded, color: Colors.white, size: 24)),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: uiScale.gap(8)),
                    Text('${(ride.packageSize ?? 'PACKAGE').toUpperCase()} · ${ride.packageWeight.toStringAsFixed(1)}kg',
                        style: TextStyle(color: os.withValues(alpha: 0.6), fontSize: uiScale.font(10), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                    SizedBox(height: uiScale.gap(16)),
                  ],

                  if (instructions != null && instructions.isNotEmpty) ...[
                    Container(
                      padding: EdgeInsets.all(uiScale.inset(12)),
                      decoration: BoxDecoration(
                        color: isSendMe ? badgeColor.withValues(alpha: 0.1) : (isDark ? Colors.black26 : Colors.grey.shade100),
                        borderRadius: BorderRadius.circular(uiScale.radius(12)),
                        border: Border.all(
                            color: isSendMe ? badgeColor.withValues(alpha: 0.3) : cs.outlineVariant.withValues(alpha: 0.5),
                            width: isSendMe ? 1.0 : 0.5),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(isSendMe ? Icons.assignment_rounded : Icons.info_outline_rounded,
                                size: uiScale.icon(14), color: isSendMe ? badgeColor : os.withValues(alpha: 0.6)),
                            SizedBox(width: uiScale.gap(6)),
                            Text(isSendMe ? 'TASK INSTRUCTIONS' : 'NOTE',
                                style: TextStyle(
                                    color: isSendMe ? badgeColor : os.withValues(alpha: 0.7),
                                    fontSize: uiScale.font(9),
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.5)),
                          ]),
                          SizedBox(height: uiScale.gap(6)),
                          Text(instructions,
                              style: TextStyle(
                                  color: os.withValues(alpha: 0.9),
                                  fontSize: uiScale.font(12),
                                  fontWeight: isSendMe ? FontWeight.w600 : FontWeight.w500,
                                  height: 1.4)),
                        ],
                      ),
                    ),
                    SizedBox(height: uiScale.gap(16)),
                  ],

                  // ── Stops ─────────────────────────────────────
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(children: [
                        Icon(Icons.radio_button_checked, color: badgeColor, size: uiScale.icon(16)),
                        Container(width: 2, height: uiScale.gap(45), color: os.withValues(alpha: 0.15)),
                        Icon(Icons.location_on, color: Colors.red.shade600, size: uiScale.icon(16)),
                      ]),
                      SizedBox(width: uiScale.gap(12)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(originLabel,
                                style: TextStyle(color: os.withValues(alpha: 0.5), fontSize: uiScale.font(8), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                            Text(ride.pickupText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: os, fontSize: uiScale.font(13), fontWeight: FontWeight.w800)),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(ride.riderName.isNotEmpty ? ride.riderName : (isDispatch ? 'Sender' : 'Customer'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: os.withValues(alpha: 0.6), fontSize: uiScale.font(11), fontWeight: FontWeight.w600)),
                                ),
                                if (riderPhone.isNotEmpty)
                                  _CallChip(
                                    uiScale: uiScale,
                                    color: badgeColor,
                                    label: isDispatch ? 'Call Sender' : 'Call Customer',
                                    onTap: () => _call(context, riderPhone),
                                  ),
                              ],
                            ),
                            SizedBox(height: uiScale.gap(16)),
                            Text(destLabel,
                                style: TextStyle(color: os.withValues(alpha: 0.5), fontSize: uiScale.font(8), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                            Text(ride.destText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: os, fontSize: uiScale.font(13), fontWeight: FontWeight.w800)),
                            if (showReceiverCall)
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(isDispatch ? 'Receiver' : 'Contact',
                                        style: TextStyle(color: os.withValues(alpha: 0.6), fontSize: uiScale.font(11), fontWeight: FontWeight.w600)),
                                  ),
                                  _CallChip(
                                    uiScale: uiScale,
                                    color: Colors.blue,
                                    label: isDispatch ? 'Call Receiver' : 'Call Contact',
                                    onTap: () => _call(context, receiverPhone),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  SizedBox(height: uiScale.gap(16)),

                  // ── Earnings ──────────────────────────────────
                  Container(
                    padding: EdgeInsets.all(uiScale.inset(14)),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.black26 : Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(uiScale.radius(16)),
                      border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('TOTAL FARE',
                                style: TextStyle(color: os.withValues(alpha: 0.5), fontSize: uiScale.font(9), fontWeight: FontWeight.w800, letterSpacing: 1.0)),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: (isWallet ? Colors.blue : Colors.orange).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: (isWallet ? Colors.blue : Colors.orange).withValues(alpha: 0.3)),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(isWallet ? Icons.account_balance_wallet_rounded : Icons.payments_rounded,
                                    color: isWallet ? Colors.blue : Colors.orange.shade700, size: uiScale.icon(10)),
                                const SizedBox(width: 4),
                                Text(payMethod,
                                    style: TextStyle(
                                        color: isWallet ? Colors.blue : Colors.orange.shade700,
                                        fontSize: uiScale.font(9),
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.5)),
                              ]),
                            ),
                          ],
                        ),
                        Text('$currency ${_money.format(ride.price)}',
                            style: TextStyle(color: os, fontSize: uiScale.font(20), fontWeight: FontWeight.w900)),
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: uiScale.gap(12)),
                          child: Divider(color: cs.outlineVariant.withValues(alpha: 0.4), height: 1, thickness: 1),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('YOUR EARNINGS (${(100 - ride.appFeePercentage).toStringAsFixed(0)}%)',
                                  style: TextStyle(color: Colors.green, fontSize: uiScale.font(8.5), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                              Text('$currency ${_money.format(ride.driverEarnings)}',
                                  style: TextStyle(color: Colors.green, fontSize: uiScale.font(14), fontWeight: FontWeight.w900)),
                            ]),
                            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              Text('APP FEE (${ride.appFeePercentage.toStringAsFixed(0)}%)',
                                  style: TextStyle(color: os.withValues(alpha: 0.5), fontSize: uiScale.font(8.5), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                              Text('$currency ${_money.format(ride.appFee)}',
                                  style: TextStyle(color: os.withValues(alpha: 0.7), fontSize: uiScale.font(14), fontWeight: FontWeight.w800)),
                            ]),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Pinned actions ──────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(uiScale.inset(16), uiScale.inset(4), uiScale.inset(16), uiScale.inset(14)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (primary != null)
                  SizedBox(
                    width: double.infinity,
                    height: uiScale.gap(50),
                    child: ElevatedButton.icon(
                      onPressed: busy ? null : () => onAction(primary),
                      icon: pendingAction == primary
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Icon(_primaryIcon(primary), size: uiScale.icon(18)),
                      label: Text(_primaryLabel(primary),
                          style: TextStyle(fontSize: uiScale.font(14), fontWeight: FontWeight.w900, letterSpacing: 0.3)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: badgeColor,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: badgeColor.withValues(alpha: 0.5),
                        disabledForegroundColor: Colors.white70,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(14))),
                      ),
                    ),
                  ),
                SizedBox(height: uiScale.gap(8)),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onNavigate,
                        icon: Icon(Icons.navigation_rounded, size: uiScale.icon(16)),
                        label: Text('Navigate', style: TextStyle(fontSize: uiScale.font(12.5), fontWeight: FontWeight.w800)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: badgeColor,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(12))),
                        ),
                      ),
                    ),
                    if (canCancel) ...[
                      SizedBox(width: uiScale.gap(8)),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: busy ? null : () => onAction(DriverRideAction.cancel),
                          icon: pendingAction == DriverRideAction.cancel
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                              : Icon(Icons.close_rounded, size: uiScale.icon(16)),
                          label: Text('Cancel', style: TextStyle(fontSize: uiScale.font(12.5), fontWeight: FontWeight.w800)),
                          style: TextButton.styleFrom(foregroundColor: Colors.red.shade600),
                        ),
                      ),
                    ],
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

class _CallChip extends StatelessWidget {
  final UIScale uiScale;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _CallChip({required this.uiScale, required this.color, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.call, color: color, size: uiScale.icon(12)),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: uiScale.font(10))),
          ]),
        ),
      ),
    );
  }
}
