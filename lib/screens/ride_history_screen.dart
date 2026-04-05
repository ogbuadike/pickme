import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../themes/app_theme.dart';
import '../widgets/inner_background.dart';
import '../widgets/driver_details_sheet.dart'; // <--- INJECTED TO SUPPORT THE NEW PROFILE VIEW
import '../models/geo_point.dart';
import '../utility/notification.dart';
import 'trip_navigation_page.dart';

class RideHistoryScreen extends StatefulWidget {
  const RideHistoryScreen({super.key});

  @override
  State<RideHistoryScreen> createState() => _RideHistoryScreenState();
}

class _RideHistoryScreenState extends State<RideHistoryScreen> {
  late ApiClient _api;
  bool _isLoading = true;
  bool _isBackgroundSyncing = false;
  bool _isDriverMode = false;
  List<dynamic> _rides = [];
  String _activeFilter = 'All';
  String _userId = '';

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);
    _initAndLoad();
  }

  Future<void> _initAndLoad() async {
    final prefs = await SharedPreferences.getInstance();
    _isDriverMode = prefs.getBool('user_is_driver') ?? false;
    _userId = prefs.getString('user_id') ?? '';

    // Stale-while-revalidate caching
    final cachedData = prefs.getString('ride_history_cache_${_isDriverMode ? "driver" : "rider"}');
    if (cachedData != null && cachedData.isNotEmpty) {
      try {
        final decoded = jsonDecode(cachedData);
        if (mounted) {
          setState(() {
            _rides = decoded;
            _isLoading = false;
            _isBackgroundSyncing = true;
          });
        }
      } catch (_) {}
    }

    await _fetchHistoryFromNetwork();
  }

  Future<void> _fetchHistoryFromNetwork() async {
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

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('ride_history_cache_${_isDriverMode ? "driver" : "rider"}', jsonEncode(data));

        if (mounted) {
          setState(() {
            _rides = data;
            _isLoading = false;
            _isBackgroundSyncing = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isBackgroundSyncing = false;
        });
      }
    }
  }

  List<dynamic> get _filteredRides {
    if (_activeFilter == 'All') return _rides;
    if (_activeFilter == 'Active') {
      return _rides.where((r) => ['searching', 'accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination'].contains(r['status'])).toList();
    }
    return _rides.where((r) => r['status'].toString().toLowerCase() == _activeFilter.toLowerCase()).toList();
  }

  void _showRideDetails(Map<String, dynamic> ride) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _RideDetailSheet(
        ride: ride,
        isDriverMode: _isDriverMode,
        userId: _userId,
        apiClient: _api,
        onActionTriggered: () {
          Navigator.pop(context);
          _fetchHistoryFromNetwork();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filtered = _filteredRides;

    return Scaffold(
      backgroundColor: cs.background,
      appBar: AppBar(
        title: const Text('Ride History', style: TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (_isBackgroundSyncing)
            const Padding(
              padding: EdgeInsets.only(right: 20.0),
              child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          const BackgroundWidget(style: HoloStyle.vapor, intensity: 0.5, animate: true),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildFilters(),
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : RefreshIndicator(
                    onRefresh: _fetchHistoryFromNetwork,
                    color: AppColors.primary,
                    child: filtered.isEmpty
                        ? _buildEmptyState()
                        : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(top: 8, bottom: 40, left: 16, right: 16),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) => _RideCard(
                        ride: filtered[index] as Map<String, dynamic>,
                        isDriverMode: _isDriverMode,
                        onTap: () => _showRideDetails(filtered[index] as Map<String, dynamic>),
                      ),
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

  Widget _buildFilters() {
    final filters = ['All', 'Active', 'Completed', 'Canceled'];
    return SizedBox(
      height: 60,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        itemCount: filters.length,
        itemBuilder: (context, index) {
          final f = filters[index];
          final active = _activeFilter == f;
          return Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: ChoiceChip(
              label: Text(f, style: TextStyle(fontWeight: FontWeight.w700, color: active ? Colors.white : AppColors.textSecondary)),
              selected: active,
              selectedColor: AppColors.primary,
              backgroundColor: AppColors.surface.withOpacity(0.5),
              onSelected: (v) => setState(() => _activeFilter = f),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history_rounded, size: 80, color: AppColors.textSecondary.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text('No rides found', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          Text('Your $_activeFilter ride history will appear here.', style: TextStyle(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _RideCard extends StatelessWidget {
  final Map<String, dynamic> ride;
  final bool isDriverMode;
  final VoidCallback onTap;

  const _RideCard({required this.ride, required this.isDriverMode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final status = ride['status'].toString().toLowerCase().trim();
    final isActive = ['searching', 'accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination'].contains(status);

    Color statusColor;
    if (isActive) statusColor = AppColors.primary;
    else if (status == 'completed') statusColor = Colors.green;
    else statusColor = Colors.red;

    final dateStr = ride['created_at']?.toString() ?? '';
    String displayDate = '';
    if (dateStr.isNotEmpty) {
      try {
        final d = DateTime.parse(dateStr);
        displayDate = DateFormat('MMM d, yyyy • h:mm a').format(d);
      } catch (_) {}
    }

    final avatarUrl = ride['peer_avatar']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: cs.surface.withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isActive ? AppColors.primary.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(displayDate, style: TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: statusColor.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                      child: Text(status.toUpperCase(), style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.w900)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: AppColors.primary.withOpacity(0.1),
                      backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
                      child: avatarUrl.isEmpty ? Icon(isDriverMode ? Icons.person : Icons.local_taxi_rounded, color: AppColors.primary, size: 20) : null,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(ride['dest_text'] ?? 'Destination', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                          const SizedBox(height: 4),
                          Text('${ride['currency']} ${ride['price']}', style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.primary)),
                        ],
                      ),
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

class _RideDetailSheet extends StatefulWidget {
  final Map<String, dynamic> ride;
  final bool isDriverMode;
  final String userId;
  final ApiClient apiClient;
  final VoidCallback onActionTriggered;

  const _RideDetailSheet({
    required this.ride,
    required this.isDriverMode,
    required this.userId,
    required this.apiClient,
    required this.onActionTriggered
  });

  @override
  State<_RideDetailSheet> createState() => _RideDetailSheetState();
}

class _RideDetailSheetState extends State<_RideDetailSheet> {
  bool _isActionBusy = false;

  double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  TripNavPhase _derivePhase(String status) {
    switch (status.trim().toLowerCase()) {
      case 'searching':
      case 'accepted':
      case 'driver_assigned':
      case 'enroute_pickup':
        return TripNavPhase.driverToPickup;
      case 'arrived_pickup':
        return TripNavPhase.waitingPickup;
      case 'in_progress':
      case 'in_ride':
        return TripNavPhase.enRoute;
      case 'arrived_destination':
        return TripNavPhase.arrivedDestination;
      case 'completed':
        return TripNavPhase.completed;
      case 'canceled':
      case 'cancelled':
        return TripNavPhase.cancelled;
      default:
        return TripNavPhase.driverToPickup;
    }
  }

  // Live Snapshot Provider: Polls the backend while the map is open
  Future<Map<String, dynamic>?> _liveSnapshotProvider() async {
    try {
      if (widget.isDriverMode) {
        final res = await widget.apiClient.request(
          'driver_hub.php',
          method: 'POST',
          data: {'action': 'dashboard', 'user': widget.userId},
        );
        final body = jsonDecode(res.body);
        if (body['error'] == true) return null;
        final activeRide = body['data']['active_ride'];
        final live = body['data']['driver_live'];
        if (activeRide == null) return null;

        return {
          'ride_id': activeRide['id'].toString(),
          'status': activeRide['status'],
          'driver_lat': live != null ? live['lat'] : null,
          'driver_lng': live != null ? live['lng'] : null,
          'driver_heading': live != null ? live['heading'] : 0,
          'pickup_lat': activeRide['pickup_lat'],
          'pickup_lng': activeRide['pickup_lng'],
          'dest_lat': activeRide['dest_lat'],
          'dest_lng': activeRide['dest_lng'],
        };
      } else {
        // Rider mode fetching live data
        final res = await widget.apiClient.request(
          ApiConstants.rideStatusEndpoint,
          method: 'POST',
          data: {'rider_id': widget.userId, 'ride_id': widget.ride['id'].toString()},
        );
        final body = jsonDecode(res.body);
        if (body['error'] == true) return null;
        final ride = body['ride'];
        final driver = body['driver'];
        if (ride == null) return null;

        return {
          'ride_id': ride['id'].toString(),
          'status': ride['status'],
          'driver_lat': driver != null ? driver['lat'] : null,
          'driver_lng': driver != null ? driver['lng'] : null,
          'driver_heading': driver != null ? driver['heading'] : 0,
          'pickup_lat': ride['pickup_lat'],
          'pickup_lng': ride['pickup_lng'],
          'dest_lat': ride['dest_lat'],
          'dest_lng': ride['dest_lng'],
        };
      }
    } catch (_) {
      return null;
    }
  }

  // Backup Action executor for Drivers directly from History
  Future<void> _performBackupDriverAction(String action) async {
    if (_isActionBusy) return;
    setState(() => _isActionBusy = true);

    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

      final res = await widget.apiClient.request(
        'driver_hub.php',
        method: 'POST',
        data: {
          'action': 'ride_action',
          'user': widget.userId,
          'ride_id': widget.ride['id'].toString(),
          'ride_action': action,
          'lat': pos.latitude.toStringAsFixed(7),
          'lng': pos.longitude.toStringAsFixed(7),
          'heading': (pos.heading.isFinite ? pos.heading : 0).toStringAsFixed(2),
          'accuracy': pos.accuracy.toStringAsFixed(2), // DAC injection
        },
      );

      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body['error'] == true) {
        throw Exception(body['message'] ?? 'Action failed');
      }

      showToastNotification(context: context, title: 'Success', message: 'Trip updated successfully.', isSuccess: true);
      widget.onActionTriggered();
    } catch (e) {
      showToastNotification(context: context, title: 'Action Failed', message: e.toString().replaceAll('Exception: ', ''), isSuccess: false);
    } finally {
      if (mounted) setState(() => _isActionBusy = false);
    }
  }

  // Backup Cancel action for Riders
  Future<void> _performBackupRiderCancel() async {
    if (_isActionBusy) return;
    setState(() => _isActionBusy = true);

    try {
      final res = await widget.apiClient.request(
        ApiConstants.rideCancelEndpoint,
        method: 'POST',
        data: {
          'user_id': widget.userId,
          'ride_id': widget.ride['id'].toString(),
        },
      );

      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body['error'] == true) {
        throw Exception(body['message'] ?? 'Cancel failed');
      }

      showToastNotification(context: context, title: 'Canceled', message: 'Ride has been canceled.', isSuccess: true);
      widget.onActionTriggered();
    } catch (e) {
      showToastNotification(context: context, title: 'Failed to cancel', message: e.toString().replaceAll('Exception: ', ''), isSuccess: false);
    } finally {
      if (mounted) setState(() => _isActionBusy = false);
    }
  }

  void _resumeNavigation(BuildContext context) async {
    final status = widget.ride['status'].toString().toLowerCase().trim();
    final isActive = ['searching', 'accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination'].contains(status);
    if (!isActive) return;

    final List<LatLng> dropOffs = [];
    final List<String> dropOffTexts = [];
    if (widget.ride['stops'] is List) {
      for (var s in widget.ride['stops']) {
        if (s['lat'] != null && s['lng'] != null) {
          dropOffs.add(LatLng(_toDouble(s['lat']), _toDouble(s['lng'])));
          dropOffTexts.add('Stop');
        }
      }
    }

    final pickup = LatLng(_toDouble(widget.ride['pickup_lat']), _toDouble(widget.ride['pickup_lng']));
    final destination = LatLng(_toDouble(widget.ride['dest_lat']), _toDouble(widget.ride['dest_lng']));

    LatLng? initialDriverLocation;
    if (widget.isDriverMode) {
      try {
        final pos = await Geolocator.getLastKnownPosition() ?? await Geolocator.getCurrentPosition();
        initialDriverLocation = LatLng(pos.latitude, pos.longitude);
      } catch (_) {}
    }

    final args = TripNavigationArgs(
      userId: widget.isDriverMode ? widget.ride['rider_id'].toString() : widget.userId,
      driverId: widget.isDriverMode ? widget.userId : widget.ride['driver_id'].toString(),
      tripId: widget.ride['id'].toString(),
      pickup: pickup,
      destination: destination,
      dropOffs: dropOffs,
      dropOffTexts: dropOffTexts,
      originText: widget.ride['pickup_text'] ?? '',
      destinationText: widget.ride['dest_text'] ?? '',
      driverName: widget.isDriverMode ? null : widget.ride['peer_name'],
      vehicleType: widget.ride['vehicle_type']?.toString(),
      carPlate: widget.isDriverMode ? null : widget.ride['peer_plate'],
      rating: widget.isDriverMode ? null : _toDouble(widget.ride['peer_rating']),

      initialDriverLocation: initialDriverLocation,
      initialRiderLocation: pickup,
      initialPhase: _derivePhase(status),

      liveSnapshotProvider: _liveSnapshotProvider,

      onArrivedPickup: widget.isDriverMode ? () => _performBackupDriverAction('arrived_pickup') : null,
      onStartTrip: widget.isDriverMode ? () => _performBackupDriverAction('start_trip') : null,
      onArrivedDestination: widget.isDriverMode ? () => _performBackupDriverAction('arrived_destination') : null,
      onCompleteTrip: widget.isDriverMode ? () => _performBackupDriverAction('complete_trip') : null,
      onCancelTrip: widget.isDriverMode ? () => _performBackupDriverAction('cancel') : () => _performBackupRiderCancel(),

      role: widget.isDriverMode ? TripNavigationRole.driver : TripNavigationRole.rider,

      tickEvery: const Duration(seconds: 2),
      routeMinGap: const Duration(seconds: 2),
      arrivalMeters: 150.0,
      routeMoveThresholdMeters: 8.0,
      autoFollowCamera: true,

      showArrivedPickupButton: const {'accepted', 'driver_assigned', 'driver_arriving', 'enroute_pickup'}.contains(status),
      showStartTripButton: status == 'arrived_pickup',
      showArrivedDestinationButton: status == 'in_progress' || status == 'in_ride',
      showCompleteTripButton: status == 'arrived_destination',

      showCancelButton: true,
      showMetaCard: true,
      showDebugPanel: false,
      enableLivePickupTracking: false,
      preserveStopOrder: true,
      autoCloseOnCancel: true,
    );

    if (mounted) {
      Navigator.pop(context);
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => TripNavigationPage(args: args)));
    }
  }

  Future<void> _makePhoneCall(String phone) async {
    final cleanPhone = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleanPhone.isEmpty) return;

    final Uri url = Uri.parse('tel:$cleanPhone');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    } else {
      if (mounted) showToastNotification(context: context, title: 'Cannot Call', message: 'Phone dialer not supported on this device.', isSuccess: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.ride['status'].toString().toLowerCase().trim();
    final isActive = ['searching', 'accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination'].contains(status);
    final avatarUrl = widget.ride['peer_avatar']?.toString() ?? '';
    final phone = widget.ride['peer_phone']?.toString() ?? '';

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Trip Details', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                  Text('${widget.ride['currency']} ${widget.ride['price']}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.primary)),
                ],
              ),
              const SizedBox(height: 24),

              // Peer Profile Card: Wrapping with InkWell to launch DriverDetailsSheet
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => DriverDetailsSheet(
                        isViewOnly: true, // Hides the Confirm button
                        driver: {
                          'name': widget.ride['peer_name'],
                          'phone': widget.ride['peer_phone'],
                          'car_plate': widget.ride['peer_plate'],
                          'vehicle_type': widget.ride['vehicle_type'],
                          'rating': widget.ride['peer_rating'],
                          'avatar_url': widget.ride['peer_avatar'],
                        },
                        offer: {
                          'price': widget.ride['price'],
                          'currency': widget.ride['currency'],
                          'eta_min': widget.ride['eta_min'],
                        },
                        originText: widget.ride['pickup_text'] ?? '',
                        destinationText: widget.ride['dest_text'] ?? '',
                        distanceText: '—',
                        durationText: '—',
                        tripDistanceKm: 0.0,
                        pickupLocation: GeoPoint(_toDouble(widget.ride['pickup_lat']), _toDouble(widget.ride['pickup_lng'])),
                        dropLocation: GeoPoint(_toDouble(widget.ride['dest_lat']), _toDouble(widget.ride['dest_lng'])),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: AppColors.mintBgLight.withOpacity(0.1), borderRadius: BorderRadius.circular(16)),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 26,
                          backgroundColor: AppColors.primary.withOpacity(0.2),
                          backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
                          child: avatarUrl.isEmpty ? Icon(widget.isDriverMode ? Icons.person : Icons.local_taxi_rounded, color: AppColors.primary) : null,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(widget.isDriverMode ? 'Rider' : 'Driver', style: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w700)),
                              Text(widget.ride['peer_name'] ?? 'Unknown', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                              if (!widget.isDriverMode && widget.ride['peer_plate'] != null && widget.ride['peer_plate'].toString().isNotEmpty)
                                Text(widget.ride['peer_plate'], style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                        if (phone.isNotEmpty)
                          Container(
                            decoration: BoxDecoration(
                              color: AppColors.primary.withOpacity(0.15),
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.phone_rounded, color: AppColors.primary),
                              onPressed: () => _makePhoneCall(phone),
                            ),
                          )
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),
              // Timeline
              _buildTimelineRow(Icons.my_location_rounded, 'Pickup', widget.ride['pickup_text'] ?? '', true),

              // Handle multiple stops
              if (widget.ride['stops'] is List)
                ...((widget.ride['stops'] as List).map((stop) => _buildTimelineRow(Icons.stop_circle_rounded, 'Stop', 'Intermediate Drop-off', true, color: Colors.orange))),

              _buildTimelineRow(Icons.location_on_rounded, 'Destination', widget.ride['dest_text'] ?? '', false),

              const SizedBox(height: 32),

              // Actions
              if (isActive) ...[
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton.icon(
                    icon: _isActionBusy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.navigation_rounded),
                    label: Text(_isActionBusy ? 'Processing...' : 'Return to Live Navigation', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))
                    ),
                    onPressed: _isActionBusy ? null : () => _resumeNavigation(context),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineRow(IconData icon, String title, String address, bool showLine, {Color color = AppColors.primary}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
              child: Icon(icon, size: 16, color: color),
            ),
            if (showLine) Container(width: 2, height: 30, color: color.withOpacity(0.2)),
          ],
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(address, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ],
    );
  }
}