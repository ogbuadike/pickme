import 'package:flutter/material.dart';
import '../themes/app_theme.dart';
import '../widgets/inner_background.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help & Safety')),
      body: Stack(
        children: [
          const BackgroundWidget(intensity: .35, animate: true),
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _card(
                context,
                title: 'Safety & Respect',
                body:
                'Treat everyone with kindness, help keep one another safe, follow the laws, and report any abuse or misconduct immediately.',
              ),
              const SizedBox(height: 8),
              _card(
                context,
                title: 'Contact support',
                body:
                'Questions about a trip, payment, or driver? Reach our support from here.',
                trailing: const Icon(Icons.chevron_right),
              ),
              const SizedBox(height: 8),
              _card(
                context,
                title: 'Report an issue',
                body:
                'Something went wrong? Tell us and we’ll take action quickly.',
                trailing: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context,
      {required String title, required String body, Widget? trailing}) {
    return ListTile(
      tileColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.mintBgLight),
      ),
      title:
      Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
      subtitle: Text(body),
      trailing: trailing,
    );
  }
}
