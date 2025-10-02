import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../../api/url.dart';
import '../themes/app_theme.dart';
import '../utility/notification.dart';
import '../widgets/inner_background.dart';
import '../widgets/expandable_floating_action_button_widget.dart';
import '../widgets/floating_action_button_widget.dart';
import '../widgets/transactionList.dart';
import '../widgets/balance.dart';
import '../widgets/quick_pay.dart';
import '../routes/routes.dart';
import '../widgets/bottom_navigation_bar.dart';

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  late SharedPreferences _prefs;
  late ApiClient _apiClient;
  bool _isLoading = false;
  bool _hasError = false;
  Map<String, dynamic>? _userData;

  int _currentIndex = 0;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _initializeData();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
    });
  }

  Future<void> _initializeData() async {
    _prefs = await SharedPreferences.getInstance();
    _apiClient = ApiClient(http.Client(), context);
    await _fetchUserProfile();
  }

  Future<void> _fetchUserProfile() async {
    setState(() { _isLoading = true; _hasError = false; });

    try {
      final userId = _prefs.getString('user_id');
      final data = {'user': userId ?? ''};

      final response = await _apiClient.request(
        ApiConstants.userInfoEndpoint,
        method: 'POST',
        data: data,
      );

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        if (!(responseData['error'] as bool)) {
          setState(() => _userData = responseData['user']);
        } else {
          throw Exception(responseData['error_msg']);
        }
      } else {
        throw Exception('Failed to load user info');
      }
    } catch (_) {
      setState(() => _hasError = true);
      showToastNotification(
        context: context,
        title: 'Error',
        message: 'Failed to load info. Please try again.',
        isSuccess: false,
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // KEY: let body render UNDER the transparent bottom bar
      extendBody: true,

      body: Stack(
        children: [
          // your full-page background/hero
          BackgroundWidget(),

          SafeArea(
            child: CustomScrollView(
              slivers: [
                _buildAppBar(),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        SizedBox(height: 16),
                        BalanceCard(),
                        SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: _buildQuickSendSection(),
                  ),
                ),
                _buildTransactionListSliver(),

                // Add bottom spacer so the last list items aren’t hidden by the floating bar
                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
            ),
          ),

          // Your floating action menu remains above content
          Positioned(
            right: 8,
            bottom: 8,
            child: ExpandableFloatingActionButton(
              floatingActionButtons: [
                CustomFloatingActionButton(
                  icon: Icons.send,
                  label: 'Transfer Funds',
                  color: AppColors.secondary,
                  onPressed: () {},
                ),
                const SizedBox(height: 8),
                CustomFloatingActionButton(
                  icon: Icons.shopping_cart,
                  label: 'Buy Gift Card',
                  color: AppColors.success,
                  onPressed: () {},
                ),
                const SizedBox(height: 8),
                CustomFloatingActionButton(
                  icon: Icons.payment,
                  label: 'Pay Bills',
                  color: AppColors.darkerColor,
                  onPressed: () {},
                ),
              ],
              mainButtonColor: AppColors.primary,
              collapsedIcon: Icons.add,
              expandedIcon: Icons.close,
              animation: _animationController,
              onToggle: _toggleExpanded,
            ),
          ),
        ],
      ),

      // Floating, fully transparent nav on top of the body
      bottomNavigationBar: CustomBottomNavBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
      ),
    );
  }

  SliverAppBar _buildAppBar() {
    return SliverAppBar(
      floating: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      title: GestureDetector(
        onTap: () => Navigator.pushNamed(context, AppRoutes.profile),
        child: Row(
          children: [
            CircleAvatar(
              backgroundImage: NetworkImage(
                _userData?['user_logo'] ??
                    'https://icon-library.com/images/icon-avatar/icon-avatar-6.jpg',
              ),
              radius: 16,
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppTextStyles.subHeading.copyWith(
                  fontSize: 14,
                  color: AppColors.textOnLightPrimary,
                ).let((s) => Text('Hello, ${_userData?['user_lname'] ?? 'N/A'}', style: s)),
                AppTextStyles.caption.copyWith(
                  fontSize: 12,
                  color: AppColors.textOnLightSecondary,
                ).let((s) => Text('Welcome back', style: s)),
              ],
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.notifications, size: 20),
          color: AppColors.textOnLightPrimary,
          onPressed: () {},
        ),
      ],
    );
  }

  Widget _buildQuickSendSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Quick Pay', style: AppTextStyles.subHeading.copyWith(fontSize: 14)),
        const SizedBox(height: 8),
        QuickPaySection(onQuickPayButtonPressed: (name, code) {}),
      ],
    );
  }

  SliverPadding _buildTransactionListSliver() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          Text('Recent Transactions', style: AppTextStyles.subHeading.copyWith(fontSize: 14)),
          const SizedBox(height: 8),
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.50,
            child: TransactionList(limit: 10, filter: '', startDate: null, endDate: null),
          ),
        ]),
      ),
    );
  }
}

// tiny extension for cleaner inline text style use
extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
