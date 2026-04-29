// lib/screens/ride_history_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' hide TextDirection; // Hid TextDirection to prevent dart:ui conflict
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../widgets/inner_background.dart';
import '../utility/notification.dart';
import 'trip_navigation_page.dart';

class RideHistoryScreen extends StatefulWidget {
  const RideHistoryScreen({super.key});

  @override
  State<RideHistoryScreen> createState() => _RideHistoryScreenState();
}

class _RideHistoryScreenState extends State<RideHistoryScreen> {
  late ApiClient _api;
  bool _initialLoading = true;
  bool _syncing = false;
  bool _isDriverMode = false;
  String _userId = '';
  List<Map<String, dynamic>> _rides = [];

  // Filter & Search
  String _activeFilter = 'All';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // Caching keys
  late String _cacheKey;
  static const int _maxCacheAgeHours = 1;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);
    _initAndLoad();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _initAndLoad() async {
    final prefs = await SharedPreferences.getInstance();
    _isDriverMode = prefs.getBool('user_is_driver') ?? false;
    _userId = prefs.getString('user_id') ?? '';
    _cacheKey = 'ride_history_${_isDriverMode ? "driver" : "rider"}';

    final cachedJson = prefs.getString(_cacheKey);
    final int? cachedTimestamp = prefs.getInt('${_cacheKey}_timestamp');

    if (cachedJson != null && cachedTimestamp != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final ageMs = now - cachedTimestamp;
      final ageHours = ageMs / (1000 * 60 * 60);

      try {
        final decoded = jsonDecode(cachedJson) as List<dynamic>;
        if (mounted) {
          setState(() {
            _rides = decoded.cast<Map<String, dynamic>>();
            _initialLoading = false;
            if (ageHours > _maxCacheAgeHours) _syncing = true;
          });
        }
      } catch (_) {}
    }

    await _fetchFromNetwork();

    if (mounted) {
      setState(() {
        _initialLoading = false;
        _syncing = false;
      });
    }
  }

  Future<void> _fetchFromNetwork() async {
    try {
      final res = await _api.request(
        ApiConstants.rideHistoryEndpoint,
        method: 'POST',
        data: {
          'user_id': _userId,
          'role': _isDriverMode ? 'driver' : 'rider',
          'limit': '50',
        },
      );

      final body = jsonDecode(res.body);
      if (res.statusCode == 200 && body['error'] == false) {
        final data = body['data'] as List<dynamic>;
        final rides = data.cast<Map<String, dynamic>>();

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, jsonEncode(rides));
        await prefs.setInt('${_cacheKey}_timestamp', DateTime.now().millisecondsSinceEpoch);

        if (mounted) {
          setState(() {
            _rides = rides;
            _syncing = false;
          });
        }
      } else {
        _showErrorSnack('Failed to load history');
      }
    } catch (e) {
      if (mounted && _rides.isEmpty) {
        _showErrorSnack('Network error – showing cached data');
      }
    }
  }

  void _showErrorSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  List<Map<String, dynamic>> get _filteredRides {
    var list = _rides;

    if (_activeFilter != 'All') {
      if (_activeFilter == 'Active') {
        list = list.where((r) {
          final s = (r['status'] ?? '').toString().toLowerCase();
          return ['searching', 'accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination'].contains(s);
        }).toList();
      } else if (_activeFilter == 'Cancelled') {
        // FIXED: Handle both 'canceled' (1 L) and 'cancelled' (2 Ls) from the backend
        list = list.where((r) {
          final s = (r['status'] ?? '').toString().toLowerCase();
          return s == 'cancelled' || s == 'canceled';
        }).toList();
      } else {
        final lower = _activeFilter.toLowerCase();
        list = list.where((r) {
          final s = (r['status'] ?? '').toString().toLowerCase();
          return s == lower;
        }).toList();
      }
    }

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((r) {
        final dest = (r['dest_text'] ?? '').toString().toLowerCase();
        final peer = (r['peer_name'] ?? '').toString().toLowerCase();
        final type = (r['ride_type'] ?? '').toString().toLowerCase();
        final pickup = (r['pickup_text'] ?? '').toString().toLowerCase();
        return dest.contains(q) || peer.contains(q) || type.contains(q) || pickup.contains(q);
      }).toList();
    }

    return list;
  }

  void _openDetails(Map<String, dynamic> ride) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => _PremiumRideDetailSheet(
        ride: ride,
        isDriverMode: _isDriverMode,
        userId: _userId,
        apiClient: _api,
        onChanged: (didModify) {
          if (didModify) {
            setState(() => _syncing = true);
            _fetchFromNetwork();
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;
    final ui = UIScale.of(context);
    final displayRides = _filteredRides;

    final maxContentWidth = ui.tablet ? 800.0 : (ui.landscape ? 700.0 : double.infinity);

    return Scaffold(
      backgroundColor: isDark ? Colors.black : AppColors.offWhite,
      body: Stack(
        children: [
          BackgroundWidget(style: HoloStyle.vapor, intensity: isDark ? 0.15 : 0.4, animate: true),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxContentWidth),
                child: Column(
                  children: [
                    _buildHeader(isDark, cs, ui),
                    _buildSearchBar(isDark, cs, ui),
                    SizedBox(height: ui.gap(6)),
                    _buildFilterChips(isDark, cs, ui),
                    SizedBox(height: ui.gap(10)),
                    Expanded(
                      child: _initialLoading
                          ? _buildShimmerList(isDark, cs, ui)
                          : RefreshIndicator(
                        onRefresh: _fetchFromNetwork,
                        color: cs.primary,
                        child: displayRides.isEmpty
                            ? _buildEmptyState(isDark, cs, ui)
                            : ListView.builder(
                          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                          padding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.inset(8)),
                          itemCount: displayRides.length,
                          itemBuilder: (_, i) => _RideCard(
                            ui: ui,
                            ride: displayRides[i],
                            isDriverMode: _isDriverMode,
                            onTap: () => _openDetails(displayRides[i]),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(bool isDark, ColorScheme cs, UIScale ui) {
    return Padding(
      padding: EdgeInsets.fromLTRB(ui.inset(16), ui.inset(8), ui.inset(16), ui.inset(6)),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).maybePop(),
            child: Container(
              padding: EdgeInsets.all(ui.inset(6)),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withOpacity(0.4),
                borderRadius: BorderRadius.circular(ui.radius(10)),
              ),
              child: Icon(Icons.arrow_back_ios_rounded, size: ui.icon(16), color: cs.onPrimaryContainer),
            ),
          ),
          SizedBox(width: ui.gap(12)),
          Expanded(
            child: Text(
              'Ride History',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: ui.font(18),
                letterSpacing: -0.25,
                color: cs.onSurface,
              ),
            ),
          ),
          if (_syncing)
            SizedBox(
              width: ui.gap(16),
              height: ui.gap(16),
              child: CircularProgressIndicator(strokeWidth: 2.0, color: cs.primary),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(bool isDark, ColorScheme cs, UIScale ui) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(16)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ui.radius(12)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: ui.reduceFx ? 4 : 10, sigmaY: ui.reduceFx ? 4 : 10),
          child: Container(
            height: ui.gap(38),
            decoration: BoxDecoration(
              color: isDark ? cs.surfaceVariant.withOpacity(0.6) : Colors.white.withOpacity(0.7),
              borderRadius: BorderRadius.circular(ui.radius(12)),
              border: Border.all(
                color: isDark ? cs.outlineVariant.withOpacity(0.4) : AppColors.mintBgLight.withOpacity(0.4),
                width: 1,
              ),
            ),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              onChanged: (v) => setState(() => _searchQuery = v),
              style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface, fontSize: ui.font(12.5)),
              decoration: InputDecoration(
                hintText: 'Search destinations, names...',
                hintStyle: TextStyle(color: cs.onSurfaceVariant.withOpacity(0.7), fontSize: ui.font(12)),
                prefixIcon: Icon(Icons.search_rounded, color: cs.primary, size: ui.icon(16)),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                  icon: Icon(Icons.clear_rounded, size: ui.icon(14), color: cs.onSurfaceVariant),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                    _searchFocusNode.unfocus();
                  },
                  splashRadius: 18,
                )
                    : null,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: ui.inset(10)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChips(bool isDark, ColorScheme cs, UIScale ui) {
    final filters = ['All', 'Active', 'Completed', 'Cancelled'];
    return SizedBox(
      height: ui.gap(32),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: ui.inset(16)),
        itemCount: filters.length,
        separatorBuilder: (_, __) => SizedBox(width: ui.gap(6)),
        itemBuilder: (_, i) {
          final label = filters[i];
          final selected = _activeFilter == label;
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _activeFilter = label);
            },
            child: Container(
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(horizontal: ui.inset(12)),
              decoration: BoxDecoration(
                color: selected
                    ? cs.primary.withOpacity(0.15)
                    : (isDark ? cs.surfaceVariant.withOpacity(0.5) : Colors.white.withOpacity(0.6)),
                borderRadius: BorderRadius.circular(ui.radius(10)),
                border: Border.all(
                  color: selected
                      ? cs.primary.withOpacity(0.8)
                      : (isDark ? cs.outlineVariant.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.4)),
                  width: 1.0,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: ui.font(11.5),
                  letterSpacing: -0.1,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildShimmerList(bool isDark, ColorScheme cs, UIScale ui) {
    return ListView.builder(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.inset(8)),
      itemCount: 6,
      itemBuilder: (_, __) => _NativeSkeletonPulse(
        child: Container(
          height: ui.gap(90),
          margin: EdgeInsets.only(bottom: ui.gap(8)),
          decoration: BoxDecoration(
            color: isDark ? cs.surfaceVariant.withOpacity(0.4) : Colors.black.withOpacity(0.04),
            borderRadius: BorderRadius.circular(ui.radius(14)),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark, ColorScheme cs, UIScale ui) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: EdgeInsets.all(ui.inset(10)),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.primary.withOpacity(0.1),
            ),
            child: Icon(Icons.history_toggle_off_rounded, size: ui.icon(32), color: cs.primary.withOpacity(0.6)),
          ),
          SizedBox(height: ui.gap(12)),
          Text('No rides yet', style: TextStyle(fontSize: ui.font(14), fontWeight: FontWeight.w800, color: cs.onSurface)),
          SizedBox(height: ui.gap(4)),
          Text(
            'Your trips will appear here',
            style: TextStyle(fontSize: ui.font(11.5), color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _RideCard extends StatelessWidget {
  final UIScale ui;
  final Map<String, dynamic> ride;
  final bool isDriverMode;
  final VoidCallback onTap;

  const _RideCard({
    required this.ui,
    required this.ride,
    required this.isDriverMode,
    required this.onTap,
  });

  static const _activeStatuses = [
    'searching', 'accepted', 'enroute_pickup', 'arrived_pickup',
    'in_progress', 'arrived_destination'
  ];

  String _formatCurrency(dynamic amount, String currency) {
    final n = double.tryParse(amount.toString()) ?? 0.0;
    return NumberFormat.currency(symbol: '${currency == 'NGN' ? '₦' : '$currency '}', decimalDigits: (n % 1 == 0 ? 0 : 2)).format(n);
  }

  Color _statusColor(String status) {
    if (_activeStatuses.contains(status)) return const Color(0xFF3B82F6);
    if (status == 'completed') return const Color(0xFF10B981);
    if (status == 'cancelled' || status == 'canceled') return const Color(0xFFEF4444);
    return Colors.grey;
  }

  String _statusLabel(String status) => status.toUpperCase().replaceAll('_', ' ');

  String _rideTypeLabel(String type) {
    final t = type.toLowerCase();
    if (t.contains('campus')) return 'Campus';
    if (t.contains('luxury')) return 'Luxury';
    if (t.contains('bike') || t.contains('motor')) return 'Bike';
    return 'Standard';
  }

  Color _rideTypeColor(String type) {
    final t = type.toLowerCase();
    if (t.contains('campus')) return Colors.deepPurple;
    if (t.contains('luxury')) return Colors.amber.shade700;
    if (t.contains('bike') || t.contains('motor')) return Colors.teal;
    return Colors.blue;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    final status = (ride['status'] ?? 'searching').toString().toLowerCase();
    final isActive = _activeStatuses.contains(status);
    final statusColor = _statusColor(status);

    final rideType = ride['ride_type'] ?? 'standard';
    final typeLabel = _rideTypeLabel(rideType);
    final typeColor = _rideTypeColor(rideType);

    final dateStr = ride['created_at'] ?? '';
    String formattedDate = '';
    if (dateStr.toString().isNotEmpty) {
      try {
        final d = DateTime.parse(dateStr.toString());
        formattedDate = DateFormat('MMM d, yyyy • h:mm a').format(d);
      } catch (_) {}
    }

    final avatarUrl = ride['peer_avatar'] ?? '';

    return Container(
      margin: EdgeInsets.only(bottom: ui.gap(8)),
      child: Material(
        color: isDark ? cs.surface.withOpacity(0.8) : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(ui.radius(14)),
        child: InkWell(
          borderRadius: BorderRadius.circular(ui.radius(14)),
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: ui.inset(12), vertical: ui.inset(10)),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(ui.radius(14)),
              border: Border.all(
                color: isActive ? statusColor.withOpacity(0.4) : (isDark ? cs.outlineVariant.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.3)),
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      formattedDate,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: ui.font(10),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: ui.inset(6), vertical: ui.inset(2)),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(ui.radius(6)),
                      ),
                      child: Text(
                        _statusLabel(status),
                        style: TextStyle(
                          color: statusColor,
                          fontSize: ui.font(8.5),
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: ui.gap(8)),
                Row(
                  children: [
                    Container(
                      width: ui.gap(32),
                      height: ui.gap(32),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(ui.radius(8)),
                        color: cs.primary.withOpacity(0.1),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(ui.radius(8)),
                        child: avatarUrl.toString().isNotEmpty
                            ? Image.network(
                          avatarUrl.toString(),
                          width: ui.gap(32),
                          height: ui.gap(32),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Icon(isDriverMode ? Icons.person : Icons.local_taxi_rounded, size: ui.icon(16), color: cs.primary),
                        )
                            : Icon(isDriverMode ? Icons.person : Icons.local_taxi_rounded, size: ui.icon(16), color: cs.primary),
                      ),
                    ),
                    SizedBox(width: ui.gap(10)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ride['dest_text'] ?? 'Unknown destination',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: ui.font(13),
                              letterSpacing: -0.1,
                              color: cs.onSurface,
                            ),
                          ),
                          SizedBox(height: ui.gap(3)),
                          Row(
                            children: [
                              Text(
                                _formatCurrency(ride['price'], ride['currency'] ?? 'NGN'),
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: ui.font(11.5),
                                  color: cs.primary,
                                ),
                              ),
                              SizedBox(width: ui.gap(6)),
                              Container(
                                width: ui.gap(3),
                                height: ui.gap(3),
                                decoration: BoxDecoration(color: cs.onSurfaceVariant.withOpacity(0.5), shape: BoxShape.circle),
                              ),
                              SizedBox(width: ui.gap(6)),
                              Text(
                                typeLabel,
                                style: TextStyle(
                                  color: typeColor,
                                  fontSize: ui.font(10),
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: ui.gap(4)),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: ui.icon(16),
                      color: cs.onSurfaceVariant.withOpacity(0.5),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PremiumRideDetailSheet extends StatefulWidget {
  final Map<String, dynamic> ride;
  final bool isDriverMode;
  final String userId;
  final ApiClient apiClient;
  final void Function(bool didModify) onChanged;

  const _PremiumRideDetailSheet({
    required this.ride,
    required this.isDriverMode,
    required this.userId,
    required this.apiClient,
    required this.onChanged,
  });

  @override
  State<_PremiumRideDetailSheet> createState() => _PremiumRideDetailSheetState();
}

class _PremiumRideDetailSheetState extends State<_PremiumRideDetailSheet> {
  bool _actionBusy = false;

  double _d(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  String _formatCurrency(dynamic amount, String currency) {
    final n = double.tryParse(amount.toString()) ?? 0.0;
    return NumberFormat.currency(symbol: '${currency == 'NGN' ? '₦' : '$currency '}', decimalDigits: (n % 1 == 0 ? 0 : 2)).format(n);
  }

  TripNavPhase _derivePhase(String status) {
    switch (status) {
      case 'searching': case 'accepted': case 'driver_assigned': case 'enroute_pickup':
      return TripNavPhase.driverToPickup;
      case 'arrived_pickup': return TripNavPhase.waitingPickup;
      case 'in_progress': case 'in_ride': return TripNavPhase.enRoute;
      case 'arrived_destination': return TripNavPhase.arrivedDestination;
      case 'completed': return TripNavPhase.completed;
      case 'canceled': case 'cancelled': return TripNavPhase.cancelled;
      default: return TripNavPhase.driverToPickup;
    }
  }

  Future<Map<String, dynamic>?> _liveSnapshot() async {
    try {
      if (widget.isDriverMode) {
        final res = await widget.apiClient.request('driver_hub.php', method: 'POST', data: {'action': 'dashboard', 'user': widget.userId});
        final body = jsonDecode(res.body);
        if (body['error'] == true) return null;
        final act = body['data']['active_ride'] as Map<String, dynamic>?;
        final live = body['data']['driver_live'] as Map<String, dynamic>?;
        if (act == null) return null;
        return {
          'ride_id': act['id'].toString(), 'status': act['status'],
          'driver_lat': live?['lat'], 'driver_lng': live?['lng'], 'driver_heading': live?['heading'] ?? 0,
          'pickup_lat': act['pickup_lat'], 'pickup_lng': act['pickup_lng'], 'dest_lat': act['dest_lat'], 'dest_lng': act['dest_lng'],
        };
      } else {
        final res = await widget.apiClient.request(ApiConstants.rideStatusEndpoint, method: 'POST', data: {'rider_id': widget.userId, 'ride_id': widget.ride['id'].toString()});
        final body = jsonDecode(res.body);
        if (body['error'] == true) return null;
        final ride = body['ride'] as Map<String, dynamic>?;
        final driver = body['driver'] as Map<String, dynamic>?;
        if (ride == null) return null;
        return {
          'ride_id': ride['id'].toString(), 'status': ride['status'],
          'driver_lat': driver?['lat'], 'driver_lng': driver?['lng'], 'driver_heading': driver?['heading'] ?? 0,
          'pickup_lat': ride['pickup_lat'], 'pickup_lng': ride['pickup_lng'], 'dest_lat': ride['dest_lat'], 'dest_lng': ride['dest_lng'],
        };
      }
    } catch (_) { return null; }
  }

  Future<void> _driverAction(String action) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final res = await widget.apiClient.request('driver_hub.php', method: 'POST', data: {
        'action': 'ride_action', 'user': widget.userId, 'ride_id': widget.ride['id'].toString(), 'ride_action': action,
        'lat': pos.latitude.toStringAsFixed(7), 'lng': pos.longitude.toStringAsFixed(7), 'heading': (pos.heading.isFinite ? pos.heading : 0).toStringAsFixed(2), 'accuracy': pos.accuracy.toStringAsFixed(2),
      });
      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body['error'] == true) throw Exception(body['message'] ?? 'Action failed');

      showToastNotification(context: context, title: 'Success', message: 'Trip updated.', isSuccess: true);
      widget.onChanged(true);
    } catch (e) {
      showToastNotification(context: context, title: 'Error', message: e.toString().replaceFirst('Exception: ', ''), isSuccess: false);
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _riderCancel() async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      final res = await widget.apiClient.request(ApiConstants.rideCancelEndpoint, method: 'POST', data: {'user_id': widget.userId, 'ride_id': widget.ride['id'].toString()});
      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body['error'] == true) throw Exception(body['message'] ?? 'Cancel failed');
      showToastNotification(context: context, title: 'Cancelled', message: 'Ride has been cancelled.', isSuccess: true);
      widget.onChanged(true);
    } catch (e) {
      showToastNotification(context: context, title: 'Error', message: e.toString().replaceFirst('Exception: ', ''), isSuccess: false);
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  void _call(String phone) async {
    final clean = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (clean.isEmpty) return;
    final uri = Uri.parse('tel:$clean');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
    else showToastNotification(context: context, title: 'Error', message: 'Unable to place call.', isSuccess: false);
  }

  void _resumeTrip() async {
    final status = (widget.ride['status'] ?? '').toString().toLowerCase();
    final activeStatuses = ['searching', 'accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination'];
    if (!activeStatuses.contains(status)) return;

    final List<LatLng> dropOffs = [];
    final stopsRaw = widget.ride['stops'];
    if (stopsRaw is List) {
      for (var s in stopsRaw) {
        if (s['lat'] != null && s['lng'] != null) dropOffs.add(LatLng(_d(s['lat']), _d(s['lng'])));
      }
    }

    final pickup = LatLng(_d(widget.ride['pickup_lat']), _d(widget.ride['pickup_lng']));
    final dest = LatLng(_d(widget.ride['dest_lat']), _d(widget.ride['dest_lng']));

    LatLng? driverInitialPos;
    if (widget.isDriverMode) {
      try {
        final pos = await Geolocator.getLastKnownPosition() ?? await Geolocator.getCurrentPosition();
        driverInitialPos = LatLng(pos.latitude, pos.longitude);
      } catch (_) {}
    }

    final rideType = widget.ride['ride_type']?.toString().toLowerCase() ?? 'standard';

    final args = TripNavigationArgs(
      userId: widget.userId,
      driverId: widget.isDriverMode ? widget.userId : (widget.ride['driver_id'] ?? '').toString(),
      tripId: widget.ride['id'].toString(),
      pickup: pickup, destination: dest, dropOffs: dropOffs,
      originText: widget.ride['pickup_text'] ?? '', destinationText: widget.ride['dest_text'] ?? '',
      rideType: rideType, driverName: widget.ride['peer_name'],
      vehicleType: widget.ride['vehicle_type']?.toString(), carPlate: widget.isDriverMode ? null : (widget.ride['peer_plate']?.toString()),
      rating: widget.isDriverMode ? null : _d(widget.ride['peer_rating']),
      initialDriverLocation: driverInitialPos, initialRiderLocation: pickup,
      initialPhase: _derivePhase(status), liveSnapshotProvider: _liveSnapshot,
      onStartTrip: widget.isDriverMode ? () => _driverAction('start_trip') : null,
      onArrivedPickup: widget.isDriverMode ? () => _driverAction('arrived_pickup') : null,
      onArrivedDestination: widget.isDriverMode ? () => _driverAction('arrived_destination') : null,
      onCompleteTrip: widget.isDriverMode ? () => _driverAction('complete_trip') : null,
      onCancelTrip: widget.isDriverMode ? () => _driverAction('cancel') : _riderCancel,
      role: widget.isDriverMode ? TripNavigationRole.driver : TripNavigationRole.rider,
      tickEvery: const Duration(seconds: 2), routeMinGap: const Duration(seconds: 3),
      arrivalMeters: 150, routeMoveThresholdMeters: 15, autoFollowCamera: true,
      showArrivedPickupButton: const {'accepted', 'driver_assigned', 'driver_arriving', 'enroute_pickup'}.contains(status),
      showStartTripButton: status == 'arrived_pickup',
      showArrivedDestinationButton: status == 'in_progress' || status == 'in_ride',
      showCompleteTripButton: status == 'arrived_destination',
      showCancelButton: true, showMetaCard: true, enableLivePickupTracking: false, preserveStopOrder: true, autoCloseOnCancel: true,
    );

    if (mounted) {
      widget.onChanged(false);
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => TripNavigationPage(args: args)));
    }
  }

  Color _statusColor(String s) {
    if (['searching', 'accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination'].contains(s)) return const Color(0xFF3B82F6);
    if (s == 'completed') return const Color(0xFF10B981);
    if (s == 'cancelled' || s == 'canceled') return const Color(0xFFEF4444);
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;
    final ui = UIScale.of(context);

    final status = (widget.ride['status'] ?? '').toString().toLowerCase();
    final isActive = ['searching', 'accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination'].contains(status);
    final avatarUrl = widget.ride['peer_avatar']?.toString() ?? '';
    final phone = widget.ride['peer_phone']?.toString() ?? '';
    final name = widget.ride['peer_name'] ?? (widget.isDriverMode ? 'Rider' : 'Driver');
    final plate = widget.ride['peer_plate']?.toString() ?? '';
    final rating = _d(widget.ride['peer_rating']);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * (ui.landscape ? 0.85 : 0.65),
        maxWidth: ui.tablet ? 600 : double.infinity,
      ),
      child: Container(
        margin: EdgeInsets.all(ui.inset(12)),
        // FIXED: Removed heavy shadows and BackdropFilter, using standard theme colors
        decoration: BoxDecoration(
          color: isDark ? cs.surface : Colors.white,
          borderRadius: BorderRadius.circular(ui.radius(20)),
          border: Border.all(
              color: isDark ? cs.outlineVariant.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.4),
              width: 1.0
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ui.radius(20)),
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.inset(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurfaceVariant.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                SizedBox(height: ui.gap(16)),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatCurrency(widget.ride['price'], widget.ride['currency'] ?? 'NGN'),
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: ui.font(20), color: cs.primary),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: ui.inset(8), vertical: ui.inset(4)),
                      decoration: BoxDecoration(
                        color: _statusColor(status).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(ui.radius(8)),
                      ),
                      child: Text(
                        status.toUpperCase().replaceAll('_', ' '),
                        style: TextStyle(color: _statusColor(status), fontWeight: FontWeight.w800, fontSize: ui.font(9.5)),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: ui.gap(16)),

                Container(
                  padding: EdgeInsets.all(ui.inset(12)),
                  decoration: BoxDecoration(
                    color: isDark ? cs.surfaceVariant.withOpacity(0.3) : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(ui.radius(12)),
                    border: Border.all(color: isDark ? cs.outlineVariant.withOpacity(0.2) : Colors.black12, width: 1),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: ui.gap(40),
                        height: ui.gap(40),
                        decoration: BoxDecoration(
                          color: cs.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(ui.radius(10)),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(ui.radius(10)),
                          child: avatarUrl.toString().isNotEmpty
                              ? Image.network(
                            avatarUrl.toString(),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Icon(widget.isDriverMode ? Icons.person : Icons.local_taxi_rounded, size: ui.icon(20), color: cs.primary),
                          )
                              : Icon(widget.isDriverMode ? Icons.person : Icons.local_taxi_rounded, size: ui.icon(20), color: cs.primary),
                        ),
                      ),
                      SizedBox(width: ui.gap(12)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.isDriverMode ? 'RIDER' : 'DRIVER',
                              style: TextStyle(fontSize: ui.font(9), fontWeight: FontWeight.w800, color: cs.onSurfaceVariant, letterSpacing: 0.5),
                            ),
                            SizedBox(height: ui.gap(2)),
                            Text(
                              name,
                              style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(14), color: cs.onSurface),
                            ),
                            if (plate.isNotEmpty || rating > 0) ...[
                              SizedBox(height: ui.gap(4)),
                              Row(
                                children: [
                                  if (plate.isNotEmpty)
                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: ui.inset(4), vertical: ui.inset(2)),
                                      decoration: BoxDecoration(color: const Color(0xFFFACC15), borderRadius: BorderRadius.circular(ui.radius(4))),
                                      child: Text(plate.toUpperCase(), style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: ui.font(8.5), letterSpacing: 0.5)),
                                    ),
                                  if (plate.isNotEmpty && rating > 0) SizedBox(width: ui.gap(8)),
                                  if (rating > 0)
                                    Row(
                                      children: [
                                        Icon(Icons.star_rounded, size: ui.icon(12), color: Colors.amber),
                                        SizedBox(width: ui.gap(2)),
                                        Text(rating.toStringAsFixed(1), style: TextStyle(fontWeight: FontWeight.w800, color: Colors.amber.shade700, fontSize: ui.font(11))),
                                      ],
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (phone.isNotEmpty)
                        Container(
                          width: ui.gap(32),
                          height: ui.gap(32),
                          decoration: BoxDecoration(color: cs.primary.withOpacity(0.15), shape: BoxShape.circle),
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: Icon(Icons.phone_rounded, color: cs.primary, size: ui.icon(16)),
                            onPressed: () => _call(phone),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: ui.gap(16)),

                _buildTimeline(isDark, cs, ui),
                SizedBox(height: ui.gap(20)),

                if (isActive)
                  SizedBox(
                    width: double.infinity,
                    height: ui.gap(44),
                    child: ElevatedButton.icon(
                      onPressed: _actionBusy ? null : _resumeTrip,
                      icon: _actionBusy ? SizedBox(width: ui.gap(16), height: ui.gap(16), child: const CircularProgressIndicator(strokeWidth: 2.0, color: Colors.white)) : Icon(Icons.navigation_rounded, size: ui.icon(16)),
                      label: Text(_actionBusy ? 'LOADING...' : 'RESUME NAVIGATION', style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(12.5), letterSpacing: 0.5)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: cs.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ui.radius(12))),
                      ),
                    ),
                  ),
                SizedBox(height: ui.gap(4)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimeline(bool isDark, ColorScheme cs, UIScale ui) {
    final pickup = widget.ride['pickup_text'] ?? '';
    final dest = widget.ride['dest_text'] ?? '';
    final stops = widget.ride['stops'] as List<dynamic>? ?? [];

    return Column(
      children: [
        _timelineItem(ui, Icons.radio_button_checked, 'PICKUP', pickup, cs.primary, isLast: stops.isEmpty),
        if (stops.isNotEmpty)
          ...stops.asMap().entries.map((e) => _timelineItem(ui, Icons.stop_circle_rounded, 'STOP ${e.key + 1}', e.value['address']?.toString() ?? 'Drop-off point', Colors.orange, isLast: e.key == stops.length - 1)),
        _timelineItem(ui, Icons.location_on_rounded, 'DESTINATION', dest, const Color(0xFF10B981), isLast: true),
      ],
    );
  }

  Widget _timelineItem(UIScale ui, IconData icon, String title, String address, Color color, {bool isLast = false}) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              padding: EdgeInsets.all(ui.inset(4)),
              decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
              child: Icon(icon, size: ui.icon(12), color: color),
            ),
            if (!isLast) Container(width: 1.5, height: ui.gap(24), color: color.withOpacity(0.3)),
          ],
        ),
        SizedBox(width: ui.gap(10)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: ui.gap(2)),
              Text(title, style: TextStyle(fontSize: ui.font(9), fontWeight: FontWeight.w800, color: cs.onSurfaceVariant, letterSpacing: 0.5)),
              SizedBox(height: ui.gap(2)),
              Text(address, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: ui.font(12), color: cs.onSurface)),
              if (!isLast) SizedBox(height: ui.gap(8)),
            ],
          ),
        ),
      ],
    );
  }
}

class _NativeSkeletonPulse extends StatefulWidget {
  final Widget child;
  const _NativeSkeletonPulse({required this.child});
  @override
  State<_NativeSkeletonPulse> createState() => _NativeSkeletonPulseState();
}

class _NativeSkeletonPulseState extends State<_NativeSkeletonPulse> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 0.8).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _anim, child: widget.child);
}