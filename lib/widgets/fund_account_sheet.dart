// lib/widgets/fund_account_sheet.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_client.dart';
import '../api/url.dart';
import '../themes/app_theme.dart';

class FundAccountSheet extends StatefulWidget {
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

  @override
  State<FundAccountSheet> createState() => _FundAccountSheetState();
}

class _FundAccountSheetState extends State<FundAccountSheet> {
  // Live State Variables
  double? _liveBalance;
  String? _liveLastTran;
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    _liveBalance = widget.balance;
    _loadStoredData();
  }

  Future<void> _loadStoredData() async {
    final prefs = await SharedPreferences.getInstance();
    final storedBal = prefs.getString('user_bal');
    final storedTran = prefs.getString('user_last_tran');
    if (mounted) {
      setState(() {
        if (storedBal != null) _liveBalance = double.tryParse(storedBal);
        if (storedTran != null) _liveLastTran = storedTran;
      });
    }
  }

  /// Refreshes the user balance via API and Syncs to Global SharedPreferences
  Future<void> _refreshData() async {
    if (_isRefreshing) return;

    HapticFeedback.lightImpact();
    setState(() => _isRefreshing = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final uid = prefs.getString('user_id');

      if (uid == null) throw Exception('User ID not found');

      final api = ApiClient(http.Client(), context);

      final res = await api.request(
        ApiConstants.userInfoEndpoint,
        method: 'POST',
        data: {'user': uid},
      );

      final body = jsonDecode(res.body);
      if (body['error'] == false && body['user'] != null) {
        final String newBalStr = body['user']['user_bal']?.toString() ?? '0.0';
        final String newLastTranStr = body['user']['user_last_tran']?.toString() ?? '';

        // Mutate parent state by reference if available
        if (widget.account != null) {
          widget.account!['user_bal'] = newBalStr;
          widget.account!['user_last_tran'] = newLastTranStr;
        }

        // Global Sync
        await prefs.setString('user_bal', newBalStr);
        await prefs.setString('user_last_tran', newLastTranStr);

        final userDataStr = prefs.getString('user_data') ?? prefs.getString('user');
        if (userDataStr != null) {
          try {
            final Map<String, dynamic> storedUser = jsonDecode(userDataStr);
            storedUser['user_bal'] = newBalStr;
            storedUser['user_last_tran'] = newLastTranStr;
            await prefs.setString('user_data', jsonEncode(storedUser));
            await prefs.setString('user', jsonEncode(storedUser));
          } catch (_) {}
        }

        if (mounted) {
          setState(() {
            _liveBalance = double.tryParse(newBalStr);
            _liveLastTran = newLastTranStr;
          });
        }
      }
    } catch (e) {
      debugPrint('Refresh failed: $e');
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

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
        color: isDark ? cs.surfaceVariant.withOpacity(0.3) : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
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

  Widget _buildCryptoIndicator(ColorScheme cs, bool isDark) {
    final displayTran = _liveLastTran ?? widget.account?['user_last_tran']?.toString() ?? '';

    if (displayTran.isEmpty || displayTran == '+0.00' || displayTran == '-0.00') {
      return const SizedBox.shrink();
    }

    final isSubtracted = displayTran.startsWith('-');
    final amountStr = displayTran.replaceAll(RegExp(r'[+-]'), '');
    final amount = double.tryParse(amountStr) ?? 0.0;

    if (amount == 0.0) return const SizedBox.shrink();

    // Standard high-contrast colors (since background here is the sheet, not a gradient)
    final indicatorColor = isSubtracted
        ? Colors.redAccent.shade700
        : (isDark ? const Color(0xFF00E676) : const Color(0xFF1E8E3E));

    final bgColor = isSubtracted
        ? Colors.redAccent.withOpacity(0.1)
        : indicatorColor.withOpacity(0.1);

    final icon = isSubtracted ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded;
    final sign = isSubtracted ? '-' : '+';

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: indicatorColor.withOpacity(0.3), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: indicatorColor),
          const SizedBox(width: 4),
          Text(
            'Recent: $sign${widget.currency} ${_fmt(amount)}',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: indicatorColor,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    final bank = _firstNonEmpty(widget.account, ['bankName', 'bank', 'bank_name', 'user_bank']) ?? 'PickMe Partner Bank';
    final number =
        _firstNonEmpty(widget.account, ['accountNumber', 'account_number', 'user_account_number']) ?? '0000000000';
    final name =
        _firstNonEmpty(widget.account, ['accountName', 'account_name', 'user_account_name']) ?? 'Your Virtual Account';

    final displayBalance = _liveBalance ?? widget.balance;

    // EXPLICIT BACKGROUND COLOR to prevent transparency issues
    return Material(
      color: isDark ? cs.surface : AppColors.offWhite,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
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

              // Title Header
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

              // Top Stats Block (Balance + Refresh + Crypto Indicator)
              if (displayBalance != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isDark
                          ? [cs.primary.withOpacity(.15), cs.primary.withOpacity(.05)]
                          : [AppColors.accentColor.withOpacity(.12), AppColors.accentColor.withOpacity(.06)],
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: isDark ? cs.primary.withOpacity(.3) : AppColors.accentColor.withOpacity(.4)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Current Balance',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${widget.currency}${_fmt(displayBalance)}',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.5,
                                  color: isDark ? cs.primary : AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: _isRefreshing ? null : _refreshData,
                              borderRadius: BorderRadius.circular(20),
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: _isRefreshing
                                    ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(isDark ? cs.primary : AppColors.primary),
                                  ),
                                )
                                    : Icon(
                                  Icons.refresh_rounded,
                                  size: 20,
                                  color: isDark ? cs.primary : AppColors.primary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),

                      // Align Crypto indicator to the left
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _buildCryptoIndicator(cs, isDark),
                      ),
                    ],
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

              // Notes
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