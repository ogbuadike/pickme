// lib/models/ride_model.dart
//
// Minimal typed ride. Tolerates both payload shapes the backend returns:
//  * ride_history.php: flat `pickup_lat`, `dest_lat`, `pickup_text`, ...
//  * ride_status.php : nested `pickup: {lat,lng,text}`, `destination: {...}`
// and string/number ids.
class Ride {
  final int id;
  final String status;
  final double pickupLat, pickupLng, destLat, destLng;
  final String? pickupAddress, destAddress;
  final double? userLat, userLng, driverLat, driverLng;

  Ride({
    required this.id,
    required this.status,
    required this.pickupLat,
    required this.pickupLng,
    required this.destLat,
    required this.destLng,
    this.pickupAddress,
    this.destAddress,
    this.userLat,
    this.userLng,
    this.driverLat,
    this.driverLng,
  });

  static double? _d(Object? v) {
    if (v == null) return null;
    if (v is num) return v.isFinite ? v.toDouble() : null;
    final double? d = double.tryParse(v.toString().trim());
    return (d != null && d.isFinite) ? d : null;
  }

  static String? _s(Object? v) {
    final String s = (v ?? '').toString().trim();
    return s.isEmpty ? null : s;
  }

  factory Ride.fromJson(Map<String, dynamic> j) {
    final Map<dynamic, dynamic> p = j['pickup'] is Map ? j['pickup'] as Map : const <dynamic, dynamic>{};
    final Map<dynamic, dynamic> d = j['destination'] is Map ? j['destination'] as Map : const <dynamic, dynamic>{};
    final double? dLat = _d(j['driver_lat']);
    final double? dLng = _d(j['driver_lng']);
    final bool driverFix = dLat != null && dLng != null && !(dLat == 0 && dLng == 0);
    return Ride(
      id: int.tryParse('${j['id'] ?? j['ride_id'] ?? ''}') ?? 0,
      status: _s(j['status']) ?? 'searching',
      pickupLat: _d(j['pickup_lat']) ?? _d(p['lat']) ?? 0,
      pickupLng: _d(j['pickup_lng']) ?? _d(p['lng']) ?? 0,
      destLat: _d(j['destination_lat']) ?? _d(j['dest_lat']) ?? _d(d['lat']) ?? 0,
      destLng: _d(j['destination_lng']) ?? _d(j['dest_lng']) ?? _d(d['lng']) ?? 0,
      pickupAddress: _s(j['pickup_address']) ?? _s(j['pickup_text']) ?? _s(p['text']),
      destAddress: _s(j['destination_address']) ?? _s(j['dest_text']) ?? _s(d['text']),
      userLat: _d(j['user_lat']),
      userLng: _d(j['user_lng']),
      driverLat: driverFix ? dLat : null,
      driverLng: driverFix ? dLng : null,
    );
  }
}
