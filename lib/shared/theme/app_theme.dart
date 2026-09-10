import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Colour palette pulled from the Homebound pitch deck
/// (deep navy background, gold accent, status colours for delay risk).
class AppColors {
  static const Color background = Color(0xFF0F1330);
  static const Color surface = Color(0xFF1A1F45);
  static const Color surfaceAlt = Color(0xFF20265A);
  static const Color navy = Color(0xFF161A3C);
  static const Color gold = Color(0xFFF0B93A);
  static const Color textPrimary = Color(0xFFF5F6FA);
  static const Color textSecondary = Color(0xFF9BA0C2);
  static const Color success = Color(0xFF3BD671);
  static const Color warning = Color(0xFFF0B93A);
  static const Color critical = Color(0xFFEF5D5D);
  static const Color divider = Color(0xFF2B3163);
}

class AppTheme {
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    );

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      primaryColor: AppColors.gold,
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.gold,
        secondary: AppColors.gold,
        surface: AppColors.surface,
        error: AppColors.critical,
      ),
      textTheme: textTheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.gold, width: 1.5),
        ),
        hintStyle: const TextStyle(color: AppColors.textSecondary),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.gold,
          foregroundColor: AppColors.navy,
          minimumSize: const Size.fromHeight(52),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          minimumSize: const Size.fromHeight(52),
          side: const BorderSide(color: AppColors.divider),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerColor: AppColors.divider,
    );
  }
}

/// Departure proximity helper used across the transit screens.
enum ServiceUrgency { onTime, closingSoon, critical }

extension ServiceUrgencyColor on ServiceUrgency {
  Color get color {
    switch (this) {
      case ServiceUrgency.onTime:
        return AppColors.success;
      case ServiceUrgency.closingSoon:
        return AppColors.warning;
      case ServiceUrgency.critical:
        return AppColors.critical;
    }
  }

  String get label {
    switch (this) {
      case ServiceUrgency.onTime:
        return 'SCHEDULED';
      case ServiceUrgency.closingSoon:
        return 'ARRIVING SOON';
      case ServiceUrgency.critical:
        return 'DUE SOON';
    }
  }
}
