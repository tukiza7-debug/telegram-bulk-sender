/// Central design tokens: spacing (4/8 dp grid), radii, elevation.
/// Never use raw values in widgets — reference these tokens instead.
abstract final class AppDimens {
  // Spacing scale — 4/8 dp grid.
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s40 = 40;
  static const double s48 = 48;
  static const double s64 = 64;

  // Radius scale.
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 24;
  static const double radiusFull = 999;

  // Minimum interactive target size.
  static const double minTouchTarget = 48;

  // Borders.
  static const double borderThin = 1;
  static const double borderThick = 2;
}
