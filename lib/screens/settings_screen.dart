// lib/screens/settings_screen.dart
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../api/url.dart';
import '../routes/routes.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../utility/notification.dart';
import '../widgets/inner_background.dart';

// IMPORTANT: We assume you will add a global ValueNotifier in main.dart to listen to theme changes.
// e.g., static final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);
import '../../main.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ApiClient _api;
  late SharedPreferences _prefs;
  bool _isLoading = true;

  // Notification Settings
  bool _pushNotifications = true;
  bool _smsNotifications = true;
  bool _emailPromos = false;

  // Privacy Settings
  bool _locationAccess = true;
  bool _shareRideStatus = false;

  // App Preferences
  String _selectedLanguage = 'English';
  String _selectedTheme = 'System'; // System, Light, Dark

  // Dynamic URLs
  String _termsOfServiceUrl = 'https://phantomphones.store/pick_me/terms';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _api = ApiClient(http.Client(), context);
      await _loadSettings();
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showToast('Failed to load settings locally.', isSuccess: false);
      }
    }
  }

  Future<void> _loadSettings() async {
    // 1. Load from local cache instantly for fast UI
    if (mounted) {
      setState(() {
        _pushNotifications = _prefs.getBool('set_push_notif') ?? true;
        _smsNotifications = _prefs.getBool('set_sms_notif') ?? true;
        _emailPromos = _prefs.getBool('set_email_promos') ?? false;

        _locationAccess = _prefs.getBool('set_loc_access') ?? true;
        _shareRideStatus = _prefs.getBool('set_share_ride') ?? false;

        _selectedLanguage = _prefs.getString('set_language') ?? 'English';
        _selectedTheme = _prefs.getString('set_theme') ?? 'System';
      });
    }

    // 2. Fetch latest from server
    try {
      final uid = _prefs.getString('user_id');
      if (uid == null) throw Exception('No user ID');

      final res = await _api.request(
        'user_settings.php',
        method: 'POST',
        data: {'user': uid, 'action': 'get_settings'},
      );

      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data['error'] == false) {
        final Map<String, dynamic> s = data['settings'];

        if (mounted) {
          setState(() {
            _pushNotifications = s['push_notif'] == 1;
            _smsNotifications = s['sms_notif'] == 1;
            _emailPromos = s['email_promos'] == 1;
            _locationAccess = s['loc_access'] == 1;
            _shareRideStatus = s['share_ride'] == 1;
            _selectedLanguage = s['language'] ?? 'English';
            _selectedTheme = s['theme'] ?? 'System';

            if (data['app_settings'] != null) {
              _termsOfServiceUrl = data['app_settings']['terms_of_service_url'] ?? _termsOfServiceUrl;
            }
          });
        }

        // Sync to local
        await _prefs.setBool('set_push_notif', _pushNotifications);
        await _prefs.setBool('set_sms_notif', _smsNotifications);
        await _prefs.setBool('set_email_promos', _emailPromos);
        await _prefs.setBool('set_loc_access', _locationAccess);
        await _prefs.setBool('set_share_ride', _shareRideStatus);
        await _prefs.setString('set_language', _selectedLanguage);
        await _prefs.setString('set_theme', _selectedTheme);
      }
    } catch (_) {
      // Silently fail if offline, local settings will suffice
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _updateSettingOnServer(String key, dynamic value) async {
    try {
      final uid = _prefs.getString('user_id');
      if (uid == null) return;

      await _api.request(
        'user_settings.php',
        method: 'POST',
        data: {
          'user': uid,
          'action': 'update_setting',
          'setting_key': key,
          'setting_value': value.toString(),
        },
      );
    } catch (_) {
      // Background sync
    }
  }

  Future<void> _toggleBoolSetting(String localKey, String serverKey, bool value, Function(bool) updateState) async {
    HapticFeedback.lightImpact();
    setState(() => updateState(value));
    await _prefs.setBool(localKey, value);
    _updateSettingOnServer(serverKey, value ? 1 : 0);
  }

  Future<void> _launchUrl(String urlString) async {
    final Uri url = Uri.parse(urlString);
    try {
      // This forces the phone to open the link in Chrome/Safari securely
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      _showToast('Could not open link.', isSuccess: false);
    }
  }

  void _showToast(String message, {bool isSuccess = true}) {
    if (!mounted) return;
    showToastNotification(context: context, title: isSuccess ? 'Success' : 'Error', message: message, isSuccess: isSuccess);
  }

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
          'Settings',
          style: TextStyle(fontSize: ui.font(18), fontWeight: FontWeight.w900, color: isDark ? Colors.white : AppColors.textPrimary),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: ui.icon(20), color: isDark ? Colors.white : AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          BackgroundWidget(style: HoloStyle.vapor, intensity: isDark ? 0.15 : 0.5, animate: false),
          SafeArea(
            child: _isLoading
                ? Center(child: CircularProgressIndicator(color: isDark ? cs.primary : AppColors.primary))
                : _buildContent(ui, cs, isDark),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCardContainer(
            ui: ui,
            cs: cs,
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(ui, cs, isDark, 'App Preferences', Icons.tune_rounded),
                _buildNavigationTile(
                  ui: ui,
                  cs: cs,
                  isDark: isDark,
                  title: 'Language',
                  subtitle: _selectedLanguage,
                  icon: Icons.language_rounded,
                  iconColor: isDark ? cs.primary : AppColors.primary,
                  onTap: _showLanguageBottomSheet,
                ),
                Divider(color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2), height: 1),
                _buildNavigationTile(
                  ui: ui,
                  cs: cs,
                  isDark: isDark,
                  title: 'Theme',
                  subtitle: _selectedTheme,
                  icon: Icons.palette_outlined,
                  iconColor: const Color(0xFFB8860B),
                  onTap: _showThemeBottomSheet,
                ),
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
                _buildSectionHeader(ui, cs, isDark, 'Notifications', Icons.notifications_active_outlined),
                _buildSwitchTile(
                  ui: ui,
                  cs: cs,
                  isDark: isDark,
                  title: 'Push Notifications',
                  subtitle: 'Ride updates and driver arrivals',
                  icon: Icons.app_shortcut_rounded,
                  iconColor: isDark ? cs.primary : AppColors.primary,
                  value: _pushNotifications,
                  onChanged: (v) => _toggleBoolSetting('set_push_notif', 'push_notif', v, (val) => _pushNotifications = val),
                ),
                Divider(color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2), height: 1),
                _buildSwitchTile(
                  ui: ui,
                  cs: cs,
                  isDark: isDark,
                  title: 'SMS Alerts',
                  subtitle: 'Important trip alerts via text',
                  icon: Icons.sms_rounded,
                  iconColor: isDark ? cs.secondary : AppColors.secondary,
                  value: _smsNotifications,
                  onChanged: (v) => _toggleBoolSetting('set_sms_notif', 'sms_notif', v, (val) => _smsNotifications = val),
                ),
                Divider(color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2), height: 1),
                _buildSwitchTile(
                  ui: ui,
                  cs: cs,
                  isDark: isDark,
                  title: 'Email Promotions',
                  subtitle: 'Discounts, receipts, and news',
                  icon: Icons.email_outlined,
                  iconColor: const Color(0xFF1E8E3E),
                  value: _emailPromos,
                  onChanged: (v) => _toggleBoolSetting('set_email_promos', 'email_promos', v, (val) => _emailPromos = val),
                ),
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
                _buildSectionHeader(ui, cs, isDark, 'Privacy & Location', Icons.security_rounded),
                _buildSwitchTile(
                  ui: ui,
                  cs: cs,
                  isDark: isDark,
                  title: 'Location Services',
                  subtitle: 'Allow precise pickup tracking',
                  icon: Icons.my_location_rounded,
                  iconColor: isDark ? cs.primary : AppColors.primary,
                  value: _locationAccess,
                  onChanged: (v) {
                    if (v == false) {
                      showToastNotification(context: context, title: 'Notice', message: 'Disabling location may affect pickup accuracy.', isSuccess: true);
                    }
                    _toggleBoolSetting('set_loc_access', 'loc_access', v, (val) => _locationAccess = val);
                  },
                ),
                Divider(color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2), height: 1),
                _buildSwitchTile(
                  ui: ui,
                  cs: cs,
                  isDark: isDark,
                  title: 'Share Ride Status',
                  subtitle: 'Automatically send trips to emergency contacts',
                  icon: Icons.share_location_rounded,
                  iconColor: const Color(0xFF6A5ACD),
                  value: _shareRideStatus,
                  onChanged: (v) => _toggleBoolSetting('set_share_ride', 'share_ride', v, (val) => _shareRideStatus = val),
                ),
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
                _buildSectionHeader(ui, cs, isDark, 'Support & Legal', Icons.support_agent_rounded),
                _buildNavigationTile(
                  ui: ui,
                  cs: cs,
                  isDark: isDark,
                  title: 'Help Center',
                  icon: Icons.help_outline_rounded,
                  iconColor: isDark ? cs.primary : AppColors.primary,
                  onTap: () => Navigator.pushNamed(context, AppRoutes.help),
                ),
                Divider(color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.2), height: 1),
                _buildNavigationTile(
                  ui: ui,
                  cs: cs,
                  isDark: isDark,
                  title: 'Terms of Service',
                  icon: Icons.gavel_rounded,
                  iconColor: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                  onTap: () => _launchUrl(_termsOfServiceUrl),
                ),
              ],
            ),
          ),

          SizedBox(height: ui.gap(32)),
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
            color: isDark ? cs.surface.withOpacity(0.85) : Colors.white.withOpacity(0.85), // Uses true surface color
            borderRadius: BorderRadius.circular(ui.radius(20)),
            border: Border.all(color: isDark ? cs.outline.withOpacity(0.4) : AppColors.mintBgLight.withOpacity(0.3)),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(isDark ? 0.3 : 0.04), blurRadius: 20, offset: const Offset(0, 8)),
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

  Widget _buildSwitchTile({
    required UIScale ui,
    required ColorScheme cs,
    required bool isDark,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.inset(8)),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(ui.inset(10)),
            decoration: BoxDecoration(color: iconColor.withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: ui.icon(20)),
          ),
          SizedBox(width: ui.gap(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(14), color: isDark ? Colors.white : AppColors.textPrimary)),
                SizedBox(height: ui.gap(2)),
                // FIXED THE FENTY TEXT - Now uses cs.onSurfaceVariant for high visibility in dark mode
                Text(subtitle, style: TextStyle(fontWeight: FontWeight.w600, fontSize: ui.font(11.5), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeColor: isDark ? cs.primary : AppColors.primary,
            activeTrackColor: (isDark ? cs.primary : AppColors.primary).withOpacity(0.3),
            inactiveThumbColor: isDark ? Colors.grey.shade400 : Colors.white,
            inactiveTrackColor: isDark ? Colors.white.withOpacity(0.1) : Colors.black.withOpacity(0.1),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationTile({
    required UIScale ui,
    required ColorScheme cs,
    required bool isDark,
    required String title,
    String? subtitle,
    required IconData icon,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.inset(12)),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.all(ui.inset(10)),
                decoration: BoxDecoration(color: iconColor.withOpacity(0.1), shape: BoxShape.circle),
                child: Icon(icon, color: iconColor, size: ui.icon(20)),
              ),
              SizedBox(width: ui.gap(12)),
              Expanded(
                child: Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(14), color: isDark ? Colors.white : AppColors.textPrimary)),
              ),
              if (subtitle != null) ...[
                // FIXED THE FENTY TEXT
                Text(subtitle, style: TextStyle(fontWeight: FontWeight.w700, fontSize: ui.font(13), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
                SizedBox(width: ui.gap(8)),
              ],
              Icon(Icons.chevron_right_rounded, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(0.5)),
            ],
          ),
        ),
      ),
    );
  }

  // ── BOTTOM SHEETS ──────────────────────────────────────────────────

  void _showLanguageBottomSheet() {
    final languages = ['English', 'French', 'Spanish', 'Igbo', 'Hausa', 'Yoruba'];
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (c) => Container(
        decoration: BoxDecoration(color: isDark ? cs.surface : Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 24),
            Text('Select Language', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: isDark ? Colors.white : AppColors.textPrimary)),
            const SizedBox(height: 16),
            ...languages.map((lang) => ListTile(
              title: Text(lang, style: TextStyle(fontWeight: FontWeight.w700, color: isDark ? Colors.white : AppColors.textPrimary)),
              trailing: _selectedLanguage == lang ? Icon(Icons.check_circle_rounded, color: isDark ? cs.primary : AppColors.primary) : null,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onTap: () async {
                HapticFeedback.selectionClick();
                setState(() => _selectedLanguage = lang);
                await _prefs.setString('set_language', lang);
                _updateSettingOnServer('language', lang);
                if (mounted) Navigator.pop(c);
              },
            )).toList(),
          ],
        ),
      ),
    );
  }

  void _showThemeBottomSheet() {
    final themes = ['System', 'Light', 'Dark'];
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (c) => Container(
        decoration: BoxDecoration(color: isDark ? cs.surface : Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 24),
            Text('Select Theme', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: isDark ? Colors.white : AppColors.textPrimary)),
            const SizedBox(height: 16),
            ...themes.map((theme) => ListTile(
              title: Text(theme, style: TextStyle(fontWeight: FontWeight.w700, color: isDark ? Colors.white : AppColors.textPrimary)),
              trailing: _selectedTheme == theme ? Icon(Icons.check_circle_rounded, color: isDark ? cs.primary : AppColors.primary) : null,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onTap: () async {
                HapticFeedback.selectionClick();
                setState(() => _selectedTheme = theme);
                await _prefs.setString('set_theme', theme);
                _updateSettingOnServer('theme', theme);

                // Trigger the global theme change
                ThemeMode newMode = theme == 'Dark' ? ThemeMode.dark : (theme == 'Light' ? ThemeMode.light : ThemeMode.system);

                try {
                  MyApp.themeNotifier.value = newMode;
                } catch (e) {
                  debugPrint('Ensure MyApp.themeNotifier exists in main.dart: $e');
                }

                if (mounted) Navigator.pop(c);
              },
            )).toList(),
          ],
        ),
      ),
    );
  }
}