// lib/screens/state/map_gesture_sensor.dart
//
// Detects real user drags / pinches on top of a GoogleMap platform view
// (plain taps are ignored) so camera-follow modes can pause instead of
// fighting the user. Pointer events still reach the map untouched.
import 'package:flutter/widgets.dart';

class MapGestureSensor extends StatefulWidget {
  final Widget child;
  final VoidCallback onUserGesture;

  /// Movement (logical px) after which a single-finger touch counts as a pan.
  final double slop;

  const MapGestureSensor({super.key, required this.child, required this.onUserGesture, this.slop = 14});

  @override
  State<MapGestureSensor> createState() => _MapGestureSensorState();
}

class _MapGestureSensorState extends State<MapGestureSensor> {
  final Map<int, Offset> _downs = <int, Offset>{};
  bool _fired = false;

  void _fire() {
    if (_fired) return;
    _fired = true;
    widget.onUserGesture();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (_downs.isEmpty) _fired = false;
        _downs[e.pointer] = e.position;
        if (_downs.length > 1) _fire(); // pinch / rotate
      },
      onPointerMove: (e) {
        final d = _downs[e.pointer];
        if (d != null && (e.position - d).distance > widget.slop) _fire();
      },
      onPointerUp: (e) => _downs.remove(e.pointer),
      onPointerCancel: (e) => _downs.remove(e.pointer),
      onPointerSignal: (_) => _fire(), // mouse wheel / trackpad zoom
      child: widget.child,
    );
  }
}
