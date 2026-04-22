// lib/screens/profile.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui'; // <--- Removed "as ui"

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../api/api_client.dart';
import '../api/url.dart';
import '../routes/routes.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../utility/notification.dart';
import '../widgets/inner_background.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({Key? key}) : super(key: key);

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> with SingleTickerProviderStateMixin {
  late ApiClient _api;
  late SharedPreferences _prefs;

  final _picker = ImagePicker();

  bool _isLoading = true;
  bool _isUploadingImage = false;
  bool _hasError = false;

  Map<String, dynamic> _user = {};
  String _appVersion = '1.0.0';
  String _privacyPolicyUrl = 'https://phantomphones.store/pick_me/privacy';

  // Make this nullable to prevent LateInitializationError crashes
  AnimationController? _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _api = ApiClient(http.Client(), context);

      // Fetch App Version safely
      try {
        final packageInfo = await PackageInfo.fromPlatform();
        _appVersion = '${packageInfo.version} (${packageInfo.buildNumber})';
      } catch (_) {
        _appVersion = '1.0.0';
      }

      await _fetchUser();
    } catch (e) {
      _fail('Failed to initialize: $e');
    }
  }

  @override
  void dispose() {
    _shimmerController?.dispose(); // Safe dispose
    super.dispose();
  }

  Future<void> _fetchUser() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      final uid = _prefs.getString('user_id');
      if (uid == null) throw Exception('User session missing');

      final res = await _api.request(
        ApiConstants.userInfoEndpoint,
        method: 'POST',
        data: {'user': uid},
      );

      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data['error'] == false) {
        setState(() {
          _user = (data['user'] as Map).map(
                (k, v) => MapEntry<String, dynamic>(k.toString(), v),
          );
          if (data['app_settings'] != null) {
            _privacyPolicyUrl = data['app_settings']['privacy_policy_url'] ?? _privacyPolicyUrl;
          }
        });
      } else {
        throw Exception(data['error_msg'] ?? 'Unable to load profile');
      }
    } catch (e) {
      _fail('Failed to load profile. Check connection.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _update(Map<String, String> body, String action) async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final uid = _prefs.getString('user_id');
      if (uid == null) throw Exception('User ID missing');

      final res = await _api.request(
        ApiConstants.updateUserInfoEndpoint,
        method: 'POST',
        data: {'user': uid, 'action': action, ...body},
      );

      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data['error'] == false) {
        _ok(data['message'] ?? 'Profile updated successfully');
        _fetchUser();
      } else {
        throw Exception(data['message'] ?? data['error_msg'] ?? 'Update failed');
      }
    } catch (e) {
      _fail(e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteAccount() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final uid = _prefs.getString('user_id');
      if (uid == null) throw Exception('User ID missing');

      final res = await _api.request(
        ApiConstants.updateUserInfoEndpoint,
        method: 'POST',
        data: {'user': uid, 'action': 'delete_account'},
      );

      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data['error'] == false) {
        await _prefs.clear();
        if (!mounted) return;
        _ok('Account deleted successfully');
        Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
      } else {
        throw Exception(data['message'] ?? 'Failed to delete account');
      }
    } catch (e) {
      _fail(e.toString().replaceAll('Exception: ', ''));
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickAndUploadImage() async {
    if (_isUploadingImage) return;
    try {
      final x = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 80,
      );
      if (x == null) return;

      setState(() => _isUploadingImage = true);

      final imageFile = File(x.path);
      if (await imageFile.length() > 5 * 1024 * 1024) {
        throw Exception('Image size must be less than 5MB');
      }

      final uid = _prefs.getString('user_id');
      if (uid == null) throw Exception('User session missing');

      final res = await _api.request(
        ApiConstants.updateProfilePictureEndpoint,
        method: 'POST',
        data: {'user': uid, 'action': 'update_profile_picture'},
        files: {'profile_picture': imageFile},
      );

      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data['error'] == false) {
        setState(() => _user['user_logo'] = data['user_logo']);
        _ok('Profile picture updated!');
        _fetchUser();
      } else {
        throw Exception(data['message'] ?? data['error_msg'] ?? 'Upload failed');
      }
    } catch (e) {
      _fail(e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  Future<void> _launchUrl(String urlString) async {
    final Uri url = Uri.parse(urlString);
    if (!await launchUrl(url)) {
      _fail('Could not launch $urlString');
    }
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() => _hasError = true);
    showToastNotification(context: context, title: 'Error', message: msg, isSuccess: false);
  }

  void _ok(String msg) {
    if (!mounted) return;
    showToastNotification(context: context, title: 'Success', message: msg, isSuccess: true);
  }

  // ────────────────────────────────────────────────────────────────────────
  // WIDGET BUILDERS
  // ────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ui = UIScale.of(context);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'Profile',
          style: TextStyle(
            fontSize: ui.font(18),
            fontWeight: FontWeight.w900,
            color: isDark ? cs.onSurface : AppColors.textPrimary,
          ),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: ui.icon(20), color: isDark ? cs.onSurface : AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          BackgroundWidget(style: HoloStyle.vapor, intensity: isDark ? 0.15 : 0.5, animate: false),
          SafeArea(
            child: _isLoading && _user.isEmpty
                ? _buildPremiumSkeleton(ui, isDark)
                : _hasError && _user.isEmpty
                ? _buildErrorState(ui, isDark)
                : _buildContent(ui, cs, isDark),
          ),
          if (_isUploadingImage || (_isLoading && _user.isNotEmpty))
            Container(
              color: Colors.black.withOpacity(0.4),
              child: Center(
                child: Container(
                  padding: EdgeInsets.all(ui.inset(20)),
                  decoration: BoxDecoration(
                    color: isDark ? cs.surface : Colors.white,
                    borderRadius: BorderRadius.circular(ui.radius(16)),
                  ),
                  child: CircularProgressIndicator(color: isDark ? cs.primary : AppColors.primary),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContent(UIScale ui, ColorScheme cs, bool isDark) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(ui.inset(16), ui.gap(10), ui.inset(16), ui.gap(40)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildHeader(ui, cs, isDark),
          SizedBox(height: ui.gap(24)),

          _buildCardContainer(
            ui: ui,
            cs: cs,
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(ui, cs, isDark, 'Safety & Security', Icons.shield_rounded),
                _buildSafety(ui, cs, isDark),
              ],
            ),
          ),

          SizedBox(height: ui.gap(16)),

          _buildCardContainer(
            ui: ui,
            cs: cs,
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(ui, cs, isDark, 'Account Management', Icons.manage_accounts_rounded),
                _buildAccount(ui, cs, isDark),
              ],
            ),
          ),

          SizedBox(height: ui.gap(16)),

          _buildCardContainer(
            ui: ui,
            cs: cs,
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(ui, cs, isDark, 'About & Legal', Icons.info_outline_rounded),
                _buildAbout(ui, cs, isDark),
              ],
            ),
          ),

          SizedBox(height: ui.gap(32)),
          _buildDangerZone(ui, cs, isDark),
        ],
      ),
    );
  }

  Widget _buildCardContainer({required UIScale ui, required ColorScheme cs, required bool isDark, required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(ui.radius(20)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? cs.surface.withOpacity(0.85) : Colors.white.withOpacity(0.85),
            borderRadius: BorderRadius.circular(ui.radius(20)),
            border: Border.all(color: isDark ? cs.outline.withOpacity(0.4) : AppColors.mintBgLight.withOpacity(0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.3 : 0.04),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildSectionHeader(UIScale ui, ColorScheme cs, bool isDark, String title, IconData icon) {
    return Padding(
      padding: EdgeInsets.fromLTRB(ui.inset(16), ui.inset(16), ui.inset(16), ui.inset(8)),
      child: Row(
        children: [
          Icon(icon, size: ui.icon(18), color: isDark ? cs.primary : AppColors.primary),
          SizedBox(width: ui.gap(8)),
          Text(title, style: TextStyle(fontSize: ui.font(14), fontWeight: FontWeight.w800, color: isDark ? cs.primary : AppColors.primary)),
        ],
      ),
    );
  }

  Widget _buildHeader(UIScale ui, ColorScheme cs, bool isDark) {
    final avatarUrl = _user['user_logo']?.toString() ?? '';
    final fName = _user['user_fname']?.toString() ?? '';
    final lName = _user['user_lname']?.toString() ?? '';
    final name = '$fName $lName'.trim();
    final initials = name.isNotEmpty ? '${fName.isNotEmpty ? fName[0] : ''}${lName.isNotEmpty ? lName[0] : ''}' : 'U';
    final email = _user['user_email']?.toString() ?? '';
    final phone = _user['user_phone']?.toString() ?? '';
    final dateReg = _user['user_date_registered']?.toString() ?? '';

    // Dynamic Stats parsing
    final totalTrips = int.tryParse(_user['total_trips']?.toString() ?? '0') ?? 0;
    final ratingVal = double.tryParse(_user['user_rating']?.toString() ?? '5.0') ?? 5.0;
    final rating = ratingVal > 0 ? ratingVal.toStringAsFixed(1) : '5.0';

    String memberSince = 'Recently';
    if (dateReg.isNotEmpty) {
      try {
        final d = DateTime.parse(dateReg);
        memberSince = DateFormat('MMM yyyy').format(d);
      } catch (_) {}
    }

    return Column(
      children: [
        Stack(
          alignment: Alignment.bottomRight,
          children: [
            GestureDetector(
              onTap: avatarUrl.isNotEmpty ? _showProfilePicture : _pickAndUploadImage,
              child: Container(
                width: ui.inset(100),
                height: ui.inset(100),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark ? cs.surfaceVariant : AppColors.mintBgLight.withOpacity(0.2),
                  border: Border.all(color: isDark ? cs.primary : AppColors.primary, width: 3),
                  boxShadow: [
                    BoxShadow(color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.3), blurRadius: 20, offset: const Offset(0, 8)),
                  ],
                  image: avatarUrl.isNotEmpty ? DecorationImage(image: NetworkImage(avatarUrl), fit: BoxFit.cover) : null,
                ),
                child: avatarUrl.isEmpty
                    ? Center(child: Text(initials.toUpperCase(), style: TextStyle(fontSize: ui.font(32), fontWeight: FontWeight.w900, color: isDark ? cs.primary : AppColors.primary)))
                    : null,
              ),
            ),
            InkWell(
              onTap: _pickAndUploadImage,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: EdgeInsets.all(ui.inset(8)),
                decoration: BoxDecoration(
                  color: isDark ? cs.surfaceVariant : AppColors.secondary,
                  shape: BoxShape.circle,
                  border: Border.all(color: isDark ? cs.surface : Colors.white, width: 3),
                ),
                child: Icon(Icons.camera_alt_rounded, size: ui.icon(16), color: isDark ? cs.onSurface : Colors.white),
              ),
            ),
          ],
        ),
        SizedBox(height: ui.gap(16)),
        Text(
          name.isNotEmpty ? name : 'Pick Me User',
          style: TextStyle(fontSize: ui.font(22), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary),
        ),
        if (email.isNotEmpty || phone.isNotEmpty) ...[
          SizedBox(height: ui.gap(4)),
          Text(
            [if (phone.isNotEmpty) phone, if (email.isNotEmpty) email].join(' • '),
            style: TextStyle(fontSize: ui.font(13), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
          ),
        ],
        SizedBox(height: ui.gap(20)),

        // Premium Dashboard Stats Row
        Container(
          padding: EdgeInsets.symmetric(vertical: ui.gap(16), horizontal: ui.inset(16)),
          decoration: BoxDecoration(
            color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.05),
            borderRadius: BorderRadius.circular(ui.radius(20)),
            border: Border.all(color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.15)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildDashboardStat(ui, cs, isDark, Icons.local_taxi_rounded, totalTrips.toString(), 'Trips', color: isDark ? cs.primary : AppColors.primary),
              Container(width: 1, height: 40, color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.2)),
              _buildDashboardStat(ui, cs, isDark, Icons.star_rounded, rating, 'Rating', color: const Color(0xFFFFD54F)),
              Container(width: 1, height: 40, color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.2)),
              _buildDashboardStat(ui, cs, isDark, Icons.calendar_month_rounded, memberSince, 'Joined', color: isDark ? cs.secondary : AppColors.secondary),
            ],
          ),
        )
      ],
    );
  }

  Widget _buildDashboardStat(UIScale ui, ColorScheme cs, bool isDark, IconData icon, String val, String label, {required Color color}) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: ui.icon(18), color: color),
            SizedBox(width: ui.gap(6)),
            Text(val, style: TextStyle(fontSize: ui.font(16), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary)),
          ],
        ),
        SizedBox(height: ui.gap(2)),
        Text(label, style: TextStyle(fontSize: ui.font(11), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _buildSafety(UIScale ui, ColorScheme cs, bool isDark) {
    final contact = (_user['emergency_contact']?.toString() ?? '').trim();
    final hasContact = contact.isNotEmpty;

    return Column(
      children: [
        Divider(color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2), height: 1),
        ListTile(
          contentPadding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.inset(4)),
          leading: Container(
            padding: EdgeInsets.all(ui.inset(10)),
            decoration: BoxDecoration(color: cs.error.withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(Icons.contact_phone_rounded, color: cs.error, size: ui.icon(20)),
          ),
          title: Text('Emergency Contact', style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(14), color: isDark ? cs.onSurface : AppColors.textPrimary)),
          subtitle: Text(hasContact ? contact : 'Not set for emergencies', style: TextStyle(fontSize: ui.font(12), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w600)),
          trailing: TextButton(
            onPressed: () => _showEditBottomSheet(
              title: 'Emergency Contact',
              dbKey: 'emergency_contact',
              dbAction: 'update_emergency_contact',
              initialValue: contact,
              hint: 'e.g. John Doe - 08012345678',
              icon: Icons.contact_phone_rounded,
            ),
            style: TextButton.styleFrom(foregroundColor: cs.error, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: Text(hasContact ? 'Edit' : 'Add', style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }

  Widget _buildAccount(UIScale ui, ColorScheme cs, bool isDark) {
    return Column(
      children: [
        Divider(color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2), height: 1),
        _buildListTile(ui, cs, isDark, 'Change Password', Icons.lock_outline_rounded, isDark ? cs.secondary : AppColors.secondary, onTap: _showPasswordBottomSheet),
        Divider(color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2), height: 1),
        _buildListTile(ui, cs, isDark, 'Update Transaction Code', Icons.pin_rounded, const Color(0xFFB8860B), onTap: _showTransactionCodeBottomSheet),
        Divider(color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2), height: 1),
        _buildListTile(ui, cs, isDark, 'Sign Out', Icons.logout_rounded, isDark ? cs.onSurfaceVariant : AppColors.textSecondary, onTap: _showLogoutBottomSheet),
      ],
    );
  }

  Widget _buildAbout(UIScale ui, ColorScheme cs, bool isDark) {
    return Column(
      children: [
        Divider(color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2), height: 1),
        ListTile(
          contentPadding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.inset(4)),
          leading: Container(
            padding: EdgeInsets.all(ui.inset(10)),
            decoration: BoxDecoration(color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(Icons.info_outline_rounded, color: isDark ? cs.primary : AppColors.primary, size: ui.icon(20)),
          ),
          title: Text('App Version', style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(14), color: isDark ? cs.onSurface : AppColors.textPrimary)),
          trailing: Text(_appVersion, style: TextStyle(fontWeight: FontWeight.w900, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
        ),
        Divider(color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2), height: 1),
        _buildListTile(ui, cs, isDark, 'Privacy Policy', Icons.privacy_tip_outlined, const Color(0xFF1E8E3E), onTap: () => _launchUrl(_privacyPolicyUrl)),
      ],
    );
  }

  Widget _buildListTile(UIScale ui, ColorScheme cs, bool isDark, String title, IconData icon, Color iconColor, {VoidCallback? onTap}) {
    return ListTile(
      contentPadding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.inset(4)),
      leading: Container(
        padding: EdgeInsets.all(ui.inset(10)),
        decoration: BoxDecoration(color: iconColor.withOpacity(0.1), shape: BoxShape.circle),
        child: Icon(icon, color: iconColor, size: ui.icon(20)),
      ),
      title: Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(14), color: isDark ? cs.onSurface : AppColors.textPrimary)),
      trailing: Icon(Icons.chevron_right_rounded, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(0.5)),
      onTap: () {
        HapticFeedback.lightImpact();
        if (onTap != null) onTap();
      },
    );
  }

  Widget _buildDangerZone(UIScale ui, ColorScheme cs, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: ui.inset(16), bottom: ui.gap(8)),
          child: Text('DANGER ZONE', style: TextStyle(color: cs.error, fontWeight: FontWeight.w900, fontSize: ui.font(12), letterSpacing: 1.2)),
        ),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: cs.error.withOpacity(0.05),
            borderRadius: BorderRadius.circular(ui.radius(20)),
            border: Border.all(color: cs.error.withOpacity(0.3)),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                HapticFeedback.heavyImpact();
                _showDeleteAccountBottomSheet();
              },
              borderRadius: BorderRadius.circular(ui.radius(20)),
              child: Padding(
                padding: EdgeInsets.all(ui.inset(16)),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(ui.inset(10)),
                      decoration: BoxDecoration(color: cs.error.withOpacity(0.15), shape: BoxShape.circle),
                      child: Icon(Icons.delete_forever_rounded, color: cs.error, size: ui.icon(20)),
                    ),
                    SizedBox(width: ui.gap(16)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Delete Account', style: TextStyle(fontSize: ui.font(15), fontWeight: FontWeight.w900, color: cs.error)),
                          SizedBox(height: ui.gap(4)),
                          Text('Permanently remove all data.', style: TextStyle(fontSize: ui.font(12), color: cs.error.withOpacity(0.8), fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: cs.error.withOpacity(0.5)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── PREMIUM SKELETON LOADER ─────────────────────────────────────────
  Widget _buildPremiumSkeleton(UIScale ui, bool isDark) {
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
              transform: SlideGradientTransform(_shimmerController!.value),
            ).createShader(bounds);
          },
          child: SingleChildScrollView(
            padding: EdgeInsets.all(ui.inset(16)),
            child: Column(
              children: [
                SizedBox(height: ui.gap(20)),
                Container(width: ui.inset(100), height: ui.inset(100), decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
                SizedBox(height: ui.gap(16)),
                Container(width: 180, height: 24, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8))),
                SizedBox(height: ui.gap(8)),
                Container(width: 120, height: 16, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8))),
                SizedBox(height: ui.gap(24)),
                Container(width: double.infinity, height: 80, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20))),
                SizedBox(height: ui.gap(24)),
                Container(width: double.infinity, height: 120, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20))),
                SizedBox(height: ui.gap(16)),
                Container(width: double.infinity, height: 180, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20))),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildErrorState(UIScale ui, bool isDark) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off_rounded, size: ui.icon(60), color: cs.error.withOpacity(0.5)),
          SizedBox(height: ui.gap(16)),
          Text('Connection Error', style: TextStyle(fontSize: ui.font(20), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary)),
          SizedBox(height: ui.gap(8)),
          Text('Unable to load your profile data.', style: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w600)),
          SizedBox(height: ui.gap(24)),
          ElevatedButton.icon(
            onPressed: _fetchUser,
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

  // ── DIALOGS & BOTTOM SHEETS ──────────────────────────────────────────

  void _showProfilePicture() {
    showDialog(
      context: context,
      builder: (c) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: GestureDetector(
          onTap: () => Navigator.pop(c),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Image.network(_user['user_logo'], fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  Widget _bottomSheetHeader(String title, String subtitle, IconData icon, Color color, bool isDark, ColorScheme cs) {
    return Column(
      children: [
        Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
          child: Icon(icon, size: 36, color: color),
        ),
        const SizedBox(height: 16),
        Text(title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary)),
        const SizedBox(height: 8),
        Text(subtitle, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),
      ],
    );
  }

  void _showEditBottomSheet({required String title, required String dbKey, required String dbAction, required String initialValue, required String hint, required IconData icon}) {
    final ctrl = TextEditingController(text: initialValue);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) => Container(
        decoration: BoxDecoration(color: isDark ? cs.surface : Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
        padding: EdgeInsets.fromLTRB(24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _bottomSheetHeader(title, 'Update your information below.', icon, isDark ? cs.primary : AppColors.primary, isDark, cs),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: TextStyle(color: isDark ? cs.onSurface : AppColors.textPrimary, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(0.5)),
                filled: true,
                fillColor: isDark ? cs.surfaceVariant : AppColors.mintBgLight.withOpacity(0.3),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(c);
                  if (ctrl.text.trim() != initialValue) {
                    _update({dbKey: ctrl.text.trim()}, dbAction);
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: isDark ? cs.primary : AppColors.primary, foregroundColor: isDark ? cs.onPrimary : Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), elevation: 0),
                child: const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPasswordBottomSheet() {
    final oldC = TextEditingController();
    final newC = TextEditingController();
    final confC = TextEditingController();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) => Container(
        decoration: BoxDecoration(color: isDark ? cs.surface : Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
        padding: EdgeInsets.fromLTRB(24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _bottomSheetHeader('Change Password', 'Secure your account with a new password.', Icons.lock_outline_rounded, isDark ? cs.secondary : AppColors.secondary, isDark, cs),
            _buildDialogTextField(oldC, 'Old Password', isDark, cs),
            const SizedBox(height: 12),
            _buildDialogTextField(newC, 'New Password', isDark, cs),
            const SizedBox(height: 12),
            _buildDialogTextField(confC, 'Confirm New Password', isDark, cs),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: () {
                  if (newC.text.isEmpty || oldC.text.isEmpty) return _fail('Fields cannot be empty');
                  if (newC.text != confC.text) return _fail('New passwords do not match');
                  Navigator.pop(c);
                  _update({'old_password': oldC.text, 'new_password': newC.text}, 'update_password');
                },
                style: ElevatedButton.styleFrom(backgroundColor: isDark ? cs.primary : AppColors.primary, foregroundColor: isDark ? cs.onPrimary : Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), elevation: 0),
                child: const Text('Update Password', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTransactionCodeBottomSheet() {
    final oldC = TextEditingController();
    final newC = TextEditingController();
    final confC = TextEditingController();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) => Container(
        decoration: BoxDecoration(color: isDark ? cs.surface : Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
        padding: EdgeInsets.fromLTRB(24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _bottomSheetHeader('Transaction Code', 'Update your 4-digit security code.', Icons.pin_rounded, const Color(0xFFB8860B), isDark, cs),
            _buildDialogTextField(oldC, 'Old 4-Digit Code', isDark, cs, isNumber: true),
            const SizedBox(height: 12),
            _buildDialogTextField(newC, 'New 4-Digit Code', isDark, cs, isNumber: true),
            const SizedBox(height: 12),
            _buildDialogTextField(confC, 'Confirm New Code', isDark, cs, isNumber: true),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: () {
                  if (newC.text.isEmpty || oldC.text.isEmpty) return _fail('Fields cannot be empty');
                  if (newC.text.length != 4) return _fail('Code must be exactly 4 digits');
                  if (newC.text != confC.text) return _fail('New codes do not match');
                  Navigator.pop(c);
                  _update({'old_transaction_code': oldC.text, 'new_transaction_code': newC.text}, 'update_transaction_code');
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB8860B), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), elevation: 0),
                child: const Text('Update Code', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLogoutBottomSheet() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (c) => Container(
        decoration: BoxDecoration(color: isDark ? cs.surface : Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _bottomSheetHeader('Sign Out', 'You will need your password to log back in.', Icons.logout_rounded, isDark ? cs.onSurfaceVariant : AppColors.textSecondary, isDark, cs),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(c),
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    child: Text('Cancel', style: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w800, fontSize: 16)),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(c);
                      await _prefs.clear();
                      if (mounted) Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError, elevation: 0, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    child: const Text('Sign Out', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteAccountBottomSheet() {
    final confC = TextEditingController();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) => Container(
        decoration: BoxDecoration(color: isDark ? cs.surface : Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
        padding: EdgeInsets.fromLTRB(24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _bottomSheetHeader('Delete Account', 'This action is permanent and cannot be undone. All your ride history, wallet balance, and profile data will be permanently wiped.', Icons.warning_amber_rounded, cs.error, isDark, cs),
            TextField(
              controller: confC,
              style: TextStyle(fontWeight: FontWeight.w900, color: cs.error, letterSpacing: 2),
              decoration: InputDecoration(
                hintText: 'Type DELETE to confirm',
                hintStyle: TextStyle(color: cs.error.withOpacity(0.5), letterSpacing: 0, fontWeight: FontWeight.w600),
                filled: true,
                fillColor: cs.error.withOpacity(0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: cs.error.withOpacity(0.3))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: cs.error, width: 2)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(c),
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    child: Text('Cancel', style: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w800, fontSize: 16)),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      if (confC.text.trim() == 'DELETE') {
                        Navigator.pop(c);
                        _deleteAccount();
                      } else {
                        _fail('You must type DELETE to confirm.');
                      }
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError, elevation: 0, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    child: const Text('Delete Forever', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDialogTextField(TextEditingController ctrl, String hint, bool isDark, ColorScheme cs, {bool isNumber = false}) {
    return TextField(
      controller: ctrl,
      obscureText: true,
      style: TextStyle(color: isDark ? cs.onSurface : AppColors.textPrimary, fontWeight: FontWeight.w700, letterSpacing: 2),
      keyboardType: isNumber ? TextInputType.number : TextInputType.text,
      inputFormatters: isNumber ? [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)] : null,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(0.5), letterSpacing: 0, fontWeight: FontWeight.w500),
        filled: true,
        fillColor: isDark ? cs.surfaceVariant : AppColors.mintBgLight.withOpacity(0.3),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      ),
    );
  }
}

class SlideGradientTransform extends GradientTransform {
  final double percent;
  const SlideGradientTransform(this.percent);
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (percent * 2 - 1), 0, 0);
  }
}