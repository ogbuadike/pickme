import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';

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
///
///

/// A premium, full-screen dialog with an animated, delayed close button.
///
/// **Usage Examples:**
///
/// **1. Text-Only Alert (e.g., Important Announcement)**
/// ```dart
/// showDialog(
///   context: context,
///   barrierDismissible: false,
///   builder: (context) => const DelayedCloseButtonDialog(
///     title: 'System Update',
///     message: 'We are performing routine maintenance. Some features may be offline.',
///     textColor: Colors.white,
///     countdown: Duration(seconds: 3), // Faster 3-second close
///   ),
/// );
/// ```
///
/// **2. Promotional Image / Asset (e.g., Holiday Promo)**
/// ```dart
/// showDialog(
///   context: context,
///   barrierDismissible: false,
///   useSafeArea: false, // Allows image to fill the notch/status bar area
///   builder: (context) => const DelayedCloseButtonDialog(
///     title: 'Flash Sale!',
///     message: 'Get 20% off your next ride today.',
///     textColor: Colors.white,
///     image: AssetImage('images/promo_banner.png'), // Using local asset
///     countdown: Duration(seconds: 5),
///   ),
/// );
/// ```
///
/// **3. Network Image (e.g., Dynamic Ad from backend)**
/// ```dart
/// showDialog(
///   context: context,
///   barrierDismissible: false,
///   useSafeArea: false,
///   builder: (context) => const DelayedCloseButtonDialog(
///     textColor: Colors.white,
///     image: NetworkImage('[https://yourdomain.com/ad_image.jpg](https://yourdomain.com/ad_image.jpg)'),
///     // Omit title and message if the image already contains the text
///   ),
/// );
/// ```

// 1. The Global Helper Function
void showInAppNotification(
    BuildContext context, {
      required String title,
      required String message,
      String? imageUrl,
    }) {
  showDialog(
    context: context,
    barrierDismissible: false, // Prevents closing by tapping outside
    useSafeArea: false, // Allows the dialog to go edge-to-edge if there's an image
    builder: (BuildContext context) {
      return DelayedCloseButtonDialog(
        title: title,
        message: message,
        // Since the background overlay is black, we force white text for contrast
        textColor: Colors.white,
        image: imageUrl != null ? NetworkImage(imageUrl) : null,
        countdown: const Duration(seconds: 5),
      );
    },
  );
}

// 2. The Main Stateful Widget
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
    // Using AnimationController for native 60/120fps performance instead of Timer
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

    return PopScope(
      canPop: false, // Modern replacement for WillPopScope
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Background Layer
            if (widget.image != null)
              Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Image(
                    image: widget.image!,
                    width: screen.width,
                    height: screen.height,
                  ),
                ),
              )
            else
              Container(color: Colors.black.withOpacity(0.85)),

            // Text Content Overlay
            Positioned.fill(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.45),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.title != null)
                          Text(
                            widget.title!,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              color: widget.textColor,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        if (widget.message != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            widget.message!,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: widget.textColor,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Top Right Controls (Progress + Close Button)
            Positioned(
              top: 40, // Increased slightly to clear SafeArea/Notch
              right: 20,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 40,
                    height: 40,
                    // AnimatedBuilder isolates rebuilds strictly to the ring
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (context, child) {
                        return CircularProgressIndicator(
                          value: _controller.value,
                          strokeWidth: 3.5,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                          backgroundColor: Colors.white24,
                        );
                      },
                    ),
                  ),
                  if (_isButtonEnabled)
                    Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.red,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 20),
                        padding: EdgeInsets.zero, // Centers icon perfectly
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
      final Uint8List png = bytes.buffer.asUint8List();

      // TODO: Save/share png with image_gallery_saver / share_plus if you enable those packages.
      // This placeholder keeps UX responsive without adding deps here.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Receipt ready (plug in saver/share to persist).')),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to capture receipt')),
        );
      }
    }
  }

  // Title adapted to ride/dispatch/payments
  String _title(Map d) {
    final service = '${d['service'] ?? d['type'] ?? ''}'.toLowerCase();
    if (service.contains('ride')) return 'Ride booked';
    if (service.contains('dispatch') || service.contains('package')) return 'Dispatch scheduled';
    return (d['status'] ?? 'Payment Successful').toString();
  }

  // Status color (success/info/warn/error) via ColorScheme
  Color _statusColor(ColorScheme cs, String status) {
    final s = status.toLowerCase();
    if (s.contains('complete') || s.contains('success')) return cs.primary;
    if (s.contains('pending') || s.contains('processing')) return cs.tertiary;
    if (s.contains('cancel')) return cs.error;
    return cs.primary;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final d = widget.transactionData;

    final amount = d['amount'];
    final currency = d['currency'] ?? '₦';
    final status = (d['status'] ?? 'Completed').toString();
    final title = _title(d);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            key: _captureKey,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.9,
                maxHeight: MediaQuery.of(context).size.height * 0.8,
              ),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: cs.surfaceVariant),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(.10),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    _headerStripe(context, title, status),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                      child: _detailsTable(context, currency, amount),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                      child: _rideSpecificSection(context),
                    ),
                    _brandFooter(context),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (widget.showSaveButton)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _saveAsImage,
                  icon: const Icon(Icons.save_alt_rounded, size: 18),
                  label: const Text('Save receipt'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Close'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _headerStripe(BuildContext context, String title, String status) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final color = _statusColor(cs, status);

    Widget safeLottie() {
      try {
        return Lottie.asset(
          'assets/lottie/success.json',
          height: 68,
          repeat: true,
        );
      } catch (_) {
        return Icon(Icons.verified_rounded, size: 48, color: cs.onPrimary);
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color, color.withOpacity(.85)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        children: [
          safeLottie(),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tt.titleLarge?.copyWith(color: cs.onPrimary, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            status,
            style: tt.labelLarge?.copyWith(color: cs.onPrimary.withOpacity(.9)),
          ),
        ],
      ),
    );
  }

  Widget _detailsTable(BuildContext context, String currency, dynamic amount) {
    final d = widget.transactionData;
    return Column(
      children: [
        _row(context, 'Date', _fmtDate(DateTime.now())),
        _row(context, 'Reference', '${d['reference'] ?? d['ref'] ?? ''}', copyable: true),
        _row(context, 'Amount', '$currency${numberFormat(amount ?? 0)}'),
        _row(context, 'Service', '${d['service'] ?? d['type'] ?? 'Ride'}'),
        _row(context, 'Recipient', '${d['recipient'] ?? d['driver_name'] ?? '—'}'),
        const Divider(height: 20),
        _row(context, 'Status', '${d['status'] ?? 'Completed'}', highlight: true),
      ],
    );
  }

  Widget _rideSpecificSection(BuildContext context) {
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
        _sectionTitle(context, 'Ride details'),
        const SizedBox(height: 6),
        if (pickup.toString().isNotEmpty) _row(context, 'Pickup', pickup.toString()),
        if (drop.toString().isNotEmpty) _row(context, 'Drop-off', drop.toString()),
        if (driver.toString().isNotEmpty) _row(context, 'Driver', driver.toString()),
        if (plate.toString().isNotEmpty) _row(context, 'Plate', plate.toString()),
        if (eta.toString().isNotEmpty) _row(context, 'ETA', eta.toString()),
        if (dist.toString().isNotEmpty) _row(context, 'Distance', dist.toString()),
      ],
    );
  }

  Widget _brandFooter(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.surfaceVariant)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(color: cs.primary.withOpacity(.25), blurRadius: 18, offset: const Offset(0, 6)),
              ],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.directions_car_rounded, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Text('Pick Me', style: tt.labelLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
            ]),
          ),
          const SizedBox(height: 8),
          Text(
            '${widget.transactionData['reference'] ?? ''}',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String t) {
    final tt = Theme.of(context).textTheme;
    return Text(t, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800));
  }

  Widget _row(BuildContext context, String label, String value,
      {bool highlight = false, bool copyable = false}) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    final labelStyle = tt.labelMedium?.copyWith(color: cs.onSurfaceVariant);
    final valueStyle = tt.bodyMedium?.copyWith(
      color: highlight ? _statusColor(cs, value) : cs.onSurface,
      fontWeight: highlight ? FontWeight.w800 : FontWeight.w500,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text(label, style: labelStyle, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Expanded(
            flex: 6,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Flexible(child: Text(value, style: valueStyle, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right)),
                if (copyable)
                  IconButton(
                    icon: const Icon(Icons.content_copy_rounded, size: 16),
                    color: cs.onSurfaceVariant,
                    tooltip: 'Copy',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: value));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied to clipboard')),
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

/// ----------------------------------------------------------------------------
/// Notifications
void showRetryNotification(BuildContext context, String message, {VoidCallback? onRetry}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      action: onRetry != null ? SnackBarAction(label: 'Retry', onPressed: onRetry) : null,
      duration: const Duration(seconds: 12),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

void showAdvancedNotification({
  required BuildContext context,
  String? title,
  String? message,
  bool isSuccess = true,
}) {
  final cs = Theme.of(context).colorScheme;
  final bg = isSuccess ? cs.primary : cs.error;
  final fg = isSuccess ? cs.onPrimary : cs.onError;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: title != null
            ? Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: fg))
            : null,
        content: message != null
            ? Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: fg))
            : null,
        actions: [
          IconButton(
            icon: Icon(Icons.close_rounded, color: fg),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    ),
  );
}

void showBannerNotification({
  required BuildContext context,
  String? title,
  String? message,
  bool isSuccess = true,
}) {
  final cs = Theme.of(context).colorScheme;
  final bg = isSuccess ? cs.primary : cs.error;
  final fg = isSuccess ? cs.onPrimary : cs.onError;

  final banner = MaterialBanner(
    backgroundColor: bg,
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: fg, fontWeight: FontWeight.w800)),
        if (message != null)
          Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: fg)),
      ],
    ),
    actions: [
      IconButton(
        icon: Icon(Icons.close_rounded, color: fg),
        onPressed: () => ScaffoldMessenger.of(context).hideCurrentMaterialBanner(),
      ),
    ],
  );

  ScaffoldMessenger.of(context)
    ..hideCurrentMaterialBanner()
    ..showMaterialBanner(banner);

  Future.delayed(const Duration(seconds: 5), () {
    ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
  });
}

void showToastNotification({
  required BuildContext context,
  String? title,
  String? message,
  bool isSuccess = true,
}) {
  final cs = Theme.of(context).colorScheme;
  final bg = isSuccess ? cs.primary : cs.error;
  final fg = isSuccess ? cs.onPrimary : cs.onError;

  final sb = SnackBar(
    backgroundColor: bg,
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 5),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null)
          Text(
            '$title:',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w800,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(top: 2.0),
            child:
            Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: fg), overflow: TextOverflow.ellipsis),
          ),
      ],
    ),
  );

  ScaffoldMessenger.of(context).showSnackBar(sb);
}

void showFullScreenOverlayNotification({
  required BuildContext context,
  String? title,
  String? message,
  bool isSuccess = true,
}) {
  final cs = Theme.of(context).colorScheme;
  final bg = isSuccess ? cs.primary : cs.error;
  final fg = isSuccess ? cs.onPrimary : cs.onError;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (title != null)
                Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: fg, fontWeight: FontWeight.w800)),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: fg), textAlign: TextAlign.center),
              ],
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(backgroundColor: fg, foregroundColor: bg),
                child: const Text('Dismiss'),
              ),
            ],
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
  final cs = Theme.of(context).colorScheme;
  final textColor = isSuccess ? cs.onPrimary : cs.onError;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => DelayedCloseButtonDialog( // <-- Fixed the underscore here!
      image: image,
      title: title,
      message: message,
      textColor: textColor,
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