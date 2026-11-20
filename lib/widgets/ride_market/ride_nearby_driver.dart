// lib/widgets/ride_market/ride_nearby_driver.dart
//
// View-model for a driver listed in the ride market sheet. Re-exported from
// ride_market_sheet.dart for source compatibility.
import 'package:flutter/material.dart';

import '../../services/ride_market_service.dart';

enum VehicleClass { car, keke, bike }

VehicleClass vehicleClassOf(String vehicleType) {
  final String v = vehicleType.toLowerCase();
  if (v.contains('bike') || v.contains('moto')) return VehicleClass.bike;
  if (v.contains('keke') || v.contains('tricycle') || v.contains('rickshaw')) return VehicleClass.keke;
  return VehicleClass.car;
}

String vehicleLabelOf(String vehicleType) {
  switch (vehicleClassOf(vehicleType)) {
    case VehicleClass.bike:
      return 'Bike';
    case VehicleClass.keke:
      return 'Ke-ke';
    case VehicleClass.car:
      return 'Car';
  }
}

IconData vehicleIconOf(String vehicleType) {
  final String v = vehicleType.toLowerCase();
  switch (vehicleClassOf(v)) {
    case VehicleClass.bike:
      return Icons.two_wheeler_rounded;
    case VehicleClass.keke:
      return Icons.electric_rickshaw_rounded;
    case VehicleClass.car:
      if (v.contains('bus') || v.contains('van')) return Icons.airport_shuttle_rounded;
      if (v.contains('lux') || v.contains('vip')) return Icons.workspace_premium_rounded;
      return Icons.directions_car_filled_rounded;
  }
}

String _fixUrl(String url) {
  String u = url.trim();
  if (u.isEmpty) return '';
  if (u.startsWith('//')) u = 'https:$u';
  if (u.startsWith('http://')) u = 'https://${u.substring(7)}';
  return u.startsWith('https://') ? u : '';
}

num _num(dynamic v, num fallback) {
  if (v == null) return fallback;
  if (v is num) return v.isFinite ? v : fallback;
  return num.tryParse(v.toString().trim()) ?? fallback;
}

List<String> _strList(dynamic v) {
  if (v == null) return const <String>[];
  Iterable<String> raw;
  if (v is List) {
    raw = v.map((dynamic e) => e.toString());
  } else {
    String s = v.toString().trim();
    if (s.startsWith('[') && s.endsWith(']')) s = s.substring(1, s.length - 1);
    raw = s.split(',').map((String x) => x.replaceAll('"', '').replaceAll("'", ''));
  }
  return raw.map(_fixUrl).where((String x) => x.isNotEmpty).toList(growable: false);
}

@immutable
class RideNearbyDriver {
  final String id;
  final String name;
  final String category;
  final double rating;
  final String carPlate;
  final double heading;
  final double lat;
  final double lng;
  final double distanceKm;
  final int etaMin;
  final String vehicleType;
  final int seats;
  final List<String> vehicleImages;
  final String vehicleDescription;
  final String carImageUrl;
  final String avatarUrl;
  final String phone;
  final String nin;
  final String rank;
  final int completedTrips;
  final int cancelledTrips;
  final int incompleteTrips;
  final int reviewsCount;
  final int totalTrips;
  final String currency;
  final double pricePerKm;
  final double baseFare;
  final double estimatedTotal;
  final double tripKm;

  const RideNearbyDriver({
    required this.id,
    required this.name,
    required this.category,
    required this.rating,
    required this.carPlate,
    required this.heading,
    required this.lat,
    required this.lng,
    required this.distanceKm,
    required this.etaMin,
    this.vehicleType = 'car',
    this.seats = 4,
    this.vehicleImages = const <String>[],
    this.vehicleDescription = '',
    this.carImageUrl = '',
    this.avatarUrl = '',
    this.phone = '',
    this.nin = '',
    this.rank = '',
    this.completedTrips = 0,
    this.cancelledTrips = 0,
    this.incompleteTrips = 0,
    this.reviewsCount = 0,
    this.totalTrips = 0,
    this.currency = 'NGN',
    this.pricePerKm = 0,
    this.baseFare = 0,
    this.estimatedTotal = 0,
    this.tripKm = 0,
  });

  static const RideNearbyDriver empty = RideNearbyDriver(
    id: '',
    name: 'Driver',
    category: 'Standard',
    rating: 0,
    carPlate: '',
    heading: 0,
    lat: 0,
    lng: 0,
    distanceKm: 0,
    etaMin: 0,
  );

  /// Accepts a [DriverCar] or a backend JSON map.
  factory RideNearbyDriver.from(dynamic raw) {
    if (raw is RideNearbyDriver) return raw;
    if (raw is DriverCar) {
      final String vt = (raw.vehicleType ?? 'car').trim().isEmpty ? 'car' : raw.vehicleType!.trim();
      final bool bike = vehicleClassOf(vt) == VehicleClass.bike;
      return RideNearbyDriver(
        id: raw.id,
        name: (raw.name ?? '').trim().isEmpty ? 'Driver' : raw.name!.trim(),
        category: (raw.category ?? '').trim().isEmpty ? 'Standard' : raw.category!.trim(),
        rating: raw.rating ?? 0,
        carPlate: raw.carPlate ?? '',
        heading: raw.heading,
        lat: raw.ll.latitude,
        lng: raw.ll.longitude,
        distanceKm: raw.distanceKm ?? 0,
        etaMin: raw.etaMin ?? 0,
        vehicleType: vt,
        seats: bike ? 1 : ((raw.seats ?? 0) > 0 ? raw.seats! : 4),
        vehicleImages: _strList(raw.vehicleImages),
        vehicleDescription: raw.vehicleDescription ?? '',
        carImageUrl: _fixUrl(raw.carImageUrl ?? ''),
        avatarUrl: _fixUrl(raw.avatarUrl ?? ''),
        phone: raw.phone ?? '',
        nin: raw.nin ?? '',
        rank: raw.rank ?? '',
        completedTrips: raw.completedTrips ?? 0,
        cancelledTrips: raw.cancelledTrips ?? 0,
        incompleteTrips: raw.incompleteTrips ?? 0,
        reviewsCount: raw.reviewsCount ?? 0,
        totalTrips: raw.totalTrips ?? 0,
        currency: raw.currency,
        pricePerKm: raw.pricePerKm ?? 0,
        baseFare: raw.baseFare ?? 0,
        estimatedTotal: raw.estimatedTotal ?? 0,
        tripKm: raw.tripKm ?? 0,
      );
    }
    if (raw is Map) {
      final Map<String, dynamic> m = raw.cast<String, dynamic>();
      final String vt = (m['vehicle_type'] ?? 'car').toString();
      final bool bike = vehicleClassOf(vt) == VehicleClass.bike;
      final int seats = _num(m['seats'], 4).toInt();
      return RideNearbyDriver(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? 'Driver').toString(),
        category: (m['category'] ?? 'Standard').toString(),
        rating: _num(m['rating'], 0).toDouble(),
        carPlate: (m['car_plate'] ?? m['plate'] ?? '').toString(),
        heading: _num(m['heading'], 0).toDouble(),
        lat: _num(m['lat'], 0).toDouble(),
        lng: _num(m['lng'], 0).toDouble(),
        distanceKm: _num(m['distance_km'], 0).toDouble(),
        etaMin: _num(m['eta_min'], 0).toInt(),
        vehicleType: vt,
        seats: bike ? 1 : (seats > 0 ? seats : 4),
        vehicleImages: _strList(m['vehicle_images']),
        vehicleDescription: (m['vehicle_description'] ?? '').toString(),
        carImageUrl: _fixUrl((m['car_image_url'] ?? '').toString()),
        avatarUrl: _fixUrl((m['avatar_url'] ?? '').toString()),
        phone: (m['phone'] ?? m['phone_number'] ?? '').toString(),
        nin: (m['nin'] ?? '').toString(),
        rank: (m['rank'] ?? '').toString(),
        completedTrips: _num(m['completed_trips'], 0).toInt(),
        cancelledTrips: _num(m['cancelled_trips'], 0).toInt(),
        incompleteTrips: _num(m['incomplete_trips'], 0).toInt(),
        reviewsCount: _num(m['reviews_count'], 0).toInt(),
        totalTrips: _num(m['total_trips'], 0).toInt(),
        currency: (m['currency'] ?? 'NGN').toString(),
        pricePerKm: _num(m['price_per_km'], 0).toDouble(),
        baseFare: _num(m['base_fare'], 0).toDouble(),
        estimatedTotal: _num(m['estimated_total'] ?? m['price_total'], 0).toDouble(),
        tripKm: _num(m['trip_km'], 0).toDouble(),
      );
    }
    return empty;
  }

  String get initials {
    final List<String> parts = name.trim().split(RegExp(r'\s+')).where((String e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return 'D';
    String first(String x) => x.isEmpty ? '' : String.fromCharCode(x.runes.first);
    return (first(parts.first).toUpperCase() + (parts.length > 1 ? first(parts.last).toUpperCase() : '')).trim();
  }

  List<String> get imagesEffective {
    final List<String> out = vehicleImages.where((String s) => s.trim().isNotEmpty).toList();
    if (out.isEmpty && carImageUrl.trim().isNotEmpty) out.add(carImageUrl.trim());
    return out;
  }

  String get rankLabel => rank.trim().isEmpty ? 'Verified' : rank.trim();

  /// Fare for a trip of [routeKm] (route distance shown to the rider). Uses
  /// the driver's own tariff when known so the price matches the distance on
  /// screen; falls back to the server's estimate. Rounded to whole naira.
  double fareFor(double routeKm) {
    double total = 0;
    if (routeKm > 0 && pricePerKm > 0) {
      total = baseFare + pricePerKm * routeKm;
    } else if (estimatedTotal > 0) {
      total = estimatedTotal;
    } else if (tripKm > 0 && pricePerKm > 0) {
      total = baseFare + pricePerKm * tripKm;
    }
    if (!total.isFinite || total <= 0) return 0;
    return total.roundToDouble();
  }

  /// Cheap change signature (what the card actually shows).
  String get signature =>
      '$id|$name|${rating.toStringAsFixed(1)}|$etaMin|${distanceKm.toStringAsFixed(2)}|'
      '${pricePerKm.toStringAsFixed(0)}|${baseFare.toStringAsFixed(0)}|${estimatedTotal.toStringAsFixed(0)}|'
      '$vehicleType|$seats|$avatarUrl|${imagesEffective.isEmpty ? '' : imagesEffective.first}|$rank';
}
