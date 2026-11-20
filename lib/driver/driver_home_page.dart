// lib/driver/driver_home_page.dart
//
// Driver console screen. Composition only:
//   * DriverSessionController  – server state, polling, transitions
//   * DriverLocationUpdater    – GPS stream + heartbeat
//   * DriverMapView            – map (never rebuilt by state changes)
//   * DriverCommandCenter / ActiveRideCard – bottom panel
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../routes/routes.dart';
import '../screens/authentication/transactionAuthSheet.dart';
import '../screens/trip_navigation_page.dart';
import '../services/driver_location_updater.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../utility/notification.dart';
import '../widgets/app_menu_drawer.dart';
import '../widgets/fund_account_sheet.dart';
import '../widgets/header_bar.dart';
import 'state/driver_api.dart';
import 'state/driver_command_center.dart';
import 'state/driver_location_permission.dart';
import 'state/driver_models.dart';
import 'state/driver_session_controller.dart';
import 'widgets/active_ride_card.dart';
import 'widgets/delivery_otp_sheet.dart';
import 'widgets/driver_map_view.dart';

class DriverHomePage extends StatefulWidget {
  const DriverHomePage({super.key});

  @override
  State<DriverHomePage> createState() => _DriverHomePageState();
}

class _DriverHomePageState extends State<DriverHomePage> with WidgetsBindingObserver {
  static const double _headerVisualH = 88.0;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>(debugLabel: 'DriverHomeScaffold');

  late final ApiClient _api;
  late final DriverLocationUpdater _location;
  final DriverMapController _mapController = DriverMapController();
  final ValueNotifier<EdgeInsets> _mapPadding = ValueNotifier<EdgeInsets>(EdgeInsets.zero);

  SharedPreferences? _prefs;
  DriverHubApi? _hub;
  DriverSessionController? _session;
  StreamSubscription<DriverEvent>? _eventSub;
  Widget? _mapLayer;

  Map<String, dynamic>? _user;
  bool _busyProfile = false;
  bool _panelExpanded = false;
  bool _onlineFlow = false;
  bool _acceptFlow = false;
  bool _rideFlow = false;
  bool _navOpen = false;
  double _panelHeight = 0;

  String get _userId => _prefs?.getString('user_id')?.trim() ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = ApiClient();
    _location = DriverLocationUpdater(_api, sender: (fix, phase) async {
      final hub = _hub;
      if (hub == null) throw const DriverActionRejected('Driver session not ready.');
      await hub.heartbeat(fix.toPayload(), phase: phase);
    });
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final hub = DriverHubApi(_api, () => _userId);
    _hub = hub;
    final session = DriverSessionController(api: hub, location: _location, prefs: prefs);
    _eventSub = session.events.listen(_onEvent);
    setState(() {
      _prefs = prefs;
      _session = session;
    });
    unawaited(_fetchUser());
    await session.start();
    if (!mounted) return;
    // Background-safe: only prime GPS if permission already exists. Asking is
    // reserved for explicit actions (go online, trip actions).
    if (await DriverLocationPermissionGate.hasAccess()) {
      unawaited(_location.currentFix());
    } else if (mounted && (session.isOnline || session.activeRide != null)) {
      // Restored as online / on a trip without location access: ask once.
      final ok = await DriverLocationPermissionGate.ensure(context, userTriggered: false);
      if (ok && mounted) {
        _location.retry();
        unawaited(_location.currentFix());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSub?.cancel();
    _session?.dispose();
    _location.dispose();
    _mapController.dispose();
    _mapPadding.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` also fires for permission dialogs / the notification shade:
    // reacting to it would tear down tracking and re-prompt in a loop.
    switch (state) {
      case AppLifecycleState.resumed:
        _session?.setForeground(true);
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _session?.setForeground(false);
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Events

  void _onEvent(DriverEvent e) {
    if (!mounted) return;
    switch (e) {
      case NewOfferEvent():
        if (_session?.booting == true) return;
        HapticFeedback.heavyImpact();
        SystemSound.play(SystemSoundType.alert);
        if (!_panelExpanded) setState(() => _panelExpanded = true);
      case RideEndedRemotelyEvent(:final ride):
        HapticFeedback.mediumImpact();
        _toast('Trip ended', '${ride.riderName.isNotEmpty ? ride.riderName : 'The customer'} canceled this trip.', ok: false);
      case RideRestoredEvent():
        _toast('Trip restored', 'Picking up where you left off.', ok: true);
      case SessionEndedEvent():
        break; // ApiTransport.onUnauthorized routes to login.
    }
  }

  void _toast(String title, String message, {required bool ok}) {
    if (!mounted) return;
    showToastNotification(context: context, title: title, message: message, isSuccess: ok);
  }

  static String _errorText(Object e) => e.toString().replaceFirst('Exception: ', '');

  // ---------------------------------------------------------------------------
  // Profile header

  Future<void> _fetchUser() async {
    final uid = _userId;
    if (uid.isEmpty || _busyProfile) return;
    setState(() => _busyProfile = true);
    try {
      final res = await _api.request(ApiConstants.userInfoEndpoint, method: 'POST', data: {'user': uid}, timeout: const Duration(seconds: 10));
      final body = jsonDecode(res.body);
      if (body is Map && body['error'] == false && body['user'] is Map && mounted) {
        setState(() => _user = (body['user'] as Map).map((k, v) => MapEntry<String, dynamic>(k.toString(), v)));
      }
    } catch (_) {
      // Header falls back to placeholders; dashboard connectivity is tracked separately.
    } finally {
      if (mounted) setState(() => _busyProfile = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Online / offline

  Future<void> _toggleOnline(bool value) async {
    final s = _session;
    if (s == null || _onlineFlow || s.busyOnline) return;
    _onlineFlow = true;
    try {
      DriverLocationFix? fix;
      if (value) {
        if (!await DriverLocationPermissionGate.ensure(context)) return;
        if (!mounted) return;
        _location.retry();
        fix = await _location.currentFix();
        if (!mounted) return;
        if (fix == null) {
          _toast('Waiting for GPS', 'We could not get your location yet. Move to open sky and try again.', ok: false);
          return;
        }
      }
      await s.setOnline(value, fix: fix);
      HapticFeedback.mediumImpact();
    } catch (e) {
      _toast('Update failed', _errorText(e), ok: false);
    } finally {
      _onlineFlow = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Offers

  Future<void> _accept(RideJob ride) async {
    final s = _session;
    if (s == null || _acceptFlow || s.busyRideAction) return;
    _acceptFlow = true;
    s.holdOffer(ride.id, true);
    try {
      final authorized = await TransactionPinBottomSheet.show(context, _api);
      if (!mounted || !authorized) return;
      final outcome = await s.acceptOffer(ride);
      if (!mounted) return;
      switch (outcome) {
        case AcceptOutcome.accepted:
          HapticFeedback.heavyImpact();
          _toast('Ride accepted', 'Head to the pickup point.', ok: true);
        case AcceptOutcome.taken:
          HapticFeedback.mediumImpact();
          _toast('Request taken', 'Another driver accepted this request first.', ok: false);
        case AcceptOutcome.failed:
          break;
      }
    } catch (e) {
      _toast('Unable to accept', _errorText(e), ok: false);
    } finally {
      _acceptFlow = false;
      if (mounted) s.holdOffer(ride.id, false);
    }
  }

  void _decline(RideJob ride) {
    HapticFeedback.selectionClick();
    _session?.declineOffer(ride.id);
  }

  // ---------------------------------------------------------------------------
  // Trip transitions

  Future<bool> _confirmCancel(RideJob ride) async {
    final charged = ride.rideStatus.cancelIsCharged;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this trip?'),
        content: Text(charged
            ? 'The trip has already started. Cancelling now still deducts the app fee from your wallet and counts as a cancelled trip.'
            : 'The customer will be notified and this counts as a cancelled trip on your profile.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep trip')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Cancel trip'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Runs one transition including its UI preconditions (confirm, permission,
  /// delivery PIN). With [rethrowErrors] failures propagate to the caller
  /// (TripNavigationPage) so it does not advance its phase optimistically.
  Future<void> _runRideAction(DriverRideAction action, {bool rethrowErrors = false}) async {
    final s = _session;
    final ride = s?.activeRide;
    try {
      if (s == null || ride == null) throw const DriverActionRejected('There is no active trip.');
      if (_rideFlow || s.busyRideAction) throw const DriverActionRejected('Please wait, the previous action is still in progress.');
      _rideFlow = true;
      try {
        if (action == DriverRideAction.cancel) {
          if (!await _confirmCancel(ride)) throw const DriverActionRejected('Trip was not cancelled.');
        }
        if (action.needsGps && !await DriverLocationPermissionGate.hasAccess()) {
          if (!mounted || !await DriverLocationPermissionGate.ensure(context)) {
            throw const DriverActionRejected('Location access is required for this step.');
          }
          _location.retry();
        }
        if (action == DriverRideAction.complete && ride.requiresDeliveryOtp && !s.isOtpVerified(ride.id)) {
          if (!mounted) throw const DriverActionRejected('Screen closed.');
          final verified = await DeliveryOtpSheet.show(
            context,
            recipientPhone: ride.handoffPhone ?? '',
            verify: (otp) => s.verifyDeliveryOtp(ride.id, otp),
          );
          if (!verified) throw const DriverActionRejected('Delivery PIN not verified.');
        }
        await s.performRideAction(action);
      } finally {
        _rideFlow = false;
      }
      HapticFeedback.selectionClick();
      if (!rethrowErrors) {
        if (action == DriverRideAction.complete) {
          _toast('Trip completed', 'Nice work! Earnings have been recorded.', ok: true);
        } else if (action == DriverRideAction.cancel) {
          _toast('Trip cancelled', 'You are available for new requests.', ok: true);
        }
      }
    } catch (e) {
      if (rethrowErrors) rethrow;
      final silent = e is DriverActionRejected && e.message == 'Trip was not cancelled.';
      if (!silent) _toast('Action failed', _errorText(e), ok: false);
    }
  }

  TripNavPhase _navPhaseFor(DriverRideStatus status) {
    switch (status) {
      case DriverRideStatus.arrivedPickup:
        return TripNavPhase.waitingPickup;
      case DriverRideStatus.inProgress:
        return TripNavPhase.enRoute;
      case DriverRideStatus.arrivedDestination:
        return TripNavPhase.arrivedDestination;
      case DriverRideStatus.completed:
        return TripNavPhase.completed;
      case DriverRideStatus.canceled:
        return TripNavPhase.cancelled;
      default:
        return TripNavPhase.driverToPickup;
    }
  }

  Future<void> _openTripNavigation() async {
    final s = _session;
    final ride = s?.activeRide;
    final driver = s?.driver;
    if (s == null || ride == null || driver == null || _navOpen) return;
    _navOpen = true;
    try {
      final fix = _location.fix.value;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TripNavigationPage(
            args: TripNavigationArgs(
              userId: ride.riderId,
              driverId: '${driver.id}',
              tripId: '${ride.id}',
              rideType: ride.rideType.replaceAll('_', ' '),
              pickup: LatLng(ride.pickupLat, ride.pickupLng),
              destination: LatLng(ride.destLat, ride.destLng),
              originText: ride.pickupText,
              destinationText: ride.destText,
              driverName: driver.name,
              vehicleType: driver.vehicleType,
              carPlate: driver.carPlate,
              rating: driver.rating,
              initialDriverLocation: fix?.latLng,
              initialRiderLocation: LatLng(ride.pickupLat, ride.pickupLng),
              initialPhase: _navPhaseFor(ride.rideStatus),
              // Local snapshot (no network): the session controller is already polling.
              liveSnapshotProvider: () async => s.navigationSnapshot(ride.id),
              onArrivedPickup: () => _runRideAction(DriverRideAction.arrivedPickup, rethrowErrors: true),
              onStartTrip: () => _runRideAction(DriverRideAction.startTrip, rethrowErrors: true),
              onArrivedDestination: () => _runRideAction(DriverRideAction.arrivedDestination, rethrowErrors: true),
              onCompleteTrip: () => _runRideAction(DriverRideAction.complete, rethrowErrors: true),
              onCancelTrip: () => _runRideAction(DriverRideAction.cancel, rethrowErrors: true),
              role: TripNavigationRole.driver,
              tickEvery: const Duration(seconds: 1),
              routeMinGap: const Duration(seconds: 20),
              arrivalMeters: 35.0,
              routeMoveThresholdMeters: 25.0,
              autoFollowCamera: true,
              // The page gates each button by its live phase; these only enable them.
              showArrivedPickupButton: true,
              showStartTripButton: true,
              showArrivedDestinationButton: true,
              showCompleteTripButton: true,
              showCancelButton: true,
              showMetaCard: true,
              showDebugPanel: false,
              enableLivePickupTracking: false,
              preserveStopOrder: true,
              autoCloseOnCancel: true,
            ),
          ),
        ),
      );
    } finally {
      _navOpen = false;
      if (mounted) unawaited(s.refresh(fresh: true));
    }
  }

  void _openWallet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FundAccountSheet(
        account: _user,
        balance: double.tryParse('${_user?['user_bal'] ?? _user?['bal'] ?? 0}') ?? 0.0,
        currency: '${_user?['user_currency'] ?? 'NGN'}',
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Layout

  void _updateMapPadding(double panelHeight) {
    _panelHeight = panelHeight;
    if (!mounted) return;
    final mq = MediaQuery.of(context);
    final uiScale = UIScale.of(context);
    final scale = (uiScale.shortest / 390.0).clamp(0.56, 1.12);
    final top = mq.padding.top + _headerVisualH * scale;
    final bottomNavH = uiScale.compact ? 110.0 : uiScale.inset(116.0);
    final bottom = (panelHeight + bottomNavH + uiScale.gap(12)).clamp(20.0, mq.size.height * 0.6);
    final next = EdgeInsets.fromLTRB(8, top, 8, bottom);
    if (next != _mapPadding.value) _mapPadding.value = next;
  }

  Widget _buildMapLayer(DriverSessionController? s) {
    if (s == null) return const SizedBox.shrink();
    // Cached instance: page rebuilds never rebuild the GoogleMap subtree.
    return _mapLayer ??= DriverMapView(
      controller: _mapController,
      fix: _location.fix,
      activeRide: s.activeRideListenable,
      padding: _mapPadding,
    );
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mq = MediaQuery.of(context);
    final safeTop = mq.padding.top;
    final headerHeight = safeTop + _headerVisualH;
    final bottomNavH = uiScale.compact ? 110.0 : uiScale.inset(116.0);
    final panelMaxHeight = uiScale.landscape
        ? (mq.size.height * 0.45).clamp(250.0, 320.0)
        : (mq.size.height * 0.45).clamp(300.0, 420.0);
    final activeCardMaxHeight = (mq.size.height - headerHeight - bottomNavH - 24).clamp(240.0, mq.size.height * 0.62);
    final s = _session;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: theme.scaffoldBackgroundColor,
      drawer: AppMenuDrawer(user: _user),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          Positioned.fill(child: _buildMapLayer(s)),

          Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: Container(
                height: headerHeight + 18,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black.withValues(alpha: .64), Colors.transparent],
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            top: safeTop, left: 0, right: 0,
            child: HeaderBar(
              user: _user,
              busyProfile: _busyProfile,
              hasActiveTask: s?.activeRide != null,
              onMenu: () => _scaffoldKey.currentState?.openDrawer(),
              onWallet: _openWallet,
              onNotifications: () => Navigator.pushNamed(context, AppRoutes.notifications),
            ),
          ),

          if (s != null)
            ListenableBuilder(
              listenable: s,
              builder: (context, _) => (s.connected || s.booting)
                  ? const SizedBox.shrink()
                  : Positioned(
                      top: headerHeight + 8, left: uiScale.inset(14), right: uiScale.inset(14),
                      child: Material(
                        color: Colors.orange.shade700,
                        borderRadius: BorderRadius.circular(uiScale.radius(12)),
                        child: Padding(
                          padding: EdgeInsets.all(uiScale.inset(10)),
                          child: Row(children: [
                            Icon(Icons.wifi_off_rounded, size: uiScale.icon(18), color: Colors.white),
                            SizedBox(width: uiScale.gap(8)),
                            Expanded(
                              child: Text('Connection issue. Retrying automatically…',
                                  style: TextStyle(color: Colors.white, fontSize: uiScale.font(12), fontWeight: FontWeight.w700)),
                            ),
                          ]),
                        ),
                      ),
                    ),
            ),

          // Locate / recenter button.
          Positioned(
            right: uiScale.inset(14),
            bottom: bottomNavH + (_panelHeight > 0 ? _panelHeight : 150.0) + uiScale.gap(16),
            child: ValueListenableBuilder<bool>(
              valueListenable: _mapController.following,
              builder: (context, following, _) => FloatingActionButton.small(
                heroTag: 'driver_locate_fab',
                tooltip: following ? 'Show whole trip' : 'Re-center',
                onPressed: () {
                  HapticFeedback.selectionClick();
                  if (following && s?.activeRide != null) {
                    _mapController.showOverview();
                  } else {
                    _mapController.recenter();
                  }
                },
                child: Icon(following ? Icons.my_location_rounded : Icons.location_searching_rounded),
              ),
            ),
          ),

          // Bottom panel.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomNavH, left: uiScale.inset(12), right: uiScale.inset(12)),
              child: _MeasureSize(
                onChange: (size) {
                  _updateMapPadding(size.height);
                  if (mounted) setState(() {}); // repositions the FAB only
                },
                child: s == null
                    ? _BootingPanel(uiScale: uiScale, cs: cs)
                    : ListenableBuilder(
                        listenable: Listenable.merge([s, _location.lastSentAt]),
                        builder: (context, _) => _buildPanel(s, uiScale, panelMaxHeight, activeCardMaxHeight),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel(DriverSessionController s, UIScale uiScale, double panelMaxHeight, double activeCardMaxHeight) {
    final cs = Theme.of(context).colorScheme;
    if (s.booting) return _BootingPanel(uiScale: uiScale, cs: cs);
    if (s.driver == null) {
      return _BootErrorPanel(
        uiScale: uiScale,
        message: s.bootError ?? 'Unable to load your driver profile.',
        onRetry: () => unawaited(s.refresh(fresh: true)),
      );
    }
    final ride = s.activeRide;
    if (ride != null) {
      return ActiveRideCard(
        key: ValueKey('active_${ride.id}'),
        ride: ride,
        uiScale: uiScale,
        maxHeight: activeCardMaxHeight,
        pendingAction: s.pendingAction,
        otpVerified: s.isOtpVerified(ride.id),
        onAction: (a) => unawaited(_runRideAction(a)),
        onNavigate: () => unawaited(_openTripNavigation()),
      );
    }
    return DriverCommandCenter(
      uiScale: uiScale,
      height: panelMaxHeight,
      expanded: _panelExpanded,
      driver: s.driver,
      offers: s.offers,
      lastSyncAt: s.lastSyncAt,
      lastHeartbeatAt: _location.lastSentAt.value,
      connected: s.connected,
      busyOnlineToggle: s.busyOnline || _onlineFlow,
      acceptingRideId: s.acceptingRideId,
      driverPosition: _location.fix.value?.latLng,
      onExpandToggle: () => setState(() => _panelExpanded = !_panelExpanded),
      onOnlineToggle: (v) => unawaited(_toggleOnline(v)),
      onWallet: _openWallet,
      onHistory: () => Navigator.pushNamed(context, AppRoutes.history),
      onProfile: () => Navigator.pushNamed(context, AppRoutes.profile),
      onRefresh: () => unawaited(s.refresh(fresh: true)),
      onAccept: (ride) => unawaited(_accept(ride)),
      onDecline: _decline,
    );
  }
}

class _BootingPanel extends StatelessWidget {
  final UIScale uiScale;
  final ColorScheme cs;
  const _BootingPanel({required this.uiScale, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 150,
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(uiScale.radius(28)),
      ),
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

class _BootErrorPanel extends StatelessWidget {
  final UIScale uiScale;
  final String message;
  final VoidCallback onRetry;
  const _BootErrorPanel({required this.uiScale, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.all(uiScale.inset(18)),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(uiScale.radius(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, color: AppColors.primary, size: uiScale.icon(32)),
          SizedBox(height: uiScale.gap(8)),
          Text(message, textAlign: TextAlign.center, style: TextStyle(fontSize: uiScale.font(13), fontWeight: FontWeight.w700)),
          SizedBox(height: uiScale.gap(12)),
          FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('Retry')),
        ],
      ),
    );
  }
}

/// Reports its child's size after layout (post-frame, only on change).
class _MeasureSize extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onChange;
  const _MeasureSize({required this.onChange, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasureSize(onChange);

  @override
  void updateRenderObject(BuildContext context, covariant _RenderMeasureSize renderObject) {
    renderObject.onChange = onChange;
  }
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onChange);
  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    final s = size;
    if (s == _last) return;
    _last = s;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onChange(s);
    });
  }
}
