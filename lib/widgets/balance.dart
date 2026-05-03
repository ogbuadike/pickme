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

      // Load initial local data to prevent showing 0.0 while loading
      final storedBal = prefs.getString('user_bal');
      final storedTran = prefs.getString('user_last_tran');

      if (userId != null && userId.isNotEmpty) {
        setState(() {
          _uid = userId;
          if (storedBal != null) _balance = double.tryParse(storedBal) ?? 0.0;
          if (storedTran != null) _lastTran = storedTran;
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

    if (mounted) setState(() => _isLoading = true);

    try {
      final response = await _apiClient.request(
        ApiConstants.userInfoEndpoint,
        method: 'POST',
        data: {'user': _uid},
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        if (responseData['error'] == false) {
          await _updateUserInfo(responseData['user']);
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

  // --- GLOBAL STATE SYNC INCLUDED HERE ---
  Future<void> _updateUserInfo(Map<String, dynamic> userData) async {
    double newBalance = double.tryParse(userData['user_bal'] ?? '0.0') ?? 0.0;
    String newLastTranStr = userData['user_last_tran'] ?? '';

    // Save globally so the entire app (Drawers, Profile, etc.) syncs instantly
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_bal', userData['user_bal'] ?? '0.0');
    await prefs.setString('user_last_tran', newLastTranStr);

    final userDataStr = prefs.getString('user_data') ?? prefs.getString('user');
    if (userDataStr != null) {
      try {
        final Map<String, dynamic> storedUser = jsonDecode(userDataStr);
        storedUser['user_bal'] = userData['user_bal'] ?? '0.0';
        storedUser['user_last_tran'] = newLastTranStr;
        await prefs.setString('user_data', jsonEncode(storedUser));
        await prefs.setString('user', jsonEncode(storedUser));
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _balance = newBalance;
        _currency = userData['user_currency'] ?? 'NGN';
        _lastTran = newLastTranStr;
        _bankName = userData['user_bank'] ?? '';
        _accountNumber = userData['user_account_number'] ?? '';
        _accountName = userData['user_account_name'] ?? '';
        _isLoading = false;
        _retryCount = 0; // Reset retry count on successful fetch
      });
    }

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
    if (mounted) setState(() => _isLoading = false);
    showToastNotification(
      context: context,
      title: 'Error',
      message: message,
      isSuccess: false,
    );
  }

  Future<void> _onRefresh() async {
    HapticFeedback.lightImpact();
    _updateInterval = 10; // Reset interval on manual refresh
    _retryCount = 0; // Reset retry count
    await _fetchUserInfo();
    _startPeriodicUpdates();
  }

  void _toggleBalanceVisibility() {
    HapticFeedback.selectionClick();
    setState(() {
      _isBalanceVisible = !_isBalanceVisible;
      _animationController.forward(from: 0);
    });
  }

  // --- BULLETPROOF BOTTOM SHEET ---
  void _showFundAccountBottomSheet() {
    HapticFeedback.mediumImpact();

    // Explicitly grab the theme to enforce a hard background color
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final solidBgColor = isDark ? Theme.of(context).colorScheme.surface : Colors.white;
    final textColor = isDark ? Colors.white : AppColors.textPrimary;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent, // Keep transparent for the rounded corners
      builder: (BuildContext context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.50,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (_, ScrollController scrollController) {
            return Material(
              color: Colors.transparent,
              child: Container(
                // This solid decoration mathematically guarantees it will never lose its background
                decoration: BoxDecoration(
                  color: solidBgColor,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 10,
                      spreadRadius: 2,
                    )
                  ],
                ),
                child: Column(
                  children: [
                    Container(
                      height: 5,
                      width: 40,
                      margin: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.grey[700] : Colors.grey[300],
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.all(16),
                        children: [
                          Text(
                            'Fund Your Account',
                            style: AppTextStyles.heading2.copyWith(fontSize: 20, color: textColor),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Make a transfer to the account details below:',
                            style: AppTextStyles.bodyText.copyWith(fontSize: 14, color: textColor),
                          ),
                          const SizedBox(height: 16),
                          _buildAccountInfoCard(isDark, textColor),
                          const SizedBox(height: 16),
                          Text(
                            'Important Notes:',
                            style: AppTextStyles.subHeading.copyWith(fontSize: 16, color: textColor),
                          ),
                          const SizedBox(height: 8),
                          _buildBulletPoint('Transfers may be delayed within 30-60 minutes.', textColor),
                          _buildBulletPoint('Include detailed info in the transfer description (optional).', textColor),
                          _buildBulletPoint('Contact support if you encounter any issues.', textColor),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAccountInfoCard(bool isDark, Color textColor) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.accentColor.withOpacity(0.15) : AppColors.accentColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accentColor.withOpacity(0.5)),
      ),
      child: Column(
        children: [
          _buildAccountInfoRow('Bank Name', _bankName, textColor),
          _buildAccountInfoRow('Account Name', _accountName, textColor),
          _buildAccountInfoRow('Account Number', _accountNumber, textColor),
        ],
      ),
    );
  }

  Widget _buildAccountInfoRow(String label, String value, Color textColor) {
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
                  fontSize: 12,
                  color: AppColors.accentColor,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      value.isNotEmpty ? value : 'Not available',
                      style: AppTextStyles.bodyText.copyWith(fontSize: 15, fontWeight: FontWeight.bold, color: textColor),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(Icons.copy_rounded, size: 18, color: AppColors.accentColor),
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
    return SizedBox(
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
                  decoration: BoxDecoration(color: Colors.grey.withOpacity(0.4)),
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

  Widget _buildBulletPoint(String text, Color textColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• ', style: AppTextStyles.bodyText.copyWith(fontSize: 14, color: textColor)),
          Expanded(
            child: Text(
              text,
              style: AppTextStyles.bodyText.copyWith(fontSize: 14, color: textColor),
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
          height: 190, // Adjusted height to accommodate Crypto Indicator
          child: _buildCard(),
        ),
      ),
    );
  }

  Widget _buildCard() {
    return Container(
      padding: const EdgeInsets.all(16),
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
      child: _buildCardContent(),
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
            // Title + Refresh Icon inside the Card Header
            Row(
              children: [
                Text(
                  'Total Balance',
                  style: AppTextStyles.subHeading.copyWith(
                    color: AppColors.textOnDarkPrimary,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _isLoading ? null : _onRefresh,
                  child: _isLoading
                      ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textOnDarkPrimary.withOpacity(0.8))
                  )
                      : Icon(Icons.refresh_rounded, color: AppColors.textOnDarkPrimary.withOpacity(0.8), size: 16),
                ),
              ],
            ),
            GestureDetector(
              onTap: _toggleBalanceVisibility,
              child: Icon(
                _isBalanceVisible ? Icons.visibility : Icons.visibility_off,
                color: AppColors.textOnDarkPrimary,
                size: 20,
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
                _isBalanceVisible ? '$_currency${_formatNumber(_balance)}' : '****',
                style: AppTextStyles.heading.copyWith(
                  fontSize: 26, // Kept prominent
                  fontWeight: FontWeight.bold,
                  color: AppColors.textOnDarkPrimary,
                ),
              ),
            );
          },
        ),

        // --- PREMIUM CRYPTO-STYLE INDICATOR ---
        _buildLastTransactionInfo(),

        _buildFundAccountButton(),
      ],
    );
  }

  // --- REPLACED WITH HIGH CONTRAST CRYPTO INDICATOR ---
  Widget _buildLastTransactionInfo() {
    if (_lastTran.isEmpty || _lastTran == '+0.00' || _lastTran == '-0.00') {
      return const SizedBox.shrink();
    }

    final isSubtracted = _lastTran.startsWith('-');
    final amountStr = _lastTran.replaceAll(RegExp(r'[+-]'), '');
    final amount = double.tryParse(amountStr) ?? 0.0;

    if (amount == 0.0) return const SizedBox.shrink();

    // High Contrast Colors for the green gradient background
    final indicatorColor = isSubtracted
        ? const Color(0xFFFF8A80) // Bright Coral/Red
        : Colors.white; // Pure White

    final bgColor = isSubtracted
        ? Colors.redAccent.withOpacity(0.2)
        : Colors.white.withOpacity(0.25);

    final icon = isSubtracted ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded;
    final sign = isSubtracted ? '-' : '+';

    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: indicatorColor.withOpacity(0.4), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: indicatorColor),
          const SizedBox(width: 4),
          Text(
            'Recent: $sign$_currency ${_formatNumber(amount)}',
            style: AppTextStyles.caption.copyWith(
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

  Widget _buildFundAccountButton() {
    return ElevatedButton(
      onPressed: _showFundAccountBottomSheet,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white, // Contrasting button against dark gradient
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add_circle_outline, color: AppColors.accentColor, size: 16),
          const SizedBox(width: 6),
          Text(
            'Fund Account',
            style: AppTextStyles.bodyText.copyWith(
              color: AppColors.accentColor,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  String _formatNumber(double number) {
    String numberString = number.toStringAsFixed(2);
    RegExp regExp = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    return numberString.replaceAllMapped(regExp, (Match match) => '${match[1]},');
  }
}