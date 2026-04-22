// lib/screens/forgot_password.dart
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../themes/app_theme.dart';
import '../../utility/notification.dart';
import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../routes/routes.dart';
import '../../widgets/inner_background.dart';
import '../../ui/ui_scale.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  late ApiClient _apiClient;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _apiClient = ApiClient(http.Client(), context);
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _handlePasswordReset() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    final email = _emailController.text.trim();

    try {
      // Call your backend exclusively
      final response = await _apiClient.request(
        ApiConstants.restPwdEndpoint,
        method: 'POST',
        data: {'email': email},
      );

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 200 && responseData['error'] == false) {
        if (!mounted) return;
        showToastNotification(
          context: context,
          title: 'Success',
          message: responseData['message'] ?? 'Password reset link sent',
          isSuccess: true,
        );
        Navigator.pop(context);
      } else {
        if (!mounted) return;
        showToastNotification(
          context: context,
          title: 'Error',
          message: responseData['message'] ?? 'Unable to reset password',
          isSuccess: false,
        );
      }
    } catch (e) {
      if (!mounted) return;
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

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : theme.colorScheme.background,
      body: Stack(
        children: [
          BackgroundWidget(
            style: HoloStyle.vapor,
            animate: true,
            intensity: isDark ? 0.3 : 0.8,
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: uiScale.screenPadding.copyWith(
                  bottom: uiScale.screenPadding.bottom + uiScale.viewInsets.bottom,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: uiScale.authCardMaxWidth),
                  child: _FrostedCard(
                    uiScale: uiScale,
                    isDark: isDark,
                    cs: cs,
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _HeaderLogo(uiScale: uiScale, isDark: isDark, cs: cs),
                          SizedBox(height: uiScale.gap(18)),
                          Text(
                            'Forgot Password',
                            style: TextStyle(
                              fontSize: uiScale.font(uiScale.compact ? 24 : 28),
                              fontWeight: FontWeight.w900,
                              color: isDark ? cs.onSurface : AppColors.textPrimary,
                              letterSpacing: -0.5,
                            ),
                          ),
                          SizedBox(height: uiScale.gap(8)),
                          Text(
                            'Enter your email address to receive a reset link',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                              fontSize: uiScale.font(13),
                            ),
                          ),
                          SizedBox(height: uiScale.gap(24)),

                          _FieldWrapper(
                            uiScale: uiScale,
                            isDark: isDark,
                            child: TextFormField(
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.done,
                              autofillHints: const [AutofillHints.email, AutofillHints.username],
                              style: TextStyle(
                                fontSize: uiScale.font(14),
                                color: isDark ? cs.onSurface : AppColors.textPrimary,
                              ),
                              decoration: _inputDecoration(
                                label: 'Email Address',
                                icon: Icons.email_rounded,
                                uiScale: uiScale,
                                isDark: isDark,
                                cs: cs,
                              ),
                              validator: (v) {
                                final s = (v ?? '').trim();
                                if (s.isEmpty) return 'Email can’t be empty';
                                final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);
                                return ok ? null : 'Enter a valid email';
                              },
                              onFieldSubmitted: (_) => _busy ? null : _handlePasswordReset(),
                            ),
                          ),

                          SizedBox(height: uiScale.gap(22)),

                          _PrimaryGradientButton(
                            label: 'Reset Password',
                            busy: _busy,
                            uiScale: uiScale,
                            isDark: isDark,
                            cs: cs,
                            onPressed: _busy
                                ? null
                                : () {
                              HapticFeedback.lightImpact();
                              _handlePasswordReset();
                            },
                          ),

                          SizedBox(height: uiScale.gap(16)),

                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => Navigator.pushReplacementNamed(context, AppRoutes.login),
                            style: TextButton.styleFrom(
                              foregroundColor: isDark ? cs.primary : AppColors.primary,
                              padding: EdgeInsets.symmetric(
                                horizontal: uiScale.inset(12),
                                vertical: uiScale.inset(8),
                              ),
                            ),
                            child: Text(
                              'Back to Login',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: uiScale.font(13.5),
                              ),
                            ),
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

  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
    required UIScale uiScale,
    required bool isDark,
    required ColorScheme cs,
  }) {
    return InputDecoration(
      isDense: uiScale.compact,
      labelText: label,
      labelStyle: TextStyle(
        color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(.9),
      ),
      contentPadding: EdgeInsets.symmetric(
        horizontal: uiScale.inset(14),
        vertical: uiScale.inputVerticalPadding,
      ),
      prefixIcon: Padding(
        padding: EdgeInsets.all(uiScale.inset(8)),
        child: Container(
          decoration: BoxDecoration(
            color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.10),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: uiScale.icon(18), color: isDark ? cs.primary : AppColors.primary),
        ),
      ),
      filled: true,
      fillColor: isDark ? cs.surfaceVariant.withOpacity(0.5) : AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(uiScale.radius(16)),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(uiScale.radius(16)),
        borderSide: BorderSide(
          color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.30),
          width: 1,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(uiScale.radius(16)),
        borderSide: BorderSide(
          color: isDark ? cs.primary : AppColors.primary,
          width: 2,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(uiScale.radius(16)),
        borderSide: BorderSide(
          color: cs.error,
          width: 1,
        ),
      ),
    );
  }
}

class _HeaderLogo extends StatelessWidget {
  final UIScale uiScale;
  final bool isDark;
  final ColorScheme cs;

  const _HeaderLogo({
    required this.uiScale,
    required this.isDark,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    final size = uiScale.compactLogoSize;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: isDark ? [cs.primary, cs.secondary] : [AppColors.primary, AppColors.secondary],
        ),
        boxShadow: [
          BoxShadow(
            color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.22),
            blurRadius: uiScale.reduceFx ? 10 : 20,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(uiScale.inset(14)),
        child: Image.asset(
          'image/pickme.png',
          fit: BoxFit.contain,
          color: isDark ? cs.onPrimary : AppColors.surface,
        ),
      ),
    );
  }
}

class _FrostedCard extends StatelessWidget {
  final Widget child;
  final UIScale uiScale;
  final bool isDark;
  final ColorScheme cs;

  const _FrostedCard({
    required this.child,
    required this.uiScale,
    required this.isDark,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(uiScale.cardRadius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: uiScale.blur(20),
          sigmaY: uiScale.blur(20),
        ),
        child: Container(
          padding: EdgeInsets.all(uiScale.compact ? uiScale.inset(18) : uiScale.inset(28)),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isDark
                  ? [cs.surface.withOpacity(0.95), cs.surfaceVariant.withOpacity(0.8)]
                  : [AppColors.surface.withOpacity(0.92), AppColors.mintBgLight.withOpacity(0.28)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(uiScale.cardRadius),
            border: Border.all(
              color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.45),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black.withOpacity(0.5) : AppColors.deep.withOpacity(uiScale.reduceFx ? 0.05 : 0.10),
                blurRadius: uiScale.reduceFx ? 12 : 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _FieldWrapper extends StatelessWidget {
  final Widget child;
  final UIScale uiScale;
  final bool isDark;

  const _FieldWrapper({
    required this.child,
    required this.uiScale,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(uiScale.radius(16)),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black.withOpacity(0.3) : AppColors.deep.withOpacity(0.05),
            blurRadius: uiScale.reduceFx ? 6 : 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _PrimaryGradientButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final UIScale uiScale;
  final bool isDark;
  final ColorScheme cs;

  const _PrimaryGradientButton({
    required this.label,
    required this.onPressed,
    required this.busy,
    required this.uiScale,
    required this.isDark,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: uiScale.buttonHeight,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark ? [cs.primary, cs.secondary] : [AppColors.primary, AppColors.secondary],
        ),
        borderRadius: BorderRadius.circular(uiScale.radius(30)),
        boxShadow: [
          BoxShadow(
            color: (isDark ? cs.primary : AppColors.primary).withOpacity(uiScale.reduceFx ? 0.18 : 0.30),
            blurRadius: uiScale.reduceFx ? 12 : 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(30))),
        ),
        child: busy
            ? SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(isDark ? cs.onPrimary : AppColors.surface),
          ),
        )
            : Text(
          label,
          style: TextStyle(
            color: isDark ? cs.onPrimary : AppColors.surface,
            fontWeight: FontWeight.w700,
            fontSize: uiScale.font(15.5),
          ),
        ),
      ),
    );
  }
}