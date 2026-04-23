// lib/driver/state/driver_command_center.dart
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import '../../themes/app_theme.dart';
import '../../ui/ui_scale.dart';
import 'driver_models.dart';

class DriverCommandCenter extends StatelessWidget {
  final UIScale uiScale;
  final double height;
  final bool expanded;
  final DriverProfile? driver;
  final RideJob? activeRide;
  final List<RideJob> queue;
  final String? statusMessage;
  final DateTime? lastSyncAt;
  final DateTime? lastHeartbeatAt;
  final bool busyOnlineToggle;
  final bool busyRideAction;
  final VoidCallback onExpandToggle;
  final ValueChanged<bool> onOnlineToggle;
  final VoidCallback onWallet;
  final VoidCallback onHistory;
  final VoidCallback onProfile;
  final VoidCallback onRefresh;
  final ValueChanged<RideJob> onAccept;
  final ValueChanged<String> onRideAction;
  final VoidCallback onNavigate;

  const DriverCommandCenter({
    super.key,
    required this.uiScale,
    required this.height,
    required this.expanded,
    required this.driver,
    required this.activeRide,
    required this.queue,
    required this.statusMessage,
    required this.lastSyncAt,
    required this.lastHeartbeatAt,
    required this.busyOnlineToggle,
    required this.busyRideAction,
    required this.onExpandToggle,
    required this.onOnlineToggle,
    required this.onWallet,
    required this.onHistory,
    required this.onProfile,
    required this.onRefresh,
    required this.onAccept,
    required this.onRideAction,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final driverOnline = driver?.isOnline == true;
    final status = activeRide?.status ?? (driverOnline ? 'online' : 'offline');
    final statusColor = _statusColor(status);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      constraints: BoxConstraints(
        minHeight: expanded ? math.min(220, height) : 96,
        maxHeight: height,
      ),
      decoration: BoxDecoration(
        color: isDark ? cs.surface.withOpacity(0.85) : Colors.white.withOpacity(0.92),
        borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(28))),
        border: Border(top: BorderSide(color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight, width: 1.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.6 : 0.15),
            blurRadius: uiScale.reduceFx ? 16 : 30,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(28))),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: expanded
                ? _buildExpanded(isDark, cs, statusColor, status)
                : _buildCollapsed(isDark, cs, statusColor, status),
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsed(bool isDark, ColorScheme cs, Color statusColor, String status) {
    final online = driver?.isOnline == true;
    return Padding(
      key: const ValueKey('collapsed'),
      padding: EdgeInsets.fromLTRB(uiScale.inset(16), uiScale.gap(8), uiScale.inset(16), uiScale.gap(12)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: GestureDetector(
              onTap: onExpandToggle,
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : Colors.black12,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
          SizedBox(height: uiScale.gap(8)),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Driver Terminal',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: uiScale.font(14.0), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary, letterSpacing: -0.2),
                ),
              ),
              SizedBox(width: uiScale.gap(8)),
              _StatusDotChip(uiScale: uiScale, color: statusColor, label: _statusLabel(status), isDark: isDark, cs: cs),
              SizedBox(width: uiScale.gap(4)),
              IconButton(
                onPressed: onExpandToggle,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: Icon(Icons.keyboard_arrow_up_rounded, size: uiScale.icon(20), color: isDark ? cs.onSurface : AppColors.textPrimary),
              ),
            ],
          ),
          SizedBox(height: uiScale.gap(6)),
          _CompactSummaryRow(
            uiScale: uiScale, driver: driver, activeRide: activeRide, lastSyncAt: lastSyncAt, lastHeartbeatAt: lastSyncAt,
            queueCount: queue.length, dense: true, online: online, busyOnlineToggle: busyOnlineToggle,
            onOnlineToggle: () => onOnlineToggle(!online), isDark: isDark, cs: cs,
          ),
        ],
      ),
    );
  }

  Widget _buildExpanded(bool isDark, ColorScheme cs, Color statusColor, String status) {
    final driverOnline = driver?.isOnline == true;
    return ListView(
      key: const ValueKey('expanded'),
      padding: EdgeInsets.fromLTRB(uiScale.inset(16), uiScale.gap(8), uiScale.inset(16), uiScale.gap(20)),
      physics: const BouncingScrollPhysics(),
      children: [
        Center(
          child: GestureDetector(
            onTap: onExpandToggle,
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : Colors.black12,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
        SizedBox(height: uiScale.gap(12)),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    activeRide != null ? 'Active Trip Control' : 'Driver Terminal',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: uiScale.font(16.0), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary, letterSpacing: -0.3),
                  ),
                  SizedBox(height: uiScale.gap(2)),
                  Text(
                    statusMessage?.trim().isNotEmpty == true ? statusMessage!.trim() : (activeRide != null ? 'Pickup and destination are live on the map.' : 'Go online to appear to riders and start receiving ride requests.'),
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: uiScale.font(11.5), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            SizedBox(width: uiScale.gap(8)),
            _StatusDotChip(uiScale: uiScale, color: statusColor, label: _statusLabel(status), isDark: isDark, cs: cs),
            SizedBox(width: uiScale.gap(4)),
            IconButton(
              onPressed: onExpandToggle,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.keyboard_arrow_down_rounded, color: isDark ? cs.onSurface : AppColors.textPrimary),
            ),
          ],
        ),
        SizedBox(height: uiScale.gap(16)),
        _CompactSummaryRow(
          uiScale: uiScale, driver: driver, activeRide: activeRide, lastSyncAt: lastSyncAt, lastHeartbeatAt: lastHeartbeatAt, isDark: isDark, cs: cs,
        ),
        SizedBox(height: uiScale.gap(12)),
        _OnlineRow(uiScale: uiScale, online: driverOnline, busy: busyOnlineToggle, onToggle: onOnlineToggle, isDark: isDark, cs: cs),
        SizedBox(height: uiScale.gap(12)),
        _QuickActionStrip(uiScale: uiScale, onWallet: onWallet, onHistory: onHistory, onProfile: onProfile, onRefresh: onRefresh, isDark: isDark, cs: cs),
        SizedBox(height: uiScale.gap(12)),

        if (activeRide != null) ...[
          _TripStateCard(uiScale: uiScale, ride: activeRide!, busy: busyRideAction, onRideAction: onRideAction, onNavigate: onNavigate, isDark: isDark, cs: cs),
          SizedBox(height: uiScale.gap(12)),
        ],

        _QueueCard(uiScale: uiScale, rides: queue, busy: busyRideAction, onAccept: onAccept, isDark: isDark, cs: cs),
      ],
    );
  }

  // --- Static Styling Helpers ---
  Color _statusColor(String status) {
    switch (status.trim().toLowerCase()) {
      case 'online':
      case 'accepted':
      case 'enroute_pickup':
      case 'in_progress':
        return AppColors.primary;
      case 'arrived_pickup':
      case 'arrived_destination':
        return Colors.orange;
      case 'completed':
        return Colors.green;
      case 'cancel':
      case 'canceled':
        return Colors.red;
      default:
        return Colors.grey.shade600;
    }
  }

  String _statusLabel(String status) {
    switch (status.trim().toLowerCase()) {
      case 'accepted': return 'Accepted';
      case 'enroute_pickup': return 'To Pickup';
      case 'arrived_pickup': return 'At Pickup';
      case 'in_progress': return 'On Trip';
      case 'arrived_destination': return 'At Dropoff';
      case 'completed': return 'Completed';
      case 'online': return 'Online';
      case 'offline': return 'Offline';
      default: return status.isEmpty ? 'Offline' : status.toUpperCase();
    }
  }
}

// --- Sub-Components (Styled for OLED/Glass) ---

class _StatusDotChip extends StatelessWidget {
  final UIScale uiScale;
  final Color color;
  final String label;
  final bool isDark;
  final ColorScheme cs;

  const _StatusDotChip({required this.uiScale, required this.color, required this.label, required this.isDark, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: uiScale.inset(10), vertical: uiScale.inset(6)),
      decoration: BoxDecoration(
        color: color.withOpacity(isDark ? 0.15 : 0.10),
        borderRadius: BorderRadius.circular(uiScale.radius(999)),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 4)]),
          ),
          SizedBox(width: uiScale.gap(6)),
          Text(label, style: TextStyle(fontSize: uiScale.font(10.5), fontWeight: FontWeight.w900, color: color, letterSpacing: 0.2)),
        ],
      ),
    );
  }
}

class _CompactSummaryRow extends StatelessWidget {
  final UIScale uiScale;
  final DriverProfile? driver;
  final RideJob? activeRide;
  final DateTime? lastSyncAt;
  final DateTime? lastHeartbeatAt;
  final int queueCount;
  final bool dense;
  final bool online;
  final bool busyOnlineToggle;
  final VoidCallback? onOnlineToggle;
  final bool isDark;
  final ColorScheme cs;

  const _CompactSummaryRow({
    required this.uiScale, required this.driver, required this.activeRide, required this.lastSyncAt, required this.lastHeartbeatAt,
    this.queueCount = 0, this.dense = false, this.online = false, this.busyOnlineToggle = false, this.onOnlineToggle,
    required this.isDark, required this.cs,
  });

  String _fmtTime(DateTime? value) {
    if (value == null) return '—';
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final meridian = value.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $meridian';
  }

  @override
  Widget build(BuildContext context) {
    if (dense) {
      final compactPlate = driver?.carPlate?.trim();
      return SizedBox(
        height: 36,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [
              _DenseSummaryPill(uiScale: uiScale, label: 'Trips', value: '${driver?.completedTrips ?? 0}', isDark: isDark, cs: cs),
              SizedBox(width: uiScale.gap(6)),
              _DenseSummaryPill(uiScale: uiScale, label: activeRide != null ? 'Trip' : 'Queue', value: activeRide != null ? 'Live' : '$queueCount', isDark: isDark, cs: cs),
              SizedBox(width: uiScale.gap(6)),
              _DenseSummaryPill(uiScale: uiScale, label: 'Sync', value: _fmtTime(lastSyncAt), isDark: isDark, cs: cs),
              SizedBox(width: uiScale.gap(6)),
              _DenseTogglePill(uiScale: uiScale, online: online, busy: busyOnlineToggle, onTap: onOnlineToggle, isDark: isDark, cs: cs),
              if (compactPlate != null && compactPlate.isNotEmpty) ...[
                SizedBox(width: uiScale.gap(6)),
                _DenseSummaryPill(uiScale: uiScale, label: 'Plate', value: compactPlate, isDark: isDark, cs: cs),
              ]
            ],
          ),
        ),
      );
    }

    return SizedBox(
      height: uiScale.gap(68),
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        children: [
          _MiniMetricCard(uiScale: uiScale, label: 'Trips', value: '${driver?.completedTrips ?? 0}', hint: 'Completed', isDark: isDark, cs: cs),
          SizedBox(width: uiScale.gap(8)),
          _MiniMetricCard(uiScale: uiScale, label: 'Rating', value: (driver?.rating ?? 0).toStringAsFixed(2), hint: driver?.category ?? 'driver', isDark: isDark, cs: cs),
          SizedBox(width: uiScale.gap(8)),
          _MiniMetricCard(uiScale: uiScale, label: 'Sync', value: _fmtTime(lastSyncAt), hint: 'Server', isDark: isDark, cs: cs),
          SizedBox(width: uiScale.gap(8)),
          _MiniMetricCard(uiScale: uiScale, label: 'Live', value: _fmtTime(lastHeartbeatAt), hint: activeRide != null ? 'Trip GPS' : 'GPS', isDark: isDark, cs: cs),
          if (driver?.carPlate != null) ...[
            SizedBox(width: uiScale.gap(8)),
            _MiniMetricCard(uiScale: uiScale, label: 'Plate', value: driver!.carPlate!, hint: driver?.vehicleType ?? 'Vehicle', isDark: isDark, cs: cs),
          ],
        ],
      ),
    );
  }
}

class _DenseSummaryPill extends StatelessWidget {
  final UIScale uiScale;
  final String label;
  final String value;
  final bool isDark;
  final ColorScheme cs;

  const _DenseSummaryPill({required this.uiScale, required this.label, required this.value, required this.isDark, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: uiScale.inset(10), vertical: uiScale.inset(6)),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceVariant.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.5),
        borderRadius: BorderRadius.circular(uiScale.radius(999)),
        border: Border.all(color: isDark ? cs.outline.withOpacity(0.5) : Colors.black.withOpacity(0.05)),
      ),
      child: RichText(
        maxLines: 1,
        text: TextSpan(
          children: [
            TextSpan(text: '$label ', style: TextStyle(fontSize: uiScale.font(10.0), fontWeight: FontWeight.w700, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
            TextSpan(text: value, style: TextStyle(fontSize: uiScale.font(10.5), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary)),
          ],
        ),
      ),
    );
  }
}

class _DenseTogglePill extends StatelessWidget {
  final UIScale uiScale;
  final bool online;
  final bool busy;
  final VoidCallback? onTap;
  final bool isDark;
  final ColorScheme cs;

  const _DenseTogglePill({required this.uiScale, required this.online, required this.busy, required this.onTap, required this.isDark, required this.cs});

  @override
  Widget build(BuildContext context) {
    final color = online ? AppColors.primary : (isDark ? cs.onSurfaceVariant : AppColors.textSecondary);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: uiScale.inset(6), vertical: uiScale.inset(2)),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(uiScale.radius(999)),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(online ? 'Online' : 'Offline', style: TextStyle(fontSize: uiScale.font(10.0), fontWeight: FontWeight.w900, color: color)),
          SizedBox(width: uiScale.gap(2)),
          Transform.scale(
            scale: 0.62,
            child: Switch.adaptive(
              value: online,
              onChanged: busy || onTap == null ? null : (_) => onTap!.call(),
              activeColor: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniMetricCard extends StatelessWidget {
  final UIScale uiScale;
  final String label;
  final String value;
  final String hint;
  final bool isDark;
  final ColorScheme cs;

  const _MiniMetricCard({required this.uiScale, required this.label, required this.value, required this.hint, required this.isDark, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: uiScale.gap(100),
      padding: EdgeInsets.symmetric(horizontal: uiScale.inset(12), vertical: uiScale.inset(10)),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceVariant.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.3),
        borderRadius: BorderRadius.circular(uiScale.radius(16)),
        border: Border.all(color: isDark ? cs.outline.withOpacity(0.5) : Colors.black.withOpacity(0.04)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: uiScale.font(10.0), fontWeight: FontWeight.w700, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
          SizedBox(height: uiScale.gap(3)),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, maxLines: 1, style: TextStyle(fontSize: uiScale.font(13.0), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary))),
          SizedBox(height: uiScale.gap(2)),
          Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: uiScale.font(9.0), fontWeight: FontWeight.w700, color: isDark ? cs.onSurfaceVariant.withOpacity(0.6) : AppColors.textSecondary.withOpacity(0.6))),
        ],
      ),
    );
  }
}

class _OnlineRow extends StatelessWidget {
  final UIScale uiScale;
  final bool online;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final bool isDark;
  final ColorScheme cs;

  const _OnlineRow({required this.uiScale, required this.online, required this.busy, required this.onToggle, required this.isDark, required this.cs});

  @override
  Widget build(BuildContext context) {
    final color = online ? AppColors.primary : (isDark ? cs.onSurfaceVariant : AppColors.textSecondary);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: uiScale.inset(12), vertical: uiScale.inset(10)),
      decoration: BoxDecoration(
        color: color.withOpacity(isDark ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(uiScale.radius(18)),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: uiScale.inset(40), height: uiScale.inset(40),
            decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(uiScale.radius(14))),
            child: Icon(online ? Icons.radar_rounded : Icons.pause_circle_rounded, color: color),
          ),
          SizedBox(width: uiScale.gap(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(online ? 'Visible to riders' : 'Currently offline', style: TextStyle(fontSize: uiScale.font(13.0), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary)),
                SizedBox(height: uiScale.gap(2)),
                Text(online ? 'GPS location is live.' : 'Turn on to receive requests.', style: TextStyle(fontSize: uiScale.font(10.5), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
              ],
            ),
          ),
          busy ? SizedBox(width: uiScale.inset(22), height: uiScale.inset(22), child: const CircularProgressIndicator(strokeWidth: 2)) : Switch.adaptive(value: online, onChanged: onToggle, activeColor: AppColors.primary),
        ],
      ),
    );
  }
}

class _QuickActionStrip extends StatelessWidget {
  final UIScale uiScale;
  final VoidCallback onWallet;
  final VoidCallback onHistory;
  final VoidCallback onProfile;
  final VoidCallback onRefresh;
  final bool isDark;
  final ColorScheme cs;

  const _QuickActionStrip({required this.uiScale, required this.onWallet, required this.onHistory, required this.onProfile, required this.onRefresh, required this.isDark, required this.cs});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          _ActionPill(uiScale: uiScale, icon: Icons.account_balance_wallet_rounded, label: 'Wallet', onTap: onWallet, isDark: isDark, cs: cs),
          SizedBox(width: uiScale.gap(8)),
          _ActionPill(uiScale: uiScale, icon: Icons.receipt_long_rounded, label: 'History', onTap: onHistory, isDark: isDark, cs: cs),
          SizedBox(width: uiScale.gap(8)),
          _ActionPill(uiScale: uiScale, icon: Icons.person_rounded, label: 'Profile', onTap: onProfile, isDark: isDark, cs: cs),
          SizedBox(width: uiScale.gap(8)),
          _ActionPill(uiScale: uiScale, icon: Icons.sync_rounded, label: 'Refresh', onTap: onRefresh, isDark: isDark, cs: cs),
        ],
      ),
    );
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
        borderRadius: BorderRadius.circular(uiScale.radius(999)),
        child: Ink(
          padding: EdgeInsets.symmetric(horizontal: uiScale.inset(12), vertical: uiScale.inset(8)),
          decoration: BoxDecoration(color: isDark ? cs.surfaceVariant.withOpacity(0.4) : AppColors.mintBgLight.withOpacity(0.4), borderRadius: BorderRadius.circular(uiScale.radius(999)), border: Border.all(color: isDark ? cs.outline.withOpacity(0.5) : Colors.black.withOpacity(0.05))),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: uiScale.icon(14), color: isDark ? cs.primary : AppColors.primary),
              SizedBox(width: uiScale.gap(6)),
              Text(label, style: TextStyle(fontSize: uiScale.font(11.0), fontWeight: FontWeight.w800, color: isDark ? cs.onSurface : AppColors.textPrimary)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TripStateCard extends StatelessWidget {
  final UIScale uiScale;
  final RideJob ride;
  final bool busy;
  final ValueChanged<String> onRideAction;
  final VoidCallback onNavigate;
  final bool isDark;
  final ColorScheme cs;

  const _TripStateCard({required this.uiScale, required this.ride, required this.busy, required this.onRideAction, required this.onNavigate, required this.isDark, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(uiScale.inset(14)),
      decoration: BoxDecoration(
        color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.08),
        borderRadius: BorderRadius.circular(uiScale.radius(20)),
        border: Border.all(color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Active Trip · ${ride.riderName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: uiScale.font(13.5), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary))),
              _StatusDotChip(uiScale: uiScale, color: AppColors.primary, label: 'Live', isDark: isDark, cs: cs),
            ],
          ),
          SizedBox(height: uiScale.gap(12)),
          Row(
            children: [
              Icon(Icons.place_rounded, size: uiScale.icon(14), color: AppColors.primary),
              SizedBox(width: uiScale.gap(6)),
              Expanded(child: Text(ride.pickupText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: uiScale.font(11.5), fontWeight: FontWeight.w700, color: isDark ? cs.onSurface : AppColors.textPrimary))),
            ],
          ),
          SizedBox(height: uiScale.gap(6)),
          Row(
            children: [
              Icon(Icons.flag_rounded, size: uiScale.icon(14), color: Colors.red),
              SizedBox(width: uiScale.gap(6)),
              Expanded(child: Text(ride.destText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: uiScale.font(11.5), fontWeight: FontWeight.w700, color: isDark ? cs.onSurface : AppColors.textPrimary))),
            ],
          ),
          SizedBox(height: uiScale.gap(16)),
          SizedBox(
            width: double.infinity,
            height: 42,
            child: ElevatedButton.icon(
              onPressed: onNavigate,
              icon: Icon(Icons.navigation_rounded, size: uiScale.icon(16)),
              label: Text('Open Navigation', style: TextStyle(fontSize: uiScale.font(12.5), fontWeight: FontWeight.w900)),
              style: ElevatedButton.styleFrom(backgroundColor: isDark ? cs.primary : AppColors.primary, foregroundColor: isDark ? cs.onPrimary : Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(12))), elevation: 0),
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueCard extends StatelessWidget {
  final UIScale uiScale;
  final List<RideJob> rides;
  final bool busy;
  final ValueChanged<RideJob> onAccept;
  final bool isDark;
  final ColorScheme cs;

  const _QueueCard({
    required this.uiScale,
    required this.rides,
    required this.busy,
    required this.onAccept,
    required this.isDark,
    required this.cs,
  });

  /// High-performance regex to add commas to the price without needing the 'intl' package.
  String _formatAmount(double amount) {
    return amount.toStringAsFixed(0).replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (Match m) => '${m[1]},',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(uiScale.inset(14)),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceVariant.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.3),
        borderRadius: BorderRadius.circular(uiScale.radius(20)),
        border: Border.all(color: isDark ? cs.outline.withOpacity(0.4) : Colors.black.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Incoming Requests',
                  style: TextStyle(fontSize: uiScale.font(13.5), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary),
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: uiScale.inset(8), vertical: uiScale.inset(4)),
                decoration: BoxDecoration(
                  color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${rides.length} Live',
                  style: TextStyle(fontSize: uiScale.font(10.0), fontWeight: FontWeight.w900, color: isDark ? cs.primary : AppColors.primary),
                ),
              ),
            ],
          ),
          SizedBox(height: uiScale.gap(12)),

          if (rides.isEmpty)
            Text(
              'No requests right now. Stay online and nearby requests will appear here automatically.',
              style: TextStyle(fontSize: uiScale.font(11.0), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, height: 1.4),
            )
          else
            ...rides.take(5).map((ride) => Padding(
              padding: EdgeInsets.only(bottom: uiScale.gap(10)),
              child: Container(
                padding: EdgeInsets.all(uiScale.inset(14)),
                decoration: BoxDecoration(
                  color: isDark ? cs.surface : Colors.white,
                  borderRadius: BorderRadius.circular(uiScale.radius(16)),
                  border: Border.all(color: isDark ? cs.outline.withOpacity(0.5) : Colors.black.withOpacity(0.04)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(isDark ? 0.3 : 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    )
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            ride.riderName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: uiScale.font(14.0), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary),
                          ),
                        ),
                        Text(
                          '${ride.currency} ${_formatAmount(ride.price)}',
                          style: TextStyle(fontSize: uiScale.font(15.0), fontWeight: FontWeight.w900, color: isDark ? cs.primary : AppColors.primary, letterSpacing: -0.5),
                        ),
                      ],
                    ),
                    SizedBox(height: uiScale.gap(10)),
                    Row(
                      children: [
                        Icon(Icons.place_rounded, size: uiScale.icon(14), color: AppColors.textSecondary),
                        SizedBox(width: uiScale.gap(6)),
                        Expanded(
                          child: Text(
                            ride.pickupText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: uiScale.font(11.5), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
                          ),
                        )
                      ],
                    ),
                    SizedBox(height: uiScale.gap(6)),
                    Row(
                      children: [
                        Icon(Icons.flag_rounded, size: uiScale.icon(14), color: AppColors.textSecondary),
                        SizedBox(width: uiScale.gap(6)),
                        Expanded(
                          child: Text(
                            ride.destText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: uiScale.font(11.5), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
                          ),
                        )
                      ],
                    ),
                    SizedBox(height: uiScale.gap(16)),

                    Container(
                      width: double.infinity,
                      height: uiScale.inset(48),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(uiScale.radius(12)),
                        boxShadow: [
                          BoxShadow(
                            color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.25),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: busy ? null : () => onAccept(ride),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isDark ? cs.primary : AppColors.primary,
                          foregroundColor: isDark ? cs.onPrimary : Colors.white,
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(12))),
                          elevation: 0,
                        ),
                        child: busy
                            ? SizedBox(
                          width: uiScale.icon(20),
                          height: uiScale.icon(20),
                          child: const CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                            : Text(
                          'Accept Request',
                          style: TextStyle(fontSize: uiScale.font(13.5), fontWeight: FontWeight.w800, letterSpacing: 0.2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )),
        ],
      ),
    );
  }
}