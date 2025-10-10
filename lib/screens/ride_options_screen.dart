import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../themes/app_theme.dart';
import '../utility/notification.dart';
import '../widgets/inner_background.dart';

class RideOptionsScreen extends StatefulWidget {
  const RideOptionsScreen({super.key, this.args});
  final Map<String, dynamic>? args;

  @override
  State<RideOptionsScreen> createState() => _RideOptionsScreenState();
}

class _RideOptionsScreenState extends State<RideOptionsScreen> {
  late final String pickupText =
      widget.args?['pickupText'] as String? ?? 'Pickup';
  late final String dropText =
      widget.args?['dropText'] as String? ?? 'Destination';
  late final String distanceText =
      widget.args?['distance'] as String? ?? '--';
  late final String durationText =
      widget.args?['duration'] as String? ?? '--';
  late final LatLng? pickup = widget.args?['pickup'] as LatLng?;
  late final LatLng? drop = widget.args?['drop'] as LatLng?;

  int _selectedIndex = 0;

  double get _distanceKm {
    final d = distanceText.toLowerCase();
    // common formats: "5.2 km", "850 m"
    if (d.contains('km')) {
      return double.tryParse(d.replaceAll('km', '').trim()) ?? 0.0;
    }
    if (d.contains('m')) {
      final m = double.tryParse(d.replaceAll('m', '').trim()) ?? 0.0;
      return m / 1000.0;
    }
    return 0.0;
  }

  double _estimate(double base, double perKm, double perMin) {
    // naive estimate for demo
    final km = _distanceKm;
    // try extracting mins
    final mins = _extractMins(durationText);
    return (base + km * perKm + mins * perMin).clamp(500, 200000);
  }

  double _extractMins(String t) {
    // "25 mins", "1 hr 10 min"
    final lower = t.toLowerCase();
    int mins = 0;
    final hrMatch = RegExp(r'(\d+)\s*hr').firstMatch(lower);
    final minMatch = RegExp(r'(\d+)\s*min').firstMatch(lower);
    if (hrMatch != null) mins += int.parse(hrMatch.group(1)!)*60;
    if (minMatch != null) mins += int.parse(minMatch.group(1)!);
    return mins.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final options = [
      _RideType('Pick Mini', Icons.local_taxi_rounded,
          _estimate(350, 220, 8)),
      _RideType('Pick Go', Icons.directions_car_filled_rounded,
          _estimate(500, 260, 10)),
      _RideType('Pick XL', Icons.airport_shuttle_rounded,
          _estimate(800, 320, 12)),
      _RideType('Dispatch', Icons.pedal_bike_rounded,
          _estimate(250, 180, 6)),
    ];

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Ride Options'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          const BackgroundWidget(style: HoloStyle.vapor, animate: true, intensity: .7),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              children: [
                _TripSummaryCard(
                  pickup: pickupText,
                  drop: dropText,
                  distanceText: distanceText,
                  durationText: durationText,
                ),
                const SizedBox(height: 16),
                Text('Choose your ride',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    )),
                const SizedBox(height: 8),
                for (int i = 0; i < options.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _RideOptionTile(
                      option: options[i],
                      selected: _selectedIndex == i,
                      onTap: () => setState(() => _selectedIndex = i),
                    ),
                  ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Request ride',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  onPressed: () {
                    showToastNotification(
                      context: context,
                      title: 'Ride requested',
                      message: 'Your driver will be assigned shortly.',
                      isSuccess: true,
                    );
                    Navigator.pop(context); // back to Home
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TripSummaryCard extends StatelessWidget {
  const _TripSummaryCard({
    required this.pickup,
    required this.drop,
    required this.distanceText,
    required this.durationText,
  });

  final String pickup;
  final String drop;
  final String distanceText;
  final String durationText;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: [
            AppColors.surface.withOpacity(.95),
            AppColors.mintBgLight.withOpacity(.5),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: AppColors.mintBgLight),
        boxShadow: [
          BoxShadow(
            color: AppColors.deep.withOpacity(.12),
            blurRadius: 20,
            offset: const Offset(0, 10),
          )
        ],
      ),
      child: Column(
        children: [
          _row(Icons.radio_button_checked_rounded, pickup),
          const SizedBox(height: 10),
          _row(Icons.location_on_rounded, drop),
          const Divider(height: 24),
          Row(
            children: [
              const Icon(Icons.route_rounded, color: AppColors.primary),
              const SizedBox(width: 8),
              Text('$distanceText • $durationText',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(IconData ic, String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(ic, color: AppColors.primary),
      const SizedBox(width: 8),
      Expanded(
        child: Text(text,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            )),
      ),
    ],
  );
}

class _RideType {
  final String name;
  final IconData icon;
  final double price;
  _RideType(this.name, this.icon, this.price);
}

class _RideOptionTile extends StatelessWidget {
  const _RideOptionTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final _RideType option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = option.price;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withOpacity(.10)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: selected ? AppColors.primary : AppColors.mintBgLight),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: AppColors.primary.withOpacity(.12),
              child: Icon(option.icon, color: AppColors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(option.name,
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w800)),
            ),
            Text('₦${p.toStringAsFixed(0)}',
                style: TextStyle(
                    color: AppColors.deep,
                    fontSize: 16,
                    fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}
