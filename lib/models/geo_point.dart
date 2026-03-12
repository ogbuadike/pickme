class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint(this.lat, this.lng);

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng};

  String toShort() => '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';
}