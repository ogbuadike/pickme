// lib/widgets/fund_account_sheet.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../themes/app_theme.dart';

class FundAccountSheet extends StatelessWidget {
  const FundAccountSheet({super.key, required this.account});
  final Map<String, dynamic>? account; // {bankName, accountNumber, accountName}

  @override
  Widget build(BuildContext context) {
    final bank = account?['bankName'] ?? 'PickMe Partner Bank';
    final number = account?['accountNumber'] ?? '0000000000';
    final name = account?['accountName'] ?? 'Your Virtual Account';

    Widget row(String label, String value, {bool copy = false}) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.mintBgLight),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  const SizedBox(height: 4),
                  Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
            if (copy)
              IconButton(
                icon: const Icon(Icons.copy_rounded),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                },
              ),
          ],
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4,
                decoration: BoxDecoration(color: AppColors.mintBgLight, borderRadius: BorderRadius.circular(4))),
            const SizedBox(height: 16),
            const Text('Fund account', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            row('Bank', bank),
            const SizedBox(height: 12),
            row('Account number', number, copy: true),
            const SizedBox(height: 12),
            row('Account name', name),
            const SizedBox(height: 16),
            Text(
              'Transfer to this virtual account to fund your Pick Me wallet instantly.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(.7)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
