// lib/themes/app_theme.dart
import 'package:flutter/material.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// PALETTE (modern names + full compatibility aliases)
/// ─────────────────────────────────────────────────────────────────────────
class AppColors {
  // Brand core
  static const Color primary   = Color(0xFF319863); // emerald
  static const Color secondary = Color(0xFF59A981); // soft green
  static const Color deep      = Color(0xFF172B20); // deep green ink

  // Surfaces
  static const Color mintBg       = Color(0xFFD8EBE2);
  static const Color mintBgLight  = Color(0xFFE4F0EA);
  static const Color offWhite     = Color(0xFFF8FEFA);
  static const Color surface      = Color(0xFFFFFFFF);

  // Neutrals
  static const Color outline      = Color(0xFF93A89D);
  static const Color textPrimary  = deep;
  static const Color textSecondary= Color(0xFF5C615D);

  // Status
  static const Color error        = Color(0xFFD64545);
  static const Color success      = Color(0xFF2FA96E);

  // Helpers
  static Color darken(Color c, [double amount = .08]) {
    final h = HSLColor.fromColor(c);
    return h.withLightness((h.lightness - amount).clamp(0.0, 1.0)).toColor();
  }

  static Color lighten(Color c, [double amount = .12]) {
    final h = HSLColor.fromColor(c);
    return h.withLightness((h.lightness + amount).clamp(0.0, 1.0)).toColor();
  }

  // ── Compatibility aliases used by existing screens ─────────────────────
  static const Color primaryColor     = primary;
  static const Color secondaryColor   = secondary;
  static const Color accentColor      = secondary;        // highlight/cta
  static const Color darkerColor      = Color(0xFF1E5138); // deep emerald
  static const Color darkColor        = Color(0xFF2A6A49); // darker emerald
  static const Color darkBackground   = Color(0xFF0B1410);
  static const Color backgroundColor  = offWhite;
  static const Color goldenColor      = Color(0xFFD4AF37);

  static const Color errorColor       = error;
  static const Color onErrorColor     = Colors.white;

  static const Color successColor     = success;
  static const Color onSuccessColor   = Colors.white;
  static const Color lightSuccessColor= Color(0x3363C78F); // translucent success
  static const Color solidSuccessColor= Color(0xFF29A329);

  static const Color textOnLightPrimary   = textPrimary;
  static const Color textOnLightSecondary = textSecondary;
  static const Color textOnLightAccent    = darkerColor;

  static const Color textOnDarkPrimary    = Colors.white;
  static const Color textOnDarkSecondary  = Color(0xFFDDE7E2);
  static const Color textOnDarkAccent     = secondary;
}

/// ─────────────────────────────────────────────────────────────────────────
/// TYPOGRAPHY (modern + legacy symbols)
/// ─────────────────────────────────────────────────────────────────────────
class AppTextStyles {
  // Material text theme generator (used by ThemeData)
  static TextTheme textTheme(Color onSurface, Color secondary) => TextTheme(
    displayLarge:   TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: onSurface),
    displayMedium:  TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: onSurface),
    headlineMedium: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: onSurface),
    titleLarge:     TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: onSurface),
    titleMedium:    TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: onSurface),
    bodyLarge:      TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: onSurface),
    bodyMedium:     TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: secondary),
    labelLarge:     TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: onSurface),
    labelMedium:    TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: secondary),
  );

  // Legacy constants referenced around the app (kept stable)
  static const TextStyle heading  = TextStyle(
    fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.textOnDarkPrimary,
  );
  static const TextStyle heading2 = TextStyle(
    fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textOnLightPrimary,
  );
  static const TextStyle subHeading = TextStyle(
    fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textOnLightSecondary,
  );
  static const TextStyle bodyText = TextStyle(
    fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.textOnLightSecondary,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textOnLightAccent, fontStyle: FontStyle.italic,
  );

  // ✅ Add this so widgets can safely fall back to AppTextStyles.labelLarge
  static const TextStyle labelLarge = TextStyle(
    fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary,
  );

  // Dark-side legacy
  static const TextStyle darkHeading = TextStyle(
    fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.textOnDarkPrimary,
  );
  static const TextStyle darkSubHeading = TextStyle(
    fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textOnDarkSecondary,
  );
  static const TextStyle darkBodyText = TextStyle(
    fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.textOnDarkSecondary,
  );
}

/// ─────────────────────────────────────────────────────────────────────────
/// SHAPES
/// ─────────────────────────────────────────────────────────────────────────
class AppShape {
  static const double radius = 16;
  static RoundedRectangleBorder rounded([double r = radius]) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));
  static const StadiumBorder pill = StadiumBorder();
  static final BorderSide outline = BorderSide(color: AppColors.outline, width: 1);
}

/// ─────────────────────────────────────────────────────────────────────────
/// COLOR SCHEMES
/// ─────────────────────────────────────────────────────────────────────────
final ColorScheme _lightScheme = const ColorScheme(
  brightness: Brightness.light,
  primary: AppColors.primary,
  onPrimary: Colors.white,
  primaryContainer: AppColors.mintBgLight,
  onPrimaryContainer: AppColors.deep,
  secondary: AppColors.secondary,
  onSecondary: Colors.white,
  secondaryContainer: AppColors.mintBg,
  onSecondaryContainer: AppColors.deep,
  tertiary: AppColors.success,
  onTertiary: Colors.white,
  tertiaryContainer: Color(0xFFE6F5EE),
  onTertiaryContainer: AppColors.deep,
  error: AppColors.error,
  onError: Colors.white,
  errorContainer: Color(0xFFFCE8E8),
  onErrorContainer: Color(0xFF5E1212),
  surface: AppColors.surface,
  onSurface: AppColors.textPrimary,
  surfaceVariant: AppColors.mintBgLight,
  onSurfaceVariant: AppColors.textSecondary,
  outline: AppColors.outline,
  shadow: Colors.black,
  scrim: Colors.black,
  inverseSurface: AppColors.deep,
  onInverseSurface: Colors.white,
  inversePrimary: Color(0xFF6BC39B),
  background: AppColors.offWhite,
  onBackground: AppColors.textPrimary,
);

final ColorScheme _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: const Color(0xFF6BC39B),
  onPrimary: AppColors.deep,
  primaryContainer: AppColors.deep,
  onPrimaryContainer: Colors.white,
  secondary: const Color(0xFF74C5A4),
  onSecondary: AppColors.deep,
  secondaryContainer: AppColors.darken(AppColors.deep, .05),
  onSecondaryContainer: Colors.white,
  tertiary: const Color(0xFF63C78F),
  onTertiary: AppColors.deep,
  tertiaryContainer: AppColors.deep,
  onTertiaryContainer: Colors.white,
  error: const Color(0xFFFFB3B3),
  onError: AppColors.deep,
  errorContainer: const Color(0xFF5E1212),
  onErrorContainer: Colors.white,
  surface: const Color(0xFF0F1713),
  onSurface: Colors.white,
  surfaceVariant: const Color(0xFF13211B),
  onSurfaceVariant: const Color(0xFFDDE7E2),
  outline: const Color(0xFF6F8B80),
  shadow: Colors.black,
  scrim: Colors.black,
  inverseSurface: AppColors.offWhite,
  onInverseSurface: AppColors.deep,
  inversePrimary: AppColors.primary,
  background: const Color(0xFF0B1410),
  onBackground: Colors.white,
);

/// ─────────────────────────────────────────────────────────────────────────
/// THEME (uses CardThemeData to match your SDK)
/// ─────────────────────────────────────────────────────────────────────────
class AppTheme {
  static ThemeData light() {
    final cs = _lightScheme;

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.background,
      splashFactory: InkRipple.splashFactory,
      textTheme: AppTextStyles.textTheme(cs.onSurface, AppColors.textSecondary),

      appBarTheme: AppBarTheme(
        elevation: 0,
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: AppTextStyles.textTheme(cs.onSurface, AppColors.textSecondary).titleLarge,
      ),

      cardTheme: CardThemeData(
        color: cs.surface,
        elevation: 1.5,
        margin: EdgeInsets.zero,
        shape: AppShape.rounded(),
        shadowColor: Colors.black.withOpacity(.06),
        surfaceTintColor: Colors.transparent,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          shape: const MaterialStatePropertyAll(AppShape.pill),
          padding: const MaterialStatePropertyAll(EdgeInsets.symmetric(horizontal: 20, vertical: 14)),
          elevation: const MaterialStatePropertyAll(0),
          backgroundColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.disabled)) {
              return AppColors.lighten(cs.primary, .30);
            }
            return cs.primary;
          }),
          foregroundColor: const MaterialStatePropertyAll(Colors.white),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          shape: const MaterialStatePropertyAll(AppShape.pill),
          padding: const MaterialStatePropertyAll(EdgeInsets.symmetric(horizontal: 20, vertical: 14)),
          backgroundColor: MaterialStatePropertyAll(AppColors.secondary),
          foregroundColor: const MaterialStatePropertyAll(Colors.white),
          elevation: const MaterialStatePropertyAll(0),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          shape: const MaterialStatePropertyAll(AppShape.pill),
          side: MaterialStatePropertyAll(AppShape.outline),
          padding: const MaterialStatePropertyAll(EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
          foregroundColor: MaterialStatePropertyAll(cs.primary),
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        shape: AppShape.rounded(18),
        elevation: 0,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: TextStyle(color: AppColors.textSecondary),
        labelStyle: TextStyle(color: AppColors.textSecondary),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.mintBgLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.error, width: 2),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: AppColors.mintBgLight,
        selectedColor: cs.primary,
        disabledColor: AppColors.mintBgLight,
        labelStyle: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
        secondaryLabelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: const StadiumBorder(),
        side: BorderSide.none,
      ),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        type: BottomNavigationBarType.fixed,
        backgroundColor: cs.surface,
        selectedItemColor: cs.primary,
        unselectedItemColor: AppColors.textSecondary,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
        elevation: 0,
      ),

      dividerTheme: DividerThemeData(color: AppColors.mintBgLight, thickness: 1),
      iconTheme: IconThemeData(color: cs.onSurface),
    );
  }

  static ThemeData dark() {
    final cs = _darkScheme;

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.background,
      textTheme: AppTextStyles.textTheme(cs.onSurface, const Color(0xFFDDE7E2)),

      appBarTheme: AppBarTheme(
        elevation: 0,
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
      ),

      cardTheme: CardThemeData(
        color: cs.surface,
        elevation: 0.5,
        margin: EdgeInsets.zero,
        shape: AppShape.rounded(),
        shadowColor: Colors.black.withOpacity(.25),
        surfaceTintColor: Colors.transparent,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          shape: const MaterialStatePropertyAll(AppShape.pill),
          padding: const MaterialStatePropertyAll(EdgeInsets.symmetric(horizontal: 20, vertical: 14)),
          elevation: const MaterialStatePropertyAll(0),
          backgroundColor: MaterialStatePropertyAll(cs.primary),
          foregroundColor: MaterialStatePropertyAll(cs.onPrimary),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          shape: const MaterialStatePropertyAll(AppShape.pill),
          backgroundColor: MaterialStatePropertyAll(cs.secondary),
          foregroundColor: MaterialStatePropertyAll(cs.onSecondary),
          elevation: const MaterialStatePropertyAll(0),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          shape: const MaterialStatePropertyAll(AppShape.pill),
          side: MaterialStatePropertyAll(BorderSide(color: AppColors.lighten(cs.outline, .2))),
          foregroundColor: MaterialStatePropertyAll(cs.inversePrimary),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.darken(cs.surface, .04),
        hintStyle: TextStyle(color: AppColors.lighten(cs.onSurface, .35)),
        labelStyle: TextStyle(color: AppColors.lighten(cs.onSurface, .35)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.darken(cs.surfaceVariant, .06)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.primary, width: 2),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: AppColors.darken(cs.surfaceVariant, .05),
        selectedColor: cs.primary,
        disabledColor: AppColors.darken(cs.surfaceVariant, .05),
        labelStyle: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w700),
        secondaryLabelStyle: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: const StadiumBorder(),
        side: BorderSide.none,
      ),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: cs.surface,
        selectedItemColor: cs.primary,
        unselectedItemColor: AppColors.lighten(cs.onSurface, .35),
        elevation: 0,
      ),

      dividerTheme: DividerThemeData(color: AppColors.darken(cs.surfaceVariant, .1), thickness: 1),
      iconTheme: IconThemeData(color: cs.onSurface),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────
/// IMAGE STYLES
/// ─────────────────────────────────────────────────────────────────────────
class AppImageStyles {
  static const double borderRadius = 16.0;
  static BorderRadius get defaultBorderRadius => BorderRadius.circular(borderRadius);

  static BoxDecoration roundedImage({required ImageProvider image}) {
    return BoxDecoration(
      borderRadius: defaultBorderRadius,
      border: Border.all(color: AppColors.mintBgLight, width: 1),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.06),
          offset: const Offset(0, 6),
          blurRadius: 14,
        ),
      ],
      image: DecorationImage(image: image, fit: BoxFit.cover),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────
/// Curved gradient background used across splash/hero sections.
/// ─────────────────────────────────────────────────────────────────────────
class CurvedBackgroundPainter extends CustomPainter {
  final Color topColor;
  final Color bottomColor;

  CurvedBackgroundPainter({
    this.topColor = AppColors.primary,
    this.bottomColor = AppColors.secondary,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [AppColors.primary, AppColors.secondary],
      ).createShader(rect);
    canvas.drawRect(rect, bg);

    final wave = Path()
      ..moveTo(0, size.height * .60)
      ..quadraticBezierTo(size.width * .25, size.height * .50, size.width * .5, size.height * .62)
      ..quadraticBezierTo(size.width * .75, size.height * .74, size.width, size.height * .66)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final wavePaint = Paint()..color = Colors.white.withOpacity(.08);
    canvas.drawPath(wave, wavePaint);
  }

  @override
  bool shouldRepaint(covariant CurvedBackgroundPainter old) =>
      old.topColor != topColor || old.bottomColor != bottomColor;
}
