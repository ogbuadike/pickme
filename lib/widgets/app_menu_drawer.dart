// lib/widgets/app_menu_drawer.dart
//
// Premium, highly responsive navigation drawer with:
// - Balance card with fund action, live refresh, & crypto-style recent transaction indicator
// - Profile header with avatar & edit button
// - Categorized menu items
// - Premium Become a Driver opportunity card (Hides if already a driver)
// - Landscape/portrait adaptive layout
// - Dark mode support
// - Smooth animations & haptics
// - Safe avatar loading (no SSL errors)
// - Deep State Syncing (Mutates parent map and SharedPrefs JSON)

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../routes/routes.dart';
import '../themes/app_theme.dart';
import '../utility/notification.dart';
import 'fund_account_sheet.dart';

class AppMenuDrawer extends StatefulWidget {
  final Map<String, dynamic>? user;

  const AppMenuDrawer({super.key, required this.user});

  @override
  State<AppMenuDrawer> createState() => _AppMenuDrawerState();
}

class _AppMenuDrawerState extends State<AppMenuDrawer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  bool _isAlreadyDriver = false;

  // Balance State Variables
  double? _liveBalance;
  String? _liveLastTran;
  bool _isRefreshingBalance = false;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();
    _checkDriverStatus();
    _loadStoredBalance();
  }

  Future<void> _checkDriverStatus() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isAlreadyDriver = prefs.getBool('user_is_driver') ?? false;
      });
    }
  }

  /// Initial load check to see if we have a fresher balance in preferences
  Future<void> _loadStoredBalance() async {
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
  Future<void> _refreshBalance() async {
    if (_isRefreshingBalance) return;

    HapticFeedback.lightImpact();
    setState(() => _isRefreshingBalance = true);

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

        // --- 1. MUTATE PARENT STATE BY REFERENCE ---
        // Modifying widget.user directly guarantees that the parent screen
        // instantly has the new data without needing to fetch it again.
        if (widget.user != null) {
          widget.user!['user_bal'] = newBalStr;
          widget.user!['user_last_tran'] = newLastTranStr;
        }

        // --- 2. UPDATE INDIVIDUAL PREFS ---
        await prefs.setString('user_bal', newBalStr);
        await prefs.setString('user_last_tran', newLastTranStr);

        // --- 3. UPDATE JSON OBJECT IN PREFS ---
        // Finds the full stored user string and injects the new balance into it.
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
      debugPrint('Balance refresh failed: $e');
    } finally {
      if (mounted) setState(() => _isRefreshingBalance = false);
    }
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  /// Responsive scale factor based on shortest screen dimension
  double _scale(BuildContext c) {
    final mq = MediaQuery.of(c);
    final shortest = math.min(mq.size.width, mq.size.height);
    return (shortest / 390.0).clamp(0.75, 1.10);
  }

  /// Safe avatar URL (skip domains with SSL issues)
  String? _safeAvatar(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.toLowerCase().contains('icon-library.com')) return null;
    return url.startsWith('http') ? url : null;
  }

  /// Navigate with haptic feedback
  void _nav(String route) {
    HapticFeedback.selectionClick();
    Navigator.pop(context); // close drawer first
    Navigator.pushNamed(context, route);
  }

  /// Show fund account sheet
  void _showFundSheet(double displayBalance) {
    HapticFeedback.mediumImpact();
    Navigator.pop(context); // close drawer
    final currency = widget.user?['user_currency']?.toString() ?? 'NGN';

    showModalBottomSheet(
      context: context,
      isScrollControlled: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FundAccountSheet(
        account: widget.user,
        balance: displayBalance,
        currency: currency,
      ),
    );
  }

  /// Sign out with confirmation
  void _signOut() {
    HapticFeedback.heavyImpact();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('user_id');
              await prefs.remove('user_pin');
              await prefs.remove('user_driver_id');
              await prefs.remove('user_driver_status');
              await prefs.remove('user_is_driver');
              if (mounted) {
                Navigator.pushReplacementNamed(context, AppRoutes.login);
              }
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final s = _scale(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isLandscape = mq.orientation == Orientation.landscape;

    // Extract user data
    final avatarUrl = _safeAvatar(widget.user?['user_logo'] as String?);
    final name = widget.user?['user_lname'] ?? widget.user?['user_name'] ?? 'User';
    final email = (widget.user?['user_email'] as String?) ?? '';

    // Determine the balance to show (Live overridden value, or initial passed value)
    final initialBalance = widget.user != null
        ? double.tryParse(widget.user!['user_bal']?.toString() ?? '0.0') ?? 0.0
        : 0.0;
    final displayBalance = _liveBalance ?? initialBalance;

    // Determine last transaction text
    final displayLastTran = _liveLastTran ?? widget.user?['user_last_tran']?.toString() ?? '';

    final currency = widget.user?['user_currency']?.toString() ?? 'NGN';

    // Drawer width: narrower in landscape
    final drawerWidth = isLandscape
        ? math.min(mq.size.width * 0.65, 320.0)
        : math.min(mq.size.width * 0.82, 360.0);

    return Drawer(
      width: drawerWidth,
      backgroundColor: isDark ? cs.surface : Colors.white,
      child: FadeTransition(
        opacity: _fadeAnim,
        child: SafeArea(
          child: Column(
            children: [
              // Profile header
              _ProfileHeader(
                avatarUrl: avatarUrl,
                name: name,
                email: email,
                scale: s,
                isDark: isDark,
                onEditProfile: () => _nav(AppRoutes.profile),
              ),

              SizedBox(height: 12 * s),

              // Balance card
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16 * s),
                child: _BalanceCard(
                  balance: displayBalance,
                  currency: currency,
                  lastTran: displayLastTran,
                  scale: s,
                  isDark: isDark,
                  isRefreshing: _isRefreshingBalance,
                  onRefresh: _refreshBalance,
                  onFund: () => _showFundSheet(displayBalance),
                ),
              ),

              SizedBox(height: 16 * s),

              // Menu items (scrollable)
              Expanded(
                child: ListView(
                  padding: EdgeInsets.symmetric(horizontal: 8 * s),
                  children: [
                    _SectionLabel('Activity', s, isDark),
                    _MenuItem(
                      icon: Icons.local_taxi_rounded,
                      label: 'My Rides',
                      scale: s,
                      isDark: isDark,
                      onTap: () => _nav(AppRoutes.rideHistory),
                    ),
                    _MenuItem(
                      icon: Icons.receipt_long_rounded,
                      label: 'Transactions',
                      scale: s,
                      isDark: isDark,
                      onTap: () => _nav(AppRoutes.transactions),
                    ),

                    SizedBox(height: 8 * s),
                    _SectionLabel('Support', s, isDark),
                    _MenuItem(
                      icon: Icons.help_outline_rounded,
                      label: 'Help & FAQ',
                      scale: s,
                      isDark: isDark,
                      onTap: () => _nav(AppRoutes.help),
                    ),
                    _MenuItem(
                      icon: Icons.settings_rounded,
                      label: 'Settings',
                      scale: s,
                      isDark: isDark,
                      onTap: () => _nav(AppRoutes.settings),
                    ),

                    SizedBox(height: 16 * s),

                    // Become a Driver premium card (Hidden if already a driver)
                    if (!_isAlreadyDriver) ...[
                      _BecomeDriverCard(
                        scale: s,
                        isDark: isDark,
                        onTap: () => _nav(AppRoutes.become_a_driver),
                      ),
                      SizedBox(height: 12 * s),
                    ],
                  ],
                ),
              ),

              // Sign out button
              Container(
                padding: EdgeInsets.fromLTRB(12 * s, 8 * s, 12 * s, 12 * s),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: isDark
                          ? cs.outline.withOpacity(0.5)
                          : Colors.black.withOpacity(0.06),
                    ),
                  ),
                ),
                child: _SignOutButton(scale: s, isDark: isDark, onTap: _signOut),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PROFILE HEADER
// ═══════════════════════════════════════════════════════════════════════════

class _ProfileHeader extends StatelessWidget {
  final String? avatarUrl;
  final String name;
  final String email;
  final double scale;
  final bool isDark;
  final VoidCallback onEditProfile;

  const _ProfileHeader({
    required this.avatarUrl,
    required this.name,
    required this.email,
    required this.scale,
    required this.isDark,
    required this.onEditProfile,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [cs.primary.withOpacity(0.15), Colors.transparent]
              : [AppColors.primary.withOpacity(0.08), AppColors.accentColor.withOpacity(0.05)],
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(20 * scale),
          bottomRight: Radius.circular(20 * scale),
        ),
      ),
      child: Row(
        children: [
          // Avatar
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: isDark ? cs.primary.withOpacity(0.5) : AppColors.primary.withOpacity(0.5),
                width: 2.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  blurRadius: 10 * scale,
                  offset: Offset(0, 4 * scale),
                ),
              ],
            ),
            child: CircleAvatar(
              radius: 32 * scale,
              backgroundColor: isDark ? cs.surfaceVariant : AppColors.mintBgLight,
              backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
              child: avatarUrl == null
                  ? Icon(Icons.person, size: 32 * scale, color: isDark ? cs.primary : AppColors.primary)
                  : null,
            ),
          ),

          SizedBox(width: 12 * scale),

          // Name & email
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: (17 * scale).clamp(15.0, 20.0),
                    fontWeight: FontWeight.w900,
                    // Uses pure theme colors
                    color: isDark ? cs.onSurface : AppColors.textPrimary,
                    letterSpacing: -0.3,
                  ),
                ),
                if (email.isNotEmpty) ...[
                  SizedBox(height: 2 * scale),
                  Text(
                    email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: (12 * scale).clamp(11.0, 14.0),
                      // Uses crisp grey for dark mode
                      color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Edit button
          IconButton(
            icon: Icon(
              Icons.edit_rounded,
              size: 20 * scale,
              color: isDark ? cs.primary : AppColors.primary,
            ),
            onPressed: onEditProfile,
            tooltip: 'Edit profile',
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// BALANCE CARD WITH HIGH-CONTRAST CRYPTO INDICATOR
// ═══════════════════════════════════════════════════════════════════════════

class _BalanceCard extends StatelessWidget {
  final double balance;
  final String currency;
  final String lastTran;
  final double scale;
  final bool isDark;
  final bool isRefreshing;
  final VoidCallback onRefresh;
  final VoidCallback onFund;

  const _BalanceCard({
    required this.balance,
    required this.currency,
    required this.lastTran,
    required this.scale,
    required this.isDark,
    required this.isRefreshing,
    required this.onRefresh,
    required this.onFund,
  });

  String _fmt(double n) {
    final s = n.toStringAsFixed(2);
    final parts = s.split('.');
    final whole = parts[0].replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
    );
    return '$whole.${parts[1]}';
  }

  Widget _buildCryptoIndicator(ColorScheme cs, double scale) {
    if (lastTran.isEmpty || lastTran == '+0.00' || lastTran == '-0.00') {
      return const SizedBox.shrink();
    }

    final isSubtracted = lastTran.startsWith('-');
    final amountStr = lastTran.replaceAll(RegExp(r'[+-]'), '');
    final amount = double.tryParse(amountStr) ?? 0.0;

    if (amount == 0.0) return const SizedBox.shrink();

    // High Contrast Colors:
    // Negative = Bright Coral/Red.
    // Positive = Neon Green (Dark Mode) or Pure White (Light Mode green card)
    final indicatorColor = isSubtracted
        ? const Color(0xFFFF8A80)
        : (isDark ? const Color(0xFF69F0AE) : Colors.white);

    final bgColor = isSubtracted
        ? Colors.redAccent.withOpacity(0.2)
        : (isDark ? const Color(0xFF00E676).withOpacity(0.15) : Colors.white.withOpacity(0.25));

    final icon = isSubtracted ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded;
    final sign = isSubtracted ? '-' : '+';

    return Container(
      margin: EdgeInsets.only(top: 6 * scale),
      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 4 * scale),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: indicatorColor.withOpacity(0.4), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12 * scale, color: indicatorColor),
          SizedBox(width: 4 * scale),
          Text(
            'Recent: $sign$currency ${_fmt(amount)}',
            style: TextStyle(
              fontSize: (10.5 * scale).clamp(9.0, 12.0),
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
    final cs = Theme.of(context).colorScheme;
    final contentColor = isDark ? cs.onPrimaryContainer.withOpacity(0.9) : Colors.white.withOpacity(0.85);

    return Container(
      padding: EdgeInsets.all(14 * scale),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [cs.primaryContainer, cs.surfaceVariant]
              : [AppColors.accentColor, AppColors.darkColor],
        ),
        borderRadius: BorderRadius.circular(16 * scale),
        border: isDark ? Border.all(color: cs.primary.withOpacity(0.3), width: 1) : null,
        boxShadow: [
          BoxShadow(
            color: isDark ? cs.primary.withOpacity(0.15) : AppColors.primary.withOpacity(0.35),
            blurRadius: 12 * scale,
            offset: Offset(0, 4 * scale),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Label and Refresh Button Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Wallet Balance',
                style: TextStyle(
                  fontSize: (11 * scale).clamp(10.0, 13.0),
                  fontWeight: FontWeight.w700,
                  color: contentColor,
                  letterSpacing: 0.3,
                ),
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: isRefreshing ? null : onRefresh,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: EdgeInsets.all(4 * scale),
                    child: isRefreshing
                        ? SizedBox(
                      width: 14 * scale,
                      height: 14 * scale,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(contentColor),
                      ),
                    )
                        : Icon(
                      Icons.refresh_rounded,
                      size: 16 * scale,
                      color: contentColor,
                    ),
                  ),
                ),
              ),
            ],
          ),

          SizedBox(height: 2 * scale),

          // Balance amount
          Row(
            children: [
              Expanded(
                child: Text(
                  '$currency ${_fmt(balance)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: (26 * scale).clamp(24.0, 32.0),
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            ],
          ),

          // Crypto-style Recent Transaction Indicator
          _buildCryptoIndicator(cs, scale),

          SizedBox(height: 14 * scale),

          // Fund button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onFund,
              icon: Icon(Icons.add_circle_outline, size: 16 * scale),
              label: Text(
                'Fund Account',
                style: TextStyle(
                  fontSize: (13 * scale).clamp(12.0, 15.0),
                  fontWeight: FontWeight.w800,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark ? cs.primary : Colors.white,
                foregroundColor: isDark ? cs.onPrimary : AppColors.accentColor,
                padding: EdgeInsets.symmetric(vertical: 10 * scale),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10 * scale),
                ),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// BECOME DRIVER CARD - PREMIUM
// ═══════════════════════════════════════════════════════════════════════════

class _BecomeDriverCard extends StatefulWidget {
  final double scale;
  final bool isDark;
  final VoidCallback onTap;

  const _BecomeDriverCard({
    required this.scale,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<_BecomeDriverCard> createState() => _BecomeDriverCardState();
}

class _BecomeDriverCardState extends State<_BecomeDriverCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scaleCtrl;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _scaleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.96).animate(
      CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTapDown: (_) => _scaleCtrl.forward(),
      onTapUp: (_) {
        _scaleCtrl.reverse();
        HapticFeedback.mediumImpact();
        widget.onTap();
      },
      onTapCancel: () => _scaleCtrl.reverse(),
      child: ScaleTransition(
        scale: _scaleAnim,
        child: Container(
          margin: EdgeInsets.symmetric(horizontal: 4 * widget.scale),
          padding: EdgeInsets.all(12 * widget.scale),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: widget.isDark
                  ? [
                cs.surfaceVariant,
                cs.surfaceVariant.withOpacity(0.5),
              ]
                  : [
                const Color(0xFF00D084).withOpacity(0.12),
                const Color(0xFF00A366).withOpacity(0.08),
              ],
            ),
            borderRadius: BorderRadius.circular(14 * widget.scale),
            border: Border.all(
              color: widget.isDark
                  ? cs.primary.withOpacity(0.35)
                  : const Color(0xFF00D084).withOpacity(0.25),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: widget.isDark ? cs.primary.withOpacity(0.1) : const Color(0xFF00D084).withOpacity(0.2),
                blurRadius: 10 * widget.scale,
                offset: Offset(0, 3 * widget.scale),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with icon and title
              Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(8 * widget.scale),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: (widget.isDark ? cs.primary : const Color(0xFF00D084)).withOpacity(
                        widget.isDark ? 0.20 : 0.15,
                      ),
                    ),
                    child: Icon(
                      Icons.directions_car_rounded,
                      size: 20 * widget.scale,
                      color: widget.isDark
                          ? cs.primary
                          : const Color(0xFF00A366),
                    ),
                  ),
                  SizedBox(width: 10 * widget.scale),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Become a Driver',
                          style: TextStyle(
                            fontSize: (14 * widget.scale).clamp(12.0, 16.0),
                            fontWeight: FontWeight.w900,
                            color: widget.isDark
                                ? cs.onSurface
                                : const Color(0xFF1E7B5F),
                            letterSpacing: -0.3,
                          ),
                        ),
                        SizedBox(height: 2 * widget.scale),
                        Text(
                          'Earn & grow with us',
                          style: TextStyle(
                            fontSize: (11 * widget.scale).clamp(10.0, 12.0),
                            fontWeight: FontWeight.w600,
                            color: widget.isDark
                                ? cs.onSurfaceVariant
                                : const Color(0xFF1E7B5F).withOpacity(0.75),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 18 * widget.scale,
                    color: widget.isDark
                        ? cs.primary
                        : const Color(0xFF00A366),
                  ),
                ],
              ),

              SizedBox(height: 10 * widget.scale),

              // Benefits preview
              Text(
                'Get instant access to:',
                style: TextStyle(
                  fontSize: (10 * widget.scale).clamp(9.0, 11.0),
                  fontWeight: FontWeight.w700,
                  color: widget.isDark
                      ? cs.onSurfaceVariant
                      : const Color(0xFF1E7B5F).withOpacity(0.85),
                  letterSpacing: 0.2,
                ),
              ),

              SizedBox(height: 6 * widget.scale),

              // Benefits list
              ..._buildBenefits(widget.scale, widget.isDark, cs),

              SizedBox(height: 10 * widget.scale),

              // CTA Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: widget.onTap,
                  icon: Icon(Icons.play_arrow_rounded, size: 16 * widget.scale),
                  label: Text(
                    'Apply Now',
                    style: TextStyle(
                      fontSize: (12 * widget.scale).clamp(11.0, 14.0),
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: widget.isDark ? cs.primary : const Color(0xFF00D084),
                    foregroundColor: widget.isDark ? cs.onPrimary : Colors.white,
                    padding: EdgeInsets.symmetric(vertical: 9 * widget.scale),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9 * widget.scale),
                    ),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build benefit items with optimized layout
  List<Widget> _buildBenefits(double scale, bool isDark, ColorScheme cs) {
    const benefits = [
      ('Flexible hours', Icons.schedule_rounded),
      ('Competitive earnings', Icons.trending_up_rounded),
      ('24/7 support', Icons.support_agent_rounded),
    ];

    return benefits
        .asMap()
        .entries
        .map((e) {
      final isLast = e.key == benefits.length - 1;
      return Padding(
        padding: EdgeInsets.only(bottom: isLast ? 0 : 5 * scale),
        child: Row(
          children: [
            Icon(
              e.value.$2,
              size: 14 * scale,
              color: isDark
                  ? cs.primary
                  : const Color(0xFF00A366),
            ),
            SizedBox(width: 8 * scale),
            Expanded(
              child: Text(
                e.value.$1,
                style: TextStyle(
                  fontSize: (10 * scale).clamp(9.0, 11.0),
                  fontWeight: FontWeight.w600,
                  color: isDark
                      ? cs.onSurface.withOpacity(0.9)
                      : const Color(0xFF1E7B5F).withOpacity(0.8),
                ),
              ),
            ),
          ],
        ),
      );
    })
        .toList();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SECTION LABEL
// ═══════════════════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final String text;
  final double scale;
  final bool isDark;

  const _SectionLabel(this.text, this.scale, this.isDark);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(12 * scale, 8 * scale, 12 * scale, 6 * scale),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: (10 * scale).clamp(9.0, 12.0),
          fontWeight: FontWeight.w800,
          color: isDark
              ? cs.onSurfaceVariant
              : AppColors.textSecondary.withOpacity(0.7),
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MENU ITEM
// ═══════════════════════════════════════════════════════════════════════════

class _MenuItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final double scale;
  final bool isDark;
  final VoidCallback onTap;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.scale,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        margin: EdgeInsets.symmetric(vertical: 2 * widget.scale, horizontal: 4 * widget.scale),
        padding: EdgeInsets.symmetric(horizontal: 12 * widget.scale, vertical: 10 * widget.scale),
        decoration: BoxDecoration(
          color: _pressed
              ? (widget.isDark
              ? cs.primary.withOpacity(0.15)
              : AppColors.primary.withOpacity(0.08))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10 * widget.scale),
        ),
        child: Row(
          children: [
            Icon(
              widget.icon,
              size: 22 * widget.scale,
              color: widget.isDark ? cs.primary : AppColors.primary,
            ),
            SizedBox(width: 14 * widget.scale),
            Expanded(
              child: Text(
                widget.label,
                style: TextStyle(
                  fontSize: (14 * widget.scale).clamp(13.0, 16.0),
                  fontWeight: FontWeight.w700,
                  color: widget.isDark ? cs.onSurface : AppColors.textPrimary,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20 * widget.scale,
              color: widget.isDark
                  ? cs.onSurfaceVariant
                  : AppColors.textSecondary.withOpacity(0.5),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SIGN OUT BUTTON
// ═══════════════════════════════════════════════════════════════════════════

class _SignOutButton extends StatefulWidget {
  final double scale;
  final bool isDark;
  final VoidCallback onTap;

  const _SignOutButton({
    required this.scale,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<_SignOutButton> createState() => _SignOutButtonState();
}

class _SignOutButtonState extends State<_SignOutButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: EdgeInsets.symmetric(horizontal: 12 * widget.scale, vertical: 12 * widget.scale),
        decoration: BoxDecoration(
          color: _pressed
              ? cs.error.withOpacity(0.12)
              : (widget.isDark ? cs.surfaceVariant.withOpacity(0.5) : Colors.transparent),
          borderRadius: BorderRadius.circular(10 * widget.scale),
          border: Border.all(
            color: cs.error.withOpacity(_pressed ? 0.5 : (widget.isDark ? 0.3 : 0.3)),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.logout_rounded,
              size: 20 * widget.scale,
              color: cs.error,
            ),
            SizedBox(width: 10 * widget.scale),
            Text(
              'Sign Out',
              style: TextStyle(
                fontSize: (14 * widget.scale).clamp(13.0, 16.0),
                fontWeight: FontWeight.w800,
                color: cs.error,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}