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

  Widget _dashedDivider(bool isDark, ColorScheme cs) {
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
                // FIXED: Uses crisp outline color in dark mode instead of grey
                decoration: BoxDecoration(color: isDark ? cs.outline : Colors.grey.withOpacity(.45)),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _row(BuildContext context, String label, String value, bool isDark, ColorScheme cs, {bool copy = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        // FIXED: Elevated slightly off the background in dark mode
        color: isDark ? cs.surfaceVariant.withOpacity(0.3) : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        // FIXED: Uses sleek outline instead of mint green in dark mode
        border: Border.all(color: isDark ? cs.outline : AppColors.mintBgLight),
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
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(height: 4),
                  Text(
                    value.isNotEmpty ? value : 'Not available',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: isDark ? cs.onSurface : AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (copy && value.isNotEmpty)
            IconButton(
              tooltip: 'Copy $label',
              icon: Icon(Icons.copy_rounded, size: 18, color: isDark ? cs.primary : AppColors.textSecondary),
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

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
                color: isDark ? cs.surfaceVariant : AppColors.mintBgLight,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 14),

            // Title + optional balance (same data, different layout from BalanceCard)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.account_balance_wallet_outlined, size: 18, color: isDark ? cs.primary : AppColors.textPrimary),
                const SizedBox(width: 8),
                Text(
                  'Fund Your Account',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary),
                ),
              ],
            ),
            if (balance != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isDark
                        ? [cs.primary.withOpacity(.15), cs.primary.withOpacity(.05)]
                        : [AppColors.accentColor.withOpacity(.12), AppColors.accentColor.withOpacity(.06)],
                  ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isDark ? cs.primary.withOpacity(.3) : AppColors.accentColor.withOpacity(.4)),
                ),
                child: Text(
                  'Current balance: $currency${_fmt(balance!)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.1,
                    color: isDark ? cs.primary : AppColors.textPrimary,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 16),
            _row(context, 'Bank', bank, isDark, cs),
            const SizedBox(height: 12),
            _row(context, 'Account number', number, isDark, cs, copy: true),
            const SizedBox(height: 12),
            _row(context, 'Account name', name, isDark, cs),
            const SizedBox(height: 14),

            _dashedDivider(isDark, cs),
            const SizedBox(height: 12),

            // Notes – mirrors BalanceCard messaging (layout-only difference)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Important Notes:',
                style: TextStyle(
                  color: isDark ? cs.onSurface : theme.colorScheme.onSurface.withOpacity(.9),
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 6),
            _note('Transfers may be delayed within 30–60 minutes.', isDark, cs),
            _note('Include detailed info in the transfer description (optional).', isDark, cs),
            _note('Contact support if you encounter any issues.', isDark, cs),
          ],
        ),
      ),
    );
  }

  Widget _note(String text, bool isDark, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• ', style: TextStyle(fontSize: 13, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.25, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}