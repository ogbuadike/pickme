import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:lottie/lottie.dart';
import '../themes/app_theme.dart';
import '../api/api_client.dart';
import '../api/url.dart';
import '../utility/notification.dart';
import 'dart:io';
import '../screens/transaction_detail_page.dart';

class TransactionList extends StatefulWidget {
  final int limit;

  const TransactionList({Key? key, this.limit = 5, required String filter, required DateTime? startDate, required DateTime? endDate}) : super(key: key);

  @override
  _TransactionListState createState() => _TransactionListState();
}

class _TransactionListState extends State<TransactionList> {
  late ApiClient _apiClient;
  String? _uid;
  List<Map<String, dynamic>> _transactions = [];
  bool _isLoading = true;
  Timer? _updateTimer;
  int _updateInterval = 30;

  @override
  void initState() {
    super.initState();
    _apiClient = ApiClient(http.Client(), context);
    _initializePrefs();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  Future<void> _initializePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _uid = prefs.getString('user_id');
    });
    await _fetchTransactions();
    _startPeriodicUpdates();
  }

  void _startPeriodicUpdates() {
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(Duration(seconds: _updateInterval), (timer) {
      _fetchTransactions();
    });
  }

  Future<void> _fetchTransactions() async {
    if (_uid == null) return;

    try {
      final response = await _apiClient.request(
        ApiConstants.transactionsEndpoint,
        method: 'POST',
        data: {'user': _uid!, 'limit': widget.limit.toString()},
      );

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);

        if (responseData['error'] == false && responseData['transactions'] is List) {
          List<Map<String, dynamic>> newTransactions = [];
          try {
            newTransactions = (responseData['transactions'] as List).map((transaction) {
              return {
                'id': transaction['id']?.toString() ?? '',
                'title': transaction['title']?.toString() ?? '',
                'datetime': transaction['datetime'] != null
                    ? DateTime.tryParse(transaction['datetime'].toString()) ?? DateTime.now()
                    : DateTime.now(),
                'amount': transaction['amount'] != null
                    ? double.tryParse(transaction['amount'].toString()) ?? 0.0
                    : 0.0,
                'type': transaction['type']?.toString() ?? '',
                'payment_mode': transaction['payment_mode']?.toString() ?? '',
                'status': transaction['status']?.toString() ?? '',
                'reference': transaction['reference']?.toString() ?? '',
                'recharge_token': transaction['recharge_token']?.toString() ?? '',
                'icon': transaction['icon']?.toString() ?? '',
                'metadata': transaction['metadata'] ?? {},
                'recipient': transaction['recipient'] ?? {},
              };
            }).toList();

            setState(() {
              _transactions = newTransactions;
              _isLoading = false;
            });
          } catch (e) {
            // Handle parsing error
          }
        } else {
          // Handle API error
        }
      } else {
        // Handle server error
      }
    } catch (error) {
      if (error is SocketException) {
        _showError('Network error: Unable to connect to the server');
      } else {
        // Handle other errors
      }
    }
  }

  void _showError(String message) {
    setState(() => _isLoading = false);
    showToastNotification(
      context: context,
      title: 'Error',
      message: message,
      isSuccess: false,
    );
  }

  Future<void> _onRefresh() async {
    _updateInterval = 30;
    await _fetchTransactions();
    _startPeriodicUpdates();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.4, // Dynamic height
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: _onRefresh,
        child: _buildTransactionList(),
      ),
    );
  }

  Widget _buildTransactionList() {
    if (_transactions.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight,
              ),
              child: IntrinsicHeight(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Lottie.asset(
                              'assets/lottie/no_transaction.json',
                              width: constraints.maxWidth * 0.4, // Smaller animation
                              height: constraints.maxHeight * 0.3,
                              fit: BoxFit.contain,
                            ),
                            SizedBox(height: 10), // Reduced spacing
                            Text(
                              'No transactions found',
                              style: AppTextStyles.bodyText.copyWith(
                                fontSize: 14, // Smaller font
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _transactions.length,
      itemBuilder: (context, index) {
        final transaction = _transactions[index];
        return _buildTransactionItem(transaction);
      },
    );
  }

  Widget _buildTransactionItem(Map<String, dynamic> transaction) {
    final title = transaction['title'];
    final date = transaction['datetime'];
    final amount = transaction['amount'];
    final type = transaction['type'];
    final iconUrl = transaction['icon'];

    final formattedDate = DateFormat('MMM d, yyyy').format(date);
    final formattedTime = DateFormat('h:mm a').format(date);

    String sign = type == "minus" ? '-' : '+';
    Color textColor = type == "minus" ? AppColors.errorColor : AppColors.successColor;

    return Card(
      elevation: 1, // Reduced elevation
      margin: const EdgeInsets.symmetric(vertical: 4), // Reduced margin
      child: InkWell(
        onTap: () => _navigateToTransactionDetail(transaction),
        child: ListTile(
          dense: true, // Compact list item
          leading: CircleAvatar(
            radius: 16, // Smaller avatar
            backgroundColor: AppColors.accentColor.withOpacity(0.1),
            backgroundImage: iconUrl == "N/A" || iconUrl.isEmpty
                ? null
                : NetworkImage(iconUrl),
            child: iconUrl == "N/A" || iconUrl.isEmpty
                ? Icon(Icons.business, size: 16, color: AppColors.darkerColor) // Smaller icon
                : null,
          ),
          title: Text(
            title,
            style: AppTextStyles.bodyText.copyWith(
              fontWeight: FontWeight.bold,
              fontSize: 12, // Smaller font
            ),
          ),
          subtitle: Text(
            '$formattedDate, $formattedTime',
            style: AppTextStyles.caption.copyWith(fontSize: 10), // Smaller font
          ),
          trailing: Text(
            '$sign\NGN${amount.abs().toStringAsFixed(2)}',
            style: AppTextStyles.bodyText.copyWith(
              color: textColor,
              fontWeight: FontWeight.bold,
              fontSize: 12, // Smaller font
            ),
          ),
        ),
      ),
    );
  }

  void _navigateToTransactionDetail(Map<String, dynamic> transaction) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TransactionDetailPage(transaction: transaction),
      ),
    );
  }
}