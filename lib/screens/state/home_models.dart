// lib/screens/home/state/home_models.dart
// Core models + enums (pure & reusable).

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../../themes/app_theme.dart';

enum PointType { pickup, stop, destination }

extension PointTypeX on PointType {
  IconData get icon => switch (this) {
    PointType.pickup => Icons.radio_button_checked,
    PointType.stop => Icons.stop_circle_outlined,
    PointType.destination => Icons.location_on_rounded,
  };
  Color get color => switch (this) {
    PointType.pickup => AppColors.primary,
    PointType.stop => AppColors.secondary,
    PointType.destination => AppColors.error,
  };
  String get label => switch (this) {
    PointType.pickup => 'Pickup',
    PointType.stop => 'Stop',
    PointType.destination => 'Destination',
  };
}

class RoutePoint {
  final PointType type;
  final TextEditingController controller;
  final FocusNode focus;
  final String hint;
  LatLng? latLng;
  String? placeId;
  bool isCurrent;

  RoutePoint({
    required this.type,
    required this.controller,
    required this.focus,
    required this.hint,
    this.latLng,
    this.placeId,
    this.isCurrent = false,
  });
}

class Suggestion {
  final String description;
  final String placeId;
  final String mainText;
  final String secondaryText;
  final int? distanceMeters;

  const Suggestion({
    required this.description,
    required this.placeId,
    required this.mainText,
    required this.secondaryText,
    this.distanceMeters,
  });

  Map<String, dynamic> toJson() => {
    'description': description,
    'placeId': placeId,
    'mainText': mainText,
    'secondaryText': secondaryText,
    'distanceMeters': distanceMeters,
  };

  factory Suggestion.fromJson(Map<String, dynamic> j) => Suggestion(
    description: j['description'] ?? '',
    placeId: j['placeId'] ?? '',
    mainText: j['mainText'] ?? '',
    secondaryText: j['secondaryText'] ?? '',
    distanceMeters: (j['distanceMeters'] is int) ? j['distanceMeters'] : null,
  );
}

class PlaceDetails {
  final LatLng? latLng;
  const PlaceDetails(this.latLng);
}

class AutoResult {
  final List<Suggestion> predictions;
  final String? status;
  final String? errorMessage;
  const AutoResult(this.predictions, this.status, this.errorMessage);
}
