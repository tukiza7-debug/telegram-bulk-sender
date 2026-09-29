import 'package:flutter/services.dart';

/// Native bridge for APK installation. Implemented in MainActivity.kt using
/// FileProvider (no storage permission required).
class InstallerChannel {
  static const MethodChannel _channel =
      MethodChannel('com.telegrambulksender.app/installer');

  /// True when the OS allows installing packages from this app.
  /// Always true below Android 8.0.
  Future<bool> canRequestInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canRequestInstall') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the system "Install unknown apps" screen for this app.
  Future<void> openInstallPermissionSettings() async {
    try {
      await _channel.invokeMethod<dynamic>('openInstallPermissionSettings');
    } on PlatformException {
      // Ignored: the user can also reach the setting manually.
    }
  }

  /// Prompts the system package installer for the APK at [path].
  /// Throws [PlatformException] when the installer cannot be started.
  Future<void> installApk(String path) async {
    await _channel.invokeMethod<dynamic>('installApk', {'path': path});
  }
}
