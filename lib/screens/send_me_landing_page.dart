// lib/screens/send_me_landing_page.dart
import 'package:flutter/material.dart';

import '../services/logistics_service.dart';
import 'logistics/logistics_landing_view.dart';

class SendMeLandingPage extends StatelessWidget {
  const SendMeLandingPage({super.key});

  static const LogisticsLandingConfig config = LogisticsLandingConfig(
    kind: LogisticsKind.sendMe,
    heroIcon: Icons.shopping_cart_checkout_rounded,
    headline: 'Send Me\nErrands.',
    tagline: 'Your personal assistant on wheels. We go to the market, pick up groceries, and run your daily errands.',
    ctaLabel: 'Start an Errand',
    features: <LogisticsFeature>[
      LogisticsFeature(Icons.checklist_rounded, Color(0xFF2979FF), 'Custom Instructions',
          'Tell the rider exactly what to do or buy.'),
      LogisticsFeature(Icons.store_rounded, Color(0xFF10B981), 'Store Pickups', 'Perfect for groceries, pharmacy, or food.'),
      LogisticsFeature(Icons.vpn_key_rounded, Color(0xFF8B5CF6), 'Secure PIN Handoff',
          'The rider only completes the errand with your delivery PIN.'),
    ],
  );

  @override
  Widget build(BuildContext context) => const LogisticsLandingView(config: config);
}
