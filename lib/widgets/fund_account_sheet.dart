// lib/widgets/fund_account_sheet.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../themes/app_theme.dart';

class FundAccountSheet extends StatelessWidget {
  /// Accepts any of these key shapes (first non-empty wins):
  /// bank: bankName | bank | bank_name | user_bank
  /// account number: accountNumber | account_number | user_account_number
  /// account name: accountName | account_name | user_account_name
  final Map<String, dynamic>? account;

  /// Optional: show current balance at the top of the sheet
  final double? balance;
  final String currency;

  const FundAccountSheet({
    super.key,
    required this.account,
    this.balance,
    this.currency = 'NGN',
  });

  String? _firstNonEmpty(Map<String, dynamic>? map, List<String> keys) {
    if (map == null) return null;
    for (final k in keys) {
      final v = map[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  void _copy(BuildContext context, String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  Widget _dashedDivider() {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        const dash = 4.0;
        final count = (w / (dash * 2)).floor();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(count, (_) {
            return SizedBox(
              width: dash,
              height: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.grey.withOpacity(.45)),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _row(BuildContext context, String label, String value, {bool copy = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.mintBgLight),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(height: 4),
                  Text(
                    value.isNotEmpty ? value : 'Not available',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (copy && value.isNotEmpty)
            IconButton(
              tooltip: 'Copy $label',
              icon: const Icon(Icons.copy_rounded, size: 18),
              onPressed: () => _copy(context, label, value),
            ),
        ],
      ),
    );
  }

  String _fmt(double n) {
    final s = n.toStringAsFixed(2);
    final parts = s.split('.');
    final whole = parts[0].replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
    );
    return '$whole.${parts[1]}';
  }

  @override
  Widget build(BuildContext context) {
    final bank = _firstNonEmpty(account, ['bankName', 'bank', 'bank_name', 'user_bank']) ?? 'PickMe Partner Bank';
    final number =
        _firstNonEmpty(account, ['accountNumber', 'account_number', 'user_account_number']) ?? '0000000000';
    final name =
        _firstNonEmpty(account, ['accountName', 'account_name', 'user_account_name']) ?? 'Your Virtual Account';

    // Content-only sheet (works inside any showModalBottomSheet / Draggable)
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 10,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Grab handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.mintBgLight,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 14),

            // Title + optional balance (same data, different layout from BalanceCard)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.account_balance_wallet_outlined, size: 18),
                SizedBox(width: 8),
                Text(
                  'Fund Your Account',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
              ],
            ),
            if (balance != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.accentColor.withOpacity(.12),
                      AppColors.accentColor.withOpacity(.06),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.accentColor.withOpacity(.4)),
                ),
                child: Text(
                  'Current balance: $currency${_fmt(balance!)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 16),
            _row(context, 'Bank', bank),
            const SizedBox(height: 12),
            _row(context, 'Account number', number, copy: true),
            const SizedBox(height: 12),
            _row(context, 'Account name', name),
            const SizedBox(height: 14),

            _dashedDivider(),
            const SizedBox(height: 12),

            // Notes – mirrors BalanceCard messaging (layout-only difference)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Important Notes:',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(.9),
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 6),
            _note('Transfers may be delayed within 30–60 minutes.'),
            _note('Include detailed info in the transfer description (optional).'),
            _note('Contact support if you encounter any issues.'),
          ],
        ),
      ),
    );
  }

  Widget _note(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(fontSize: 13)),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.25),
            ),
          ),
        ],
      ),
    );
  }
}
