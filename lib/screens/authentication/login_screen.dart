// lib/screens/login.dart
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../routes/routes.dart';
import '../../themes/app_theme.dart';
import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../utility/notification.dart';
import '../../widgets/inner_background.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _auth = FirebaseAuth.instance;

  late ApiClient _api;
  bool _busy = false;
  bool _showPass = false;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);
  }

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  // ── Google Sign-In (optional) ──────────────────────────────────────────
  Future<void> _google() async {
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
      // TODO: exchange Firebase token with your backend if required.
      showToastNotification(
        context: context,
        title: 'Signed in',
        message: 'Welcome ${account.displayName ?? ''}',
        isSuccess: true,
      );
    } catch (e) {
      showToastNotification(
        context: context,
        title: 'Google Sign-In failed',
        message: e.toString(),
        isSuccess: false,
      );
    }
  }

  // ── Email/Password login (calls your API) ──────────────────────────────
  Future<void> _login() async {
    // Validate fields first
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    try {
      final data = {'email': _email.text.trim(), 'password': _pass.text.trim()};
      final res = await _api.request(
        ApiConstants.logInEndpoint,
        method: 'POST',
        data: data,
      );

      final body = jsonDecode(res.body);
      if (res.statusCode == 200 && body['error'] == false) {
        showToastNotification(
          context: context,
          title: 'Success',
          message: body['login_msg']['title_msg_body'] ?? 'Logged in',
          isSuccess: true,
        );

        final p = await SharedPreferences.getInstance();
        await p.setString('user_id', body['login_msg']['uid'] ?? '');
        await p.setString('user_name', body['login_msg']['fname'] ?? '');
        await p.setString('user_account_name', body['login_msg']['accountname'] ?? '');
        await p.setString('user_account_number', body['login_msg']['accountnumber'] ?? '');
        await p.setString('user_account_bank', body['login_msg']['bankname'] ?? '');
        await p.setString('user_pin', '');

        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(AppRoutes.set_user_pin);
      } else {
        showBannerNotification(
          context: context,
          title: body['login_msg']?['title_msg'] ?? 'Login failed',
          message: body['login_msg']?['title_msg_body'] ?? 'Check your details and try again',
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

  // ── UI ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: Stack(
        children: [
          // Theme-aware mint/emerald background
          const BackgroundWidget(showGrid: true, intensity: 1.0),

          // Content
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 520,
                    minHeight: size.height * .72,
                  ),
                  child: _FrostedCard(
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          // Brand
                          _BrandHeader(color: cs.primary),

                          const SizedBox(height: 18),
                          Text(
                            'Welcome back',
                            style: tt.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Sign in to book rides and send packages',
                            style: tt.bodyMedium?.copyWith(color: AppColors.textSecondary),
                          ),
                          const SizedBox(height: 22),

                          // Email
                          TextFormField(
                            controller: _email,
                            textInputAction: TextInputAction.next,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.username, AutofillHints.email],
                            decoration: InputDecoration(
                              labelText: 'Email',
                              prefixIcon: Icon(Icons.email_rounded, color: cs.primary),
                            ),
                            validator: (v) {
                              final s = (v ?? '').trim();
                              if (s.isEmpty) return 'Email can’t be empty';
                              final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);
                              return ok ? null : 'Enter a valid email';
                            },
                          ),
                          const SizedBox(height: 12),

                          // Password
                          TextFormField(
                            controller: _pass,
                            textInputAction: TextInputAction.done,
                            obscureText: !_showPass,
                            autofillHints: const [AutofillHints.password],
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: Icon(Icons.lock_rounded, color: cs.primary),
                              suffixIcon: IconButton(
                                onPressed: () => setState(() => _showPass = !_showPass),
                                icon: Icon(_showPass ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                                    color: cs.primary),
                              ),
                            ),
                            validator: (v) =>
                            (v == null || v.isEmpty) ? 'Password can’t be empty' : null,
                            onFieldSubmitted: (_) => _busy ? null : _login(),
                          ),

                          // Row: Forgot / Show
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pushNamed(context, AppRoutes.forgot_password),
                                child: const Text('Forgot password?'),
                              ),
                              TextButton(
                                onPressed: () => setState(() => _showPass = !_showPass),
                                child: Text(_showPass ? 'Hide password' : 'Show password'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),

                          // Login button
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _busy ? null : _login,
                              child: _busy
                                  ? SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  valueColor: AlwaysStoppedAnimation<Color>(cs.onPrimary),
                                ),
                              )
                                  : const Text('Log in'),
                            ),
                          ),

                          const SizedBox(height: 10),

                          // Optional SSO (kept light)
                          // OutlinedButton.icon(
                          //   onPressed: _busy ? null : _google,
                          //   icon: Icon(Icons.g_mobiledata_rounded, size: 22, color: cs.primary),
                          //   label: const Text('Sign in with Google'),
                          // ),

                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('Don’t have an account?', style: tt.bodyMedium),
                              TextButton(
                                onPressed: () => Navigator.pushNamed(context, AppRoutes.registration),
                                child: Text('Create now', style: TextStyle(color: cs.primary)),
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

/// Frosted glass container that matches the mint/emerald theme.
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
              BoxShadow(
                color: Colors.black.withOpacity(.06),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          child: child,
        ),
      ),
    );
  }
}

/// Brand header with glowing emerald capsule + wordmark
class _BrandHeader extends StatelessWidget {
  const _BrandHeader({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final onP = Colors.white;

    return Column(
      children: [
        Container(
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
            Text('Pick Me', style: tt.labelLarge?.copyWith(color: onP, fontWeight: FontWeight.w800)),
          ]),
        ),
      ],
    );
  }
}
