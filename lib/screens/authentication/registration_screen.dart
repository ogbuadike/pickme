// lib/screens/registration.dart
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import '../../routes/routes.dart';
import '../../themes/app_theme.dart';
import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../utility/notification.dart';
import '../../utility/deviceInfoService.dart';
import '../../widgets/inner_background.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});
  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  // Controllers
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();

  // Form + state
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;
  bool _showPass = false;
  bool _showConfirm = false;

  // Services
  late ApiClient _api;
  final _deviceInfo = DeviceInfoService();
  final _auth = FirebaseAuth.instance;

  // Password strength (0..1)
  double _strength = 0;
  String _strengthLabel = 'Too weak';

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);
    _pass.addListener(_computeStrength);
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  // ── Validation helpers ─────────────────────────────────────────────────
  bool _validEmail(String s) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s.trim());

  void _computeStrength() {
    final s = _pass.text;
    double sc = 0;
    if (s.length >= 8) sc += .25;
    if (RegExp(r'[A-Z]').hasMatch(s)) sc += .20;
    if (RegExp(r'[a-z]').hasMatch(s)) sc += .20;
    if (RegExp(r'\d').hasMatch(s)) sc += .20;
    if (RegExp(r'[!@#\$%\^&\*\-_\+=\.\,\?\(\)]').hasMatch(s)) sc += .15;
    sc = sc.clamp(0, 1);
    String label = 'Too weak';
    if (sc >= .80) label = 'Strong';
    else if (sc >= .55) label = 'Good';
    else if (sc >= .35) label = 'Fair';
    setState(() {
      _strength = sc;
      _strengthLabel = label;
    });
  }

  // ── API: Registration ──────────────────────────────────────────────────
  Future<void> _register() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    try {
      final device = await _deviceInfo.getDeviceInfo();
      final payload = {
        'full_name': _name.text.trim(),
        'email': _email.text.trim(),
        'password': _pass.text.trim(),
        'device': jsonEncode(device),
      };

      final res = await _api.request(
        ApiConstants.registerEndpoint,
        method: 'POST',
        data: payload,
      );
      final body = jsonDecode(res.body);

      if (res.statusCode == 200 && body['error'] == false) {
        showToastNotification(
          context: context,
          title: 'Success',
          message: body['login_msg']?['title_msg_body'] ?? 'Account created',
          isSuccess: true,
        );
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(AppRoutes.login);
      } else {
        showBannerNotification(
          context: context,
          title: body['login_msg']?['title_msg'] ?? 'Registration failed',
          message: body['login_msg']?['title_msg_body'] ?? 'Please try again.',
          isSuccess: false,
        );
      }
    } catch (e) {
      showToastNotification(
        context: context,
        title: 'Error',
        message: e.toString(),
        isSuccess: false,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Optional Google Sign-Up (kept lightweight)
  Future<void> _googleSignup() async {
    try {
      final g = GoogleSignIn();
      final account = await g.signIn();
      if (account == null) return;
      final auth = await account.authentication;
      final cred = GoogleAuthProvider.credential(
        accessToken: auth.accessToken,
        idToken: auth.idToken,
      );
      await _auth.signInWithCredential(cred);
      showToastNotification(
        context: context,
        title: 'Signed in',
        message: 'Welcome ${account.displayName ?? ''}',
        isSuccess: true,
      );
      // Optionally POST account.email/uid to your backend to create/link account.
    } catch (e) {
      showToastNotification(
        context: context,
        title: 'Google Sign-In failed',
        message: e.toString(),
        isSuccess: false,
      );
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    Color _meterColor() {
      if (_strength >= .80) return cs.primary;
      if (_strength >= .55) return AppColors.secondary;
      if (_strength >= .35) return AppColors.outline;
      return cs.error;
    }

    return Scaffold(
      body: Stack(
        children: [
          const BackgroundWidget(showGrid: true, intensity: 1.0),

          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: _FrostedCard(
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          _BrandHeader(color: cs.primary),
                          const SizedBox(height: 18),
                          Text('Create your account',
                              style: tt.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: cs.onSurface,
                              )),
                          const SizedBox(height: 6),
                          Text('Ride, dispatch, and move smarter with Pick Me',
                              style: tt.bodyMedium?.copyWith(
                                color: AppColors.textSecondary,
                              )),
                          const SizedBox(height: 22),

                          // Full name
                          TextFormField(
                            controller: _name,
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              labelText: 'Legal full name',
                              prefixIcon: Icon(Icons.person_rounded, color: cs.primary),
                            ),
                            validator: (v) {
                              final s = (v ?? '').trim();
                              if (s.isEmpty) return 'Full name can’t be empty';
                              if (s.length < 3) return 'Enter a valid name';
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),

                          // Email
                          TextFormField(
                            controller: _email,
                            textInputAction: TextInputAction.next,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email, AutofillHints.username],
                            decoration: InputDecoration(
                              labelText: 'Email',
                              prefixIcon: Icon(Icons.email_rounded, color: cs.primary),
                            ),
                            validator: (v) =>
                            _validEmail(v ?? '') ? null : 'Enter a valid email',
                          ),
                          const SizedBox(height: 12),

                          // Password
                          TextFormField(
                            controller: _pass,
                            obscureText: !_showPass,
                            textInputAction: TextInputAction.next,
                            autofillHints: const [AutofillHints.newPassword],
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: Icon(Icons.lock_rounded, color: cs.primary),
                              suffixIcon: IconButton(
                                onPressed: () => setState(() => _showPass = !_showPass),
                                icon: Icon(
                                  _showPass ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                            validator: (v) {
                              final s = (v ?? '');
                              if (s.isEmpty) return 'Password can’t be empty';
                              if (s.length < 8) return 'Use at least 8 characters';
                              if (!RegExp(r'[A-Za-z]').hasMatch(s) || !RegExp(r'\d').hasMatch(s)) {
                                return 'Use letters and numbers';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 8),

                          // Strength meter
                          Row(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: LinearProgressIndicator(
                                    minHeight: 6,
                                    value: _strength == 0 ? null : _strength,
                                    color: _meterColor(),
                                    backgroundColor: AppColors.mintBgLight,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(_strengthLabel,
                                  style: tt.labelMedium?.copyWith(
                                    color: AppColors.textSecondary,
                                    fontWeight: FontWeight.w700,
                                  )),
                            ],
                          ),
                          const SizedBox(height: 12),

                          // Confirm password
                          TextFormField(
                            controller: _confirm,
                            obscureText: !_showConfirm,
                            textInputAction: TextInputAction.done,
                            autofillHints: const [AutofillHints.newPassword],
                            onFieldSubmitted: (_) => _busy ? null : _register(),
                            decoration: InputDecoration(
                              labelText: 'Confirm password',
                              prefixIcon: Icon(Icons.lock_person_rounded, color: cs.primary),
                              suffixIcon: IconButton(
                                onPressed: () => setState(() => _showConfirm = !_showConfirm),
                                icon: Icon(
                                  _showConfirm
                                      ? Icons.visibility_rounded
                                      : Icons.visibility_off_rounded,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                            validator: (v) =>
                            (v ?? '').trim() == _pass.text.trim() ? null : 'Passwords do not match',
                          ),

                          const SizedBox(height: 18),

                          // Register
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _busy ? null : _register,
                              child: _busy
                                  ? SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  valueColor: AlwaysStoppedAnimation<Color>(cs.onPrimary),
                                ),
                              )
                                  : const Text('Create account'),
                            ),
                          ),

                          const SizedBox(height: 10),

                          // Optional Google SSO (uncomment to enable)
                          // OutlinedButton.icon(
                          //   onPressed: _busy ? null : _googleSignup,
                          //   icon: Icon(Icons.g_mobiledata_rounded, size: 22, color: cs.primary),
                          //   label: const Text('Sign up with Google'),
                          // ),

                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('Already have an account?', style: tt.bodyMedium),
                              TextButton(
                                onPressed: () => Navigator.pushReplacementNamed(context, AppRoutes.login),
                                child: Text('Log in', style: TextStyle(color: cs.primary)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Frosted container (consistent with Login)
class _FrostedCard extends StatelessWidget {
  const _FrostedCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            color: cs.surface.withOpacity(.86),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.mintBgLight, width: 1),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(.06), blurRadius: 18, offset: const Offset(0, 6)),
            ],
          ),
          padding: const EdgeInsets.all(18),
          child: child,
        ),
      ),
    );
  }
}

/// Brand capsule (matches splash/login)
class _BrandHeader extends StatelessWidget {
  const _BrandHeader({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(color: color.withOpacity(.35), blurRadius: 22, spreadRadius: 1),
          BoxShadow(color: color.withOpacity(.18), blurRadius: 8, offset: const Offset(0, 3)),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.directions_car_rounded, size: 22, color: Colors.white),
        const SizedBox(width: 8),
        Text('Pick Me', style: tt.labelLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}
