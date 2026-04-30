// lib/screens/logistics_booking_sheet.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../api/api_client.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../utility/notification.dart';

class LogisticsBookingSheet extends StatefulWidget {
  final ApiClient api;
  final String userId;
  final String rideType;
  final LatLng pickup;
  final String pickupText;
  final LatLng destination;
  final String destinationText;
  final double distanceKm;
  final Function(String rideId, String? otp) onBookingSuccess;

  const LogisticsBookingSheet({
    super.key,
    required this.api, required this.userId, required this.rideType,
    required this.pickup, required this.pickupText,
    required this.destination, required this.destinationText,
    required this.distanceKm, required this.onBookingSuccess,
  });

  static Future<void> show(BuildContext context, {
    required ApiClient api, required String userId, required String rideType,
    required LatLng pickup, required String pickupText,
    required LatLng dest, required String destText, required double distanceKm,
    required Function(String, String?) onSuccess,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.6),
      builder: (_) => LogisticsBookingSheet(
        api: api, userId: userId, rideType: rideType, pickup: pickup, pickupText: pickupText,
        destination: dest, destinationText: destText, distanceKm: distanceKm,
        onBookingSuccess: onSuccess,
      ),
    );
  }

  @override
  State<LogisticsBookingSheet> createState() => _LogisticsBookingSheetState();
}

class _LogisticsBookingSheetState extends State<LogisticsBookingSheet> {
  final TextEditingController _phoneCtrl = TextEditingController();
  final TextEditingController _instructionsCtrl = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  late String _packageSize;
  late double _weightKg;
  File? _packageImage;

  double _estimatedPrice = 0.0;
  bool _isEstimating = false;
  bool _isBooking = false;

  @override
  void initState() {
    super.initState();
    if (widget.rideType == 'dispatch') {
      _packageSize = 'box';
      _weightKg = 50.0;
    } else {
      _packageSize = 'envelope';
      _weightKg = 1.0;
    }
    _fetchEstimate();
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _instructionsCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 75,
        maxWidth: 1080,
      );
      if (picked != null) {
        setState(() => _packageImage = File(picked.path));
      }
    } catch (_) {
      showToastNotification(context: context, title: 'Camera Error', message: 'Unable to access camera.', isSuccess: false);
    }
  }

  Future<void> _fetchEstimate() async {
    setState(() => _isEstimating = true);
    try {
      final res = await widget.api.request(
        'user_logistics.php', method: 'POST',
        data: {
          'action': 'estimate_delivery',
          'user': widget.userId,
          'ride_type': widget.rideType,
          'package_size': _packageSize,
          'weight_kg': _weightKg.toStringAsFixed(1),
          'distance_km': widget.distanceKm.toStringAsFixed(2),
        },
      );
      final body = jsonDecode(res.body);
      if (body['error'] == false && mounted) {
        setState(() => _estimatedPrice = (body['data']['estimated_price'] as num).toDouble());
      }
    } catch (_) {
      setState(() => _estimatedPrice = (widget.rideType == 'dispatch' ? 1500 : 1200) + (widget.distanceKm * 150));
    } finally {
      if (mounted) setState(() => _isEstimating = false);
    }
  }

  Future<void> _bookService() async {
    final isDispatch = widget.rideType == 'dispatch';

    if (isDispatch) {
      if (_phoneCtrl.text.trim().length < 10) {
        showToastNotification(context: context, title: 'Phone Required', message: 'Enter a valid recipient phone number.', isSuccess: false); return;
      }
      if (_packageImage == null) {
        showToastNotification(context: context, title: 'Photo Required', message: 'Please snap a photo of the package.', isSuccess: false); return;
      }
    } else {
      if (_instructionsCtrl.text.trim().isEmpty) {
        showToastNotification(context: context, title: 'Instructions Required', message: 'Tell the rider what to do.', isSuccess: false); return;
      }
    }

    setState(() => _isBooking = true);
    try {
      final data = {
        'action': 'book_service', 'user': widget.userId, 'ride_type': widget.rideType,
        'pickup_lat': widget.pickup.latitude.toString(), 'pickup_lng': widget.pickup.longitude.toString(), 'pickup_text': widget.pickupText,
        'dest_lat': widget.destination.latitude.toString(), 'dest_lng': widget.destination.longitude.toString(), 'dest_text': widget.destinationText,
        'distance_km': widget.distanceKm.toStringAsFixed(2), 'pay_method': 'cash',
      };

      if (isDispatch) {
        data['recipient_phone'] = _phoneCtrl.text.trim();
        data['package_size'] = _packageSize;
        data['weight_kg'] = _weightKg.toStringAsFixed(1);
      } else {
        data['instructions'] = _instructionsCtrl.text.trim();
      }

      // Map the file exactly as expected by your ApiClient
      Map<String, File>? uploadFiles;
      if (isDispatch && _packageImage != null) {
        uploadFiles = {'package_image': _packageImage!};
      }

      final res = await widget.api.request('user_logistics.php', method: 'POST', data: data, files: uploadFiles);
      final body = jsonDecode(res.body);

      if (res.statusCode == 200 && body['error'] == false) {
        HapticFeedback.heavyImpact();
        final rideId = body['data']['ride_id'].toString();
        final otp = body['data']['delivery_otp']?.toString();

        if (mounted) {
          Navigator.pop(context);
          widget.onBookingSuccess(rideId, otp);
        }
      } else {
        throw Exception(body['message'] ?? 'Booking failed');
      }
    } catch (e) {
      if (mounted) showToastNotification(context: context, title: 'Error', message: e.toString().replaceFirst('Exception: ', ''), isSuccess: false);
    } finally {
      if (mounted) setState(() => _isBooking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDispatch = widget.rideType == 'dispatch';
    final themeColor = isDispatch ? Colors.amber.shade700 : Colors.blueAccent;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(28))),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            color: isDark ? cs.surface.withOpacity(0.95) : Colors.white.withOpacity(0.98),
            padding: EdgeInsets.fromLTRB(uiScale.inset(20), uiScale.inset(12), uiScale.inset(20), uiScale.inset(24)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(width: 48, height: 5, decoration: BoxDecoration(color: cs.onSurface.withOpacity(0.2), borderRadius: BorderRadius.circular(10)))),
                SizedBox(height: uiScale.gap(24)),

                Row(
                  children: [
                    Container(padding: EdgeInsets.all(uiScale.inset(10)), decoration: BoxDecoration(color: themeColor.withOpacity(0.15), shape: BoxShape.circle), child: Icon(isDispatch ? Icons.local_shipping_rounded : Icons.shopping_cart_checkout_rounded, color: themeColor, size: uiScale.icon(24))),
                    SizedBox(width: uiScale.gap(12)),
                    Expanded(child: Text(isDispatch ? 'Fleet Dispatch Setup' : 'Errand Instructions', style: TextStyle(fontSize: uiScale.font(20), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary, letterSpacing: -0.5))),
                  ],
                ),
                SizedBox(height: uiScale.gap(24)),

                if (isDispatch) ...[
                  // --- DISPATCH: IMAGE, PHONE, SIZE, WEIGHT ---
                  GestureDetector(
                    onTap: _pickImage,
                    child: Container(
                      width: double.infinity, height: uiScale.inset(100),
                      decoration: BoxDecoration(color: isDark ? cs.surfaceVariant.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.5), borderRadius: BorderRadius.circular(uiScale.radius(16)), border: Border.all(color: _packageImage == null ? cs.error.withOpacity(0.5) : themeColor, width: 2), image: _packageImage != null ? DecorationImage(image: FileImage(_packageImage!), fit: BoxFit.cover) : null),
                      child: _packageImage == null ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.camera_alt_rounded, color: themeColor), SizedBox(height: uiScale.gap(4)), Text('Tap to snap package photo', style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurfaceVariant))]) : null,
                    ),
                  ),
                  SizedBox(height: uiScale.gap(16)),

                  TextField(
                    controller: _phoneCtrl, keyboardType: TextInputType.phone, style: TextStyle(fontSize: uiScale.font(16), fontWeight: FontWeight.w700),
                    decoration: InputDecoration(hintText: 'Recipient Phone', prefixIcon: Icon(Icons.contact_phone_rounded, color: themeColor), filled: true, fillColor: cs.onSurface.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(uiScale.radius(16)), borderSide: BorderSide.none)),
                  ),
                  SizedBox(height: uiScale.gap(16)),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildSizeChip(uiScale, cs, isDark, themeColor, 'Envelope', 'envelope', Icons.mail_outline_rounded),
                      _buildSizeChip(uiScale, cs, isDark, themeColor, 'Medium Box', 'box', Icons.inventory_2_outlined),
                      _buildSizeChip(uiScale, cs, isDark, themeColor, 'Heavy Freight', 'heavy', Icons.widgets_outlined),
                    ],
                  ),
                  SizedBox(height: uiScale.gap(16)),

                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Weight Limit', style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurfaceVariant)), Text('${_weightKg.toStringAsFixed(1)} kg', style: TextStyle(fontWeight: FontWeight.w900, color: themeColor))]),
                  SliderTheme(
                    data: SliderThemeData(trackHeight: 6, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12), overlayShape: const RoundSliderOverlayShape(overlayRadius: 24)),
                    child: Slider(value: _weightKg, min: 0.5, max: 1000.0, divisions: 100, activeColor: themeColor, inactiveColor: cs.onSurface.withOpacity(0.1), onChanged: (val) => setState(() => _weightKg = val), onChangeEnd: (_) => _fetchEstimate()),
                  ),
                ] else ...[
                  // --- SEND ME: ERRAND INSTRUCTIONS ---
                  Text('What do you need the rider to do?', style: TextStyle(fontSize: uiScale.font(13), fontWeight: FontWeight.bold, color: cs.onSurfaceVariant)),
                  SizedBox(height: uiScale.gap(8)),
                  TextField(
                    controller: _instructionsCtrl, maxLines: 4, minLines: 3, style: TextStyle(fontSize: uiScale.font(14), fontWeight: FontWeight.w600),
                    decoration: InputDecoration(hintText: 'e.g., Buy 2 loaves of bread at St Mary\'s plaza.', filled: true, fillColor: cs.onSurface.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(uiScale.radius(16)), borderSide: BorderSide.none)),
                  ),
                ],

                SizedBox(height: uiScale.gap(24)),
                Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Estimated Price', style: TextStyle(fontSize: uiScale.font(12), color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
                        SizedBox(height: uiScale.gap(4)),
                        _isEstimating ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2)) : Text('NGN ${_estimatedPrice.toStringAsFixed(0)}', style: TextStyle(fontSize: uiScale.font(24), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary, letterSpacing: -0.5)),
                      ],
                    ),
                    SizedBox(width: uiScale.gap(20)),
                    Expanded(
                      child: SizedBox(
                        height: uiScale.inset(56),
                        child: ElevatedButton(
                          onPressed: _isBooking ? null : _bookService,
                          style: ElevatedButton.styleFrom(backgroundColor: themeColor, foregroundColor: isDispatch ? Colors.black : Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(16))), elevation: 8, shadowColor: themeColor.withOpacity(0.4)),
                          child: _isBooking ? CircularProgressIndicator(color: isDispatch ? Colors.black : Colors.white) : Text('Confirm Booking', style: TextStyle(fontSize: uiScale.font(15), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSizeChip(UIScale uiScale, ColorScheme cs, bool isDark, Color themeColor, String label, String value, IconData icon) {
    final isSelected = _packageSize == value;
    return GestureDetector(
      onTap: () { HapticFeedback.lightImpact(); setState(() => _packageSize = value); _fetchEstimate(); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200), width: uiScale.inset(105), padding: EdgeInsets.symmetric(vertical: uiScale.inset(14)),
        decoration: BoxDecoration(color: isSelected ? themeColor.withOpacity(0.12) : cs.onSurface.withOpacity(0.04), borderRadius: BorderRadius.circular(uiScale.radius(16)), border: Border.all(color: isSelected ? themeColor : Colors.transparent, width: 2.0)),
        child: Column(children: [Icon(icon, size: uiScale.icon(24), color: isSelected ? themeColor : cs.onSurfaceVariant), SizedBox(height: uiScale.gap(8)), Text(label, style: TextStyle(fontSize: uiScale.font(11), fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600, color: isSelected ? themeColor : cs.onSurfaceVariant))]),
      ),
    );
  }
}