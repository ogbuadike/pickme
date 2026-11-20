import 'package:flutter/material.dart';

import '../routes/routes.dart';
import '../widgets/inner_background.dart';

/// Payment options. Only methods the app actually supports are listed – no
/// placeholder cards.
class PaymentsScreen extends StatelessWidget {
  const PaymentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payments')),
      body: Stack(
        children: [
          const BackgroundWidget(intensity: .35, animate: false),
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _tile(context, 'Wallet', Icons.account_balance_wallet_outlined,
                  subtitle: 'Fund your wallet by bank transfer and pay for trips in-app'),
              const SizedBox(height: 8),
              _tile(context, 'Cash', Icons.payments_outlined, subtitle: 'Pay your driver directly'),
              const SizedBox(height: 8),
              _tile(context, 'Transaction history', Icons.receipt_long_outlined,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pushNamed(context, AppRoutes.transactions)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, String title, IconData icon,
      {String? subtitle, Widget? trailing, VoidCallback? onTap}) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      tileColor: cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant),
      ),
      leading: Icon(icon, color: cs.primary),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: trailing,
      onTap: onTap,
    );
  }
}
