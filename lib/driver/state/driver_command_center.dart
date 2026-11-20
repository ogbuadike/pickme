// lib/driver/state/driver_command_center.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../themes/app_theme.dart';
import '../../ui/ui_scale.dart';
import '../../widgets/incoming_request_card.dart';
import 'driver_models.dart';
import 'driver_session_controller.dart' show DriverOffer, DriverSessionController;

class DriverCommandCenter extends StatelessWidget {
  final UIScale uiScale;
  final double height;
  final bool expanded;
  final DriverProfile? driver;
  final List<DriverOffer> offers;
  final DateTime? lastSyncAt;
  final DateTime? lastHeartbeatAt;
  final bool connected;
  final bool busyOnlineToggle;

  /// Ride whose accept request is in flight (spinner on that card only).
  final int? acceptingRideId;
  final LatLng? driverPosition;
  final VoidCallback onExpandToggle;
  final ValueChanged<bool> onOnlineToggle;
  final VoidCallback onWallet;
  final VoidCallback onHistory;
  final VoidCallback onProfile;
  final VoidCallback onRefresh;
  final ValueChanged<RideJob> onAccept;
  final ValueChanged<RideJob> onDecline;

  const DriverCommandCenter({
    super.key, required this.uiScale, required this.height, required this.expanded,
    required this.driver, required this.offers, required this.lastSyncAt, required this.lastHeartbeatAt,
    required this.connected, required this.busyOnlineToggle, required this.acceptingRideId,
    required this.driverPosition, required this.onExpandToggle, required this.onOnlineToggle,
    required this.onWallet, required this.onHistory, required this.onProfile, required this.onRefresh,
    required this.onAccept, required this.onDecline,
  });

  bool get _online => driver?.isOnline == true;

  String get _statusLine {
    if (driver == null) return 'Loading driver profile…';
    if (!_online) return 'You are offline. Go online to receive requests.';
    if (!connected) return 'Reconnecting… requests may be delayed.';
    if (offers.isEmpty) return 'Online · waiting for nearby requests';
    return offers.length == 1 ? '1 new request' : '${offers.length} new requests';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final statusColor = _online ? AppColors.primary : Colors.grey.shade600;
    final statusLabel = _online ? 'Online' : 'Offline';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      constraints: BoxConstraints(minHeight: expanded ? math.min(220, height) : 96, maxHeight: height),
      decoration: BoxDecoration(
        color: isDark ? cs.surface.withValues(alpha: 0.92) : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(28))),
        border: Border(top: BorderSide(color: isDark ? cs.outline.withValues(alpha: 0.5) : AppColors.mintBgLight, width: 1.5)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.6 : 0.15), blurRadius: 30, offset: const Offset(0, -10))],
      ),
      // No BackdropFilter: a full-width blur over a live GoogleMap re-rasterises
      // every map frame (jank on mid-range Android).
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(28))),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: expanded
              ? _buildExpanded(isDark, cs, statusColor, statusLabel)
              : _buildCollapsed(isDark, cs, statusColor, statusLabel),
        ),
      ),
    );
  }

  Widget _handle(bool isDark, ColorScheme cs) => Center(
        child: GestureDetector(
          onTap: onExpandToggle,
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: isDark ? cs.onSurfaceVariant.withValues(alpha: 0.5) : Colors.black12,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      );

  Widget _buildCollapsed(bool isDark, ColorScheme cs, Color statusColor, String statusLabel) {
    return Padding(
      key: const ValueKey('collapsed'),
      padding: EdgeInsets.fromLTRB(uiScale.inset(16), uiScale.gap(8), uiScale.inset(16), uiScale.gap(12)),
      child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _handle(isDark, cs),
          SizedBox(height: uiScale.gap(8)),
          Row(
            children: [
              Expanded(child: Text(_statusLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: uiScale.font(13.0), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary))),
              SizedBox(width: uiScale.gap(8)),
              _StatusDotChip(uiScale: uiScale, color: statusColor, label: statusLabel, isDark: isDark, cs: cs),
              IconButton(onPressed: onExpandToggle, constraints: const BoxConstraints(minWidth: 32, minHeight: 32), icon: Icon(Icons.keyboard_arrow_up_rounded, size: uiScale.icon(20), color: isDark ? cs.onSurface : AppColors.textPrimary)),
            ],
          ),
          SizedBox(height: uiScale.gap(6)),
          _CompactSummaryRow(uiScale: uiScale, driver: driver, lastSyncAt: lastSyncAt, lastHeartbeatAt: lastHeartbeatAt, queueCount: offers.length, dense: true, online: _online, busyOnlineToggle: busyOnlineToggle, onOnlineToggle: () => onOnlineToggle(!_online), isDark: isDark, cs: cs),
        ],
      ),
    );
  }

  Widget _buildExpanded(bool isDark, ColorScheme cs, Color statusColor, String statusLabel) {
    return ListView(
      key: const ValueKey('expanded'),
      padding: EdgeInsets.fromLTRB(uiScale.inset(16), uiScale.gap(8), uiScale.inset(16), uiScale.gap(20)),
      physics: const BouncingScrollPhysics(),
      children: [
        _handle(isDark, cs),
        SizedBox(height: uiScale.gap(12)),
        Row(
          children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Driver Terminal', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: uiScale.font(16.0), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary)),
              SizedBox(height: uiScale.gap(2)),
              Text(_statusLine, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: uiScale.font(11.5), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
            ])),
            _StatusDotChip(uiScale: uiScale, color: statusColor, label: statusLabel, isDark: isDark, cs: cs),
            IconButton(onPressed: onExpandToggle, visualDensity: VisualDensity.compact, icon: Icon(Icons.keyboard_arrow_down_rounded, color: isDark ? cs.onSurface : AppColors.textPrimary)),
          ],
        ),
        SizedBox(height: uiScale.gap(16)),
        _CompactSummaryRow(uiScale: uiScale, driver: driver, lastSyncAt: lastSyncAt, lastHeartbeatAt: lastHeartbeatAt, isDark: isDark, cs: cs),
        SizedBox(height: uiScale.gap(12)),
        _OnlineRow(uiScale: uiScale, online: _online, busy: busyOnlineToggle, onToggle: onOnlineToggle, isDark: isDark, cs: cs),
        SizedBox(height: uiScale.gap(12)),
        _QuickActionStrip(uiScale: uiScale, onWallet: onWallet, onHistory: onHistory, onProfile: onProfile, onRefresh: onRefresh, isDark: isDark, cs: cs),
        SizedBox(height: uiScale.gap(12)),
        _QueueCard(uiScale: uiScale, online: _online, offers: offers, acceptingRideId: acceptingRideId, driverPosition: driverPosition, onAccept: onAccept, onDecline: onDecline, isDark: isDark, cs: cs),
      ],
    );
  }
}

class _StatusDotChip extends StatelessWidget {
  final UIScale uiScale; final Color color; final String label; final bool isDark; final ColorScheme cs;
  const _StatusDotChip({required this.uiScale, required this.color, required this.label, required this.isDark, required this.cs});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: uiScale.inset(10), vertical: uiScale.inset(6)),
      decoration: BoxDecoration(color: color.withValues(alpha: isDark ? 0.15 : 0.10), borderRadius: BorderRadius.circular(999), border: Border.all(color: color.withValues(alpha: 0.3))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)), SizedBox(width: uiScale.gap(6)), Text(label, style: TextStyle(fontSize: uiScale.font(10.5), fontWeight: FontWeight.w900, color: color))]),
    );
  }
}

class _CompactSummaryRow extends StatelessWidget {
  final UIScale uiScale; final DriverProfile? driver; final DateTime? lastSyncAt; final DateTime? lastHeartbeatAt;
  final int queueCount; final bool dense; final bool online; final bool busyOnlineToggle; final VoidCallback? onOnlineToggle;
  final bool isDark; final ColorScheme cs;

  const _CompactSummaryRow({
    required this.uiScale, required this.driver, required this.lastSyncAt, required this.lastHeartbeatAt,
    this.queueCount = 0, this.dense = false, this.online = false, this.busyOnlineToggle = false, this.onOnlineToggle, required this.isDark, required this.cs,
  });

  String _fmtTime(DateTime? value) {
    if (value == null) return '—';
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${value.hour >= 12 ? 'PM' : 'AM'}';
  }

  @override
  Widget build(BuildContext context) {
    if (dense) {
      return SizedBox(
        height: 36,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal, physics: const BouncingScrollPhysics(),
          child: Row(children: [
            _DenseSummaryPill(uiScale: uiScale, label: 'Trips', value: '${driver?.completedTrips ?? 0}', isDark: isDark, cs: cs), SizedBox(width: uiScale.gap(6)),
            _DenseSummaryPill(uiScale: uiScale, label: 'Requests', value: '$queueCount', isDark: isDark, cs: cs), SizedBox(width: uiScale.gap(6)),
            _DenseSummaryPill(uiScale: uiScale, label: 'GPS', value: _fmtTime(lastHeartbeatAt), isDark: isDark, cs: cs), SizedBox(width: uiScale.gap(6)),
            _DenseTogglePill(uiScale: uiScale, online: online, busy: busyOnlineToggle, onTap: onOnlineToggle, isDark: isDark, cs: cs),
          ]),
        ),
      );
    }
    return SizedBox(
      height: uiScale.gap(68),
      child: ListView(
        scrollDirection: Axis.horizontal, physics: const BouncingScrollPhysics(),
        children: [
          _MiniMetricCard(uiScale: uiScale, label: 'Trips', value: '${driver?.completedTrips ?? 0}', hint: 'Completed', isDark: isDark, cs: cs), SizedBox(width: uiScale.gap(8)),
          _MiniMetricCard(uiScale: uiScale, label: 'Rating', value: (driver?.rating ?? 0).toStringAsFixed(2), hint: driver?.category ?? 'driver', isDark: isDark, cs: cs), SizedBox(width: uiScale.gap(8)),
          _MiniMetricCard(uiScale: uiScale, label: 'Sync', value: _fmtTime(lastSyncAt), hint: 'Server', isDark: isDark, cs: cs), SizedBox(width: uiScale.gap(8)),
          _MiniMetricCard(uiScale: uiScale, label: 'Live', value: _fmtTime(lastHeartbeatAt), hint: 'GPS', isDark: isDark, cs: cs),
        ],
      ),
    );
  }
}

class _DenseSummaryPill extends StatelessWidget {
  final UIScale uiScale; final String label; final String value; final bool isDark; final ColorScheme cs;
  const _DenseSummaryPill({required this.uiScale, required this.label, required this.value, required this.isDark, required this.cs});
  @override
  Widget build(BuildContext context) {
    return Container(padding: EdgeInsets.symmetric(horizontal: uiScale.inset(10), vertical: uiScale.inset(6)), decoration: BoxDecoration(color: isDark ? cs.surfaceContainerHighest.withValues(alpha: 0.5) : AppColors.mintBgLight.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(999), border: Border.all(color: isDark ? cs.outline.withValues(alpha: 0.5) : Colors.black.withValues(alpha: 0.05))), child: RichText(maxLines: 1, text: TextSpan(children: [TextSpan(text: '$label ', style: TextStyle(fontSize: uiScale.font(10.0), fontWeight: FontWeight.w700, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)), TextSpan(text: value, style: TextStyle(fontSize: uiScale.font(10.5), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary))])));
  }
}

class _DenseTogglePill extends StatelessWidget {
  final UIScale uiScale; final bool online; final bool busy; final VoidCallback? onTap; final bool isDark; final ColorScheme cs;
  const _DenseTogglePill({required this.uiScale, required this.online, required this.busy, required this.onTap, required this.isDark, required this.cs});
  @override
  Widget build(BuildContext context) {
    final color = online ? AppColors.primary : (isDark ? cs.onSurfaceVariant : AppColors.textSecondary);
    return Container(padding: EdgeInsets.symmetric(horizontal: uiScale.inset(6), vertical: uiScale.inset(2)), decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999), border: Border.all(color: color.withValues(alpha: 0.3))), child: Row(mainAxisSize: MainAxisSize.min, children: [Text(online ? 'Online' : 'Offline', style: TextStyle(fontSize: uiScale.font(10.0), fontWeight: FontWeight.w900, color: color)), SizedBox(width: uiScale.gap(2)), Transform.scale(scale: 0.62, child: Switch.adaptive(value: online, onChanged: busy || onTap == null ? null : (_) => onTap!.call(), activeThumbColor: AppColors.primary))]));
  }
}

class _MiniMetricCard extends StatelessWidget {
  final UIScale uiScale; final String label; final String value; final String hint; final bool isDark; final ColorScheme cs;
  const _MiniMetricCard({required this.uiScale, required this.label, required this.value, required this.hint, required this.isDark, required this.cs});
  @override
  Widget build(BuildContext context) {
    return Container(width: uiScale.gap(100), padding: EdgeInsets.symmetric(horizontal: uiScale.inset(12), vertical: uiScale.inset(10)), decoration: BoxDecoration(color: isDark ? cs.surfaceContainerHighest.withValues(alpha: 0.3) : AppColors.mintBgLight.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(16), border: Border.all(color: isDark ? cs.outline.withValues(alpha: 0.5) : Colors.black.withValues(alpha: 0.04))), child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, maxLines: 1, style: TextStyle(fontSize: uiScale.font(10.0), fontWeight: FontWeight.w700, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)), SizedBox(height: uiScale.gap(3)), FittedBox(fit: BoxFit.scaleDown, child: Text(value, style: TextStyle(fontSize: uiScale.font(13.0), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary))), SizedBox(height: uiScale.gap(2)), Text(hint, maxLines: 1, style: TextStyle(fontSize: uiScale.font(9.0), fontWeight: FontWeight.w700, color: isDark ? cs.onSurfaceVariant.withValues(alpha: 0.6) : AppColors.textSecondary.withValues(alpha: 0.6)))]));
  }
}

class _OnlineRow extends StatelessWidget {
  final UIScale uiScale; final bool online; final bool busy; final ValueChanged<bool> onToggle; final bool isDark; final ColorScheme cs;
  const _OnlineRow({required this.uiScale, required this.online, required this.busy, required this.onToggle, required this.isDark, required this.cs});
  @override
  Widget build(BuildContext context) {
    final color = online ? AppColors.primary : (isDark ? cs.onSurfaceVariant : AppColors.textSecondary);
    return Container(padding: EdgeInsets.symmetric(horizontal: uiScale.inset(12), vertical: uiScale.inset(10)), decoration: BoxDecoration(color: color.withValues(alpha: isDark ? 0.15 : 0.08), borderRadius: BorderRadius.circular(18), border: Border.all(color: color.withValues(alpha: 0.3))), child: Row(children: [Container(width: 40, height: 40, decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(14)), child: Icon(online ? Icons.radar_rounded : Icons.pause_circle_rounded, color: color)), SizedBox(width: uiScale.gap(12)), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(online ? 'Visible to riders' : 'Currently offline', style: TextStyle(fontSize: uiScale.font(13.0), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary)), SizedBox(height: uiScale.gap(2)), Text(online ? 'GPS location is live.' : 'Turn on to receive requests.', style: TextStyle(fontSize: uiScale.font(10.5), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary))])), busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)) : Switch.adaptive(value: online, onChanged: onToggle, activeThumbColor: AppColors.primary)]));
  }
}

class _QuickActionStrip extends StatelessWidget {
  final UIScale uiScale; final VoidCallback onWallet; final VoidCallback onHistory; final VoidCallback onProfile; final VoidCallback onRefresh; final bool isDark; final ColorScheme cs;
  const _QuickActionStrip({required this.uiScale, required this.onWallet, required this.onHistory, required this.onProfile, required this.onRefresh, required this.isDark, required this.cs});
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(scrollDirection: Axis.horizontal, physics: const BouncingScrollPhysics(), child: Row(children: [_ActionPill(uiScale: uiScale, icon: Icons.account_balance_wallet_rounded, label: 'Wallet', onTap: onWallet, isDark: isDark, cs: cs), SizedBox(width: uiScale.gap(8)), _ActionPill(uiScale: uiScale, icon: Icons.receipt_long_rounded, label: 'History', onTap: onHistory, isDark: isDark, cs: cs), SizedBox(width: uiScale.gap(8)), _ActionPill(uiScale: uiScale, icon: Icons.person_rounded, label: 'Profile', onTap: onProfile, isDark: isDark, cs: cs), SizedBox(width: uiScale.gap(8)), _ActionPill(uiScale: uiScale, icon: Icons.sync_rounded, label: 'Refresh', onTap: onRefresh, isDark: isDark, cs: cs)]));
  }
}

class _ActionPill extends StatelessWidget {
  final UIScale uiScale;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDark;
  final ColorScheme cs;

  const _ActionPill({required this.uiScale, required this.icon, required this.label, required this.onTap, required this.isDark, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Material(
        color: Colors.transparent,
        child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: Ink(
                padding: EdgeInsets.symmetric(horizontal: uiScale.inset(12), vertical: uiScale.inset(8)),
                decoration: BoxDecoration(color: isDark ? cs.surfaceContainerHighest.withValues(alpha: 0.4) : AppColors.mintBgLight.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(999), border: Border.all(color: isDark ? cs.outline.withValues(alpha: 0.5) : Colors.black.withValues(alpha: 0.05))),
                child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: uiScale.icon(14), color: isDark ? cs.primary : AppColors.primary),
                      SizedBox(width: uiScale.gap(6)),
                      Text(label, style: TextStyle(fontSize: uiScale.font(11.0), fontWeight: FontWeight.w800, color: isDark ? cs.onSurface : AppColors.textPrimary))
                    ]
                )
            )
        )
    );
  }
}

class _QueueCard extends StatelessWidget {
  final UIScale uiScale;
  final bool online;
  final List<DriverOffer> offers;
  final int? acceptingRideId;
  final LatLng? driverPosition;
  final ValueChanged<RideJob> onAccept;
  final ValueChanged<RideJob> onDecline;
  final bool isDark;
  final ColorScheme cs;

  const _QueueCard({
    required this.uiScale, required this.online, required this.offers, required this.acceptingRideId,
    required this.driverPosition, required this.onAccept, required this.onDecline, required this.isDark, required this.cs,
  });

  double? _distanceTo(RideJob ride) {
    final p = driverPosition;
    if (p == null || !ride.hasPickupCoords) return null;
    return Geolocator.distanceBetween(p.latitude, p.longitude, ride.pickupLat, ride.pickupLng);
  }

  @override
  Widget build(BuildContext context) {
    final accent = isDark ? cs.primary : AppColors.primary;
    return Container(
      padding: EdgeInsets.all(uiScale.inset(14)),
      decoration: BoxDecoration(color: isDark ? cs.surfaceContainerHighest.withValues(alpha: 0.3) : AppColors.mintBgLight.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(20), border: Border.all(color: isDark ? cs.outline.withValues(alpha: 0.4) : Colors.black.withValues(alpha: 0.05))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text('Incoming Requests', style: TextStyle(fontSize: uiScale.font(13.5), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary))),
            Container(padding: EdgeInsets.symmetric(horizontal: uiScale.inset(8), vertical: uiScale.inset(4)), decoration: BoxDecoration(color: accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)), child: Text('${offers.length} Live', style: TextStyle(fontSize: uiScale.font(10.0), fontWeight: FontWeight.w900, color: accent))),
          ]),
          SizedBox(height: uiScale.gap(12)),
          if (offers.isEmpty)
            Text(
              online
                  ? 'No requests right now. Stay online and nearby requests will appear here automatically.'
                  : 'Go online to start receiving requests.',
              style: TextStyle(fontSize: uiScale.font(11.0), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, height: 1.4),
            )
          else
            ...offers.take(5).map((offer) {
              final ride = offer.ride;
              return IncomingRequestCard(
                key: ValueKey('offer_${ride.id}'),
                ride: ride,
                uiScale: uiScale,
                isAccepting: acceptingRideId == ride.id,
                enabled: acceptingRideId == null,
                expiresAt: offer.expiresAt,
                offerWindow: DriverSessionController.offerWindow,
                countdownPaused: offer.held,
                distanceToPickupMeters: _distanceTo(ride),
                onAccept: () => onAccept(ride),
                onDecline: () => onDecline(ride),
              );
            }),
        ],
      ),
    );
  }
}
