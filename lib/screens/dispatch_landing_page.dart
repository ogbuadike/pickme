// lib/screens/dispatch_landing_page.dart
import 'package:flutter/material.dart';

import '../services/logistics_service.dart';
import 'logistics/logistics_landing_view.dart';

class DispatchLandingPage extends StatelessWidget {
  const DispatchLandingPage({super.key});

  static const LogisticsLandingConfig config = LogisticsLandingConfig(
    kind: LogisticsKind.dispatch,
    heroIcon: Icons.inventory_2_rounded,
    headline: 'Fleet\nDispatch.',
    tagline: 'Send anything, anywhere. From lightweight documents to heavy freight.',
    ctaLabel: 'Send a Package',
    features: <LogisticsFeature>[
      LogisticsFeature(Icons.scale_rounded, Color(0xFFFFA000), 'All Sizes & Weights', 'Bikes for envelopes, trucks for freight.'),
      LogisticsFeature(Icons.domain_verification_rounded, Color(0xFF10B981), 'Secure OTP Handoff',
          'Recipients must provide a PIN to receive.'),
      LogisticsFeature(Icons.route_rounded, Color(0xFF3B82F6), 'Live Tracking', 'Track your shipment every step of the way.'),
    ],
  );

  @override
  Widget build(BuildContext context) => const LogisticsLandingView(config: config);
}
