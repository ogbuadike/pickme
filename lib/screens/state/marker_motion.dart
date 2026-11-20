// lib/screens/state/marker_motion.dart
//
// Frame-rate independent marker motion model used for the rider's own dot,
// nearby driver cars and the trip-navigation car.
//
//  • Each GPS / server fix starts an interpolation from the *currently
//    displayed* position, so motion stays continuous (no jumps back).
//  • Position: linear while the vehicle is moving at a steady speed (constant
//    on-screen velocity, no "pulsing" at every fix), ease-out when settling.
//  • Bearing: shortest-arc interpolation with ease-out.
//  • Jitter: fixes that move less than the accuracy-derived threshold while
//    (nearly) stationary are ignored.
//  • Dead reckoning: once a fix has been reached, a moving vehicle keeps
//    gliding along its travel direction (or along [route] when given) for a
//    short, capped time until the next fix arrives.
//
// The class is pure Dart (no widgets); callers sample it from a Ticker.
import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'routing_engine.dart';

class MotionSample {
  final LatLng position;
  final double bearing;
  const MotionSample(this.position, this.bearing);
}

class MarkerMotion {
  /// Monotonic clock shared by all motions.
  static final Stopwatch _clock = Stopwatch()..start();
  static int get nowUs => _clock.elapsedMicroseconds;

  /// Minimum movement (meters) to accept as real motion while stationary.
  final double jitterMeters;

  /// How long we keep extrapolating after reaching the last fix.
  final Duration maxExtrapolation;

  /// Hard cap on how far ahead of the last fix we are allowed to glide.
  final double maxExtrapolationMeters;

  /// Jumps larger than this are applied instantly (teleport / first fix).
  final double teleportMeters;

  /// Optional route used for dead-reckoning along the road.
  RouteGeometry? _route;
  int? _routeHint;
  double? _toAlong;

  LatLng _fromPos;
  LatLng _toPos;
  double _fromBrg;
  double _toBrg;
  int _posStartUs = 0;
  int _posDurUs = 0;
  int _brgStartUs = 0;
  int _brgDurUs = 0;

  int? _lastFixUs;
  double _speedMps = 0;
  double _travelBrg;

  MarkerMotion({
    required LatLng initial,
    double bearing = 0,
    this.jitterMeters = 3.0,
    this.maxExtrapolation = const Duration(milliseconds: 1500),
    this.maxExtrapolationMeters = 25.0,
    this.teleportMeters = 400.0,
  })  : _fromPos = initial,
        _toPos = initial,
        _fromBrg = RoutingEngine.normalizeDeg(bearing),
        _toBrg = RoutingEngine.normalizeDeg(bearing),
        _travelBrg = RoutingEngine.normalizeDeg(bearing),
        // Treat creation as the first fix so the next fix animates over the
        // real interval instead of teleporting.
        _lastFixUs = nowUs;

  LatLng get target => _toPos;
  double get targetBearing => _toBrg;
  double get speedMps => _speedMps;

  set route(RouteGeometry? r) {
    _route = (r == null || r.isEmpty) ? null : r;
    _routeHint = null;
    _toAlong = null;
  }

  /// Feeds a new fix. Returns false when it was rejected as jitter.
  bool push(
    LatLng target, {
    double? bearing,
    double? accuracyMeters,
    double? speedMps,
    Duration? expectedInterval,
  }) {
    final now = nowUs;
    final current = sample(now);
    final dist = RoutingEngine.haversine(_toPos, target);
    final dtFixS = _lastFixUs == null ? 0.0 : (now - _lastFixUs!) / 1e6;

    final threshold = math.max(jitterMeters, math.min((accuracyMeters ?? 0) * 0.5, 15.0));
    final reportedSlow = speedMps == null || speedMps < 1.0;
    if (dist < threshold && reportedSlow) {
      // Stationary jitter: keep position, only allow an explicit heading update.
      // Freeze exactly where the marker is drawn (no snap-back from glide).
      _fromPos = current.position;
      _toPos = current.position;
      _posStartUs = now;
      _posDurUs = 0;
      _speedMps = 0;
      _toAlong = null;
      if (bearing != null) _startBearing(current.bearing, bearing, now);
      return false;
    }

    // Speed estimate (EMA) — prefer the reported value when present.
    if (speedMps != null && speedMps.isFinite && speedMps >= 0) {
      _speedMps = speedMps;
    } else if (dtFixS > 0.05) {
      final measured = dist / dtFixS;
      _speedMps = _speedMps == 0 ? measured : (_speedMps * 0.4 + measured * 0.6);
    }
    if (dist > 2.0) _travelBrg = RoutingEngine.bearingBetween(_toPos, target);

    final jump = RoutingEngine.haversine(current.position, target);
    final expected = expectedInterval ?? (dtFixS > 0 ? Duration(microseconds: (dtFixS * 1e6).round()) : const Duration(milliseconds: 600));
    final durUs = expected.inMicroseconds.clamp(250000, 2500000);

    _fromPos = current.position;
    _toPos = target;
    _posStartUs = now;
    _posDurUs = jump > teleportMeters ? 0 : durUs;

    final nextBrg = bearing ?? (dist > 2.0 ? _travelBrg : _toBrg);
    if (_posDurUs == 0) {
      _fromBrg = RoutingEngine.normalizeDeg(nextBrg);
      _toBrg = _fromBrg;
      _brgDurUs = 0;
    } else {
      _startBearing(current.bearing, nextBrg, now);
    }

    _lastFixUs = now;
    _toAlong = null;
    if (_route != null) {
      final proj = _route!.project(target, hintSegment: _routeHint);
      if (proj != null && proj.distanceToRoute < 30) {
        _routeHint = proj.segmentIndex;
        _toAlong = proj.distanceAlong;
      }
    }
    return true;
  }

  /// Instantly places the marker (no animation).
  void jumpTo(LatLng p, {double? bearing}) {
    _fromPos = p;
    _toPos = p;
    _posDurUs = 0;
    if (bearing != null) {
      _fromBrg = RoutingEngine.normalizeDeg(bearing);
      _toBrg = _fromBrg;
      _brgDurUs = 0;
    }
    _lastFixUs = nowUs;
    _speedMps = 0;
    _toAlong = null;
  }

  /// Updates only the heading (e.g. compass) with smoothing.
  void setBearing(double bearing) {
    final now = nowUs;
    _startBearing(sample(now).bearing, bearing, now);
  }

  void _startBearing(double from, double to, int now) {
    final delta = RoutingEngine.shortestAngleDelta(from, to).abs();
    _fromBrg = from;
    _toBrg = RoutingEngine.normalizeDeg(to);
    _brgStartUs = now;
    _brgDurUs = (200000 + delta / 180.0 * 700000).round().clamp(150000, 900000);
  }

  bool isAnimating([int? atUs]) {
    final now = atUs ?? nowUs;
    if (_posDurUs > 0 && now - _posStartUs < _posDurUs) return true;
    if (_brgDurUs > 0 && now - _brgStartUs < _brgDurUs) return true;
    return _extrapolating(now);
  }

  bool _extrapolating(int now) {
    if (_speedMps < 2.0 || _lastFixUs == null) return false;
    final end = _posStartUs + _posDurUs;
    return now >= end && now - end < maxExtrapolation.inMicroseconds;
  }

  double _extraMeters(int now) {
    if (_speedMps < 2.0 || _lastFixUs == null) return 0;
    final end = _posStartUs + _posDurUs;
    if (now <= end) return 0;
    final dtS = math.min(now - end, maxExtrapolation.inMicroseconds) / 1e6;
    return math.min(_speedMps * dtS, maxExtrapolationMeters);
  }

  static double _easeOutCubic(double t) {
    final p = 1 - t;
    return 1 - p * p * p;
  }

  MotionSample sample([int? atUs]) {
    final now = atUs ?? nowUs;

    // --- position ---
    LatLng pos;
    double? routeBrg;
    if (_posDurUs <= 0 || now - _posStartUs >= _posDurUs) {
      pos = _toPos;
      final extra = _extraMeters(now);
      if (extra > 0) {
        // Hold at the clamped extrapolated point once the window ends, so the
        // marker never jumps back to the last fix.
        if (_route != null && _toAlong != null) {
          final at = _route!.pointAtDistance(_toAlong! + extra);
          pos = at.point;
          routeBrg = at.bearing;
        } else {
          pos = RoutingEngine.offsetLatLng(_toPos, extra, _travelBrg);
        }
      }
    } else {
      final raw = ((now - _posStartUs) / _posDurUs).clamp(0.0, 1.0);
      final t = _speedMps > 1.5 ? raw : _easeOutCubic(raw);
      pos = RoutingEngine.lerpLatLng(_fromPos, _toPos, t);
    }

    // --- bearing ---
    double brg;
    if (_brgDurUs <= 0 || now - _brgStartUs >= _brgDurUs) {
      brg = _toBrg;
    } else {
      final t = _easeOutCubic(((now - _brgStartUs) / _brgDurUs).clamp(0.0, 1.0));
      brg = RoutingEngine.lerpAngle(_fromBrg, _toBrg, t);
    }
    if (routeBrg != null && RoutingEngine.shortestAngleDelta(brg, routeBrg).abs() < 60) {
      // Follow gentle road curvature while dead-reckoning.
      brg = RoutingEngine.lerpAngle(brg, routeBrg, 0.25);
    }
    return MotionSample(pos, brg);
  }
}
