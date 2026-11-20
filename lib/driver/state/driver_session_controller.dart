// lib/driver/state/driver_session_controller.dart
//
// Source of truth for the driver console: profile, active job, offers,
// online state and every server transition. Widgets only render it.
//
// Guarantees:
//  * The active job is always restored from the server (dashboard) on launch
//    and on resume; nothing important lives only in memory.
//  * One dashboard request at a time; polling is a self-rescheduling one-shot
//    timer (no overlap), stops in the background and backs off on errors/429.
//  * Snapshots that were requested before a local transition are discarded
//    (generation counter), so the UI never flickers back to an old state.
//  * Every mutation has an in-flight guard and a deterministic request id, and
//    transient failures are reconciled against the server before reporting.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/driver_location_updater.dart';
import 'driver_api.dart';
import 'driver_models.dart';

/// A queued ride presented to the driver with an accept window.
@immutable
class DriverOffer {
  final RideJob ride;
  final DateTime expiresAt;
  final bool held;

  const DriverOffer({required this.ride, required this.expiresAt, required this.held});

  Duration get remaining {
    final r = expiresAt.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }
}

enum AcceptOutcome { accepted, taken, failed }

/// One-off notifications for the UI (toasts, haptics). Not state.
sealed class DriverEvent {
  const DriverEvent();
}

class NewOfferEvent extends DriverEvent {
  final RideJob ride;
  const NewOfferEvent(this.ride);
}

class RideEndedRemotelyEvent extends DriverEvent {
  final RideJob ride;
  const RideEndedRemotelyEvent(this.ride);
}

class RideRestoredEvent extends DriverEvent {
  final RideJob ride;
  const RideRestoredEvent(this.ride);
}

class SessionEndedEvent extends DriverEvent {
  final String message;
  const SessionEndedEvent(this.message);
}

class DriverSessionController extends ChangeNotifier {
  static const Duration offerWindow = Duration(seconds: 30);
  static const Duration _pollActive = Duration(seconds: 4);
  static const Duration _pollOnline = Duration(seconds: 3);
  static const Duration _pollOffline = Duration(seconds: 20);
  static const Duration _maxFixAgeForAction = Duration(seconds: 45);

  // Mirrors driver_hub.php constants so the driver gets instant feedback.
  static const double _arrivedPickupMaxM = 200.0;
  static const double _startTripMaxM = 200.0;
  static const double _arrivedDestinationMaxM = 150.0;
  static const double _completeMaxM = 200.0;

  static const String _dismissedKey = 'driver_dismissed_offers_v1';
  static const String _otpVerifiedKey = 'driver_otp_verified_v1';

  final DriverHubApi api;
  final DriverLocationUpdater location;
  final SharedPreferences prefs;

  DriverSessionController({required this.api, required this.location, required this.prefs}) {
    location.phaseProvider = () => activeRide?.rideStatus.heartbeatPhase ?? 'idle';
  }

  // ---- public state ----------------------------------------------------------
  DriverProfile? driver;
  RideJob? activeRide;
  List<DriverOffer> offers = const [];
  bool booting = true;
  String? bootError;
  bool connected = true;
  DateTime? lastSyncAt;
  bool busyOnline = false;
  int? acceptingRideId;
  DriverRideAction? pendingAction;

  /// Active ride for listeners that only care about it (map).
  final ValueNotifier<RideJob?> activeRideListenable = ValueNotifier<RideJob?>(null);

  Stream<DriverEvent> get events => _events.stream;

  bool get isOnline => driver?.isOnline == true;
  bool get busyRideAction => acceptingRideId != null || pendingAction != null;

  // ---- internals ------------------------------------------------------------
  final StreamController<DriverEvent> _events = StreamController<DriverEvent>.broadcast();
  final Map<int, DateTime> _firstSeen = {};
  final Map<int, DateTime> _dismissed = {};
  final Set<int> _held = {};
  final Set<int> _otpVerified = {};
  final Map<int, DriverRideStatus> _endedLocally = {};
  final Set<int> _endedRemotely = {};
  List<RideJob> _lastQueue = const [];

  Timer? _pollTimer;
  Timer? _offerExpiryTimer;
  Future<void>? _refreshing;
  int _generation = 0;
  int _pollFailures = 0;
  Duration? _retryAfter;
  bool _foreground = true;
  bool _started = false;
  bool _disposed = false;
  bool _sessionEnded = false;
  int _mutations = 0;
  bool _dismissedDirty = false;

  // ===========================================================================
  // Lifecycle

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _loadPersisted();
    await refresh();
    if (_disposed) return;
    booting = false;
    final ride = activeRide;
    if (ride != null) _emit(RideRestoredEvent(ride));
    _notify();
  }

  /// Call from `didChangeAppLifecycleState` (resumed / paused only).
  void setForeground(bool foreground) {
    if (_disposed || foreground == _foreground) return;
    _foreground = foreground;
    location.setForeground(foreground);
    if (foreground) {
      _pollFailures = 0;
      _sessionEnded = false;
      unawaited(refresh());
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _offerExpiryTimer?.cancel();
    _events.close();
    activeRideListenable.dispose();
    super.dispose();
  }

  // ===========================================================================
  // Polling

  /// Fetches the dashboard. Concurrent callers share the in-flight request;
  /// pass [fresh] to guarantee the data was requested after this call.
  ///
  /// While a mutation is in flight, snapshots are not applied (they may predate
  /// the server commit) unless [reconcile] is set by the mutation itself.
  Future<void> refresh({bool fresh = false, bool reconcile = false}) async {
    if (_disposed) return;
    final inFlight = _refreshing;
    if (inFlight != null) {
      if (!fresh) return inFlight;
      await inFlight;
      if (_disposed) return;
      final again = _refreshing;
      if (again != null && !reconcile) return again;
    }
    final future = _doRefresh(reconcile: reconcile);
    _refreshing = future;
    try {
      await future;
    } finally {
      if (identical(_refreshing, future)) _refreshing = null;
    }
  }

  Future<void> _doRefresh({required bool reconcile}) async {
    final gen = _generation;
    _pollTimer?.cancel();
    _pollTimer = null;
    try {
      final dash = await api.dashboard();
      if (_disposed) return;
      _pollFailures = 0;
      _retryAfter = null;
      connected = true;
      bootError = null;
      lastSyncAt = DateTime.now();
      if (gen == _generation && (reconcile || _mutations == 0)) {
        _applyDashboard(dash);
      }
      // Otherwise a transition started/finished while this was in flight; its
      // own follow-up refresh delivers the authoritative state.
    } on DriverApiException catch (e) {
      if (_disposed) return;
      _pollFailures++;
      _retryAfter = e.retryAfter;
      if (e.isAuth && !_sessionEnded) {
        _sessionEnded = true; // stop polling; the app routes to login
        _emit(SessionEndedEvent(e.message));
      }
      if (e.isTransient) connected = false;
      if (booting && driver == null) bootError = e.message;
    } catch (e) {
      if (_disposed) return;
      _pollFailures++;
      if (booting && driver == null) bootError = 'Unable to load the driver dashboard.';
    } finally {
      if (!_disposed) {
        _notify();
        _scheduleNextPoll();
      }
    }
  }

  void _scheduleNextPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_disposed || !_foreground || _sessionEnded) return;
    var delay = activeRide != null ? _pollActive : (isOnline ? _pollOnline : _pollOffline);
    if (_pollFailures > 0) {
      final backoff = Duration(seconds: (1 << _pollFailures.clamp(1, 5)).clamp(2, 30)); // 2,4,8,16,30
      if (backoff > delay) delay = backoff;
    }
    final ra = _retryAfter;
    if (ra != null && ra > delay) delay = ra;
    _pollTimer = Timer(delay, () => unawaited(refresh()));
  }

  void _applyDashboard(DriverDashboard dash) {
    driver = dash.driver;
    final previous = activeRide;
    final next = dash.activeRide;

    if (previous != null && (next == null || next.id != previous.id)) {
      if (!_endedLocally.containsKey(previous.id)) {
        // The rider/admin ended it (driver_hub only returns live statuses).
        _endedRemotely.add(previous.id);
        _otpVerified.remove(previous.id);
        _persistOtp();
        _emit(RideEndedRemotelyEvent(previous));
      }
    }
    _setActiveRide(next);
    _lastQueue = dash.queue;
    _rebuildOffers();
    _syncTrackingMode();
  }

  void _setActiveRide(RideJob? ride) {
    activeRide = ride;
    if (activeRideListenable.value?.signature != ride?.signature) {
      activeRideListenable.value = ride;
    }
  }

  void _syncTrackingMode() {
    final mode = activeRide != null
        ? DriverTrackingMode.onTrip
        : (isOnline ? DriverTrackingMode.idle : DriverTrackingMode.off);
    location.setMode(mode);
  }

  // ===========================================================================
  // Offers

  void _rebuildOffers() {
    if (_disposed) return;
    final now = DateTime.now();
    final before = _dismissed.length;
    _dismissed.removeWhere((_, at) => now.difference(at) > const Duration(minutes: 30));
    if (_dismissed.length != before) _dismissedDirty = true;

    final d = driver;
    final eligible = (d == null || !d.isOnline || activeRide != null)
        ? const <RideJob>[]
        : _lastQueue.where((r) =>
            r.rideStatus == DriverRideStatus.searching && !_dismissed.containsKey(r.id) && d.canServe(r));

    final live = <int>{};
    final next = <DriverOffer>[];
    for (final ride in eligible) {
      live.add(ride.id);
      final isNew = !_firstSeen.containsKey(ride.id);
      final seen = _firstSeen.putIfAbsent(ride.id, () => now);
      final held = _held.contains(ride.id);
      final expiresAt = seen.add(offerWindow);
      if (!held && !expiresAt.isAfter(now)) {
        _dismissed[ride.id] = now; // missed
        _dismissedDirty = true;
        continue;
      }
      next.add(DriverOffer(ride: ride, expiresAt: expiresAt, held: held));
      if (isNew) _emit(NewOfferEvent(ride));
    }
    _firstSeen.removeWhere((id, _) => !live.contains(id));
    offers = List.unmodifiable(next);
    if (_dismissedDirty) _persistDismissed();
    _scheduleOfferExpiry();
  }

  void _scheduleOfferExpiry() {
    _offerExpiryTimer?.cancel();
    _offerExpiryTimer = null;
    DateTime? soonest;
    for (final o in offers) {
      if (o.held) continue;
      if (soonest == null || o.expiresAt.isBefore(soonest)) soonest = o.expiresAt;
    }
    if (soonest == null) return;
    final delay = soonest.difference(DateTime.now()) + const Duration(milliseconds: 50);
    _offerExpiryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      if (_disposed) return;
      _rebuildOffers();
      _notify();
    });
  }

  void declineOffer(int rideId) {
    if (acceptingRideId == rideId) return;
    _dismiss(rideId);
  }

  void _dismiss(int rideId) {
    _dismissed[rideId] = DateTime.now();
    _dismissedDirty = true;
    _held.remove(rideId);
    _rebuildOffers();
    _notify();
  }

  /// Freezes an offer's countdown (e.g. while the PIN sheet is open).
  void holdOffer(int rideId, bool hold) {
    final changed = hold ? _held.add(rideId) : _held.remove(rideId);
    if (!changed) return;
    if (!hold) _firstSeen[rideId] = DateTime.now().subtract(offerWindow ~/ 2); // 15 s grace
    _rebuildOffers();
    _notify();
  }

  Future<AcceptOutcome> acceptOffer(RideJob ride) async {
    if (acceptingRideId != null || pendingAction != null) return AcceptOutcome.failed;
    if (activeRide != null) throw const DriverActionRejected('Finish your current trip before accepting another.');
    if (!isOnline) throw const DriverActionRejected('Go online to accept requests.');

    acceptingRideId = ride.id;
    _held.add(ride.id);
    _beginMutation();
    try {
      await api.acceptRide(ride.id, requestId: 'accept:${ride.id}:${driver?.id ?? 0}');
      _onAccepted(ride);
      return AcceptOutcome.accepted;
    } on DriverApiException catch (e) {
      if (e.isConflict) {
        _dismissed[ride.id] = DateTime.now();
        _dismissedDirty = true;
        return AcceptOutcome.taken;
      }
      if (e.isTransient) {
        // Unknown outcome: the server may have assigned it to us.
        await refresh(fresh: true, reconcile: true);
        if (activeRide?.id == ride.id) return AcceptOutcome.accepted;
      }
      rethrow;
    } finally {
      acceptingRideId = null;
      _held.remove(ride.id);
      if (activeRide?.id != ride.id && !_dismissed.containsKey(ride.id)) {
        _firstSeen[ride.id] = DateTime.now().subtract(offerWindow ~/ 2); // grace after a failed try
      }
      _rebuildOffers();
      _endMutation();
    }
  }

  void _onAccepted(RideJob ride) {
    _endedLocally.remove(ride.id);
    _endedRemotely.remove(ride.id);
    _setActiveRide(ride.copyWith(status: DriverRideStatus.accepted.wire));
    _syncTrackingMode();
    location.flush();
  }

  // ===========================================================================
  // Online / offline

  Future<void> setOnline(bool online, {DriverLocationFix? fix}) async {
    final d = driver;
    if (d == null || busyOnline) return;
    if (d.isOnline == online) return;
    if (!online && activeRide != null) {
      throw const DriverActionRejected('Finish or cancel your current trip before going offline.');
    }
    busyOnline = true;
    _beginMutation();
    try {
      await api.setOnline(online, gps: online ? fix?.toPayload() : null);
      driver = d.copyWith(isOnline: online);
      if (!online) {
        offers = const [];
        _offerExpiryTimer?.cancel();
      }
      _syncTrackingMode();
    } finally {
      busyOnline = false;
      _endMutation();
    }
  }

  // ===========================================================================
  // Ride transitions

  bool isOtpVerified(int rideId) => _otpVerified.contains(rideId);

  Future<void> verifyDeliveryOtp(int rideId, String otp) async {
    await api.verifyDeliveryOtp(rideId, otp);
    _otpVerified.add(rideId);
    _persistOtp();
  }

  /// Returns a reason the action cannot run right now, or null.
  String? localGuard(RideJob ride, DriverRideAction action, DriverLocationFix? fix) {
    if (!ride.rideStatus.allows(action)) {
      return '${action.label} is not available while the trip is "${ride.rideStatus.label}".';
    }
    if (action == DriverRideAction.complete && ride.requiresDeliveryOtp && !isOtpVerified(ride.id)) {
      return 'Verify the delivery PIN first.';
    }
    if (!action.needsGps) return null;
    if (fix == null) return 'Waiting for a GPS fix. Make sure location is on.';
    if (fix.age > _maxFixAgeForAction) return 'Your GPS fix is stale. Wait a moment and try again.';

    final compensation = fix.accuracy.clamp(0.0, 150.0);
    double gap(double lat, double lng) => Geolocator.distanceBetween(fix.lat, fix.lng, lat, lng);

    switch (action) {
      case DriverRideAction.arrivedPickup:
        final d = gap(ride.pickupLat, ride.pickupLng);
        if (ride.hasPickupCoords && d > _arrivedPickupMaxM + compensation) {
          return 'You are ${d.round()} m from the pickup point.';
        }
        break;
      case DriverRideAction.startTrip:
        final d = gap(ride.pickupLat, ride.pickupLng);
        if (ride.hasPickupCoords && d > _startTripMaxM + compensation) {
          return 'Start the trip at the pickup point (${d.round()} m away).';
        }
        break;
      case DriverRideAction.arrivedDestination:
        final d = gap(ride.destLat, ride.destLng);
        if (ride.hasDestCoords && d > _arrivedDestinationMaxM + compensation) {
          return 'You are ${d.round()} m from the destination.';
        }
        break;
      case DriverRideAction.complete:
        final d = gap(ride.destLat, ride.destLng);
        if (ride.hasDestCoords && d > _completeMaxM + compensation) {
          return 'Complete the trip at the destination (${d.round()} m away).';
        }
        break;
      case DriverRideAction.cancel:
        break;
    }
    return null;
  }

  /// Runs one transition. Throws [DriverActionRejected] or [DriverApiException].
  Future<void> performRideAction(DriverRideAction action) async {
    final ride = activeRide;
    if (ride == null) throw const DriverActionRejected('There is no active trip.');
    if (pendingAction != null || acceptingRideId != null) {
      throw const DriverActionRejected('Please wait, the previous action is still in progress.');
    }
    // Claim the in-flight slot before any await so a double tap cannot slip in.
    pendingAction = action;
    _beginMutation();
    try {
      var fix = location.fix.value;
      if (fix == null || fix.age > const Duration(seconds: 15)) {
        fix = await location.currentFix(timeout: const Duration(seconds: 6)) ?? fix;
      }
      if (_disposed) return;
      // Re-read after the await: a poll may have changed the ride underneath us.
      final current = activeRide;
      if (current == null || current.id != ride.id) {
        throw const DriverActionRejected('This trip is no longer active.');
      }
      final guard = localGuard(current, action, fix);
      if (guard != null) throw DriverActionRejected(guard);

      try {
        await api.rideAction(
          current.id,
          action,
          gps: fix?.toPayload(),
          requestId: 'ride:${current.id}:${action.wire}:${current.status}',
        );
      } on DriverApiException catch (e) {
        if (!e.isTransient && !e.isConflict) rethrow;
        // Unknown outcome / state moved: reconcile with the server. Pre-mark a
        // terminal action so a vanished ride is not reported as "ended by rider".
        if (action.target.isTerminal) _endedLocally[current.id] = action.target;
        await refresh(fresh: true, reconcile: true);
        final now = activeRide;
        final reached = (action.target.isTerminal && (now == null || now.id != current.id)) ||
            (now != null && now.id == current.id && now.rideStatus == action.target);
        if (!reached) {
          _endedLocally.remove(current.id);
          rethrow;
        }
      }
      _applyLocalTransition(current, action);
    } finally {
      pendingAction = null;
      if (!_disposed) {
        _syncTrackingMode();
        location.flush();
      }
      _endMutation();
    }
  }

  void _applyLocalTransition(RideJob ride, DriverRideAction action) {
    if (action.target.isTerminal) {
      _endedLocally[ride.id] = action.target;
      _otpVerified.remove(ride.id);
      _persistOtp();
      if (activeRide?.id == ride.id) _setActiveRide(null);
      _rebuildOffers();
    } else if (activeRide?.id == ride.id) {
      _setActiveRide(ride.copyWith(status: action.target.wire));
    }
  }

  /// Local snapshot for TripNavigationPage's `liveSnapshotProvider`: no network
  /// (the controller is already polling) and the freshest local GPS fix.
  Map<String, dynamic>? navigationSnapshot(int rideId) {
    final ride = activeRide;
    if (ride == null || ride.id != rideId) {
      final ended = _endedLocally[rideId] ?? (_endedRemotely.contains(rideId) ? DriverRideStatus.canceled : null);
      if (ended == null) return null;
      return {'ride_id': '$rideId', 'status': ended.wire, 'phase': ended.wire, 'ride_status': ended.wire};
    }
    final fix = location.fix.value;
    final status = ride.status;
    return <String, dynamic>{
      'ride_id': '${ride.id}',
      'status': status,
      'phase': status,
      'ride_status': status,
      'driver_id': '${driver?.id ?? ''}',
      if (fix != null) 'driver_lat': fix.lat,
      if (fix != null) 'driver_lng': fix.lng,
      if (fix != null) 'driver_heading': fix.bearing,
      'pickup_lat': ride.pickupLat,
      'pickup_lng': ride.pickupLng,
      'pickup_text': ride.pickupText,
      'destination_lat': ride.destLat,
      'destination_lng': ride.destLng,
      'destination_text': ride.destText,
      'rider_lat': ride.pickupLat,
      'rider_lng': ride.pickupLng,
    };
  }

  // ===========================================================================
  // Persistence (small, best effort)

  void _loadPersisted() {
    try {
      final raw = prefs.getString(_dismissedKey);
      if (raw != null) {
        final map = jsonDecode(raw);
        if (map is Map) {
          map.forEach((k, v) {
            final id = int.tryParse('$k');
            final ms = int.tryParse('$v');
            if (id != null && ms != null) _dismissed[id] = DateTime.fromMillisecondsSinceEpoch(ms);
          });
        }
      }
      final otp = prefs.getStringList(_otpVerifiedKey) ?? const [];
      _otpVerified.addAll(otp.map(int.tryParse).whereType<int>());
    } catch (_) {}
  }

  void _persistDismissed() {
    _dismissedDirty = false;
    final data = _dismissed.map((k, v) => MapEntry('$k', v.millisecondsSinceEpoch));
    unawaited(prefs.setString(_dismissedKey, jsonEncode(data)).catchError((_) => false));
  }

  void _persistOtp() {
    unawaited(prefs.setStringList(_otpVerifiedKey, _otpVerified.map((e) => '$e').toList()).catchError((_) => false));
  }

  // ===========================================================================

  void _beginMutation() {
    _mutations++;
    _generation++;
    _notify();
  }

  /// Discards snapshots requested during the mutation and fetches a fresh one.
  void _endMutation() {
    _mutations = _mutations > 0 ? _mutations - 1 : 0;
    _generation++;
    if (_disposed) return;
    _notify();
    unawaited(refresh(fresh: true));
  }

  void _emit(DriverEvent e) {
    if (!_disposed && !_events.isClosed) _events.add(e);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
