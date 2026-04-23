// lib/driver/state/driver_models.dart

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

  const DriverProfile({
    required this.id,
    required this.name,
    required this.phone,
    required this.rank,
    required this.category,
    required this.rating,
    required this.carPlate,
    required this.vehicleType,
    required this.seats,
    required this.completedTrips,
    required this.totalTrips,
    required this.cancelledTrips,
    required this.incompleteTrips,
    required this.isOnline,
    required this.avatarUrl,
    required this.status,
  });

  factory DriverProfile.fromJson(Map<dynamic, dynamic> json) {
    return DriverProfile(
      id: _toInt(json['id']),
      name: (json['name'] ?? 'Driver').toString(),
      phone: _stringOrNull(json['phone']),
      rank: _stringOrNull(json['rank']),
      category: (json['category'] ?? 'Standard').toString(),
      rating: _toDouble(json['rating'], fallback: 5.0),
      carPlate: _stringOrNull(json['car_plate']),
      vehicleType: (json['vehicle_type'] ?? 'car').toString(),
      seats: _toInt(json['seats'], fallback: 4),
      completedTrips: _toInt(json['completed_trips']),
      totalTrips: _toInt(json['total_trips']),
      cancelledTrips: _toInt(json['cancelled_trips']),
      incompleteTrips: _toInt(json['incomplete_trips']),
      isOnline: _toBool(json['is_online']),
      avatarUrl: _stringOrNull(json['avatar_url']),
      status: _stringOrNull(json['status']),
    );
  }

  DriverProfile copyWith({bool? isOnline}) {
    return DriverProfile(
      id: id, name: name, phone: phone, rank: rank, category: category,
      rating: rating, carPlate: carPlate, vehicleType: vehicleType, seats: seats,
      completedTrips: completedTrips, totalTrips: totalTrips,
      cancelledTrips: cancelledTrips, incompleteTrips: incompleteTrips,
      isOnline: isOnline ?? this.isOnline, avatarUrl: avatarUrl, status: status,
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

  const RideJob({
    required this.id, required this.riderId, required this.riderName, required this.riderPhone,
    required this.status, required this.category, required this.vehicleType, required this.seats,
    required this.price, required this.currency, required this.pickupLat, required this.pickupLng,
    required this.pickupText, required this.destLat, required this.destLng, required this.destText,
    required this.etaMin, required this.payMethod, required this.createdAt, required this.updatedAt,
  });

  factory RideJob.fromJson(Map<dynamic, dynamic> json) {
    return RideJob(
      id: _toInt(json['id']),
      riderId: (json['rider_id'] ?? '').toString(),
      riderName: (json['rider_name'] ?? 'Rider').toString(),
      riderPhone: _stringOrNull(json['rider_phone']),
      status: (json['status'] ?? 'searching').toString(),
      category: (json['category'] ?? 'Standard').toString(),
      vehicleType: (json['vehicle_type'] ?? 'car').toString(),
      seats: _toInt(json['seats'], fallback: 4),
      price: _toDouble(json['price']),
      currency: (json['currency'] ?? 'NGN').toString(),
      pickupLat: _toDouble(json['pickup_lat'], fallback: 0.0),
      pickupLng: _toDouble(json['pickup_lng'], fallback: 0.0),
      pickupText: (json['pickup_text'] ?? 'Pickup').toString(),
      destLat: _toDouble(json['dest_lat'], fallback: 0.0),
      destLng: _toDouble(json['dest_lng'], fallback: 0.0),
      destText: (json['dest_text'] ?? 'Destination').toString(),
      etaMin: _toInt(json['eta_min']),
      payMethod: (json['pay_method'] ?? 'cash').toString(),
      createdAt: _parseDate(json['created_at']),
      updatedAt: _parseDate(json['updated_at']),
    );
  }
}

// --- Helpers ---
int _toInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  return int.tryParse((value ?? '').toString()) ?? fallback;
}

double _toDouble(dynamic value, {double fallback = 0}) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  return double.tryParse((value ?? '').toString()) ?? fallback;
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

DateTime? _parseDate(dynamic value) {
  final text = (value ?? '').toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text.replaceFirst(' ', 'T'));
}