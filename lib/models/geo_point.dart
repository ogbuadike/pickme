// lib/models/geo_point.dart
class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint(this.lat, this.lng);

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng};

  String toShort() => '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';

  // Value semantics: widgets receive a fresh GeoPoint on every parent build,
  // so identity comparison would make every rebuild look like a change.
  @override
  bool operator ==(Object other) => other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'GeoPoint(${toShort()})';
}
