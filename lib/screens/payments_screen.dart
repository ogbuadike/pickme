import 'package:flutter/material.dart';
import '../themes/app_theme.dart';
import '../widgets/inner_background.dart';

class PaymentsScreen extends StatelessWidget {
  const PaymentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payments')),
      body: Stack(
        children: [
          const BackgroundWidget(intensity: .35, animate: true),
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _tile('Default card', Icons.credit_card, subtitle: '**** 2489'),
              const SizedBox(height: 8),
              _tile('Cash', Icons.payments_outlined, subtitle: 'Enabled'),
              const SizedBox(height: 8),
              _tile('Add payment method', Icons.add_card,
                  trailing: const Icon(Icons.chevron_right)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tile(String title, IconData icon,
      {String? subtitle, Widget? trailing}) {
    return ListTile(
      tileColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.mintBgLight),
      ),
      leading: Icon(icon, color: AppColors.primary),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: trailing,
    );
  }
}
