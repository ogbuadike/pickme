// lib/screens/logistics_booking_sheet.dart
//
// Details + quote + confirm sheet for Send Me (errand instructions) and
// Dispatch (recipient phone, package photo, size, weight).
//
//  * quotes are debounced and sequence-numbered (stale answers dropped), and
//    a failed quote is shown as such - never replaced by a made-up price;
//  * all input validated (Nigerian mobile numbers, weight per size class,
//    instruction length) before the single-flight booking request;
//  * the sheet cannot be dismissed while the booking is in flight.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../api/api_client.dart';
import '../services/logistics_service.dart';
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../utility/notification.dart';
import '../widgets/ride_market/money.dart';

class LogisticsBookingSheet extends StatefulWidget {
  final ApiClient api;
  final String userId;
  final String rideType; // 'send_me' | 'dispatch'
  final LatLng pickup;
  final String pickupText;
  final LatLng destination;
  final String destinationText;
  final double distanceKm;
  final double? walletBalance;
  final void Function(String rideId, String? otp) onBookingSuccess;

  const LogisticsBookingSheet({
    super.key,
    required this.api,
    required this.userId,
    required this.rideType,
    required this.pickup,
    required this.pickupText,
    required this.destination,
    required this.destinationText,
    required this.distanceKm,
    required this.onBookingSuccess,
    this.walletBalance,
  });

  static Future<void> show(
    BuildContext context, {
    required ApiClient api,
    required String userId,
    required String rideType,
    required LatLng pickup,
    required String pickupText,
    required LatLng dest,
    required String destText,
    required double distanceKm,
    required void Function(String, String?) onSuccess,
    double? walletBalance,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (_) => LogisticsBookingSheet(
        api: api,
        userId: userId,
        rideType: rideType,
        pickup: pickup,
        pickupText: pickupText,
        destination: dest,
        destinationText: destText,
        distanceKm: distanceKm,
        walletBalance: walletBalance,
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
  late final LogisticsService _service = LogisticsService(widget.api);
  late final LogisticsKind _kind =
      LogisticsKindX.tryParse(widget.rideType) ?? LogisticsKind.sendMe;

  PackageSize _packageSize = PackageSize.envelope;
  double _weightKg = PackageSize.envelope.defaultKg;
  File? _packageImage;
  String _payMethod = 'cash';

  double? _estimatedPrice;
  String? _estimateError;
  bool _isEstimating = false;
  int _estimateSeq = 0;
  Timer? _estimateDebounce;

  bool _isBooking = false;
  String? _phoneError;

  @override
  void initState() {
    super.initState();
    if (_kind.isDispatch) {
      _packageSize = PackageSize.box;
      _weightKg = PackageSize.box.defaultKg;
    }
    _fetchEstimate();
  }

  @override
  void dispose() {
    _estimateDebounce?.cancel();
    _phoneCtrl.dispose();
    _instructionsCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    if (_isBooking) return;
    XFile? picked;
    try {
      picked = await _picker.pickImage(source: ImageSource.camera, imageQuality: 75, maxWidth: 1280);
    } catch (_) {
      // No camera / permission denied: fall back to the gallery.
      try {
        picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 75, maxWidth: 1280);
      } catch (_) {
        if (mounted) {
          showToastNotification(
            context: context,
            title: 'Camera unavailable',
            message: 'Allow camera or photo access to attach the package photo.',
            isSuccess: false,
          );
        }
        return;
      }
    }
    if (picked == null || !mounted) return;
    final File f = File(picked.path);
    final int bytes = await f.length();
    if (!mounted) return;
    if (bytes > 8 * 1024 * 1024) {
      showToastNotification(context: context, title: 'Photo too large', message: 'Please retake the photo.', isSuccess: false);
      return;
    }
    setState(() => _packageImage = f);
  }

  void _scheduleEstimate() {
    _estimateDebounce?.cancel();
    _estimateDebounce = Timer(const Duration(milliseconds: 350), _fetchEstimate);
  }

  Future<void> _fetchEstimate() async {
    final int seq = ++_estimateSeq;
    setState(() {
      _isEstimating = true;
      _estimateError = null;
    });
    try {
      final double price = await _service.estimate(
        kind: _kind,
        userId: widget.userId,
        distanceKm: widget.distanceKm,
        packageSize: _packageSize,
        weightKg: _kind.isDispatch ? _weightKg : 0,
      );
      if (!mounted || seq != _estimateSeq) return;
      setState(() {
        _estimatedPrice = price;
        if (_payMethod == 'wallet' && !_walletCovers(price)) _payMethod = 'cash';
      });
    } on LogisticsException catch (e) {
      if (!mounted || seq != _estimateSeq) return;
      setState(() {
        _estimatedPrice = null;
        _estimateError = e.message;
      });
    } finally {
      if (mounted && seq == _estimateSeq) setState(() => _isEstimating = false);
    }
  }

  bool _walletCovers(double? price) {
    final double? bal = widget.walletBalance;
    return bal != null && price != null && bal >= price;
  }

  Future<void> _bookService() async {
    if (_isBooking) return;
    FocusScope.of(context).unfocus();

    final LogisticsBookingRequest req = LogisticsBookingRequest(
      kind: _kind,
      userId: widget.userId,
      pickup: widget.pickup,
      pickupText: widget.pickupText,
      destination: widget.destination,
      destinationText: widget.destinationText,
      distanceKm: widget.distanceKm,
      payMethod: _payMethod,
      instructions: _instructionsCtrl.text,
      recipientPhone: _phoneCtrl.text,
      packageSize: _packageSize,
      weightKg: _weightKg,
      packageImage: _packageImage,
    );
    final String? invalid = req.validate();
    if (invalid != null) {
      if (_kind.isDispatch && normalizeNigerianPhone(_phoneCtrl.text) == null) {
        setState(() => _phoneError = 'Enter a valid number, e.g. 0803 123 4567');
      }
      showToastNotification(context: context, title: 'Check details', message: invalid, isSuccess: false);
      return;
    }
    if (_estimatedPrice == null) {
      showToastNotification(
        context: context,
        title: 'Price unavailable',
        message: 'We could not get a price yet. Tap retry on the price.',
        isSuccess: false,
      );
      return;
    }

    setState(() => _isBooking = true);
    try {
      final LogisticsBooking booking = await _service.book(req);
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      Navigator.pop(context);
      widget.onBookingSuccess(booking.rideId, booking.deliveryOtp.isEmpty ? null : booking.deliveryOtp);
    } on LogisticsException catch (e) {
      if (mounted) {
        showToastNotification(context: context, title: 'Booking failed', message: e.message, isSuccess: false);
      }
    } finally {
      if (mounted) setState(() => _isBooking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final UIScale uiScale = UIScale.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final bool isDispatch = _kind.isDispatch;
    final Color themeColor = _kind.brandColor;

    return PopScope(
      canPop: !_isBooking,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ClipRRect(
          borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(28))),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              color: isDark ? cs.surface.withValues(alpha: 0.95) : Colors.white.withValues(alpha: 0.98),
              padding: EdgeInsets.fromLTRB(uiScale.inset(20), uiScale.inset(12), uiScale.inset(20), uiScale.inset(24)),
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Center(
                      child: Container(
                        width: 48,
                        height: 5,
                        decoration: BoxDecoration(
                          color: cs.onSurface.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    SizedBox(height: uiScale.gap(24)),
                    Row(
                      children: <Widget>[
                        Container(
                          padding: EdgeInsets.all(uiScale.inset(10)),
                          decoration: BoxDecoration(color: themeColor.withValues(alpha: 0.15), shape: BoxShape.circle),
                          child: Icon(_kind.icon, color: themeColor, size: uiScale.icon(24)),
                        ),
                        SizedBox(width: uiScale.gap(12)),
                        Expanded(
                          child: Text(
                            isDispatch ? 'Package Details' : 'Errand Instructions',
                            style: TextStyle(
                              fontSize: uiScale.font(20),
                              fontWeight: FontWeight.w900,
                              color: isDark ? cs.onSurface : AppColors.textPrimary,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                        Text('${widget.distanceKm.toStringAsFixed(1)} km',
                            style: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurfaceVariant)),
                      ],
                    ),
                    SizedBox(height: uiScale.gap(24)),
                    if (isDispatch) ..._dispatchFields(uiScale, cs, isDark, themeColor) else ..._sendMeFields(uiScale, cs),
                    SizedBox(height: uiScale.gap(20)),
                    _paymentSelector(uiScale, cs, themeColor),
                    SizedBox(height: uiScale.gap(20)),
                    Row(
                      children: <Widget>[
                        Expanded(child: _priceBlock(uiScale, cs, isDark)),
                        SizedBox(width: uiScale.gap(16)),
                        Expanded(
                          child: SizedBox(
                            height: uiScale.inset(56),
                            child: ElevatedButton(
                              onPressed: (_isBooking || _isEstimating) ? null : _bookService,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: themeColor,
                                foregroundColor: _kind.onBrandColor,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(16))),
                                elevation: 8,
                                shadowColor: themeColor.withValues(alpha: 0.4),
                              ),
                              child: _isBooking
                                  ? SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(strokeWidth: 2.5, color: _kind.onBrandColor),
                                    )
                                  : Text('Confirm Booking',
                                      style: TextStyle(
                                          fontSize: uiScale.font(15), fontWeight: FontWeight.w800, letterSpacing: 0.5)),
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
        ),
      ),
    );
  }

  Widget _priceBlock(UIScale uiScale, ColorScheme cs, bool isDark) {
    Widget value;
    if (_isEstimating) {
      value = const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (_estimatedPrice != null) {
      value = Text(
        formatMoney(_estimatedPrice),
        style: TextStyle(
          fontSize: uiScale.font(24),
          fontWeight: FontWeight.w900,
          color: isDark ? cs.onSurface : AppColors.textPrimary,
          letterSpacing: -0.5,
        ),
      );
    } else {
      value = TextButton.icon(
        style: TextButton.styleFrom(padding: EdgeInsets.zero),
        onPressed: _fetchEstimate,
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('Retry price'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Estimated Price',
            style: TextStyle(fontSize: uiScale.font(12), color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
        SizedBox(height: uiScale.gap(4)),
        value,
        if (_estimateError != null && !_isEstimating)
          Text(_estimateError!, maxLines: 2, style: TextStyle(fontSize: uiScale.font(10.5), color: cs.error)),
      ],
    );
  }

  Widget _paymentSelector(UIScale uiScale, ColorScheme cs, Color themeColor) {
    final bool walletOk = _walletCovers(_estimatedPrice);
    Widget chip(String value, String label, IconData icon, bool enabled, String? sub) {
      final bool selected = _payMethod == value;
      return Expanded(
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: InkWell(
            borderRadius: BorderRadius.circular(uiScale.radius(14)),
            onTap: !enabled || _isBooking
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    setState(() => _payMethod = value);
                  },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: EdgeInsets.symmetric(vertical: uiScale.inset(10), horizontal: uiScale.inset(10)),
              decoration: BoxDecoration(
                color: selected ? themeColor.withValues(alpha: 0.12) : cs.onSurface.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(uiScale.radius(14)),
                border: Border.all(color: selected ? themeColor : Colors.transparent, width: 2),
              ),
              child: Row(
                children: <Widget>[
                  Icon(icon, size: 20, color: selected ? themeColor : cs.onSurfaceVariant),
                  SizedBox(width: uiScale.gap(8)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
                        if (sub != null)
                          Text(sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: uiScale.font(10.5), color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: <Widget>[
        chip('cash', 'Cash', Icons.payments_outlined, true, 'Pay the rider'),
        SizedBox(width: uiScale.gap(10)),
        chip(
          'wallet',
          'Wallet',
          Icons.account_balance_wallet_outlined,
          walletOk,
          widget.walletBalance == null ? 'Unavailable' : formatMoney(widget.walletBalance),
        ),
      ],
    );
  }

  List<Widget> _sendMeFields(UIScale uiScale, ColorScheme cs) => <Widget>[
        Text('What do you need the rider to do?',
            style: TextStyle(fontSize: uiScale.font(13), fontWeight: FontWeight.bold, color: cs.onSurfaceVariant)),
        SizedBox(height: uiScale.gap(8)),
        TextField(
          controller: _instructionsCtrl,
          enabled: !_isBooking,
          maxLines: 4,
          minLines: 3,
          maxLength: 500,
          textCapitalization: TextCapitalization.sentences,
          style: TextStyle(fontSize: uiScale.font(14), fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            hintText: "e.g., Buy 2 loaves of bread at St Mary's plaza.",
            filled: true,
            fillColor: cs.onSurface.withValues(alpha: 0.05),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(uiScale.radius(16)), borderSide: BorderSide.none),
          ),
        ),
      ];

  List<Widget> _dispatchFields(UIScale uiScale, ColorScheme cs, bool isDark, Color themeColor) => <Widget>[
        Semantics(
          button: true,
          label: _packageImage == null ? 'Take package photo' : 'Retake package photo',
          child: GestureDetector(
            onTap: _pickImage,
            child: Container(
              width: double.infinity,
              height: uiScale.inset(100),
              decoration: BoxDecoration(
                color: isDark ? cs.surfaceContainerHighest.withValues(alpha: 0.5) : AppColors.mintBgLight.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(uiScale.radius(16)),
                border: Border.all(color: _packageImage == null ? cs.error.withValues(alpha: 0.5) : themeColor, width: 2),
                image: _packageImage != null
                    ? DecorationImage(image: ResizeImage(FileImage(_packageImage!), width: 720), fit: BoxFit.cover)
                    : null,
              ),
              child: _packageImage == null
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(Icons.camera_alt_rounded, color: themeColor),
                        SizedBox(height: uiScale.gap(4)),
                        Text('Tap to snap package photo',
                            style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurfaceVariant)),
                      ],
                    )
                  : null,
            ),
          ),
        ),
        SizedBox(height: uiScale.gap(16)),
        TextField(
          controller: _phoneCtrl,
          enabled: !_isBooking,
          keyboardType: TextInputType.phone,
          autofillHints: const <String>[AutofillHints.telephoneNumber],
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')),
            LengthLimitingTextInputFormatter(17),
          ],
          onChanged: (_) {
            if (_phoneError != null) setState(() => _phoneError = null);
          },
          style: TextStyle(fontSize: uiScale.font(16), fontWeight: FontWeight.w700),
          decoration: InputDecoration(
            hintText: 'Recipient phone (e.g. 0803 123 4567)',
            errorText: _phoneError,
            prefixIcon: Icon(Icons.contact_phone_rounded, color: themeColor),
            filled: true,
            fillColor: cs.onSurface.withValues(alpha: 0.05),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(uiScale.radius(16)), borderSide: BorderSide.none),
          ),
        ),
        SizedBox(height: uiScale.gap(16)),
        Row(
          children: <Widget>[
            for (final PackageSize size in PackageSize.values) ...<Widget>[
              if (size.index > 0) SizedBox(width: uiScale.gap(8)),
              Expanded(child: _buildSizeChip(uiScale, cs, themeColor, size)),
            ],
          ],
        ),
        SizedBox(height: uiScale.gap(16)),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text('Weight', style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurfaceVariant)),
            Text('${_weightKg.toStringAsFixed(_packageSize.stepKg < 1 ? 1 : 0)} kg',
                style: TextStyle(fontWeight: FontWeight.w900, color: themeColor)),
          ],
        ),
        SliderTheme(
          data: const SliderThemeData(
            trackHeight: 6,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 12),
            overlayShape: RoundSliderOverlayShape(overlayRadius: 24),
          ),
          child: Slider(
            value: _weightKg.clamp(_packageSize.minKg, _packageSize.maxKg).toDouble(),
            min: _packageSize.minKg,
            max: _packageSize.maxKg,
            divisions: _packageSize.divisions,
            activeColor: themeColor,
            inactiveColor: cs.onSurface.withValues(alpha: 0.1),
            onChanged: _isBooking ? null : (double val) => setState(() => _weightKg = val),
            onChangeEnd: (_) => _scheduleEstimate(),
          ),
        ),
      ];

  Widget _buildSizeChip(UIScale uiScale, ColorScheme cs, Color themeColor, PackageSize size) {
    final bool isSelected = _packageSize == size;
    return GestureDetector(
      onTap: _isBooking || isSelected
          ? null
          : () {
              HapticFeedback.lightImpact();
              setState(() {
                _packageSize = size;
                _weightKg = size.defaultKg;
              });
              _scheduleEstimate();
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(vertical: uiScale.inset(14)),
        decoration: BoxDecoration(
          color: isSelected ? themeColor.withValues(alpha: 0.12) : cs.onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(uiScale.radius(16)),
          border: Border.all(color: isSelected ? themeColor : Colors.transparent, width: 2.0),
        ),
        child: Column(
          children: <Widget>[
            Icon(size.icon, size: uiScale.icon(24), color: isSelected ? themeColor : cs.onSurfaceVariant),
            SizedBox(height: uiScale.gap(8)),
            Text(
              size.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: uiScale.font(11),
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected ? themeColor : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
