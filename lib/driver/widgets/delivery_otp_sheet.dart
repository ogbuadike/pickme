// lib/driver/widgets/delivery_otp_sheet.dart
//
// Collects the recipient's delivery PIN. The network call is injected
// ([verify]), so error handling/idempotency live in DriverSessionController.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../themes/app_theme.dart';
import '../../ui/ui_scale.dart';

class DeliveryOtpSheet extends StatefulWidget {
  static const int pinLength = 4; // user_logistics.php issues 4-digit PINs

  final String recipientPhone;

  /// Throws on rejection; its `toString()` is shown to the driver.
  final Future<void> Function(String otp) verify;

  const DeliveryOtpSheet({super.key, required this.recipientPhone, required this.verify});

  /// Resolves to true only when [verify] succeeded.
  static Future<bool> show(
    BuildContext context, {
    required String recipientPhone,
    required Future<void> Function(String otp) verify,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      builder: (_) => DeliveryOtpSheet(recipientPhone: recipientPhone, verify: verify),
    );
    return result ?? false;
  }

  @override
  State<DeliveryOtpSheet> createState() => _DeliveryOtpSheetState();
}

class _DeliveryOtpSheetState extends State<DeliveryOtpSheet> {
  final TextEditingController _otpCtrl = TextEditingController();
  bool _isVerifying = false;
  String? _error;

  @override
  void dispose() {
    _otpCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isVerifying) return;
    final otp = _otpCtrl.text.trim();
    if (otp.length != DeliveryOtpSheet.pinLength) {
      setState(() => _error = 'Enter the ${DeliveryOtpSheet.pinLength}-digit PIN.');
      return;
    }
    setState(() {
      _isVerifying = true;
      _error = null;
    });
    try {
      await widget.verify(otp);
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.vibrate();
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isVerifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final cs = Theme.of(context).colorScheme;
    final phone = widget.recipientPhone.trim();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: EdgeInsets.all(uiScale.inset(20)),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(24))),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 20, offset: Offset(0, -5))],
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.onSurface.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(2))),
              SizedBox(height: uiScale.gap(20)),
              Icon(Icons.security_rounded, size: uiScale.icon(40), color: AppColors.primary),
              SizedBox(height: uiScale.gap(12)),
              Text('Secure Package Handoff', style: TextStyle(fontSize: uiScale.font(18), fontWeight: FontWeight.w900)),
              SizedBox(height: uiScale.gap(4)),
              Text(
                phone.isEmpty
                    ? 'Ask the recipient for their ${DeliveryOtpSheet.pinLength}-digit PIN to release the package.'
                    : 'Ask the recipient ($phone) for their ${DeliveryOtpSheet.pinLength}-digit PIN to release the package.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: uiScale.font(13), color: cs.onSurfaceVariant),
              ),
              SizedBox(height: uiScale.gap(24)),
              TextField(
                controller: _otpCtrl,
                autofocus: true,
                enabled: !_isVerifying,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: DeliveryOtpSheet.pinLength,
                textAlign: TextAlign.center,
                autofillHints: const [AutofillHints.oneTimeCode],
                onSubmitted: (_) => _submit(),
                onChanged: (v) {
                  if (_error != null) setState(() => _error = null);
                  if (v.length == DeliveryOtpSheet.pinLength) _submit();
                },
                style: TextStyle(fontSize: uiScale.font(28), fontWeight: FontWeight.bold, letterSpacing: 12),
                decoration: InputDecoration(
                  counterText: '',
                  errorText: _error,
                  filled: true,
                  fillColor: cs.onSurface.withValues(alpha: 0.05),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(uiScale.radius(12)), borderSide: BorderSide.none),
                ),
              ),
              SizedBox(height: uiScale.gap(24)),
              SizedBox(
                width: double.infinity,
                height: uiScale.gap(50),
                child: ElevatedButton(
                  onPressed: _isVerifying ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(16))),
                  ),
                  child: _isVerifying
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.4))
                      : Text('Verify PIN', style: TextStyle(fontSize: uiScale.font(15), fontWeight: FontWeight.bold)),
                ),
              ),
              SizedBox(height: uiScale.gap(8)),
            ],
          ),
        ),
      ),
    );
  }
}
