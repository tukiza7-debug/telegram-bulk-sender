import 'package:flutter/material.dart';

/// Typography built on the bundled Inter family.
/// Scale follows Material 3 sizes with tighter tracking on display roles.
abstract final class AppTypography {
  static const String fontFamily = 'Inter';

  static TextTheme textTheme(ColorScheme scheme) {
    final Color headline = scheme.onSurface;
    final Color muted = scheme.onSurfaceVariant;
    return TextTheme(
      displaySmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 36,
        height: 1.16,
        letterSpacing: -0.5,
        fontWeight: FontWeight.w700,
        color: headline,
      ),
      headlineMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 28,
        height: 1.2,
        letterSpacing: -0.5,
        fontWeight: FontWeight.w700,
        color: headline,
      ),
      headlineSmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 24,
        height: 1.22,
        letterSpacing: -0.25,
        fontWeight: FontWeight.w700,
        color: headline,
      ),
      titleLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 20,
        height: 1.3,
        letterSpacing: -0.25,
        fontWeight: FontWeight.w600,
        color: headline,
      ),
      titleMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 16,
        height: 1.4,
        letterSpacing: 0,
        fontWeight: FontWeight.w600,
        color: headline,
      ),
      titleSmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 14,
        height: 1.4,
        letterSpacing: 0.1,
        fontWeight: FontWeight.w600,
        color: headline,
      ),
      bodyLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 16,
        height: 1.5,
        letterSpacing: 0.1,
        fontWeight: FontWeight.w400,
        color: headline,
      ),
      bodyMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 14,
        height: 1.45,
        letterSpacing: 0.15,
        fontWeight: FontWeight.w400,
        color: headline,
      ),
      bodySmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 12,
        height: 1.4,
        letterSpacing: 0.2,
        fontWeight: FontWeight.w400,
        color: muted,
      ),
      labelLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 14,
        height: 1.2,
        letterSpacing: 0.1,
        fontWeight: FontWeight.w600,
        color: headline,
      ),
      labelMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 12,
        height: 1.2,
        letterSpacing: 0.3,
        fontWeight: FontWeight.w500,
        color: headline,
      ),
      labelSmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 11,
        height: 1.2,
        letterSpacing: 0.4,
        fontWeight: FontWeight.w500,
        color: muted,
      ),
    );
  }
}
