import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import '../themes/app_theme.dart';
import '../api/api_client.dart';
import '../api/url.dart';
import '../utility/notification.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class BalanceCard extends StatefulWidget {
  const BalanceCard({Key? key}) : super(key: key);

  @override
  _BalanceCardState createState() => _BalanceCardState();
}

class _BalanceCardState extends State<BalanceCard> with SingleTickerProviderStateMixin {
  late ApiClient _apiClient;
  String _uid = '';
  double _balance = 0.0;
  String _currency = "NGN";
  String _lastTran = '';
  String _bankName = '';
  String _accountNumber = '';
  String _accountName = '';
  bool _isLoading = true;
  Timer? _updateTimer;
  int _updateInterval = 10; // Start with 10 seconds
  int _unchangedCount = 0;
  bool _isBalanceVisible = true;
  late AnimationController _animationController;
  late Animation<double> _animation;
  int _retryCount = 0;
  final int _maxRetries = 5;

  @override
  void initState() {
    super.initState();
    _apiClient = ApiClient(http.Client(), context);
    _initializePrefs();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _animation = Tween<double>(begin: 0, end: 1).animate(_animationController);
    _animationController.forward();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _initializePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');
      if (userId != null && userId.isNotEmpty) {
        setState(() {
          _uid = userId;
        });
        await _fetchUserInfo();
        _startPeriodicUpdates();
      } else {
        throw Exception('User ID not found in SharedPreferences');
      }
    } catch (e) {
      _showError('Failed to initialize user preferences: $e');
    }
  }

  void _startPeriodicUpdates() {
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(Duration(seconds: _updateInterval), (timer) {
      _fetchUserInfo();
    });
  }

  Future<void> _fetchUserInfo() async {
    if (_uid.isEmpty) {
      _showError('User info not found');
      return;
    }

    if (!await _checkConnectivity()) {
      _showError('No internet connection. Retrying...');
      _scheduleRetry();
      return;
    }

    try {
      final response = await _apiClient.request(
        ApiConstants.userInfoEndpoint,
        method: 'POST',
        data: {'user': _uid},
      ).timeout(Duration(seconds: 30)); // Add timeout

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        if (responseData['error'] == false) {
          _updateUserInfo(responseData['user']);
        } else {
          throw Exception(responseData['message'] ?? 'Unknown error occurred');
        }
      } else {
        throw Exception('Unexpected server response: ${response.statusCode}');
      }
    } catch (error) {
      print('Error fetching user info: $error');
      if (_retryCount < _maxRetries) {
        _scheduleRetry();
      } else {
        _showError('Failed to fetch user info after multiple attempts');
      }
    }
  }

  void _updateUserInfo(Map<String, dynamic> userData) {
    double newBalance = double.tryParse(userData['user_bal'] ?? '0.0') ?? 0.0;

    setState(() {
      _balance = newBalance;
      _currency = userData['user_currency'] ?? 'NGN';
      _lastTran = userData['user_last_tran'] ?? '';
      _bankName = userData['user_bank'] ?? '';
      _accountNumber = userData['user_account_number'] ?? '';
      _accountName = userData['user_account_name'] ?? '';
      _isLoading = false;
      _retryCount = 0; // Reset retry count on successful fetch
    });

    _adjustUpdateInterval(newBalance);
  }

  void _adjustUpdateInterval(double newBalance) {
    if (newBalance == _balance) {
      _unchangedCount++;
      if (_unchangedCount >= 3 && _updateInterval < 60) {
        _updateInterval = (_updateInterval * 1.5).round();
        _startPeriodicUpdates();
      }
    } else {
      _unchangedCount = 0;
      if (_updateInterval > 10) {
        _updateInterval = 10;
        _startPeriodicUpdates();
      }
    }
  }

  Future<bool> _checkConnectivity() async {
    var connectivityResult = await (Connectivity().checkConnectivity());
    return connectivityResult != ConnectivityResult.none;
  }

  void _scheduleRetry() {
    _retryCount++;
    Future.delayed(Duration(seconds: _retryCount * 2), _fetchUserInfo);
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
    _updateInterval = 10; // Reset interval on manual refresh
    _retryCount = 0; // Reset retry count
    await _fetchUserInfo();
    _startPeriodicUpdates();
  }

  void _toggleBalanceVisibility() {
    setState(() {
      _isBalanceVisible = !_isBalanceVisible;
      _animationController.forward(from: 0);
    });
  }

  void _showFundAccountBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.50,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (_, ScrollController scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: AppColors.backgroundColor,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  Container(
                    height: 5,
                    width: 40,
                    margin: EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      padding: EdgeInsets.all(16), // Reduced padding
                      children: [
                        Text(
                          'Fund Your Account',
                          style: AppTextStyles.heading2.copyWith(fontSize: 20), // Smaller font
                        ),
                        SizedBox(height: 16), // Reduced spacing
                        Text(
                          'Make a transfer to the account details below:',
                          style: AppTextStyles.bodyText.copyWith(fontSize: 14), // Smaller font
                        ),
                        SizedBox(height: 16), // Reduced spacing
                        _buildAccountInfoCard(),
                        SizedBox(height: 16), // Reduced spacing
                        Text(
                          'Important Notes:',
                          style: AppTextStyles.subHeading.copyWith(fontSize: 16), // Smaller font
                        ),
                        SizedBox(height: 8), // Reduced spacing
                        _buildBulletPoint('Transfers may be delayed within 30-60 minutes.'),
                        _buildBulletPoint('Include detailed info in the transfer description (optional).'),
                        _buildBulletPoint('Contact support if you encounter any issues.'),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAccountInfoCard() {
    return Container(
      padding: EdgeInsets.all(16), // Reduced padding
      decoration: BoxDecoration(
        color: AppColors.accentColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accentColor),
      ),
      child: Column(
        children: [
          _buildAccountInfoRow('Bank Name', _bankName),
          _buildAccountInfoRow('Account Name', _accountName),
          _buildAccountInfoRow('Account Number', _accountNumber),
        ],
      ),
    );
  }

  Widget _buildAccountInfoRow(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppTextStyles.bodyText.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 14, // Smaller font
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      value.isNotEmpty ? value : 'Not available',
                      style: AppTextStyles.bodyText.copyWith(fontSize: 14), // Smaller font
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  const SizedBox(width: 8), // Reduced spacing
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16), // Smaller icon
                    onPressed: value.isNotEmpty ? () => _copyToClipboard(label, value) : null,
                  ),
                ],
              ),
            ],
          ),
        ),
        _buildDottedLine(),
      ],
    );
  }

  Widget _buildDottedLine() {
    return Container(
      height: 1,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final boxWidth = constraints.constrainWidth();
          const dashWidth = 4.0;
          const dashHeight = 1.0;
          final dashCount = (boxWidth / (2 * dashWidth)).floor();

          return Flex(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            direction: Axis.horizontal,
            children: List.generate(dashCount, (_) {
              return SizedBox(
                width: dashWidth,
                height: dashHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.grey.withOpacity(0.5)),
                ),
              );
            }),
          );
        },
      ),
    );
  }

  void _copyToClipboard(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    showBannerNotification(
      context: context,
      message: '$label copied to clipboard',
      isSuccess: true,
    );
  }

  Widget _buildBulletPoint(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4), // Reduced spacing
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• ', style: AppTextStyles.bodyText.copyWith(fontSize: 14)), // Smaller font
          Expanded(
            child: Text(
              text,
              style: AppTextStyles.bodyText.copyWith(fontSize: 14), // Smaller font
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: 180, // Reduced height
          child: _buildCard(),
        ),
      ),
    );
  }

  Widget _buildCard() {
    return Container(
      padding: const EdgeInsets.all(16), // Reduced padding
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.accentColor, AppColors.darkColor],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.darkColor.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: _isLoading ? _buildLoadingIndicator() : _buildCardContent(),
    );
  }

  Widget _buildCardContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Total Balance',
              style: AppTextStyles.subHeading.copyWith(
                color: AppColors.textOnDarkPrimary,
                fontSize: 16, // Smaller font
              ),
            ),
            GestureDetector(
              onTap: _toggleBalanceVisibility,
              child: Icon(
                _isBalanceVisible ? Icons.visibility : Icons.visibility_off,
                color: AppColors.textOnDarkPrimary,
                size: 20, // Smaller icon
              ),
            ),
          ],
        ),
        AnimatedBuilder(
          animation: _animation,
          builder: (context, child) {
            return Opacity(
              opacity: _animation.value,
              child: Text(
                _isBalanceVisible ? '${_currency}${_formatNumber(_balance)}' : '****',
                style: AppTextStyles.heading.copyWith(
                  fontSize: 22, // Smaller font
                  fontWeight: FontWeight.bold,
                  color: AppColors.textOnDarkPrimary,
                ),
              ),
            );
          },
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildLastTransactionInfo(),
          ],
        ),
        _buildFundAccountButton(),
      ],
    );
  }

  Widget _buildLastTransactionInfo() {
    if (_lastTran.isEmpty) return SizedBox.shrink();

    bool isIncome = _lastTran.startsWith('+');
    String transactionAmount = _lastTran.substring(1); // Remove the +/- prefix
    double lastTransactionAmount = double.tryParse(transactionAmount) ?? 0.0;
    Color transactionColor = isIncome ? Colors.white : Colors.redAccent;
    IconData transactionIcon = isIncome ? Icons.trending_up : Icons.trending_down;

    return Row(
      children: [
        Icon(transactionIcon, color: transactionColor, size: 16), // Smaller icon
        const SizedBox(width: 4), // Reduced spacing
        Text(
          '${_currency}${_formatNumber(lastTransactionAmount)}',
          style: AppTextStyles.caption.copyWith(
            color: transactionColor,
            fontSize: 14, // Smaller font
          ),
        ),
      ],
    );
  }

  Widget _buildFundAccountButton() {
    return ElevatedButton(
      onPressed: _showFundAccountBottomSheet,
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8), // Reduced padding
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add_circle_outline, color: AppColors.accentColor, size: 16), // Smaller icon
          SizedBox(width: 4), // Reduced spacing
          Text(
            'Fund Account',
            style: AppTextStyles.bodyText.copyWith(
              color: AppColors.accentColor,
              fontSize: 14, // Smaller font
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    return const Center(
      child: CircularProgressIndicator(
        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
      ),
    );
  }

  String _formatNumber(double number) {
    // Convert the number to a string with two decimal places
    String numberString = number.toStringAsFixed(2);

    // Use regular expression to add commas
    RegExp regExp = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    return numberString.replaceAllMapped(regExp, (Match match) => '${match[1]},');
  }
}