// lib/screens/profile.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../utility/notification.dart';
import '../../themes/app_theme.dart';
import '../../widgets/inner_background.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({Key? key}) : super(key: key);

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late ApiClient _api;
  late SharedPreferences _prefs;

  final _picker = ImagePicker();

  bool _isLoading = true;
  bool _isUploadingImage = false;
  bool _hasError = false;

  Map<String, dynamic> _user = {};
  File? _imageFile;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _api = ApiClient(http.Client(), context);
      await _fetchUser();
    } catch (e) {
      _fail('Failed to initialize: $e');
    }
  }

  Future<void> _fetchUser() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      final uid = _prefs.getString('user_id');
      if (uid == null) throw Exception('User ID missing');

      final res = await _api.request(
        ApiConstants.userInfoEndpoint,
        method: 'POST',
        data: {'user': uid},
      );

      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data is Map && data['error'] == false) {
        setState(() {
          _user = (data['user'] as Map).map(
                (k, v) => MapEntry<String, dynamic>(k.toString(), v),
          );
        });
      } else {
        throw Exception(data['error_msg'] ?? 'Unable to load profile');
      }
    } catch (e) {
      _fail('Failed to load profile: $e');
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
        if (data['user'] is Map<String, dynamic>) {
          setState(() => _user = Map<String, dynamic>.from(data['user']));
        }
        _ok(data['message'] ?? 'Updated');
      } else {
        throw Exception(data['error_msg'] ?? 'Update failed');
      }
    } catch (e) {
      _fail('Update failed: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickAndUploadImage() async {
    if (_isUploadingImage) return;
    try {
      setState(() => _isUploadingImage = true);

      final x = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (x == null) throw Exception('No image selected');

      _imageFile = File(x.path);
      if (await _imageFile!.length() > 5 * 1024 * 1024) {
        throw Exception('Image must be < 5MB');
      }

      final uid = _prefs.getString('user_id');
      if (uid == null) throw Exception('User ID missing');

      final res = await _api.request(
        ApiConstants.updateProfilePictureEndpoint,
        method: 'POST',
        data: {'user': uid, 'action': 'update_profile_picture'},
        files: {'profile_picture': _imageFile!},
      );

      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data['error'] == false) {
        setState(() => _user['user_logo'] = data['user_logo']);
        _ok('Profile picture updated');
      } else {
        throw Exception(data['error_msg'] ?? 'Upload failed');
      }
    } catch (e) {
      _fail('Image upload failed: $e');
    } finally {
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // UI HELPERS
  // ────────────────────────────────────────────────────────────────────────

  void _fail(String msg) {
    if (!mounted) return;
    setState(() => _hasError = true);
    showToastNotification(context: context, title: 'Error', message: msg, isSuccess: false);
  }

  void _ok(String msg) {
    showToastNotification(context: context, title: 'Success', message: msg, isSuccess: true);
  }

  TextStyle get _title => Theme.of(context).textTheme.titleLarge!;
  TextStyle get _label => Theme.of(context).textTheme.labelMedium!;
  TextStyle get _body => Theme.of(context).textTheme.bodyMedium!;

  BoxDecoration _sectionBox(ColorScheme cs) => BoxDecoration(
    color: cs.surface,
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: AppColors.mintBgLight, width: 1),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(.04),
        blurRadius: 14,
        offset: const Offset(0, 6),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          const BackgroundWidget(showGrid: true, intensity: 1.0),
          SafeArea(
            child: _isLoading
                ? Center(child: CircularProgressIndicator(color: cs.primary))
                : _hasError
                ? _errorState(cs)
                : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _appBar(cs),
                  const SizedBox(height: 8),
                  _header(cs),
                  const SizedBox(height: 12),
                  _verification(cs),
                  const SizedBox(height: 12),
                  _savedPlaces(cs),
                  const SizedBox(height: 12),
                  _ridePreferences(cs),
                  const SizedBox(height: 12),
                  _payment(cs),
                  const SizedBox(height: 12),
                  _safety(cs),
                  const SizedBox(height: 12),
                  _account(cs),
                ],
              ),
            ),
          ),
          if (_isUploadingImage)
            Container(
              color: Colors.black45,
              child: Center(child: CircularProgressIndicator(color: cs.primary)),
            ),
        ],
      ),
    );
  }

  // ── APP BAR ─────────────────────────────────────────────────────────────
  Widget _appBar(ColorScheme cs) {
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: cs.onBackground),
          onPressed: () => Navigator.of(context).pop(),
        ),
        const Spacer(),
        Text('Profile', style: _title.copyWith(fontWeight: FontWeight.w800)),
        const Spacer(),
        const SizedBox(width: 48),
      ],
    );
  }

  // ── HEADER (avatar + name + stats) ──────────────────────────────────────
  Widget _header(ColorScheme cs) {
    final initials =
        '${(_user['user_fname'] ?? 'U').toString().substring(0, 1)}${(_user['user_lname'] ?? 'N').toString().substring(0, 1)}';
    final rating = (_user['user_rating'] ?? 4.8).toString();

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: _sectionBox(cs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              GestureDetector(
                onTap: _user['user_logo'] != null ? _showProfilePicture : null,
                child: CircleAvatar(
                  radius: 42,
                  backgroundColor: AppColors.mintBgLight,
                  backgroundImage:
                  _user['user_logo'] != null ? NetworkImage(_user['user_logo']) : null,
                  child: _user['user_logo'] == null
                      ? Text(initials,
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(color: cs.primary, fontWeight: FontWeight.w800))
                      : null,
                ),
              ),
              InkWell(
                onTap: _pickAndUploadImage,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration:
                  BoxDecoration(color: cs.primary, shape: BoxShape.circle, boxShadow: [
                    BoxShadow(color: cs.primary.withOpacity(.4), blurRadius: 12),
                  ]),
                  child: Icon(Icons.camera_alt_rounded, size: 18, color: cs.onPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${_user['user_fname'] ?? ''} ${_user['user_lname'] ?? ''}'.trim(),
            style: _title.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            children: [
              _chipStat(Icons.star_rounded, '$rating', cs),
              _chipStat(Icons.directions_car_rounded, '${_user['total_trips'] ?? 0} trips', cs),
              _chipStat(Icons.calendar_today_rounded, 'Since ${(_user['user_date_registered'] ?? '').toString().split(' ').first}', cs),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chipStat(IconData icon, String text, ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.mintBgLight,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        Text(text, style: _label.copyWith(color: AppColors.textPrimary)),
      ]),
    );
  }

  // ── VERIFICATION (identity) ─────────────────────────────────────────────
  Widget _verification(ColorScheme cs) {
    //final progress = ((_user['kyc_progress'] ?? 0.66) as num).toDouble().clamp(0, 1);

    final dynamic raw = _user['kyc_progress'];
    final double progress = (() {
      if (raw is num) return raw.toDouble();
      if (raw is String) return double.tryParse(raw) ?? 0.66;
      return 0.66;
    })().clamp(0.0, 1.0).toDouble();


    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _sectionBox(cs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Identity verification', style: _title.copyWith(fontSize: 16)),
          IconButton(
            icon: Icon(Icons.info_outline_rounded, color: cs.primary, size: 20),
            onPressed: _showKycInfo,
          ),
        ]),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: progress,
          backgroundColor: AppColors.mintBgLight,
          color: cs.primary,
          minHeight: 8,
          borderRadius: BorderRadius.circular(8),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 6, children: [
          _step('ID', true, cs),
          _step('Selfie', true, cs),
          _step('Address', progress >= .66, cs),
          _step('Doc upload', progress >= .90, cs),
        ]),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: _startKycUpgrade,
          child: const Text('Continue verification'),
        ),
      ]),
    );
  }

  Widget _step(String label, bool done, ColorScheme cs) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(done ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
          size: 18, color: done ? cs.primary : AppColors.textSecondary),
      const SizedBox(width: 6),
      Text(label, style: _body),
    ]);
  }

  // ── SAVED PLACES (Home / Work) ─────────────────────────────────────────
  Widget _savedPlaces(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _sectionBox(cs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Saved places', style: _title.copyWith(fontSize: 16)),
        const SizedBox(height: 8),
        _placeRow(
          cs,
          label: 'Home',
          value: (_user['place_home'] ?? 'Add your home address') as String,
          icon: Icons.home_rounded,
          onEdit: () => _editText('Home address', 'place_home'),
        ),
        const Divider(height: 16),
        _placeRow(
          cs,
          label: 'Work',
          value: (_user['place_work'] ?? 'Add your work address') as String,
          icon: Icons.work_rounded,
          onEdit: () => _editText('Work address', 'place_work'),
        ),
      ]),
    );
  }

  Widget _placeRow(ColorScheme cs,
      {required String label,
        required String value,
        required IconData icon,
        required VoidCallback onEdit}) {
    return Row(children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppColors.mintBgLight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: cs.primary),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: _label.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 2),
          Text(value, style: _body.copyWith(fontWeight: FontWeight.w600)),
        ]),
      ),
      IconButton(icon: Icon(Icons.edit_rounded, color: cs.primary), onPressed: onEdit),
    ]);
  }

  // ── RIDE PREFERENCES (Bike/Car/XL/Dispatch) ────────────────────────────
  Widget _ridePreferences(ColorScheme cs) {
    final selected = (_user['ride_pref'] ?? 'Car') as String;
    final opts = const ['Bike', 'Car', 'XL', 'Dispatch'];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _sectionBox(cs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Ride preferences', style: _title.copyWith(fontSize: 16)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final o in opts)
            ChoiceChip(
              label: Text(o),
              selected: selected == o,
              onSelected: (v) {
                if (v) _update({'ride_pref': o}, 'update_ride_pref');
              },
              selectedColor: cs.primary,
              labelStyle: TextStyle(
                color: selected == o ? cs.onPrimary : AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
              backgroundColor: AppColors.mintBgLight,
              shape: const StadiumBorder(),
            ),
        ]),
      ]),
    );
  }

  // ── PAYMENT (default method) ───────────────────────────────────────────
  Widget _payment(ColorScheme cs) {
    final method = (_user['default_payment'] ?? '**** 6628 • Card') as String;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _sectionBox(cs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Payment', style: _title.copyWith(fontSize: 16)),
        const SizedBox(height: 8),
        Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.mintBgLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.credit_card_rounded, size: 20, color: cs.primary),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(method, style: _body.copyWith(fontWeight: FontWeight.w600))),
          TextButton(
            onPressed: () => _editText('Default payment (e.g. **** 1234 • Card)', 'default_payment'),
            child: const Text('Change'),
          ),
        ]),
      ]),
    );
  }

  // ── SAFETY (emergency contact + ride PIN) ──────────────────────────────
  Widget _safety(ColorScheme cs) {
    final contact = (_user['emergency_contact'] ?? 'Add emergency contact') as String;
    final pinSet = (_user['ride_pin_set'] ?? false) as bool;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _sectionBox(cs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Safety & privacy', style: _title.copyWith(fontSize: 16)),
        const SizedBox(height: 8),
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.contact_phone_rounded, color: cs.primary),
          title: Text('Emergency contact', style: _body),
          subtitle: Text(contact, style: _label),
          trailing: TextButton(
            onPressed: () => _editText('Emergency contact (name + phone)', 'emergency_contact'),
            child: const Text('Set'),
          ),
        ),
        const Divider(height: 12),
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.password_rounded, color: cs.primary),
          title: Text('Ride safety PIN', style: _body),
          subtitle: Text(pinSet ? 'PIN enabled' : 'Protect rides with a PIN', style: _label),
          trailing: TextButton(
            onPressed: _changeRidePin,
            child: Text(pinSet ? 'Change' : 'Enable'),
          ),
        ),
      ]),
    );
  }

  // ── ACCOUNT (password/logout) ──────────────────────────────────────────
  Widget _account(ColorScheme cs) {
    return Container(
      decoration: _sectionBox(cs),
      child: Column(children: [
        ListTile(
          leading: Icon(Icons.lock_outline_rounded, color: cs.primary),
          title: Text('Change password', style: _body),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _changePassword,
        ),
        const Divider(height: 1),
        ListTile(
          leading: Icon(Icons.logout_rounded, color: AppColors.error),
          title: Text('Log out', style: _body.copyWith(color: AppColors.error)),
          onTap: () => _logoutConfirm(cs),
        ),
      ]),
    );
  }

  // ── DIALOGS / EDITORS ──────────────────────────────────────────────────
  void _showProfilePicture() {
    showDialog(
      context: context,
      builder: (c) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: GestureDetector(
          onTap: () => Navigator.pop(c),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              image: DecorationImage(image: NetworkImage(_user['user_logo']), fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    );
  }

  void _showKycInfo() {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Verification'),
        content: const Text('Verify your identity to book and send packages with confidence.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );
  }

  void _startKycUpgrade() {
    // You can deep link to your KYC flow here.
    _ok('Starting verification…');
  }

  void _editText(String title, String key) {
    final ctrl = TextEditingController(text: (_user[key] ?? '').toString());
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(c);
              _update({key: ctrl.text.trim()}, 'update_profile');
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _changePassword() {
    final oldC = TextEditingController();
    final newC = TextEditingController();
    final confC = TextEditingController();

    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Change password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: oldC, decoration: const InputDecoration(labelText: 'Old password'), obscureText: true),
            TextField(controller: newC, decoration: const InputDecoration(labelText: 'New password'), obscureText: true),
            TextField(controller: confC, decoration: const InputDecoration(labelText: 'Confirm new password'), obscureText: true),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              if (newC.text != confC.text) return _fail('Passwords do not match');
              Navigator.pop(c);
              _update({'old_password': oldC.text, 'new_password': newC.text}, 'update_password');
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _changeRidePin() {
    final newC = TextEditingController();
    final confC = TextEditingController();

    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Ride safety PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: newC,
              decoration: const InputDecoration(labelText: 'New PIN (4–6 digits)'),
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            ),
            TextField(
              controller: confC,
              decoration: const InputDecoration(labelText: 'Confirm PIN'),
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              if (newC.text != confC.text) return _fail('PINs do not match');
              Navigator.pop(c);
              _update({'ride_pin': newC.text}, 'update_ride_pin');
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _logoutConfirm(ColorScheme cs) {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Log out'),
        content: const Text('You will need to sign in again to book rides.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(c);
              await _prefs.remove('user_id');
              await _prefs.remove('user_pin');
              if (!mounted) return;
              Navigator.of(context).pop(); // or navigate to onboarding
            },
            child: Text('Log out', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  // ── ERROR STATE ────────────────────────────────────────────────────────
  Widget _errorState(ColorScheme cs) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: _sectionBox(cs),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Failed to load profile', style: _title.copyWith(fontSize: 16)),
          const SizedBox(height: 8),
          FilledButton(onPressed: _fetchUser, child: const Text('Retry')),
        ]),
      ),
    );
  }
}
