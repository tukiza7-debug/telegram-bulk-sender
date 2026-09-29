import 'package:flutter/material.dart';

/// Semantic colors that complement the [ColorScheme]. Provided per-brightness
/// through the [AppTokens] theme extension.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.rowHighlight,
  });

  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;

  /// A very subtle hover/selected background for list rows.
  final Color rowHighlight;

  static const light = AppTokens(
    success: Color(0xFF1E7B3C),
    onSuccess: Color(0xFFFFFFFF),
    successContainer: Color(0xFFC7F0CF),
    onSuccessContainer: Color(0xFF00210A),
    warning: Color(0xFF8F5F00),
    onWarning: Color(0xFFFFFFFF),
    warningContainer: Color(0xFFFFDEA6),
    onWarningContainer: Color(0xFF2C1A00),
    rowHighlight: Color(0x0F176FA6),
  );

  static const dark = AppTokens(
    success: Color(0xFF86D695),
    onSuccess: Color(0xFF003914),
    successContainer: Color(0xFF0E5B26),
    onSuccessContainer: Color(0xFFC7F0CF),
    warning: Color(0xFFFFC85C),
    onWarning: Color(0xFF4A2E00),
    warningContainer: Color(0xFF6B4500),
    onWarningContainer: Color(0xFFFFDEA6),
    rowHighlight: Color(0x1A9ACCF1),
  );

  @override
  AppTokens copyWith({
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? rowHighlight,
  }) {
    return AppTokens(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
      rowHighlight: rowHighlight ?? this.rowHighlight,
    );
  }

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    return AppTokens(
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successContainer:
          Color.lerp(successContainer, other.successContainer, t)!,
      onSuccessContainer:
          Color.lerp(onSuccessContainer, other.onSuccessContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      warningContainer:
          Color.lerp(warningContainer, other.warningContainer, t)!,
      onWarningContainer:
          Color.lerp(onWarningContainer, other.onWarningContainer, t)!,
      rowHighlight: Color.lerp(rowHighlight, other.rowHighlight, t)!,
    );
  }
}

/// Hand-tuned color schemes. Light: cool neutral surfaces with a single
/// disciplined Telegram-adjacent blue accent. Dark: same hue family.
abstract final class AppColors {
  static const light = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF176FA6),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFCBE6FF),
    onPrimaryContainer: Color(0xFF00263D),
    secondary: Color(0xFF4C616F),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFD5E4EF),
    onSecondaryContainer: Color(0xFF091E2A),
    tertiary: Color(0xFF67587A),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFEFE1FF),
    onTertiaryContainer: Color(0xFF221435),
    error: Color(0xFFBA1A1A),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFDAD6),
    onErrorContainer: Color(0xFF410002),
    surface: Color(0xFFFAFBFD),
    onSurface: Color(0xFF191C1F),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF4F6F9),
    surfaceContainer: Color(0xFFEEF1F5),
    surfaceContainerHigh: Color(0xFFE8EBF0),
    surfaceContainerHighest: Color(0xFFE2E5EB),
    onSurfaceVariant: Color(0xFF40484C),
    outline: Color(0xFF6F797D),
    outlineVariant: Color(0xFFC0C8CC),
    inverseSurface: Color(0xFF2E3135),
    onInverseSurface: Color(0xFFF0F1F4),
    inversePrimary: Color(0xFF9ACCF1),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    surfaceTint: Color(0xFF176FA6),
  );

  static const dark = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF9ACCF1),
    onPrimary: Color(0xFF003350),
    primaryContainer: Color(0xFF0B4A70),
    onPrimaryContainer: Color(0xFFCBE6FF),
    secondary: Color(0xFFB9C8D4),
    onSecondary: Color(0xFF223340),
    secondaryContainer: Color(0xFF394A57),
    onSecondaryContainer: Color(0xFFD5E4EF),
    tertiary: Color(0xFFD2BEE5),
    onTertiary: Color(0xFF372B4C),
    tertiaryContainer: Color(0xFF4F4162),
    onTertiaryContainer: Color(0xFFEFE1FF),
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: Color(0xFF101417),
    onSurface: Color(0xFFE1E3E6),
    surfaceContainerLowest: Color(0xFF0B0F12),
    surfaceContainerLow: Color(0xFF181C1F),
    surfaceContainer: Color(0xFF1C2023),
    surfaceContainerHigh: Color(0xFF262A2E),
    surfaceContainerHighest: Color(0xFF313539),
    onSurfaceVariant: Color(0xFFBFC8CC),
    outline: Color(0xFF899297),
    outlineVariant: Color(0xFF3F484C),
    inverseSurface: Color(0xFFE1E3E6),
    onInverseSurface: Color(0xFF2E3135),
    inversePrimary: Color(0xFF176FA6),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    surfaceTint: Color(0xFF9ACCF1),
  );
}
