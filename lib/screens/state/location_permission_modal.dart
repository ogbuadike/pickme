// lib/screens/state/location_permission_modal.dart
//
// SINGLE, APP-WIDE LOCATION GATE
// ──────────────────────────────
// Every screen that needs the device location must go through
// [LocationPermissionModal.ensure] (or at least [LocationPermissionModal.show]).
// The gate guarantees:
//   • one prompt at a time – concurrent callers (e.g. several tabs of an
//     IndexedStack initialising together) share the same in-flight future and
//     never stack a second sheet / dialog;
//   • the prominent-disclosure sheet *is* the enabler UI (no extra AlertDialog
//     before the system dialog);
//   • `deniedForever` → app-settings deep-link, service off → location
//     settings deep-link;
//   • automatic (not user-triggered) prompts are shown at most once per kind
//     per app session — afterwards only an explicit user action (locate
//     button, booking) shows it again;
//   • the sheet closes itself when the underlying problem is solved while it
//     is open (permission granted via another dialog, service enabled from the
//     quick-settings shade, returning from Settings);
//   • screens that are not visible (hidden IndexedStack tabs, routes covered
//     by another page — TickerMode disabled) never show a sheet;
//   • [status] is a silent re-check for app-resume handlers: no UI, ever.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../themes/app_theme.dart';
import '../../ui/ui_scale.dart';

/// Outcome of a location gate check.
enum LocationGateStatus { granted, serviceDisabled, denied, deniedForever }

extension LocationGateStatusX on LocationGateStatus {
  bool get isGranted => this == LocationGateStatus.granted;
}

enum _GateSheetKind { disclosure, serviceOff, settings }

enum _SheetResult { accepted, dismissed, solved }

class LocationPermissionModal {
  LocationPermissionModal._();

  static Future<LocationGateStatus>? _ensureInFlight;
  static Future<LocationPermission>? _requestInFlight;
  static Future<bool>? _sheetInFlight;

  /// Kinds of automatic prompts already shown this session.
  static final Set<_GateSheetKind> _autoShown = <_GateSheetKind>{};

  /// True while a location sheet is on screen.
  static bool get isShowing => _sheetInFlight != null;

  // ───────────────────────────────────────────────────────────────────────────
  // Silent checks (never show UI)
  // ───────────────────────────────────────────────────────────────────────────

  /// Current state without any UI. Safe to call from `didChangeAppLifecycleState`.
  static Future<LocationGateStatus> status() async {
    try {
      if (!kIsWeb && !await Geolocator.isLocationServiceEnabled()) {
        return LocationGateStatus.serviceDisabled;
      }
      return _map(await Geolocator.checkPermission());
    } catch (_) {
      return LocationGateStatus.denied;
    }
  }

  /// Convenience: permission granted AND service enabled.
  static Future<bool> hasLocationAccess() async => (await status()).isGranted;

  static LocationGateStatus _map(LocationPermission p) {
    switch (p) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return LocationGateStatus.granted;
      case LocationPermission.deniedForever:
        return LocationGateStatus.deniedForever;
      case LocationPermission.denied:
      case LocationPermission.unableToDetermine:
        return LocationGateStatus.denied;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // The gate
  // ───────────────────────────────────────────────────────────────────────────

  /// Makes sure location can be used, prompting at most once.
  ///
  /// * [userTriggered] – true for explicit user actions (locate button…).
  ///   Automatic calls (initState, resume, service-status stream) never
  ///   re-show a prompt the user already dismissed during this session.
  /// * [title]/[message] – optional copy for the disclosure sheet.
  static Future<LocationGateStatus> ensure(
    BuildContext context, {
    bool userTriggered = false,
    String? title,
    String? message,
  }) {
    final existing = _ensureInFlight;
    if (existing != null) return existing;
    final f = _ensureImpl(context, userTriggered: userTriggered, title: title, message: message);
    _ensureInFlight = f;
    f.whenComplete(() {
      if (identical(_ensureInFlight, f)) _ensureInFlight = null;
    }).ignore();
    return f;
  }

  static Future<LocationGateStatus> _ensureImpl(
    BuildContext context, {
    required bool userTriggered,
    String? title,
    String? message,
  }) async {
    var st = await status();
    if (st.isGranted || !context.mounted) return st;
    // Never prompt from an invisible screen (e.g. a hidden IndexedStack tab
    // initialising in the background) unless the user explicitly asked.
    if (!userTriggered && !TickerMode.of(context)) return st;

    bool allowed(_GateSheetKind k) => userTriggered || !_autoShown.contains(k);
    // Automatic prompts are shown at most once per kind per session, whatever
    // the outcome — otherwise "Open settings" → back without granting would
    // re-pop the sheet on every resume.
    void shown(_GateSheetKind k) {
      if (!userTriggered) _autoShown.add(k);
    }

    switch (st) {
      case LocationGateStatus.granted:
        return st;

      case LocationGateStatus.serviceDisabled:
        if (!allowed(_GateSheetKind.serviceOff)) return st;
        final ok = await _present(
          context,
          kind: _GateSheetKind.serviceOff,
          title: 'Turn on location',
          message: 'Location services are off. Turn them on so Pick Me can find nearby drivers and set an accurate pickup.',
        );
        shown(_GateSheetKind.serviceOff);
        st = await status();
        // Service is on now but permission may still be missing: continue once
        // (only if the user is actively engaging, to avoid a second auto prompt).
        if (st == LocationGateStatus.denied && ok && context.mounted) {
          return _requestWithDisclosure(context, userTriggered: true, title: title, message: message);
        }
        return st;

      case LocationGateStatus.denied:
        if (!allowed(_GateSheetKind.disclosure)) return st;
        return _requestWithDisclosure(context, userTriggered: userTriggered, title: title, message: message);

      case LocationGateStatus.deniedForever:
        if (!allowed(_GateSheetKind.settings)) return st;
        await _present(
          context,
          kind: _GateSheetKind.settings,
          title: 'Allow location in Settings',
          message: 'Location access is blocked for Pick Me. Open Settings › Permissions › Location and choose "While using the app".',
        );
        shown(_GateSheetKind.settings);
        return status();
    }
  }

  static Future<LocationGateStatus> _requestWithDisclosure(
    BuildContext context, {
    required bool userTriggered,
    String? title,
    String? message,
  }) async {
    final ok = await _present(
      context,
      kind: _GateSheetKind.disclosure,
      title: title ?? 'Allow location access',
      message: message ??
          'Pick Me uses your location to match you with nearby drivers, set accurate pickups and share live trip progress while you use the app.',
    );
    if (!userTriggered) _autoShown.add(_GateSheetKind.disclosure);
    if (!ok) return status();
    // The sheet may have auto-closed because permission got granted elsewhere.
    final now = await status();
    if (now != LocationGateStatus.denied) return now;
    final p = await requestSystemPermission();
    return _map(p);
  }

  /// Single-flight wrapper around [Geolocator.requestPermission]. Other screens
  /// should call this instead of `Geolocator.requestPermission()` directly.
  static Future<LocationPermission> requestSystemPermission() {
    final existing = _requestInFlight;
    if (existing != null) return existing;
    final f = Geolocator.requestPermission().catchError((_) => LocationPermission.denied);
    _requestInFlight = f;
    f.whenComplete(() {
      if (identical(_requestInFlight, f)) _requestInFlight = null;
    }).ignore();
    return f;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Legacy API (kept source-compatible)
  // ───────────────────────────────────────────────────────────────────────────

  /// Displays the premium location sheet. De-duplicated: if a location sheet
  /// is already visible this returns when that one closes and does not open a
  /// second one. The primary button deep-links to location settings
  /// ([isServiceIssue]) or the app's settings page.
  static Future<void> show({
    required BuildContext context,
    required String title,
    required String message,
    required bool isServiceIssue,
  }) async {
    await _present(
      context,
      kind: isServiceIssue ? _GateSheetKind.serviceOff : _GateSheetKind.settings,
      title: title,
      message: message,
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Sheet presentation
  // ───────────────────────────────────────────────────────────────────────────

  /// Returns true when the user accepted (primary button) or the problem got
  /// solved while the sheet was open. Never opens two sheets.
  static Future<bool> _present(
    BuildContext context, {
    required _GateSheetKind kind,
    required String title,
    required String message,
  }) async {
    final open = _sheetInFlight;
    if (open != null) {
      await open;
      return false; // Someone else's sheet handled the interaction.
    }
    if (!context.mounted) return false;
    // Hidden IndexedStack tabs / covered routes must not pop UI.
    if (!TickerMode.of(context)) return false;

    final completer = Completer<bool>();
    _sheetInFlight = completer.future;
    try {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final result = await showModalBottomSheet<_SheetResult>(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: isDark ? 0.70 : 0.50),
        builder: (ctx) => _LocationGateSheet(kind: kind, title: title, message: message),
      );
      final accepted = result == _SheetResult.accepted || result == _SheetResult.solved;
      if (result == _SheetResult.accepted && kind != _GateSheetKind.disclosure) {
        // Deep-link after the sheet is gone so nothing stale remains on return.
        try {
          if (kind == _GateSheetKind.serviceOff) {
            await Geolocator.openLocationSettings();
          } else {
            await Geolocator.openAppSettings();
          }
        } catch (_) {}
      }
      completer.complete(accepted);
      return accepted;
    } catch (_) {
      if (!completer.isCompleted) completer.complete(false);
      return false;
    } finally {
      _sheetInFlight = null;
    }
  }
}

class _LocationGateSheet extends StatefulWidget {
  final _GateSheetKind kind;
  final String title;
  final String message;
  const _LocationGateSheet({required this.kind, required this.title, required this.message});

  @override
  State<_LocationGateSheet> createState() => _LocationGateSheetState();
}

class _LocationGateSheetState extends State<_LocationGateSheet> with WidgetsBindingObserver {
  bool _closing = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Location services can be toggled from the quick-settings shade without
    // a lifecycle change: poll lightly while the sheet is open.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _autoCloseIfSolved());
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _autoCloseIfSolved();
  }

  Future<void> _autoCloseIfSolved() async {
    if (_closing) return;
    final st = await LocationPermissionModal.status();
    final solved = switch (widget.kind) {
      _GateSheetKind.serviceOff => st != LocationGateStatus.serviceDisabled,
      _GateSheetKind.disclosure || _GateSheetKind.settings => st.isGranted,
    };
    if (solved && mounted && !_closing) {
      _closing = true;
      Navigator.of(context).pop(_SheetResult.solved);
    }
  }

  void _close(bool accepted) {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(accepted ? _SheetResult.accepted : _SheetResult.dismissed);
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;
    final accent = isDark ? cs.primary : AppColors.primary;
    final isService = widget.kind == _GateSheetKind.serviceOff;

    final primaryLabel = switch (widget.kind) {
      _GateSheetKind.disclosure => 'Allow location',
      _GateSheetKind.serviceOff => 'Turn on location',
      _GateSheetKind.settings => 'Open settings',
    };

    return SafeArea(
      child: Container(
        margin: EdgeInsets.all(uiScale.inset(16)),
        decoration: BoxDecoration(
          color: isDark ? cs.surface : Colors.white,
          borderRadius: BorderRadius.circular(uiScale.radius(28)),
          border: Border.all(
            color: isDark ? cs.outline.withValues(alpha: 0.5) : AppColors.primary.withValues(alpha: 0.2),
            width: 1.5,
          ),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 40, offset: const Offset(0, 15))],
        ),
        child: Padding(
          padding: EdgeInsets.all(uiScale.inset(24)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: uiScale.inset(48),
                height: uiScale.inset(5),
                decoration: BoxDecoration(
                  color: isDark ? cs.onSurfaceVariant.withValues(alpha: 0.5) : Colors.black.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(uiScale.radius(10)),
                ),
              ),
              SizedBox(height: uiScale.gap(28)),
              Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: uiScale.inset(90),
                    height: uiScale.inset(90),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withValues(alpha: 0.12)),
                  ),
                  Container(
                    width: uiScale.inset(65),
                    height: uiScale.inset(65),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: isDark ? [cs.primary, cs.secondary] : [AppColors.primary, AppColors.secondary],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.4), blurRadius: 18, offset: const Offset(0, 8))],
                    ),
                    child: Icon(
                      isService ? Icons.gps_off_rounded : Icons.my_location_rounded,
                      color: isDark ? cs.onPrimary : Colors.white,
                      size: uiScale.icon(32),
                    ),
                  ),
                ],
              ),
              SizedBox(height: uiScale.gap(22)),
              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: uiScale.font(22),
                  fontWeight: FontWeight.w900,
                  color: isDark ? cs.onSurface : AppColors.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              SizedBox(height: uiScale.gap(10)),
              Text(
                widget.message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: uiScale.font(14),
                  fontWeight: FontWeight.w600,
                  color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
              SizedBox(height: uiScale.gap(24)),
              Container(
                padding: EdgeInsets.all(uiScale.inset(16)),
                decoration: BoxDecoration(
                  color: isDark ? cs.surfaceContainerHighest.withValues(alpha: 0.3) : AppColors.mintBgLight.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(uiScale.radius(16)),
                  border: Border.all(color: isDark ? cs.outline : AppColors.primary.withValues(alpha: 0.05)),
                ),
                child: Column(
                  children: [
                    _bullet(uiScale, isDark, cs, Icons.flash_on_rounded, 'Find nearby drivers instantly'),
                    SizedBox(height: uiScale.gap(12)),
                    _bullet(uiScale, isDark, cs, Icons.timer_rounded, 'Get highly accurate ETAs'),
                    SizedBox(height: uiScale.gap(12)),
                    _bullet(uiScale, isDark, cs, Icons.shield_rounded, 'Share live trips for safety'),
                  ],
                ),
              ),
              SizedBox(height: uiScale.gap(30)),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => _close(false),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(vertical: uiScale.inset(16)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(16))),
                      ),
                      child: Text(
                        'Not now',
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
                      onPressed: () => _close(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: isDark ? cs.onPrimary : Colors.white,
                        elevation: 0,
                        padding: EdgeInsets.symmetric(vertical: uiScale.inset(16)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(uiScale.radius(16))),
                      ),
                      child: Text(
                        primaryLabel,
                        style: TextStyle(fontSize: uiScale.font(15), fontWeight: FontWeight.w900, letterSpacing: 0.3),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _bullet(UIScale uiScale, bool isDark, ColorScheme cs, IconData icon, String text) {
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
              color: isDark ? cs.onSurface : AppColors.textPrimary.withValues(alpha: 0.8),
            ),
          ),
        ),
      ],
    );
  }
}
