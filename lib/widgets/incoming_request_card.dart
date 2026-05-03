import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart'; // Ensure you have this package in pubspec.yaml
import '../ui/ui_scale.dart';
import '../themes/app_theme.dart';
import '../driver/state/driver_models.dart';

class IncomingRequestCard extends StatelessWidget {
  final RideJob ride;
  final UIScale uiScale;
  final bool isAccepting;
  final VoidCallback onAccept;

  const IncomingRequestCard({
    super.key,
    required this.ride,
    required this.uiScale,
    required this.isAccepting,
    required this.onAccept,
  });

  // ── Helper to launch full screen image ─────────────────────────
  void _showFullImage(BuildContext context, String imageUrl) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.all(uiScale.inset(12)),
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              panEnabled: true,
              boundaryMargin: EdgeInsets.zero,
              minScale: 1.0,
              maxScale: 4.0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(uiScale.radius(16)),
                child: Image.network(imageUrl, fit: BoxFit.contain),
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

  // ── Helper to place a phone call ───────────────────────────────
  Future<void> _callSender(BuildContext context, String? phone) async {
    if (phone == null || phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phone number not available.')),
      );
      return;
    }

    final cleanPhone = phone.replaceAll(RegExp(r'[^\d+]'), '');
    final uri = Uri.parse('tel:$cleanPhone');

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the dialer.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final os = cs.onSurface;
    final isDark = theme.brightness == Brightness.dark;

    final String rideType = ride.rideType.trim().toLowerCase();
    final bool isDispatch = rideType == 'dispatch';
    final bool isSendMe = rideType == 'send_me';
    final bool isCampus = rideType == 'campus_ride';
    final bool isStreet = rideType == 'street_ride';

    // Formatting titles and colors
    String displayTitle = rideType.replaceAll('_', ' ').toUpperCase();
    Color badgeColor = AppColors.primary;
    IconData typeIcon = Icons.local_taxi_rounded;

    if (isDispatch) {
      badgeColor = Colors.brown.shade600;
      typeIcon = Icons.inventory_2_rounded;
    } else if (isSendMe) {
      badgeColor = Colors.orange.shade600;
      typeIcon = Icons.shopping_bag_rounded;
    } else if (isCampus) {
      badgeColor = Colors.blue.shade600;
      typeIcon = Icons.school_rounded;
    } else if (isStreet) {
      badgeColor = Colors.green.shade600;
      typeIcon = Icons.signpost_rounded;
    }

    // Financial calculations
    final double feePercent = ride.appFeePercentage;
    final double totalFare = ride.price;
    final double appFee = totalFare * (feePercent / 100);
    final double driverEarnings = totalFare - appFee;
    final String currency = ride.currency;

    // Formatter to add commas (e.g. 1,500.00)
    final formatCurrency = NumberFormat('#,##0.00', 'en_US');

    return Container(
      margin: EdgeInsets.only(bottom: uiScale.gap(16)),
      decoration: BoxDecoration(
        color: isDark ? cs.surface : Colors.white,
        borderRadius: BorderRadius.circular(uiScale.radius(20)),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.4), width: 1.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 1. HEADER & BADGE ────────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(uiScale.inset(14), uiScale.inset(14), uiScale.inset(14), 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: badgeColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: badgeColor.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(typeIcon, color: badgeColor, size: uiScale.icon(12)),
                      SizedBox(width: uiScale.gap(4)),
                      Text(
                        displayTitle,
                        style: TextStyle(
                          color: badgeColor,
                          fontSize: uiScale.font(10),
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '$currency ${formatCurrency.format(totalFare)}',
                  style: TextStyle(
                    color: os,
                    fontSize: uiScale.font(16),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),

          // ── 2. RIDER PROFILE ─────────────────────────────────────
          Padding(
            padding: EdgeInsets.all(uiScale.inset(14)),
            child: Row(
              children: [
                CircleAvatar(
                  radius: uiScale.radius(18),
                  backgroundColor: cs.surfaceVariant,
                  child: Icon(Icons.person_rounded, color: os.withOpacity(0.5), size: uiScale.icon(20)),
                ),
                SizedBox(width: uiScale.gap(12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ride.riderName.isNotEmpty ? ride.riderName : 'Customer',
                        style: TextStyle(color: os, fontSize: uiScale.font(14), fontWeight: FontWeight.w800),
                      ),
                      Row(
                        children: [
                          Icon(Icons.star_rounded, color: Colors.orange, size: uiScale.icon(12)),
                          const SizedBox(width: 2),
                          Text(
                            '4.8', // Replace with dynamic rider rating if available
                            style: TextStyle(color: os.withOpacity(0.6), fontSize: uiScale.font(10), fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // ── NEW: CONDITIONAL CALL SENDER BUTTON ───────────────
                if (isSendMe)
                  Container(
                    margin: EdgeInsets.only(left: uiScale.gap(8)),
                    decoration: BoxDecoration(
                      color: Colors.green.shade600.withOpacity(0.12),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.green.shade600.withOpacity(0.3), width: 1.5),
                    ),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints(
                        minWidth: uiScale.icon(38),
                        minHeight: uiScale.icon(38),
                      ),
                      icon: Icon(Icons.phone_rounded, color: Colors.green.shade700, size: uiScale.icon(18)),
                      onPressed: () {
                        // Ensure 'riderPhone' matches the property name in your RideJob model
                        // Note: If your model uses 'phone' or 'senderPhone', update this below!
                        // (We use a cast to dynamic here to prevent a hard crash if the exact property name varies, but strong typing is preferred)
                        try {
                          final phoneToCall = (ride as dynamic).riderPhone?.toString();
                          _callSender(context, phoneToCall);
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Phone number property missing in model')),
                          );
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),

          // ── 3. DISPATCH SPECIFIC (IMAGES & PACKAGE INFO) ─────────
          if (isDispatch && ride.packageImage != null && ride.packageImage!.isNotEmpty) ...[
            Padding(
              padding: EdgeInsets.symmetric(horizontal: uiScale.inset(14)),
              child: GestureDetector(
                onTap: () => _showFullImage(context, ride.packageImage!),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(uiScale.radius(12)),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Image.network(
                        ride.packageImage!,
                        width: double.infinity,
                        height: uiScale.gap(100),
                        fit: BoxFit.cover,
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
            SizedBox(height: uiScale.gap(12)),
          ],

          // Instructions block (if any)
          if (ride.instructions != null && ride.instructions!.isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: uiScale.inset(14)),
              child: Container(
                padding: EdgeInsets.all(uiScale.inset(10)),
                decoration: BoxDecoration(
                  color: isDark ? Colors.black26 : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.outlineVariant.withOpacity(0.5), width: 0.5),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, size: uiScale.icon(14), color: os.withOpacity(0.6)),
                    SizedBox(width: uiScale.gap(8)),
                    Expanded(
                      child: Text(
                        'Note: ${ride.instructions}',
                        style: TextStyle(color: os.withOpacity(0.8), fontSize: uiScale.font(11), fontStyle: FontStyle.italic),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          SizedBox(height: uiScale.gap(12)),

          // ── 4. ROUTE LOCATIONS ───────────────────────────────────
          Padding(
            padding: EdgeInsets.symmetric(horizontal: uiScale.inset(14)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    Icon(Icons.radio_button_checked, color: badgeColor, size: uiScale.icon(14)),
                    Container(width: 2, height: uiScale.gap(25), color: os.withOpacity(0.15)),
                    Icon(Icons.location_on, color: Colors.red.shade600, size: uiScale.icon(14)),
                  ],
                ),
                SizedBox(width: uiScale.gap(10)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ride.pickupText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: os, fontSize: uiScale.font(12), fontWeight: FontWeight.w700),
                      ),
                      SizedBox(height: uiScale.gap(18)),
                      Text(
                        ride.destText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: os, fontSize: uiScale.font(12), fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: uiScale.gap(16)),
          Divider(height: 1, thickness: 1, color: cs.outlineVariant.withOpacity(0.3)),

          // ── 5. FINANCIAL BREAKDOWN & ACTION BUTTON ────────────────
          Container(
            padding: EdgeInsets.all(uiScale.inset(14)),
            decoration: BoxDecoration(
              color: isDark ? Colors.black12 : Colors.grey.shade50,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(uiScale.radius(20))),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'YOUR EARNINGS',
                          style: TextStyle(color: Colors.green.shade700, fontSize: uiScale.font(9), fontWeight: FontWeight.w900),
                        ),
                        Text(
                          '$currency ${formatCurrency.format(driverEarnings)}',
                          style: TextStyle(color: Colors.green.shade700, fontSize: uiScale.font(14), fontWeight: FontWeight.w900),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'APP FEE (${feePercent.toStringAsFixed(0)}%)',
                          style: TextStyle(color: os.withOpacity(0.5), fontSize: uiScale.font(9), fontWeight: FontWeight.w800),
                        ),
                        Text(
                          '$currency ${formatCurrency.format(appFee)}',
                          style: TextStyle(color: os.withOpacity(0.7), fontSize: uiScale.font(13), fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  ],
                ),
                SizedBox(height: uiScale.gap(16)),
                SizedBox(
                  width: double.infinity,
                  height: uiScale.gap(48),
                  child: ElevatedButton(
                    onPressed: isAccepting ? null : onAccept,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: badgeColor,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(12))),
                    ),
                    child: isAccepting
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : Text(
                      'Accept $displayTitle',
                      style: TextStyle(fontSize: uiScale.font(13), fontWeight: FontWeight.w900, letterSpacing: 0.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}