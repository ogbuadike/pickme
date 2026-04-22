import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';

import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';

/// ----------------------------------------------------------------------------
/// Compact, robust number formatting (no intl dependency)
/// Accepts num/String; returns "1,234.56"
String numberFormat(dynamic number) {
  final double parsed = switch (number) {
    int n => n.toDouble(),
    double n => n,
    String s => double.tryParse(s) ?? 0.0,
    _ => 0.0,
  };
  final parts = parsed.toStringAsFixed(2).split('.');
  final intPart = parts[0];
  final fracPart = parts[1];
  final buf = StringBuffer();
  for (int i = 0; i < intPart.length; i++) {
    final idxFromEnd = intPart.length - i;
    buf.write(intPart[i]);
    final isThousandBoundary = idxFromEnd > 1 && (idxFromEnd - 1) % 3 == 0;
    if (isThousandBoundary) buf.write(',');
  }
  return '${buf.toString()}.$fracPart';
}

/// ----------------------------------------------------------------------------
/// Full-screen image dialog with a delayed close button (default 5s)
///
void showInAppNotification(
    BuildContext context, {
      required String title,
      required String message,
      String? imageUrl,
    }) {
  showDialog(
    context: context,
    barrierDismissible: false,
    useSafeArea: false,
    builder: (BuildContext context) {
      return DelayedCloseButtonDialog(
        title: title,
        message: message,
        textColor: Colors.white,
        image: imageUrl != null ? NetworkImage(imageUrl) : null,
        countdown: const Duration(seconds: 5),
      );
    },
  );
}

class DelayedCloseButtonDialog extends StatefulWidget {
  final ImageProvider? image;
  final String? title;
  final String? message;
  final Color textColor;
  final Duration countdown;

  const DelayedCloseButtonDialog({
    super.key,
    this.image,
    this.title,
    this.message,
    required this.textColor,
    this.countdown = const Duration(seconds: 5),
  });

  @override
  State<DelayedCloseButtonDialog> createState() => _DelayedCloseButtonDialogState();
}

class _DelayedCloseButtonDialogState extends State<DelayedCloseButtonDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isButtonEnabled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.countdown,
    )..reverse(from: 1.0).then((_) {
      if (mounted) {
        setState(() {
          _isButtonEnabled = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.of(context).size;
    final uiScale = UIScale.of(context);

    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.image != null)
              Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: Image(
                    image: widget.image!,
                    width: screen.width,
                    height: screen.height,
                  ),
                ),
              )
            else
              Container(color: Colors.black.withOpacity(0.85)),

            Positioned.fill(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: uiScale.tablet ? 520 : 400),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(uiScale.radius(24)),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        margin: EdgeInsets.symmetric(horizontal: uiScale.inset(20)),
                        padding: EdgeInsets.all(uiScale.inset(24)),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.45),
                          borderRadius: BorderRadius.circular(uiScale.radius(24)),
                          border: Border.all(color: Colors.white.withOpacity(0.15), width: 1.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.3),
                              blurRadius: 30,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.title != null)
                              Text(
                                widget.title!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: uiScale.font(22),
                                  color: widget.textColor,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            if (widget.message != null) ...[
                              SizedBox(height: uiScale.gap(12)),
                              Text(
                                widget.message!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: uiScale.font(15),
                                  color: widget.textColor.withOpacity(0.9),
                                  fontWeight: FontWeight.w500,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            Positioned(
              top: MediaQuery.of(context).padding.top + uiScale.inset(16),
              right: uiScale.inset(20),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: uiScale.icon(44),
                    height: uiScale.icon(44),
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (context, child) {
                        return CircularProgressIndicator(
                          value: _controller.value,
                          strokeWidth: 3.5,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                          backgroundColor: Colors.white.withOpacity(0.15),
                        );
                      },
                    ),
                  ),
                  if (_isButtonEnabled)
                    Container(
                      width: uiScale.icon(44),
                      height: uiScale.icon(44),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.15),
                      ),
                      child: IconButton(
                        icon: Icon(Icons.close_rounded, color: Colors.white, size: uiScale.icon(22)),
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(context).pop(),
                        tooltip: 'Close',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ----------------------------------------------------------------------------
/// Ride/Payment Receipt (dialog)
class TransactionReceipt extends StatefulWidget {
  final Map<String, dynamic> transactionData;
  final bool showSaveButton;

  const TransactionReceipt({
    Key? key,
    required this.transactionData,
    this.showSaveButton = true,
  }) : super(key: key);

  @override
  State<TransactionReceipt> createState() => _TransactionReceiptState();
}

class _TransactionReceiptState extends State<TransactionReceipt> {
  final GlobalKey _captureKey = GlobalKey();

  Future<void> _saveAsImage() async {
    try {
      final boundary = _captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 3.0);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw Exception('No bytes');

      showToastNotification(
          context: context,
          title: 'Saved',
          message: 'Receipt ready to share.',
          isSuccess: true
      );
    } catch (_) {
      if (mounted) {
        showToastNotification(
            context: context,
            title: 'Error',
            message: 'Failed to capture receipt.',
            isSuccess: false
        );
      }
    }
  }

  String _title(Map d) {
    final service = '${d['service'] ?? d['type'] ?? ''}'.toLowerCase();
    if (service.contains('ride')) return 'Ride Booked';
    if (service.contains('dispatch') || service.contains('package')) return 'Dispatch Scheduled';
    return (d['status'] ?? 'Payment Successful').toString();
  }

  Color _statusColor(ColorScheme cs, String status, bool isDark) {
    final s = status.toLowerCase();
    if (s.contains('complete') || s.contains('success')) return isDark ? cs.primary : const Color(0xFF1E8E3E);
    if (s.contains('pending') || s.contains('processing')) return const Color(0xFFB8860B);
    if (s.contains('cancel') || s.contains('fail')) return cs.error;
    return isDark ? cs.primary : const Color(0xFF1E8E3E);
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;
    final d = widget.transactionData;

    final amount = d['amount'];
    final currency = d['currency'] ?? '₦';
    final status = (d['status'] ?? 'Completed').toString();
    final title = _title(d);

    return BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.symmetric(horizontal: uiScale.inset(16), vertical: uiScale.inset(24)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              key: _captureKey,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: uiScale.tablet ? 460 : uiScale.width * 0.9,
                  maxHeight: uiScale.height * 0.8,
                ),
                decoration: BoxDecoration(
                  color: isDark ? cs.surfaceVariant.withOpacity(0.95) : Colors.white,
                  borderRadius: BorderRadius.circular(uiScale.radius(24)),
                  border: Border.all(color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(isDark ? 0.5 : 0.15),
                      blurRadius: 30,
                      offset: const Offset(0, 15),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    children: [
                      _headerStripe(context, title, status, isDark, cs, uiScale),
                      Padding(
                        padding: EdgeInsets.fromLTRB(uiScale.inset(20), uiScale.inset(20), uiScale.inset(20), uiScale.inset(8)),
                        child: _detailsTable(context, currency, amount, isDark, cs, uiScale),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(uiScale.inset(20), uiScale.inset(8), uiScale.inset(20), uiScale.inset(20)),
                        child: _rideSpecificSection(context, isDark, cs, uiScale),
                      ),
                      _brandFooter(context, isDark, cs, uiScale),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: uiScale.gap(20)),
            if (widget.showSaveButton)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: _saveAsImage,
                    icon: Icon(Icons.save_alt_rounded, size: uiScale.icon(18)),
                    label: Text('Save Receipt', style: TextStyle(fontWeight: FontWeight.w800, fontSize: uiScale.font(14))),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDark ? cs.primary : AppColors.primary,
                      foregroundColor: isDark ? cs.onPrimary : Colors.white,
                      elevation: 0,
                      padding: EdgeInsets.symmetric(horizontal: uiScale.inset(20), vertical: uiScale.inset(14)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(30))),
                    ),
                  ),
                  SizedBox(width: uiScale.gap(12)),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded, size: uiScale.icon(18)),
                    label: Text('Close', style: TextStyle(fontWeight: FontWeight.w800, fontSize: uiScale.font(14))),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: isDark ? cs.onSurface : AppColors.textPrimary,
                      side: BorderSide(color: isDark ? cs.outline : AppColors.mintBgLight, width: 2),
                      backgroundColor: isDark ? cs.surface : Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: uiScale.inset(20), vertical: uiScale.inset(14)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(30))),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _headerStripe(BuildContext context, String title, String status, bool isDark, ColorScheme cs, UIScale uiScale) {
    final color = _statusColor(cs, status, isDark);

    Widget safeLottie() {
      try {
        return Lottie.asset(
          'assets/lottie/success.json',
          height: uiScale.icon(72),
          repeat: true,
        );
      } catch (_) {
        return Container(
          padding: EdgeInsets.all(uiScale.inset(12)),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), shape: BoxShape.circle),
          child: Icon(Icons.verified_rounded, size: uiScale.icon(42), color: Colors.white),
        );
      }
    }

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(uiScale.inset(20), uiScale.inset(24), uiScale.inset(20), uiScale.inset(20)),
      decoration: BoxDecoration(
        color: color,
        gradient: LinearGradient(
          colors: [color, color.withOpacity(0.85)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        children: [
          safeLottie(),
          SizedBox(height: uiScale.gap(12)),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white, fontSize: uiScale.font(20), fontWeight: FontWeight.w900, letterSpacing: -0.5),
          ),
          SizedBox(height: uiScale.gap(4)),
          Container(
            padding: EdgeInsets.symmetric(horizontal: uiScale.inset(10), vertical: uiScale.inset(4)),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.15),
              borderRadius: BorderRadius.circular(uiScale.radius(8)),
            ),
            child: Text(
              status.toUpperCase(),
              style: TextStyle(color: Colors.white.withOpacity(0.95), fontSize: uiScale.font(11), fontWeight: FontWeight.w800, letterSpacing: 1.0),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailsTable(BuildContext context, String currency, dynamic amount, bool isDark, ColorScheme cs, UIScale uiScale) {
    final d = widget.transactionData;
    return Column(
      children: [
        _row(context, 'Date', _fmtDate(DateTime.now()), isDark, cs, uiScale),
        _row(context, 'Reference', '${d['reference'] ?? d['ref'] ?? ''}', isDark, cs, uiScale, copyable: true),
        _row(context, 'Amount', '$currency${numberFormat(amount ?? 0)}', isDark, cs, uiScale),
        _row(context, 'Service', '${d['service'] ?? d['type'] ?? 'Ride'}', isDark, cs, uiScale),
        _row(context, 'Recipient', '${d['recipient'] ?? d['driver_name'] ?? '—'}', isDark, cs, uiScale),
        Padding(
          padding: EdgeInsets.symmetric(vertical: uiScale.inset(12)),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Flex(
                direction: Axis.horizontal,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate((constraints.constrainWidth() / 8).floor(), (index) {
                  return SizedBox(
                    width: 4, height: 1,
                    child: DecoratedBox(decoration: BoxDecoration(color: isDark ? cs.outline.withOpacity(0.4) : AppColors.mintBgLight)),
                  );
                }),
              );
            },
          ),
        ),
        _row(context, 'Status', '${d['status'] ?? 'Completed'}', isDark, cs, uiScale, highlight: true),
      ],
    );
  }

  Widget _rideSpecificSection(BuildContext context, bool isDark, ColorScheme cs, UIScale uiScale) {
    final d = widget.transactionData;
    final pickup = d['pickup'] ?? d['from'] ?? '';
    final drop = d['dropoff'] ?? d['to'] ?? '';
    final plate = d['driver_plate'] ?? '';
    final driver = d['driver_name'] ?? '';
    final eta = d['eta'] ?? '';
    final dist = d['distance'] ?? '';

    if ([pickup, drop, plate, driver, eta, dist].every((e) => (e ?? '').toString().isEmpty)) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, 'Ride Details', isDark, cs, uiScale),
        SizedBox(height: uiScale.gap(12)),
        if (pickup.toString().isNotEmpty) _row(context, 'Pickup', pickup.toString(), isDark, cs, uiScale),
        if (drop.toString().isNotEmpty) _row(context, 'Drop-off', drop.toString(), isDark, cs, uiScale),
        if (driver.toString().isNotEmpty) _row(context, 'Driver', driver.toString(), isDark, cs, uiScale),
        if (plate.toString().isNotEmpty) _row(context, 'Plate', plate.toString(), isDark, cs, uiScale),
        if (eta.toString().isNotEmpty) _row(context, 'ETA', eta.toString(), isDark, cs, uiScale),
        if (dist.toString().isNotEmpty) _row(context, 'Distance', dist.toString(), isDark, cs, uiScale),
      ],
    );
  }

  Widget _brandFooter(BuildContext context, bool isDark, ColorScheme cs, UIScale uiScale) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(uiScale.inset(20), uiScale.inset(16), uiScale.inset(20), uiScale.inset(20)),
      decoration: BoxDecoration(
        color: isDark ? cs.surface : AppColors.surface,
        border: Border(top: BorderSide(color: isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.5))),
      ),
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: uiScale.inset(16), vertical: uiScale.inset(10)),
            decoration: BoxDecoration(
              color: isDark ? cs.primary.withOpacity(0.15) : AppColors.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(uiScale.radius(30)),
              border: Border.all(color: isDark ? cs.primary.withOpacity(0.3) : AppColors.primary.withOpacity(0.2)),
            ),
            child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.directions_car_rounded, size: uiScale.icon(18), color: isDark ? cs.primary : AppColors.primary),
                  SizedBox(width: uiScale.gap(8)),
                  Text('Pick Me', style: TextStyle(color: isDark ? cs.primary : AppColors.primary, fontWeight: FontWeight.w900, fontSize: uiScale.font(14))),
                ]
            ),
          ),
          SizedBox(height: uiScale.gap(12)),
          Text(
            'Ref: ${widget.transactionData['reference'] ?? 'N/A'}',
            style: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontSize: uiScale.font(11), fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String t, bool isDark, ColorScheme cs, UIScale uiScale) {
    return Text(t, style: TextStyle(fontSize: uiScale.font(16), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary));
  }

  Widget _row(BuildContext context, String label, String value, bool isDark, ColorScheme cs, UIScale uiScale,
      {bool highlight = false, bool copyable = false}) {

    final labelStyle = TextStyle(fontSize: uiScale.font(13), fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary);
    final valueStyle = TextStyle(
      fontSize: uiScale.font(14),
      color: highlight ? _statusColor(cs, value, isDark) : (isDark ? cs.onSurface : AppColors.textPrimary),
      fontWeight: highlight ? FontWeight.w900 : FontWeight.w700,
    );

    return Padding(
      padding: EdgeInsets.symmetric(vertical: uiScale.inset(6)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 4, child: Text(label, style: labelStyle)),
          SizedBox(width: uiScale.gap(12)),
          Expanded(
            flex: 6,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(child: Text(value, style: valueStyle, textAlign: TextAlign.right)),
                if (copyable) ...[
                  SizedBox(width: uiScale.gap(6)),
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: value));
                      showToastNotification(context: context, title: 'Copied', message: 'Reference copied to clipboard', isSuccess: true);
                    },
                    child: Icon(Icons.content_copy_rounded, size: uiScale.icon(16), color: isDark ? cs.primary : AppColors.primary),
                  ),
                ]
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}/${dt.year} • ${two(dt.hour)}:${two(dt.minute)}';
  }
}

/// ----------------------------------------------------------------------------
/// Notifications

// FIXED: Grabs ScaffoldMessenger state before async gaps to prevent the ancestor crash!
void showRetryNotification(BuildContext context, String message, {VoidCallback? onRetry}) {
  final sm = ScaffoldMessenger.of(context);
  final uiScale = UIScale.of(context);
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final cs = Theme.of(context).colorScheme;

  sm.showSnackBar(
    SnackBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 12),
      content: Container(
        padding: EdgeInsets.symmetric(horizontal: uiScale.inset(16), vertical: uiScale.inset(12)),
        decoration: BoxDecoration(
          color: isDark ? cs.surfaceVariant : Colors.black87,
          borderRadius: BorderRadius.circular(uiScale.radius(16)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))],
          border: Border.all(color: isDark ? cs.outline.withOpacity(0.5) : Colors.transparent),
        ),
        child: Row(
          children: [
            Icon(Icons.wifi_off_rounded, color: Colors.orangeAccent, size: uiScale.icon(20)),
            SizedBox(width: uiScale.gap(12)),
            Expanded(child: Text(message, style: TextStyle(color: Colors.white, fontSize: uiScale.font(13), fontWeight: FontWeight.w600))),
            if (onRetry != null)
              TextButton(
                onPressed: () {
                  sm.hideCurrentSnackBar();
                  onRetry();
                },
                style: TextButton.styleFrom(
                  foregroundColor: isDark ? cs.primary : AppColors.primary,
                  padding: EdgeInsets.symmetric(horizontal: uiScale.inset(12)),
                  visualDensity: VisualDensity.compact,
                ),
                child: Text('RETRY', style: TextStyle(fontWeight: FontWeight.w800, fontSize: uiScale.font(12))),
              ),
          ],
        ),
      ),
    ),
  );
}

void showAdvancedNotification({
  required BuildContext context,
  String? title,
  String? message,
  bool isSuccess = true,
}) {
  final uiScale = UIScale.of(context);
  final theme = Theme.of(context);
  final isDark = theme.brightness == Brightness.dark;
  final cs = theme.colorScheme;

  final accentColor = isSuccess ? (isDark ? cs.primary : AppColors.primary) : cs.error;
  final icon = isSuccess ? Icons.check_circle_rounded : Icons.error_rounded;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.symmetric(horizontal: uiScale.inset(20)),
          child: Container(
            constraints: BoxConstraints(maxWidth: uiScale.tablet ? 400 : double.infinity),
            decoration: BoxDecoration(
              color: isDark ? cs.surface : Colors.white,
              borderRadius: BorderRadius.circular(uiScale.radius(24)),
              border: Border.all(color: isDark ? cs.outline : AppColors.mintBgLight, width: 1.5),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, 10))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(vertical: uiScale.inset(24)),
                  decoration: BoxDecoration(
                    color: accentColor.withOpacity(0.1),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(uiScale.radius(22))),
                  ),
                  child: Center(
                    child: Container(
                      padding: EdgeInsets.all(uiScale.inset(16)),
                      decoration: BoxDecoration(color: accentColor.withOpacity(0.2), shape: BoxShape.circle),
                      child: Icon(icon, size: uiScale.icon(48), color: accentColor),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(uiScale.inset(24)),
                  child: Column(
                    children: [
                      if (title != null)
                        Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: uiScale.font(20), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary)),
                      if (message != null) ...[
                        SizedBox(height: uiScale.gap(12)),
                        Text(message, textAlign: TextAlign.center, style: TextStyle(fontSize: uiScale.font(14), fontWeight: FontWeight.w500, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, height: 1.4)),
                      ],
                      SizedBox(height: uiScale.gap(24)),
                      SizedBox(
                        width: double.infinity,
                        height: uiScale.buttonHeight,
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: accentColor,
                            foregroundColor: isDark ? cs.onPrimary : Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(30))),
                          ),
                          child: Text('Okay', style: TextStyle(fontWeight: FontWeight.w800, fontSize: uiScale.font(16))),
                        ),
                      ),
                    ],
                  ),
                )
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

// FIXED: Grabs ScaffoldMessenger state before async gaps to prevent the ancestor crash!
void showBannerNotification({
  required BuildContext context,
  String? title,
  String? message,
  bool isSuccess = true,
}) {
  final sm = ScaffoldMessenger.of(context);
  final uiScale = UIScale.of(context);
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final cs = Theme.of(context).colorScheme;

  final bgColor = isSuccess ? (isDark ? cs.primary.withOpacity(0.15) : AppColors.primary.withOpacity(0.1)) : cs.error.withOpacity(0.1);
  final fgColor = isSuccess ? (isDark ? cs.primary : AppColors.primary) : cs.error;
  final icon = isSuccess ? Icons.info_outline_rounded : Icons.warning_amber_rounded;

  final banner = MaterialBanner(
    backgroundColor: Colors.transparent,
    elevation: 0,
    dividerColor: Colors.transparent,
    content: Container(
      margin: EdgeInsets.only(top: MediaQuery.of(context).padding.top + uiScale.inset(8)),
      padding: EdgeInsets.all(uiScale.inset(16)),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceVariant : Colors.white,
        borderRadius: BorderRadius.circular(uiScale.radius(16)),
        border: Border.all(color: fgColor.withOpacity(0.5), width: 1.5),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(uiScale.inset(8)),
            decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
            child: Icon(icon, color: fgColor, size: uiScale.icon(20)),
          ),
          SizedBox(width: uiScale.gap(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: uiScale.font(15), color: isDark ? cs.onSurface : AppColors.textPrimary)),
                if (message != null) ...[
                  SizedBox(height: uiScale.gap(4)),
                  Text(message, style: TextStyle(fontWeight: FontWeight.w500, fontSize: uiScale.font(13), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
                ]
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      IconButton(
        icon: Icon(Icons.close_rounded, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
        onPressed: () => sm.hideCurrentMaterialBanner(),
      ),
    ],
  );

  sm
    ..hideCurrentMaterialBanner()
    ..showMaterialBanner(banner);

  Future.delayed(const Duration(seconds: 4), () {
    sm.hideCurrentMaterialBanner();
  });
}


// FIXED: Entirely new logic using OverlayEntry so it pops from the TOP seamlessly!
void showToastNotification({
  required BuildContext context,
  String? title,
  String? message,
  bool isSuccess = true,
}) {
  final overlayState = Overlay.of(context);
  late OverlayEntry overlayEntry;

  overlayEntry = OverlayEntry(
    builder: (context) => _TopToastOverlay(
      title: title,
      message: message,
      isSuccess: isSuccess,
      onDismiss: () => overlayEntry.remove(),
    ),
  );

  overlayState.insert(overlayEntry);
}

class _TopToastOverlay extends StatefulWidget {
  final String? title;
  final String? message;
  final bool isSuccess;
  final VoidCallback onDismiss;

  const _TopToastOverlay({
    this.title,
    this.message,
    required this.isSuccess,
    required this.onDismiss,
  });

  @override
  State<_TopToastOverlay> createState() => _TopToastOverlayState();
}

class _TopToastOverlayState extends State<_TopToastOverlay> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _offsetAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _offsetAnim = Tween<Offset>(begin: const Offset(0, -1.2), end: Offset.zero)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    _controller.forward();

    // Auto-dismiss after 4 seconds
    Future.delayed(const Duration(seconds: 4), () async {
      if (mounted) {
        await _controller.reverse();
        widget.onDismiss();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;

    final accentColor = widget.isSuccess ? (isDark ? cs.primary : AppColors.primary) : cs.error;
    final icon = widget.isSuccess ? Icons.check_circle_rounded : Icons.error_outline_rounded;

    return Positioned(
      top: MediaQuery.of(context).padding.top + uiScale.inset(10),
      left: uiScale.inset(16),
      right: uiScale.inset(16),
      child: Material(
        color: Colors.transparent,
        child: SlideTransition(
          position: _offsetAnim,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: uiScale.inset(16), vertical: uiScale.inset(14)),
            decoration: BoxDecoration(
              color: isDark ? cs.surfaceVariant.withOpacity(0.95) : Colors.white.withOpacity(0.95),
              borderRadius: BorderRadius.circular(uiScale.radius(16)),
              border: Border.all(color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight, width: 1),
              boxShadow: [
                BoxShadow(color: accentColor.withOpacity(0.15), blurRadius: 15, offset: const Offset(0, 5)),
                BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 2)),
              ],
            ),
            child: Row(
              children: [
                Icon(icon, color: accentColor, size: uiScale.icon(24)),
                SizedBox(width: uiScale.gap(14)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.title != null)
                        Text(widget.title!, style: TextStyle(fontWeight: FontWeight.w800, fontSize: uiScale.font(14), color: isDark ? cs.onSurface : AppColors.textPrimary)),
                      if (widget.message != null)
                        Text(widget.message!, style: TextStyle(fontWeight: FontWeight.w500, fontSize: uiScale.font(12), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
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
}

void showFullScreenOverlayNotification({
  required BuildContext context,
  String? title,
  String? message,
  bool isSuccess = true,
}) {
  final uiScale = UIScale.of(context);
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final cs = Theme.of(context).colorScheme;

  final accentColor = isSuccess ? (isDark ? cs.primary : AppColors.primary) : cs.error;
  final icon = isSuccess ? Icons.check_circle_rounded : Icons.error_rounded;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: EdgeInsets.symmetric(horizontal: uiScale.inset(24)),
          child: Container(
            constraints: BoxConstraints(maxWidth: uiScale.tablet ? 400 : double.infinity),
            padding: EdgeInsets.all(uiScale.inset(32)),
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(uiScale.radius(32)),
              boxShadow: [BoxShadow(color: accentColor.withOpacity(0.4), blurRadius: 30, offset: const Offset(0, 15))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: EdgeInsets.all(uiScale.inset(16)),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), shape: BoxShape.circle),
                  child: Icon(icon, size: uiScale.icon(64), color: Colors.white),
                ),
                SizedBox(height: uiScale.gap(24)),
                if (title != null)
                  Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: uiScale.font(24), fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.5)),
                if (message != null) ...[
                  SizedBox(height: uiScale.gap(12)),
                  Text(message, textAlign: TextAlign.center, style: TextStyle(fontSize: uiScale.font(15), fontWeight: FontWeight.w600, color: Colors.white.withOpacity(0.9), height: 1.4)),
                ],
                SizedBox(height: uiScale.gap(32)),
                SizedBox(
                  width: double.infinity,
                  height: uiScale.buttonHeight,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: accentColor,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(30))),
                    ),
                    child: Text('Dismiss', style: TextStyle(fontWeight: FontWeight.w900, fontSize: uiScale.font(16))),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void showFullScreenImageNotification({
  required BuildContext context,
  String? title,
  String? message,
  ImageProvider? image,
  bool isSuccess = true,
  Duration countdown = const Duration(seconds: 5),
}) {
  showDialog(
    context: context,
    barrierDismissible: false,
    useSafeArea: false,
    builder: (_) => DelayedCloseButtonDialog(
      image: image,
      title: title,
      message: message,
      textColor: Colors.white,
      countdown: countdown,
    ),
  );
}

void showTransactionSuccessNotification({
  required BuildContext context,
  required Map<String, dynamic> transactionData,
}) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => TransactionReceipt(transactionData: transactionData),
  );
}