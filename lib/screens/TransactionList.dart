// lib/screens/TransactionList.dart
import 'dart:convert';
import 'dart:ui' show FontFeature, ImageFilter;

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

  // Search & Filter State
  String _filter = 'All'; // All, Credit, Debit
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

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
    _searchController.dispose();
    _searchFocusNode.dispose();
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

  // Combined Getter for Search and Chip Filtering
  List<Transaction> get _filteredTransactions {
    var list = _transactions;

    // 1. Apply Type Filter
    if (_filter != 'All') {
      final typeFilter = _filter.toLowerCase();
      list = list.where((tx) => tx.type == typeFilter).toList();
    }

    // 2. Apply Text Search
    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((tx) {
        return tx.title.toLowerCase().contains(q) ||
            tx.reference.toLowerCase().contains(q) ||
            tx.paymentMode.toLowerCase().contains(q) ||
            tx.recipientBank.toLowerCase().contains(q) ||
            tx.recipientAccount.toLowerCase().contains(q);
      }).toList();
    }

    return list;
  }

  // Smart Date Grouping (Banking App Style)
  Map<String, List<Transaction>> _groupTransactions(List<Transaction> txs) {
    final Map<String, List<Transaction>> groups = {};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    for (var tx in txs) {
      final txDate = DateTime(tx.date.year, tx.date.month, tx.date.day);
      String groupKey;

      if (txDate == today) {
        groupKey = 'Today';
      } else if (txDate == yesterday) {
        groupKey = 'Yesterday';
      } else {
        groupKey = DateFormat('MMM d, yyyy').format(txDate);
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

    final groupedData = _groupTransactions(_filteredTransactions);

    return Scaffold(
      backgroundColor: isDark ? Colors.black : AppColors.offWhite,
      appBar: AppBar(
        backgroundColor: isDark ? Colors.black : AppColors.offWhite,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'Transactions',
          style: TextStyle(fontSize: ui.font(16), fontWeight: FontWeight.w900, letterSpacing: -0.25, color: isDark ? cs.onSurface : AppColors.textPrimary),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: ui.icon(16), color: isDark ? cs.onSurface : AppColors.textPrimary),
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
          padding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.gap(6)),
          child: Row(
            children: [
              Expanded(child: _buildSummaryCard(ui, isDark, cs, 'Money In', _totalIn, true)),
              SizedBox(width: ui.gap(10)),
              Expanded(child: _buildSummaryCard(ui, isDark, cs, 'Money Out', _totalOut, false)),
            ],
          ),
        ),

        SizedBox(height: ui.gap(6)),

        // Search Bar
        _buildSearchBar(isDark, cs, ui),

        SizedBox(height: ui.gap(8)),

        // Micro Filter Chips
        SizedBox(
          height: ui.gap(32), // Strict micro height constraint
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: ui.inset(16)),
            itemCount: 3,
            separatorBuilder: (_, __) => SizedBox(width: ui.gap(6)),
            itemBuilder: (_, i) {
              final filters = ['All', 'Credit', 'Debit'];
              final filter = filters[i];
              final isSelected = _filter == filter;

              return GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _filter = filter);
                },
                child: Container(
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(horizontal: ui.inset(12)),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? cs.primary.withOpacity(0.15)
                        : (isDark ? cs.surfaceVariant.withOpacity(0.5) : Colors.white.withOpacity(0.6)),
                    borderRadius: BorderRadius.circular(ui.radius(10)),
                    border: Border.all(
                      color: isSelected
                          ? cs.primary.withOpacity(0.8)
                          : (isDark ? cs.outlineVariant.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.4)),
                      width: 1.0, // Thin premium borders
                    ),
                  ),
                  child: Text(
                    filter,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: ui.font(11.5), // Tiny, crisp typography
                      letterSpacing: -0.1,
                      color: isSelected ? cs.primary : cs.onSurfaceVariant,
                    ),
                  ),
                ),
              );
            },
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
                    padding: EdgeInsets.only(top: ui.gap(12), bottom: ui.gap(6), left: ui.inset(4)),
                    child: Text(
                      dateKey.toUpperCase(),
                      style: TextStyle(
                        fontSize: ui.font(9.5),
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.0,
                        color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(0.8),
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: isDark ? cs.surface : Colors.white,
                      borderRadius: BorderRadius.circular(ui.radius(14)),
                      border: Border.all(color: isDark ? cs.outlineVariant.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.4), width: 1.0),
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
      padding: EdgeInsets.all(ui.inset(12)), // Tighter padding
      decoration: BoxDecoration(
        color: isDark ? cs.surface : Colors.white,
        borderRadius: BorderRadius.circular(ui.radius(14)),
        border: Border.all(color: isDark ? cs.outlineVariant.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.4), width: 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isCredit ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, size: ui.icon(12), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
              SizedBox(width: ui.gap(4)),
              Text(title, style: TextStyle(fontSize: ui.font(10.5), fontWeight: FontWeight.w700, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
            ],
          ),
          SizedBox(height: ui.gap(6)),
          Text(
            _currencyFmt.format(amount),
            style: TextStyle(
              fontSize: ui.font(15), // Scaled down
              fontWeight: FontWeight.w900,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(bool isDark, ColorScheme cs, UIScale ui) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(16)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ui.radius(12)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: ui.reduceFx ? 4 : 10, sigmaY: ui.reduceFx ? 4 : 10),
          child: Container(
            height: ui.gap(38), // Ultra compact height
            decoration: BoxDecoration(
              color: isDark ? cs.surfaceVariant.withOpacity(0.6) : Colors.white.withOpacity(0.7),
              borderRadius: BorderRadius.circular(ui.radius(12)),
              border: Border.all(
                color: isDark ? cs.outlineVariant.withOpacity(0.4) : AppColors.mintBgLight.withOpacity(0.4),
                width: 1,
              ),
            ),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              onChanged: (v) => setState(() => _searchQuery = v),
              style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface, fontSize: ui.font(12.5)),
              decoration: InputDecoration(
                hintText: 'Search transactions...',
                hintStyle: TextStyle(color: cs.onSurfaceVariant.withOpacity(0.7), fontSize: ui.font(12)),
                prefixIcon: Icon(Icons.search_rounded, color: cs.primary, size: ui.icon(16)),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                  icon: Icon(Icons.clear_rounded, size: ui.icon(14), color: cs.onSurfaceVariant),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                    _searchFocusNode.unfocus();
                  },
                  splashRadius: 18,
                )
                    : null,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: ui.inset(10)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTransactionTile(UIScale ui, bool isDark, ColorScheme cs, Transaction tx, bool isLast) {
    final isCredit = tx.type == 'credit';
    final isPending = tx.status == 'pending';
    final isFailed = tx.status == 'failed' || tx.status == 'declined' || tx.status == 'reversed';

    final amountColor = isFailed
        ? cs.error
        : (isCredit ? (isDark ? cs.primary : const Color(0xFF1E8E3E)) : (isDark ? cs.onSurface : AppColors.textPrimary));

    final iconBg = isDark ? cs.surfaceVariant : AppColors.mintBgLight.withOpacity(0.3);
    final iconColor = isDark ? cs.onSurface : AppColors.textPrimary;

    Widget buildIcon() {
      if (tx.iconUrl.isNotEmpty && tx.iconUrl != 'N/A' && tx.iconUrl.startsWith('http')) {
        return ClipOval(
          child: Image.network(
            tx.iconUrl,
            width: ui.gap(32),
            height: ui.gap(32),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _fallbackIcon(iconColor, ui),
          ),
        );
      }
      return _fallbackIcon(iconColor, ui);
    }

    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        _showTransactionReceipt(ui, isDark, cs, tx);
      },
      borderRadius: BorderRadius.vertical(
        top: isLast && txsLengthIsOne(tx) ? Radius.circular(ui.radius(14)) : (isLast ? Radius.zero : Radius.circular(ui.radius(14))),
        bottom: isLast ? Radius.circular(ui.radius(14)) : Radius.zero,
      ),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: ui.inset(12), vertical: ui.inset(12)),
        decoration: BoxDecoration(
          border: isLast ? null : Border(bottom: BorderSide(color: isDark ? cs.outlineVariant.withOpacity(0.2) : AppColors.mintBgLight.withOpacity(0.3), width: 1.0)),
        ),
        child: Row(
          children: [
            Container(
              width: ui.gap(34),
              height: ui.gap(34),
              decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
              child: buildIcon(),
            ),
            SizedBox(width: ui.gap(10)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tx.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(12.5), letterSpacing: -0.1, color: isDark ? cs.onSurface : AppColors.textPrimary),
                  ),
                  SizedBox(height: ui.gap(2)),
                  Row(
                    children: [
                      Text(
                        DateFormat('h:mm a').format(tx.date),
                        style: TextStyle(fontSize: ui.font(10), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
                      ),
                      if (isPending || isFailed) ...[
                        SizedBox(width: ui.gap(6)),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: ui.inset(4), vertical: ui.inset(2)),
                          decoration: BoxDecoration(
                            color: isFailed ? cs.error.withOpacity(0.1) : const Color(0xFFB8860B).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(ui.radius(4)),
                          ),
                          child: Text(
                            isFailed ? 'Failed' : 'Pending',
                            style: TextStyle(fontSize: ui.font(8.5), fontWeight: FontWeight.w800, color: isFailed ? cs.error : const Color(0xFFB8860B)),
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
                fontSize: ui.font(13.5),
                color: amountColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool txsLengthIsOne(Transaction tx) {
    // Helper for border radiuses if needed, safely assumed from context.
    return false;
  }

  Widget _fallbackIcon(Color iconColor, UIScale ui) {
    return Icon(Icons.receipt_long_rounded, size: ui.icon(16), color: iconColor);
  }

  void _showTransactionReceipt(UIScale ui, bool isDark, ColorScheme cs, Transaction tx) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) => Container(
        // Flat, non-shadowed bottom sheet matching route_sheet
        decoration: BoxDecoration(
          color: isDark ? cs.surface : Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(ui.radius(20))),
          border: Border.all(color: isDark ? cs.outlineVariant.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.4), width: 1.0),
        ),
        padding: EdgeInsets.fromLTRB(ui.inset(20), ui.inset(16), ui.inset(20), MediaQuery.of(context).viewInsets.bottom + ui.gap(32)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: ui.gap(40), height: ui.gap(4), decoration: BoxDecoration(color: isDark ? cs.onSurfaceVariant.withOpacity(0.4) : Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(ui.radius(2)))),
            SizedBox(height: ui.gap(24)),

            // Amount Header
            Text(tx.type == 'credit' ? 'Money Received' : 'Money Spent', style: TextStyle(fontSize: ui.font(11.5), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w700)),
            SizedBox(height: ui.gap(6)),
            Text(
              _currencyFmt.format(tx.amount),
              style: TextStyle(fontSize: ui.font(24), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            SizedBox(height: ui.gap(24)),

            // Strict Receipt Details
            Container(
              decoration: BoxDecoration(
                color: isDark ? cs.surfaceVariant.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2),
                borderRadius: BorderRadius.circular(ui.radius(14)),
                border: Border.all(color: isDark ? cs.outlineVariant.withOpacity(0.2) : AppColors.mintBgLight.withOpacity(0.4), width: 1.0),
              ),
              child: Column(
                children: [
                  _buildReceiptRow('Status', tx.status.toUpperCase(), isDark, cs, ui, isStatus: true),
                  Divider(height: 1, color: isDark ? cs.outlineVariant.withOpacity(0.2) : AppColors.mintBgLight.withOpacity(0.4)),
                  _buildReceiptRow('Date & Time', DateFormat('MMM d, yyyy • h:mm a').format(tx.date), isDark, cs, ui),
                  Divider(height: 1, color: isDark ? cs.outlineVariant.withOpacity(0.2) : AppColors.mintBgLight.withOpacity(0.4)),
                  _buildReceiptRow('Description', tx.title, isDark, cs, ui),
                  Divider(height: 1, color: isDark ? cs.outlineVariant.withOpacity(0.2) : AppColors.mintBgLight.withOpacity(0.4)),
                  _buildReceiptRow('Payment Mode', tx.paymentMode.toUpperCase(), isDark, cs, ui),

                  if (tx.recipientBank != 'N/A' && tx.recipientBank.isNotEmpty) ...[
                    Divider(height: 1, color: isDark ? cs.outlineVariant.withOpacity(0.2) : AppColors.mintBgLight.withOpacity(0.4)),
                    _buildReceiptRow('Recipient Bank', tx.recipientBank, isDark, cs, ui),
                  ],
                  if (tx.recipientAccount != 'N/A' && tx.recipientAccount.isNotEmpty) ...[
                    Divider(height: 1, color: isDark ? cs.outlineVariant.withOpacity(0.2) : AppColors.mintBgLight.withOpacity(0.4)),
                    _buildReceiptRow('Account No.', tx.recipientAccount, isDark, cs, ui, isCopyable: true),
                  ],
                  if (tx.rechargeToken != 'N/A' && tx.rechargeToken.isNotEmpty) ...[
                    Divider(height: 1, color: isDark ? cs.outlineVariant.withOpacity(0.2) : AppColors.mintBgLight.withOpacity(0.4)),
                    _buildReceiptRow('Token / PIN', tx.rechargeToken, isDark, cs, ui, isCopyable: true),
                  ],

                  Divider(height: 1, color: isDark ? cs.outlineVariant.withOpacity(0.2) : AppColors.mintBgLight.withOpacity(0.4)),
                  _buildReceiptRow('Reference', tx.reference, isDark, cs, ui, isCopyable: true),
                ],
              ),
            ),
            SizedBox(height: ui.gap(20)),

            SizedBox(
              width: double.infinity,
              height: ui.gap(44),
              child: ElevatedButton(
                onPressed: () => Navigator.pop(c),
                style: ElevatedButton.styleFrom(
                    backgroundColor: isDark ? cs.surfaceVariant : AppColors.mintBgLight,
                    foregroundColor: isDark ? cs.onSurface : AppColors.textPrimary,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ui.radius(12)))
                ),
                child: Text('Close', style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(13.5))),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceiptRow(String label, String value, bool isDark, ColorScheme cs, UIScale ui, {bool isStatus = false, bool isCopyable = false}) {
    Color valColor = isDark ? cs.onSurface : AppColors.textPrimary;
    if (isStatus) {
      if (value == 'SUCCESSFUL' || value == 'COMPLETED') valColor = isDark ? cs.primary : const Color(0xFF1E8E3E);
      if (value == 'FAILED' || value == 'DECLINED' || value == 'REVERSED') valColor = cs.error;
      if (value == 'PENDING') valColor = const Color(0xFFB8860B);
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(14), vertical: ui.inset(14)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(flex: 2, child: Text(label, style: TextStyle(fontSize: ui.font(11.5), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary))),
          Expanded(
            flex: 3,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Flexible(child: Text(value, textAlign: TextAlign.right, style: TextStyle(fontSize: ui.font(12.5), fontWeight: FontWeight.w800, color: valColor))),
                if (isCopyable) ...[
                  SizedBox(width: ui.gap(6)),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: value));
                      showToastNotification(context: context, title: 'Copied', message: '$label copied.', isSuccess: true);
                    },
                    child: Icon(Icons.copy_rounded, size: ui.icon(14), color: isDark ? cs.primary : AppColors.primary),
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
            padding: EdgeInsets.all(ui.inset(12)),
            decoration: BoxDecoration(color: cs.primary.withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(Icons.receipt_long_rounded, size: ui.icon(32), color: cs.primary.withOpacity(0.6)),
          ),
          SizedBox(height: ui.gap(12)),
          Text(
              _searchQuery.isNotEmpty ? 'No Results Found' : 'No Transactions Yet',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: ui.font(14), color: isDark ? cs.onSurface : AppColors.textPrimary)
          ),
          SizedBox(height: ui.gap(4)),
          Text(
              _searchQuery.isNotEmpty ? 'Try adjusting your search or filters.' : 'Your activity will appear here',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: ui.font(11.5), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)
          ),
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
                  Expanded(child: Container(height: ui.gap(70), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(ui.radius(14))))),
                  SizedBox(width: ui.gap(10)),
                  Expanded(child: Container(height: ui.gap(70), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(ui.radius(14))))),
                ],
              ),
              SizedBox(height: ui.gap(24)),
              ...List.generate(6, (index) => Container(margin: EdgeInsets.only(bottom: ui.gap(8)), height: ui.gap(60), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(ui.radius(14))))),
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
          Icon(Icons.wifi_off_rounded, size: ui.icon(40), color: cs.error.withOpacity(0.5)),
          SizedBox(height: ui.gap(12)),
          Text('Connection Error', style: TextStyle(fontSize: ui.font(16), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary)),
          SizedBox(height: ui.gap(6)),
          Text('Unable to load your transactions.', style: TextStyle(fontSize: ui.font(12), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w600)),
          SizedBox(height: ui.gap(20)),
          ElevatedButton.icon(
            onPressed: _fetchTransactions,
            icon: Icon(Icons.refresh_rounded, size: ui.icon(16)),
            label: Text('Try Again', style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(12.5))),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark ? cs.primary : AppColors.primary,
              foregroundColor: isDark ? cs.onPrimary : Colors.white,
              padding: EdgeInsets.symmetric(horizontal: ui.inset(20), vertical: ui.inset(10)),
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ui.radius(12))),
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