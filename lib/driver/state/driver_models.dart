// lib/driver/state/driver_models.dart
//
// Plain data models for the driver console plus the ride state machine that
// mirrors `rideAction()` in backend/endpoint/driver_hub.php.

/// Canonical ride lifecycle as seen by a driver.
///
/// Server strings (driver_hub.php `normalizeRideStatus`): `searching`,
/// `accepted` (legacy `driver_assigned`), `enroute_pickup`, `arrived_pickup`,
/// `in_progress` (legacy `in_ride`), `arrived_destination`, `completed`,
/// `canceled`.
enum DriverRideStatus {
  searching('searching'),
  accepted('accepted'),
  enroutePickup('enroute_pickup'),
  arrivedPickup('arrived_pickup'),
  inProgress('in_progress'),
  arrivedDestination('arrived_destination'),
  completed('completed'),
  canceled('canceled'),
  unknown('unknown');

  const DriverRideStatus(this.wire);

  /// The exact string the server stores/returns.
  final String wire;

  static DriverRideStatus parse(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case '':
      case 'searching':
        return DriverRideStatus.searching;
      case 'accepted':
      case 'driver_assigned':
        return DriverRideStatus.accepted;
      case 'enroute_pickup':
      case 'driver_arriving':
        return DriverRideStatus.enroutePickup;
      case 'arrived_pickup':
        return DriverRideStatus.arrivedPickup;
      case 'in_progress':
      case 'in_ride':
        return DriverRideStatus.inProgress;
      case 'arrived_destination':
        return DriverRideStatus.arrivedDestination;
      case 'completed':
        return DriverRideStatus.completed;
      case 'canceled':
      case 'cancelled':
      case 'cancel':
        return DriverRideStatus.canceled;
      default:
        return DriverRideStatus.unknown;
    }
  }

  bool get isTerminal => this == completed || this == canceled;

  /// The rider has not been picked up yet (navigate to pickup).
  bool get isBeforePickup => this == accepted || this == enroutePickup || this == arrivedPickup;

  /// The trip is under way (navigate to destination).
  bool get isOnTrip => this == inProgress || this == arrivedDestination;

  /// Cancelling from here is charged by the server (`$isChargeableAction`).
  bool get cancelIsCharged => isOnTrip;

  /// `phase` value written to `ride_driver_locations` by the heartbeat.
  /// Mirrors `phaseForRideStatus()` in driver_hub.php.
  String get heartbeatPhase {
    switch (this) {
      case accepted:
      case enroutePickup:
        return 'enroute_pickup';
      case arrivedPickup:
        return 'waiting_pickup';
      case inProgress:
        return 'enroute_destination';
      case arrivedDestination:
        return 'arrived_destination';
      default:
        return 'idle';
    }
  }

  /// Legal driver actions from this status, exactly as `rideAction()` enforces
  /// them server-side.
  bool allows(DriverRideAction action) {
    switch (action) {
      case DriverRideAction.arrivedPickup:
        return this == accepted || this == enroutePickup;
      case DriverRideAction.startTrip:
        return this == arrivedPickup;
      case DriverRideAction.arrivedDestination:
        return this == inProgress;
      case DriverRideAction.complete:
        return this == inProgress || this == arrivedDestination;
      case DriverRideAction.cancel:
        return this == accepted || this == enroutePickup || this == arrivedPickup || isOnTrip;
    }
  }

  /// The single "next step" the UI offers as its primary button.
  DriverRideAction? get primaryAction {
    switch (this) {
      case accepted:
      case enroutePickup:
        return DriverRideAction.arrivedPickup;
      case arrivedPickup:
        return DriverRideAction.startTrip;
      case inProgress:
        return DriverRideAction.arrivedDestination;
      case arrivedDestination:
        return DriverRideAction.complete;
      default:
        return null;
    }
  }

  String get label {
    switch (this) {
      case searching:
        return 'Searching';
      case accepted:
      case enroutePickup:
        return 'To Pickup';
      case arrivedPickup:
        return 'At Pickup';
      case inProgress:
        return 'On Trip';
      case arrivedDestination:
        return 'At Dropoff';
      case completed:
        return 'Completed';
      case canceled:
        return 'Canceled';
      case unknown:
        return 'Unknown';
    }
  }
}

/// Driver-initiated transitions accepted by `driver_hub.php?action=ride_action`.
enum DriverRideAction {
  arrivedPickup('arrived_pickup', DriverRideStatus.arrivedPickup, 'Arrived at pickup'),
  startTrip('start_trip', DriverRideStatus.inProgress, 'Start trip'),
  arrivedDestination('arrived_destination', DriverRideStatus.arrivedDestination, 'Arrived at destination'),
  complete('complete_trip', DriverRideStatus.completed, 'Complete trip'),
  cancel('cancel', DriverRideStatus.canceled, 'Cancel trip');

  const DriverRideAction(this.wire, this.target, this.label);

  /// `ride_action` value sent to the server.
  final String wire;

  /// Status the ride is in after the server accepts the action.
  final DriverRideStatus target;

  final String label;

  /// Actions validated by the server against the driver's GPS fix.
  bool get needsGps => this != DriverRideAction.cancel;
}

class DriverProfile {
  final int id;
  final String name;
  final String? phone;
  final String? rank;
  final String category;
  final double rating;
  final String? carPlate;
  final String vehicleType;
  final int seats;
  final int completedTrips;
  final int totalTrips;
  final int cancelledTrips;
  final int incompleteTrips;
  final bool isOnline;
  final String? avatarUrl;
  final String? status;
  final String allowedRideTypes;

  const DriverProfile({
    required this.id, required this.name, required this.phone, required this.rank,
    required this.category, required this.rating, required this.carPlate,
    required this.vehicleType, required this.seats, required this.completedTrips,
    required this.totalTrips, required this.cancelledTrips, required this.incompleteTrips,
    required this.isOnline, required this.avatarUrl, required this.status, required this.allowedRideTypes,
  });

  factory DriverProfile.fromJson(Map<dynamic, dynamic> json) {
    return DriverProfile(
      id: _toInt(json['id']), name: (json['name'] ?? 'Driver').toString(),
      phone: _stringOrNull(json['phone']), rank: _stringOrNull(json['rank']),
      category: (json['category'] ?? 'Standard').toString(), rating: _toDouble(json['rating'], fallback: 5.0),
      carPlate: _stringOrNull(json['car_plate']), vehicleType: (json['vehicle_type'] ?? 'car').toString(),
      seats: _toInt(json['seats'], fallback: 4), completedTrips: _toInt(json['completed_trips']),
      totalTrips: _toInt(json['total_trips']), cancelledTrips: _toInt(json['cancelled_trips']),
      incompleteTrips: _toInt(json['incomplete_trips']), isOnline: _toBool(json['is_online']),
      avatarUrl: _stringOrNull(json['avatar_url']), status: _stringOrNull(json['status']),
      allowedRideTypes: (json['allowed_ride_types'] ?? 'street_ride,campus_ride').toString(),
    );
  }

  /// Ride types this driver may be offered (`allowed_ride_types`, CSV).
  Set<String> get allowedRideTypeSet => allowedRideTypes
      .split(',')
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toSet();

  bool canServe(RideJob ride) {
    final allowed = allowedRideTypeSet;
    return allowed.isEmpty || allowed.contains(ride.rideType.trim().toLowerCase());
  }

  DriverProfile copyWith({bool? isOnline}) {
    return DriverProfile(
      id: id, name: name, phone: phone, rank: rank, category: category, rating: rating,
      carPlate: carPlate, vehicleType: vehicleType, seats: seats, completedTrips: completedTrips,
      totalTrips: totalTrips, cancelledTrips: cancelledTrips, incompleteTrips: incompleteTrips,
      isOnline: isOnline ?? this.isOnline, avatarUrl: avatarUrl, status: status, allowedRideTypes: allowedRideTypes,
    );
  }
}

class RideJob {
  final int id;
  final String riderId;
  final String riderName;
  final String? riderPhone;
  final String status;
  final String category;
  final String vehicleType;
  final int seats;
  final double price;
  final String currency;
  final double pickupLat;
  final double pickupLng;
  final String pickupText;
  final double destLat;
  final double destLng;
  final String destText;
  final int etaMin;
  final String payMethod;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  // --- LOGISTICS FIELDS ---
  final String rideType;
  final String? packageSize;
  final double packageWeight;

  /// The server currently leaks the recipient's PIN to the driver. The UI must
  /// never display it; only [requiresDeliveryOtp] is used.
  final String? deliveryOtp;
  final String? batchGroupId;
  final String? recipientPhone;
  final String? packageImage;
  final String? instructions;

  // --- FINANCIAL FIELD ---
  final double appFeePercentage;

  const RideJob({
    required this.id, required this.riderId, required this.riderName, required this.riderPhone,
    required this.status, required this.category, required this.vehicleType, required this.seats,
    required this.price, required this.currency, required this.pickupLat, required this.pickupLng,
    required this.pickupText, required this.destLat, required this.destLng, required this.destText,
    required this.etaMin, required this.payMethod, required this.createdAt, required this.updatedAt,
    required this.rideType, required this.packageSize, required this.packageWeight,
    required this.deliveryOtp, required this.batchGroupId, required this.recipientPhone,
    required this.packageImage, required this.instructions,
    required this.appFeePercentage,
  });

  factory RideJob.fromJson(Map<dynamic, dynamic> json) {
    return RideJob(
      id: _toInt(json['id']), riderId: (json['rider_id'] ?? '').toString(),
      riderName: (json['rider_name'] ?? 'Rider').toString(), riderPhone: _stringOrNull(json['rider_phone']),
      // Normalised so legacy aliases (driver_assigned, in_ride, cancelled) never leak into UI checks.
      status: DriverRideStatus.parse(json['status']?.toString()).wire,
      category: (json['category'] ?? 'Standard').toString(),
      vehicleType: (json['vehicle_type'] ?? 'car').toString(), seats: _toInt(json['seats'], fallback: 4),
      price: _toDouble(json['price']), currency: (json['currency'] ?? 'NGN').toString(),
      pickupLat: _toDouble(json['pickup_lat']), pickupLng: _toDouble(json['pickup_lng']),
      pickupText: _textOr(json['pickup_text'], 'Pickup'), destLat: _toDouble(json['dest_lat']),
      destLng: _toDouble(json['dest_lng']), destText: _textOr(json['dest_text'], 'Destination'),
      etaMin: _toInt(json['eta_min']), payMethod: (json['pay_method'] ?? 'cash').toString(),
      createdAt: _parseDate(json['created_at']), updatedAt: _parseDate(json['updated_at']),
      rideType: (json['ride_type'] ?? 'street_ride').toString().trim().toLowerCase(),
      packageSize: _stringOrNull(json['package_size']),
      packageWeight: _toDouble(json['package_weight']),
      deliveryOtp: _stringOrNull(json['delivery_otp']),
      batchGroupId: _stringOrNull(json['batch_group_id']),
      recipientPhone: _stringOrNull(json['recipient_phone']),
      packageImage: _stringOrNull(json['package_image']),
      instructions: _stringOrNull(json['instructions']),
      appFeePercentage: _toDouble(json['app_fee_percentage'], fallback: 25.0),
    );
  }

  RideJob copyWith({String? status}) {
    return RideJob(
      id: id, riderId: riderId, riderName: riderName, riderPhone: riderPhone,
      status: status ?? this.status, category: category, vehicleType: vehicleType, seats: seats,
      price: price, currency: currency, pickupLat: pickupLat, pickupLng: pickupLng,
      pickupText: pickupText, destLat: destLat, destLng: destLng, destText: destText,
      etaMin: etaMin, payMethod: payMethod, createdAt: createdAt, updatedAt: DateTime.now(),
      rideType: rideType, packageSize: packageSize, packageWeight: packageWeight,
      deliveryOtp: deliveryOtp, batchGroupId: batchGroupId, recipientPhone: recipientPhone,
      packageImage: packageImage, instructions: instructions, appFeePercentage: appFeePercentage,
    );
  }

  DriverRideStatus get rideStatus => DriverRideStatus.parse(status);

  bool get isDispatch => rideType == 'dispatch';
  bool get isSendMe => rideType == 'send_me';
  bool get isLogistics => isDispatch || isSendMe;

  /// `user_logistics.php` issues a 4-digit PIN for every send_me and dispatch
  /// job; the driver must collect it before completing.
  bool get requiresDeliveryOtp => isLogistics;

  /// Phone of whoever receives at the destination.
  String? get handoffPhone => isDispatch ? (recipientPhone ?? riderPhone) : riderPhone;

  bool get hasPickupCoords => _validCoord(pickupLat, pickupLng);
  bool get hasDestCoords => _validCoord(destLat, destLng);

  double get driverEarnings => price - appFee;
  double get appFee => price * (appFeePercentage / 100.0);

  /// Changes whenever something the UI renders changes.
  String get signature => '$id|$status|${updatedAt?.millisecondsSinceEpoch ?? 0}|$price';
}

bool _validCoord(double lat, double lng) =>
    lat.isFinite && lng.isFinite && !(lat == 0 && lng == 0) && lat.abs() <= 90 && lng.abs() <= 180;

int _toInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is double) return value.round();
  return int.tryParse((value ?? '').toString().trim()) ?? fallback;
}

double _toDouble(dynamic value, {double fallback = 0}) {
  if (value is double) return value.isFinite ? value : fallback;
  if (value is int) return value.toDouble();
  final parsed = double.tryParse((value ?? '').toString().trim());
  return (parsed != null && parsed.isFinite) ? parsed : fallback;
}

bool _toBool(dynamic value) {
  if (value is bool) return value;
  final text = (value ?? '').toString().trim().toLowerCase();
  return text == '1' || text == 'true' || text == 'yes' || text == 'online';
}

String? _stringOrNull(dynamic value) {
  final text = (value ?? '').toString().trim();
  return text.isEmpty ? null : text;
}

String _textOr(dynamic value, String fallback) => _stringOrNull(value) ?? fallback;

DateTime? _parseDate(dynamic value) {
  final text = (value ?? '').toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text.replaceFirst(' ', 'T'));
}
