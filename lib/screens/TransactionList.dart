// lib/screens/TransactionList.dart
import 'dart:convert';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
// FIXED: Hiding TextDirection from intl to prevent the collision with dart:ui
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../utility/notification.dart';

class Transaction {
  final int id;
  final String title;
  final double amount;
  final String type; // 'credit' or 'debit'
  final String paymentMode;
  final String status;
  final String reference;
  final String rechargeToken;
  final String transactionId;
  final String recipientAccount;
  final String recipientBank;
  final String iconUrl;
  final DateTime date;

  Transaction.fromJson(Map<String, dynamic> json)
      : id = json['id'] ?? 0,
        title = json['title'] ?? 'Transaction',
        amount = double.tryParse(json['amount']?.toString() ?? '0') ?? 0.0,
        type = json['type']?.toString().toLowerCase() == 'plus' ? 'credit' : 'debit',
        paymentMode = json['payment_mode'] ?? 'Wallet',
        status = json['status']?.toString().toLowerCase() ?? 'pending',
        reference = json['reference'] ?? 'N/A',
        rechargeToken = json['recharge_token'] ?? 'N/A',
        transactionId = json['transaction_id']?.toString() ?? 'N/A',
        recipientAccount = json['recipient']?['account'] ?? 'N/A',
        recipientBank = json['recipient']?['bank'] ?? 'N/A',
        iconUrl = json['icon'] ?? '',
        date = DateTime.tryParse(json['datetime'] ?? '') ?? DateTime.now();
}

// FIXED: Renamed to TransactionHistoryPage to match your routes.dart
class TransactionHistoryPage extends StatefulWidget {
  const TransactionHistoryPage({super.key});

  @override
  State<TransactionHistoryPage> createState() => _TransactionHistoryPageState();
}

class _TransactionHistoryPageState extends State<TransactionHistoryPage> with SingleTickerProviderStateMixin {
  late ApiClient _api;
  late SharedPreferences _prefs;

  bool _isLoading = true;
  bool _hasError = false;

  List<Transaction> _transactions = [];
  double _totalIn = 0.0;
  double _totalOut = 0.0;

  String _filter = 'All'; // All, Credit, Debit

  AnimationController? _shimmerController;
  final _currencyFmt = NumberFormat.currency(symbol: '₦', decimalDigits: 2);

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _prefs = await SharedPreferences.getInstance();
    _api = ApiClient(http.Client(), context);
    _fetchTransactions();
  }

  @override
  void dispose() {
    _shimmerController?.dispose();
    super.dispose();
  }

  Future<void> _fetchTransactions() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      final uid = _prefs.getString('user_id');
      if (uid == null) throw Exception('User session missing');

      final res = await _api.request(
        ApiConstants.transactionsEndpoint,
        method: 'POST',
        data: {'user': uid, 'limit': '50', 'offset': '0'},
      );

      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data['error'] == false) {
        final txList = (data['data']['transactions'] as List).map((e) => Transaction.fromJson(e)).toList();
        setState(() {
          _transactions = txList;
          _totalIn = double.tryParse(data['data']['summary']['inflow']?.toString() ?? '0') ?? 0.0;
          _totalOut = double.tryParse(data['data']['summary']['outflow']?.toString() ?? '0') ?? 0.0;
        });
      } else {
        throw Exception(data['message'] ?? 'Failed to load transactions');
      }
    } catch (e) {
      if (mounted) setState(() => _hasError = true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Smart Date Grouping (Banking App Style)
  Map<String, List<Transaction>> _groupTransactions(List<Transaction> txs) {
    final Map<String, List<Transaction>> groups = {};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    for (var tx in txs) {
      if (_filter != 'All' && tx.type != _filter.toLowerCase()) continue;

      final txDate = DateTime(tx.date.year, tx.date.month, tx.date.day);
      String groupKey;

      if (txDate == today) {
        groupKey = 'Today';
      } else if (txDate == yesterday) {
        groupKey = 'Yesterday';
      } else {
        groupKey = DateFormat('MMMM d, yyyy').format(txDate);
      }

      if (!groups.containsKey(groupKey)) {
        groups[groupKey] = [];
      }
      groups[groupKey]!.add(tx);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final ui = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    final groupedData = _groupTransactions(_transactions);

    return Scaffold(
      backgroundColor: isDark ? Colors.black : AppColors.offWhite,
      appBar: AppBar(
        backgroundColor: isDark ? Colors.black : AppColors.offWhite,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'Transactions',
          style: TextStyle(fontSize: ui.font(18), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: ui.icon(20), color: isDark ? cs.onSurface : AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isLoading
          ? _buildSkeleton(ui, isDark, cs)
          : _hasError
          ? _buildError(ui, isDark, cs)
          : _buildContent(ui, isDark, cs, groupedData),
    );
  }

  Widget _buildContent(UIScale ui, bool isDark, ColorScheme cs, Map<String, List<Transaction>> groupedData) {
    return Column(
      children: [
        // Premium Summary Header
        Padding(
          padding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.gap(8)),
          child: Row(
            children: [
              Expanded(child: _buildSummaryCard(ui, isDark, cs, 'Money In', _totalIn, true)),
              SizedBox(width: ui.gap(12)),
              Expanded(child: _buildSummaryCard(ui, isDark, cs, 'Money Out', _totalOut, false)),
            ],
          ),
        ),

        // Filter Chips
        Padding(
          padding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.gap(8)),
          child: Row(
            children: ['All', 'Credit', 'Debit'].map((filter) {
              final isSelected = _filter == filter;
              return Padding(
                padding: EdgeInsets.only(right: ui.gap(8)),
                child: ChoiceChip(
                  label: Text(filter, style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(13))),
                  selected: isSelected,
                  onSelected: (_) {
                    HapticFeedback.lightImpact();
                    setState(() => _filter = filter);
                  },
                  selectedColor: isDark ? cs.primary.withOpacity(0.15) : AppColors.primary.withOpacity(0.15),
                  backgroundColor: isDark ? cs.surfaceVariant.withOpacity(0.4) : AppColors.mintBgLight.withOpacity(0.3),
                  labelStyle: TextStyle(color: isSelected ? (isDark ? cs.primary : AppColors.primary) : (isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
                  side: BorderSide(color: isSelected ? (isDark ? cs.primary.withOpacity(0.5) : AppColors.primary.withOpacity(0.3)) : Colors.transparent),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ui.radius(12))),
                ),
              );
            }).toList(),
          ),
        ),

        // Transaction List
        Expanded(
          child: groupedData.isEmpty
              ? _buildEmptyState(ui, isDark, cs)
              : ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(ui.inset(16), ui.gap(8), ui.inset(16), ui.gap(40)),
            itemCount: groupedData.length,
            itemBuilder: (context, index) {
              final dateKey = groupedData.keys.elementAt(index);
              final txs = groupedData[dateKey]!;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: ui.gap(16), bottom: ui.gap(8), left: ui.inset(4)),
                    child: Text(
                      dateKey.toUpperCase(),
                      style: TextStyle(
                        fontSize: ui.font(11),
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                        color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(0.8),
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: isDark ? cs.surface : Colors.white,
                      borderRadius: BorderRadius.circular(ui.radius(16)),
                      border: Border.all(color: isDark ? cs.outline : AppColors.mintBgLight.withOpacity(0.4)),
                    ),
                    child: Column(
                      children: txs.asMap().entries.map((entry) {
                        final isLast = entry.key == txs.length - 1;
                        return _buildTransactionTile(ui, isDark, cs, entry.value, isLast);
                      }).toList(),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryCard(UIScale ui, bool isDark, ColorScheme cs, String title, double amount, bool isCredit) {
    final color = isCredit ? (isDark ? cs.primary : const Color(0xFF1E8E3E)) : (isDark ? cs.onSurface : AppColors.textPrimary);

    return Container(
      padding: EdgeInsets.all(ui.inset(16)),
      decoration: BoxDecoration(
        color: isDark ? cs.surface : Colors.white,
        borderRadius: BorderRadius.circular(ui.radius(16)),
        border: Border.all(color: isDark ? cs.outline : AppColors.mintBgLight.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isCredit ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, size: ui.icon(14), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
              SizedBox(width: ui.gap(6)),
              Text(title, style: TextStyle(fontSize: ui.font(12), fontWeight: FontWeight.w700, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
            ],
          ),
          SizedBox(height: ui.gap(8)),
          Text(
            _currencyFmt.format(amount),
            style: TextStyle(
              fontSize: ui.font(16),
              fontWeight: FontWeight.w900,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransactionTile(UIScale ui, bool isDark, ColorScheme cs, Transaction tx, bool isLast) {
    final isCredit = tx.type == 'credit';
    final isPending = tx.status == 'pending';
    final isFailed = tx.status == 'failed' || tx.status == 'declined' || tx.status == 'reversed';

    // Strict financial color coding
    final amountColor = isFailed
        ? cs.error
        : (isCredit ? (isDark ? cs.primary : const Color(0xFF1E8E3E)) : (isDark ? cs.onSurface : AppColors.textPrimary));

    final iconBg = isDark ? cs.surfaceVariant : AppColors.mintBgLight.withOpacity(0.3);
    final iconColor = isDark ? cs.onSurface : AppColors.textPrimary;

    Widget buildIcon() {
      // Use network icon if valid, otherwise fallback to smart icons
      if (tx.iconUrl.isNotEmpty && tx.iconUrl != 'N/A' && tx.iconUrl.startsWith('http')) {
        return ClipOval(
          child: Image.network(
            tx.iconUrl,
            width: ui.gap(42),
            height: ui.gap(42),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _fallbackIcon(iconColor),
          ),
        );
      }
      return _fallbackIcon(iconColor);
    }

    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        _showTransactionReceipt(ui, isDark, cs, tx);
      },
      borderRadius: BorderRadius.circular(ui.radius(16)),
      child: Container(
        padding: EdgeInsets.all(ui.inset(16)),
        decoration: BoxDecoration(
          border: isLast ? null : Border(bottom: BorderSide(color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.4))),
        ),
        child: Row(
          children: [
            Container(
              width: ui.gap(42),
              height: ui.gap(42),
              decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
              child: buildIcon(),
            ),
            SizedBox(width: ui.gap(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tx.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(14), color: isDark ? cs.onSurface : AppColors.textPrimary),
                  ),
                  SizedBox(height: ui.gap(4)),
                  Row(
                    children: [
                      Text(
                        DateFormat('h:mm a').format(tx.date),
                        style: TextStyle(fontSize: ui.font(11), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
                      ),
                      if (isPending || isFailed) ...[
                        SizedBox(width: ui.gap(6)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isFailed ? cs.error.withOpacity(0.1) : const Color(0xFFB8860B).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            isFailed ? 'Failed' : 'Pending',
                            style: TextStyle(fontSize: ui.font(9), fontWeight: FontWeight.w800, color: isFailed ? cs.error : const Color(0xFFB8860B)),
                          ),
                        )
                      ]
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: ui.gap(8)),
            Text(
              '${isCredit ? '+' : '-'}${_currencyFmt.format(tx.amount)}',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: ui.font(15),
                color: amountColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fallbackIcon(Color iconColor) {
    return Icon(Icons.receipt_long_rounded, size: 20, color: iconColor);
  }

  void _showTransactionReceipt(UIScale ui, bool isDark, ColorScheme cs, Transaction tx) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) => Container(
        decoration: BoxDecoration(color: isDark ? cs.surface : Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
        padding: EdgeInsets.fromLTRB(24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 32),

            // Amount Header
            Text(tx.type == 'credit' ? 'Money Received' : 'Money Spent', style: TextStyle(fontSize: 14, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              _currencyFmt.format(tx.amount),
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            const SizedBox(height: 32),

            // Strict Receipt Details
            Container(
              decoration: BoxDecoration(
                color: isDark ? cs.surfaceVariant.withOpacity(0.4) : AppColors.mintBgLight.withOpacity(0.2),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: isDark ? cs.outline : AppColors.mintBgLight.withOpacity(0.5)),
              ),
              child: Column(
                children: [
                  _buildReceiptRow('Status', tx.status.toUpperCase(), isDark, cs, isStatus: true),
                  Divider(height: 1, color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.5)),
                  _buildReceiptRow('Date & Time', DateFormat('MMM d, yyyy • h:mm a').format(tx.date), isDark, cs),
                  Divider(height: 1, color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.5)),
                  _buildReceiptRow('Description', tx.title, isDark, cs),
                  Divider(height: 1, color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.5)),
                  _buildReceiptRow('Payment Mode', tx.paymentMode.toUpperCase(), isDark, cs),

                  if (tx.recipientBank != 'N/A' && tx.recipientBank.isNotEmpty) ...[
                    Divider(height: 1, color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.5)),
                    _buildReceiptRow('Recipient Bank', tx.recipientBank, isDark, cs),
                  ],
                  if (tx.recipientAccount != 'N/A' && tx.recipientAccount.isNotEmpty) ...[
                    Divider(height: 1, color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.5)),
                    _buildReceiptRow('Account No.', tx.recipientAccount, isDark, cs, isCopyable: true),
                  ],
                  if (tx.rechargeToken != 'N/A' && tx.rechargeToken.isNotEmpty) ...[
                    Divider(height: 1, color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.5)),
                    _buildReceiptRow('Token / PIN', tx.rechargeToken, isDark, cs, isCopyable: true),
                  ],

                  Divider(height: 1, color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.5)),
                  _buildReceiptRow('Reference', tx.reference, isDark, cs, isCopyable: true),
                ],
              ),
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(c),
                style: ElevatedButton.styleFrom(backgroundColor: isDark ? cs.surfaceVariant : AppColors.mintBgLight, foregroundColor: isDark ? cs.onSurface : AppColors.textPrimary, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                child: const Text('Close', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceiptRow(String label, String value, bool isDark, ColorScheme cs, {bool isStatus = false, bool isCopyable = false}) {
    Color valColor = isDark ? cs.onSurface : AppColors.textPrimary;
    if (isStatus) {
      if (value == 'SUCCESSFUL' || value == 'COMPLETED') valColor = isDark ? cs.primary : const Color(0xFF1E8E3E);
      if (value == 'FAILED' || value == 'DECLINED' || value == 'REVERSED') valColor = cs.error;
      if (value == 'PENDING') valColor = const Color(0xFFB8860B);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(flex: 2, child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary))),
          Expanded(
            flex: 3,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Flexible(child: Text(value, textAlign: TextAlign.right, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: valColor))),
                if (isCopyable) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: value));
                      showToastNotification(context: context, title: 'Copied', message: '$label copied to clipboard.', isSuccess: true);
                    },
                    child: Icon(Icons.copy_rounded, size: 16, color: isDark ? cs.primary : AppColors.primary),
                  )
                ]
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(UIScale ui, bool isDark, ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: EdgeInsets.all(ui.inset(20)),
            decoration: BoxDecoration(color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(Icons.receipt_long_rounded, size: ui.icon(48), color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.6)),
          ),
          SizedBox(height: ui.gap(16)),
          Text('No Transactions Yet', style: TextStyle(fontWeight: FontWeight.w900, fontSize: ui.font(18), color: isDark ? cs.onSurface : AppColors.textPrimary)),
          SizedBox(height: ui.gap(8)),
          Text('Your recent financial activity will appear here.', style: TextStyle(fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildSkeleton(UIScale ui, bool isDark, ColorScheme cs) {
    if (_shimmerController == null) return const SizedBox();
    final baseColor = isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.05);
    final highlightColor = isDark ? Colors.white.withOpacity(0.15) : Colors.black.withOpacity(0.12);

    return AnimatedBuilder(
      animation: _shimmerController!,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            return LinearGradient(
              colors: [baseColor, highlightColor, baseColor],
              stops: const [0.1, 0.5, 0.9],
              transform: _SlideGradientTransform(_shimmerController!.value),
            ).createShader(bounds);
          },
          child: ListView(
            padding: EdgeInsets.all(ui.inset(16)),
            children: [
              Row(
                children: [
                  Expanded(child: Container(height: 90, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)))),
                  SizedBox(width: ui.gap(12)),
                  Expanded(child: Container(height: 90, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)))),
                ],
              ),
              SizedBox(height: ui.gap(32)),
              ...List.generate(6, (index) => Container(margin: EdgeInsets.only(bottom: ui.gap(12)), height: 70, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)))),
            ],
          ),
        );
      },
    );
  }

  Widget _buildError(UIScale ui, bool isDark, ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off_rounded, size: ui.icon(60), color: cs.error.withOpacity(0.5)),
          SizedBox(height: ui.gap(16)),
          Text('Connection Error', style: TextStyle(fontSize: ui.font(20), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary)),
          SizedBox(height: ui.gap(8)),
          Text('Unable to load your transactions.', style: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w600)),
          SizedBox(height: ui.gap(24)),
          ElevatedButton.icon(
            onPressed: _fetchTransactions,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try Again', style: TextStyle(fontWeight: FontWeight.w800)),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark ? cs.primary : AppColors.primary,
              foregroundColor: isDark ? cs.onPrimary : Colors.white,
              padding: EdgeInsets.symmetric(horizontal: ui.inset(24), vertical: ui.inset(12)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ui.radius(30))),
            ),
          )
        ],
      ),
    );
  }
}

class _SlideGradientTransform extends GradientTransform {
  final double percent;
  const _SlideGradientTransform(this.percent);
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (percent * 2 - 1), 0, 0);
  }
}