// lib/driver/widgets/delivery_otp_sheet.dart
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../api/api_client.dart';
import '../../themes/app_theme.dart';
import '../../ui/ui_scale.dart';
import '../../utility/notification.dart';
import '../../api/url.dart';


class DeliveryOtpSheet extends StatefulWidget {
  final ApiClient api;
  final String rideId;
  final String recipientPhone;

  const DeliveryOtpSheet({super.key, required this.api, required this.rideId, required this.recipientPhone});

  static Future<bool> show(BuildContext context, ApiClient api, String rideId, String phone) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.85),
      builder: (_) => DeliveryOtpSheet(api: api, rideId: rideId, recipientPhone: phone),
    );
    return result ?? false;
  }

  @override
  State<DeliveryOtpSheet> createState() => _DeliveryOtpSheetState();
}

class _DeliveryOtpSheetState extends State<DeliveryOtpSheet> {
  final TextEditingController _otpCtrl = TextEditingController();
  bool _isVerifying = false;

  Future<void> _verify() async {
    final otp = _otpCtrl.text.trim();
    if (otp.length < 4) {
      showToastNotification(context: context, title: 'Invalid PIN', message: 'Enter the full OTP code.', isSuccess: false);
      return;
    }

    setState(() => _isVerifying = true);
    try {
      final res = await widget.api.request(
        ApiConstants._driverHubEndpoint,
        method: 'POST',
        data: {
          'action': 'verify_otp',
          'user': widget.api.prefs?.getString('user_id') ?? '',
          'ride_id': widget.rideId,
          'otp': otp,
        },
      );
      final body = jsonDecode(res.body);
      if (res.statusCode == 200 && body['error'] == false) {
        HapticFeedback.heavyImpact();
        if (mounted) Navigator.pop(context, true); // Success
      } else {
        throw Exception(body['message'] ?? 'Verification failed');
      }
    } catch (e) {
      HapticFeedback.vibrate();
      showToastNotification(context: context, title: 'Handoff Denied', message: e.toString().replaceFirst('Exception: ', ''), isSuccess: false);
    } finally {
      if (mounted) setState(() => _isVerifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: EdgeInsets.all(uiScale.inset(20)),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(24))),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 20, offset: Offset(0, -5))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.onSurface.withOpacity(0.2), borderRadius: BorderRadius.circular(2))),
            SizedBox(height: uiScale.gap(20)),
            Icon(Icons.security_rounded, size: uiScale.icon(40), color: AppColors.primary),
            SizedBox(height: uiScale.gap(12)),
            Text('Secure Package Handoff', style: TextStyle(fontSize: uiScale.font(18), fontWeight: FontWeight.w900)),
            SizedBox(height: uiScale.gap(4)),
            Text('Ask the recipient (${widget.recipientPhone}) for their 4-digit PIN to release the package.', textAlign: TextAlign.center, style: TextStyle(fontSize: uiScale.font(13), color: cs.onSurfaceVariant)),
            SizedBox(height: uiScale.gap(24)),
            TextField(
              controller: _otpCtrl,
              keyboardType: TextInputType.number,
              maxLength: 4,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: uiScale.font(28), fontWeight: FontWeight.bold, letterSpacing: 12),
              decoration: InputDecoration(
                counterText: '',
                filled: true,
                fillColor: cs.onSurface.withOpacity(0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(uiScale.radius(12)), borderSide: BorderSide.none),
              ),
            ),
            SizedBox(height: uiScale.gap(24)),
            SizedBox(
              width: double.infinity,
              height: uiScale.gap(50),
              child: ElevatedButton(
                onPressed: _isVerifying ? null : _verify,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(16))),
                ),
                child: _isVerifying
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text('Verify & Complete', style: TextStyle(fontSize: uiScale.font(15), fontWeight: FontWeight.bold)),
              ),
            ),
            SizedBox(height: uiScale.gap(16)),
          ],
        ),
      ),
    );
  }
}