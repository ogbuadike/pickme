// lib/screens/home/state/location_permission_modal.dart
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../themes/app_theme.dart';
import '../../../ui/ui_scale.dart';

class LocationPermissionModal {
  /// Displays an ultra-premium, OLED-optimized permission bottom sheet.
  /// Can be called from anywhere in the app.
  static Future<void> show({
    required BuildContext context,
    required String title,
    required String message,
    required bool isServiceIssue,
  }) async {
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(isDark ? 0.75 : 0.55),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Container(
            margin: EdgeInsets.all(uiScale.inset(16)),
            decoration: BoxDecoration(
              color: isDark ? cs.surface.withOpacity(0.85) : Colors.white.withOpacity(0.90),
              borderRadius: BorderRadius.circular(uiScale.radius(28)),
              border: Border.all(
                color: isDark ? cs.outline.withOpacity(0.5) : AppColors.primary.withOpacity(0.2),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 40,
                  offset: const Offset(0, 15),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(uiScale.radius(28)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Padding(
                  padding: EdgeInsets.all(uiScale.inset(24)),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: uiScale.inset(48),
                        height: uiScale.inset(5),
                        decoration: BoxDecoration(
                          color: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : Colors.black.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(uiScale.radius(10)),
                        ),
                      ),
                      SizedBox(height: uiScale.gap(32)),

                      Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: uiScale.inset(90),
                            height: uiScale.inset(90),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.12),
                            ),
                          ),
                          Container(
                            width: uiScale.inset(65),
                            height: uiScale.inset(65),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: isDark
                                    ? [cs.primary, cs.secondary]
                                    : [AppColors.primary, AppColors.secondary],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: (isDark ? cs.primary : AppColors.primary).withOpacity(0.4),
                                  blurRadius: 18,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Icon(
                              isServiceIssue ? Icons.gps_off_rounded : Icons.my_location_rounded,
                              color: isDark ? cs.onPrimary : Colors.white,
                              size: uiScale.icon(32),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: uiScale.gap(24)),

                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: uiScale.font(24),
                          fontWeight: FontWeight.w900,
                          color: isDark ? cs.onSurface : AppColors.textPrimary,
                          letterSpacing: -0.5,
                        ),
                      ),
                      SizedBox(height: uiScale.gap(12)),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: uiScale.font(14),
                          fontWeight: FontWeight.w600,
                          color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                          height: 1.4,
                        ),
                      ),

                      SizedBox(height: uiScale.gap(28)),

                      Container(
                        padding: EdgeInsets.all(uiScale.inset(16)),
                        decoration: BoxDecoration(
                          color: isDark ? cs.surfaceVariant.withOpacity(0.3) : AppColors.mintBgLight.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(uiScale.radius(16)),
                          border: Border.all(color: isDark ? cs.outline : AppColors.primary.withOpacity(0.05)),
                        ),
                        child: Column(
                          children: [
                            _buildInfoBullet(uiScale, isDark, cs, Icons.flash_on_rounded, 'Find nearby drivers instantly'),
                            SizedBox(height: uiScale.gap(12)),
                            _buildInfoBullet(uiScale, isDark, cs, Icons.timer_rounded, 'Get highly accurate ETAs'),
                            SizedBox(height: uiScale.gap(12)),
                            _buildInfoBullet(uiScale, isDark, cs, Icons.shield_rounded, 'Share live trips for safety'),
                          ],
                        ),
                      ),

                      SizedBox(height: uiScale.gap(36)),

                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.symmetric(vertical: uiScale.inset(16)),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(16))),
                              ),
                              child: Text(
                                'Not Now',
                                style: TextStyle(
                                  fontSize: uiScale.font(15),
                                  fontWeight: FontWeight.w800,
                                  color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: uiScale.gap(12)),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              onPressed: () async {
                                Navigator.of(ctx).pop();
                                if (isServiceIssue) {
                                  await Geolocator.openLocationSettings();
                                } else {
                                  await Geolocator.openAppSettings();
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isDark ? cs.primary : AppColors.primary,
                                foregroundColor: isDark ? cs.onPrimary : Colors.white,
                                elevation: 0,
                                padding: EdgeInsets.symmetric(vertical: uiScale.inset(16)),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(16))),
                              ),
                              child: Text(
                                'Enable Location',
                                style: TextStyle(
                                  fontSize: uiScale.font(15),
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.5,
                                ),
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
        );
      },
    );
  }

  static Widget _buildInfoBullet(UIScale uiScale, bool isDark, ColorScheme cs, IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: uiScale.icon(18), color: isDark ? cs.primary : AppColors.primary),
        SizedBox(width: uiScale.gap(12)),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: uiScale.font(13),
              fontWeight: FontWeight.w700,
              color: isDark ? cs.onSurface : AppColors.textPrimary.withOpacity(0.8),
            ),
          ),
        ),
      ],
    );
  }
}