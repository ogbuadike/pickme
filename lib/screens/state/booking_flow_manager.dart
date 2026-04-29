// lib/screens/home/state/booking_flow_manager.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../api/api_client.dart';
import '../../../themes/app_theme.dart';
import '../../../ui/ui_scale.dart';
import '../../../utility/notification.dart';
import '../../../services/booking_controller.dart';
import '../trip_navigation_page.dart';

import 'home_models.dart';

class BookingFlowManager {
  static Future<void> initiateBooking({
    required BuildContext context,
    required ApiClient apiClient,
    required SharedPreferences prefs,
    required Map<String, dynamic>? user,
    required dynamic driver, // Expects RideNearbyDriver
    required dynamic offer,  // Expects RideOffer
    required LatLng pickup,
    required LatLng destination,
    required List<LatLng> stops,
    required List<String> dropOffTexts,
    required String pickupText,
    required String destinationText,
    required bool isCurrentPickup,
    required String rideType, // <--- ADDED
    String? instructions, // <--- ADDED
    required VoidCallback onStopRideMarket,
    required VoidCallback onStartRideMarket,
    required VoidCallback onResetTripState,
    required Function(String, LatLng) onDriverEngaged,
    required Function(BookingController) onBookingControllerCreated,
    required Function(StreamSubscription<dynamic>?) onSubscriptionCreated,
    required Future<Map<String, dynamic>?> Function() snapshotProvider,
    required Future<void> Function() onStartTrip,
    required Future<void> Function() onCancelTrip,
  }) async {
    final double userBalance = user != null
        ? double.tryParse(user['bal']?.toString() ?? user['user_bal']?.toString() ?? '0.0') ?? 0.0
        : 0.0;

    final double ridePrice = double.tryParse(offer.price.toString()) ?? 0.0;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    final String? selectedPaymentMethod = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) {
        final uiScale = UIScale.of(ctx);
        return SafeArea(
          child: Container(
            margin: EdgeInsets.all(uiScale.inset(16)),
            padding: EdgeInsets.all(uiScale.inset(20)),
            decoration: BoxDecoration(
              color: isDark ? cs.surface.withOpacity(0.95) : Colors.white.withOpacity(0.95),
              borderRadius: BorderRadius.circular(uiScale.radius(24)),
              border: Border.all(color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight, width: 1.5),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 30, offset: const Offset(0, 10))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                    child: Container(
                        width: 40, height: 4,
                        margin: EdgeInsets.only(bottom: uiScale.gap(16)),
                        decoration: BoxDecoration(color: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))
                    )
                ),
                Text(
                  'Select Payment Method',
                  style: TextStyle(fontSize: uiScale.font(20), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary),
                ),
                SizedBox(height: uiScale.gap(8)),
                Text('Total Fare: ${offer.currency} ${ridePrice.toStringAsFixed(2)}', style: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w600)),
                SizedBox(height: uiScale.gap(20)),

                Container(
                  decoration: BoxDecoration(
                    color: isDark ? cs.surfaceVariant.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(uiScale.radius(16)),
                    border: Border.all(color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight),
                  ),
                  child: ListTile(
                    contentPadding: EdgeInsets.symmetric(horizontal: uiScale.inset(16), vertical: uiScale.inset(4)),
                    leading: Container(
                      padding: EdgeInsets.all(uiScale.inset(8)),
                      decoration: BoxDecoration(color: (isDark ? cs.primary : Colors.blue).withOpacity(0.15), shape: BoxShape.circle),
                      child: Icon(Icons.account_balance_wallet_rounded, color: isDark ? cs.primary : Colors.blue),
                    ),
                    title: Text('Wallet (Automatic)', style: TextStyle(color: isDark ? cs.onSurface : AppColors.textPrimary, fontWeight: FontWeight.w800, fontSize: uiScale.font(15))),
                    subtitle: Text('Balance: ${offer.currency} ${userBalance.toStringAsFixed(2)}', style: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w600)),
                    onTap: () {
                      if (userBalance < ridePrice) {
                        showToastNotification(
                          context: ctx,
                          title: 'Insufficient Balance',
                          message: 'Please fund your wallet or select Cash.',
                          isSuccess: false,
                        );
                      } else {
                        Navigator.pop(ctx, 'wallet');
                      }
                    },
                  ),
                ),
                SizedBox(height: uiScale.gap(12)),

                Container(
                  decoration: BoxDecoration(
                    color: isDark ? cs.surfaceVariant.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(uiScale.radius(16)),
                    border: Border.all(color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight),
                  ),
                  child: ListTile(
                    contentPadding: EdgeInsets.symmetric(horizontal: uiScale.inset(16), vertical: uiScale.inset(4)),
                    leading: Container(
                      padding: EdgeInsets.all(uiScale.inset(8)),
                      decoration: BoxDecoration(color: Colors.green.withOpacity(0.15), shape: BoxShape.circle),
                      child: const Icon(Icons.attach_money_rounded, color: Colors.green),
                    ),
                    title: Text('Cash (Manual)', style: TextStyle(color: isDark ? cs.onSurface : AppColors.textPrimary, fontWeight: FontWeight.w800, fontSize: uiScale.font(15))),
                    subtitle: Text('Pay the driver directly', style: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w600)),
                    onTap: () {
                      Navigator.pop(ctx, 'cash');
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (selectedPaymentMethod == null) return;

    onStopRideMarket();

    final String riderId = prefs.getString('user_id') ?? user?['id']?.toString() ?? user?['user_id']?.toString() ?? 'guest';

    final booking = BookingController(apiClient);
    onBookingControllerCreated(booking);

    final String? rideId = await booking.startBooking(
      riderId: riderId,
      driverId: driver.id,
      offer: offer,
      pickup: pickup,
      destination: destination,
      pickupText: pickupText,
      destinationText: destinationText,
      stops: stops,
      payMethod: selectedPaymentMethod,
      rideType: rideType,
      instructions: instructions,
    );

    if (rideId == null || rideId.trim().isEmpty) {
      final BookingError? err = booking.lastError;
      final String kind = err?.kind.name ?? '';
      final int? status = err?.httpStatus;
      String detail = err?.message.trim() ?? '';
      String headline = 'Booking failed';

      if (kind == 'driverBusy' || status == 409) {
        headline = 'Driver unavailable';
        detail = detail.isNotEmpty ? detail : 'This driver is currently on another ride. Choose another driver.';
      } else if (kind == 'networkError') {
        headline = 'Network error';
        detail = detail.isNotEmpty ? detail : 'Check your connection and try again.';
      } else if (detail.isEmpty) {
        detail = 'Could not book this driver. Please try again.';
      }

      showToastNotification(context: context, title: headline, message: detail, isSuccess: false);
      onStartRideMarket();
      return;
    }

    onDriverEngaged(driver.id, LatLng(driver.lat, driver.lng));

    Stream<dynamic>? activeStream;
    try { activeStream = booking.updates; } catch (_) {}

    final sub = activeStream?.listen(
          (dynamic event) {
        String statusText = '';
        String msg = '';
        try { statusText = (event?.status ?? event?['status'] ?? '').toString().toLowerCase(); } catch (_) {}
        try { msg = (event?.displayMessage ?? event?['message'] ?? '').toString().trim(); } catch (_) {}

        if ((statusText.contains('fail') || statusText.contains('error')) && msg.isNotEmpty) {
          showToastNotification(context: context, title: 'Trip error', message: msg, isSuccess: false);
        }
      },
      cancelOnError: false,
    );

    onSubscriptionCreated(sub);

    final LatLng? initialRiderLocation = isCurrentPickup ? pickup : null;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripNavigationPage(
          args: TripNavigationArgs(
            userId: riderId,
            driverId: driver.id,
            tripId: rideId,
            pickup: pickup,
            destination: destination,
            dropOffs: stops,
            rideType: rideType,
            originText: pickupText,
            destinationText: destinationText,
            dropOffTexts: dropOffTexts,
            driverName: driver.name,
            vehicleType: driver.vehicleType,
            carPlate: driver.carPlate,
            rating: driver.rating,
            initialDriverLocation: LatLng(driver.lat, driver.lng),
            initialRiderLocation: initialRiderLocation,
            initialPhase: TripNavPhase.driverToPickup,
            bookingUpdates: activeStream,
            liveSnapshotProvider: snapshotProvider,
            onStartTrip: onStartTrip,
            onCancelTrip: onCancelTrip,
            role: TripNavigationRole.rider,
            tickEvery: const Duration(seconds: 2),
            routeMinGap: const Duration(seconds: 2),
            arrivalMeters: 35.0,
            routeMoveThresholdMeters: 8.0,
            autoFollowCamera: true,
            showStartTripButton: true,
            showCancelButton: true,
            showMetaCard: true,
            showDebugPanel: true,
            enableLivePickupTracking: isCurrentPickup,
            preserveStopOrder: true,
            autoCloseOnCancel: true,
          ),
        ),
      ),
    );

    onResetTripState();
  }
}