/// App-wide constants: identity, storage keys, background task names,
/// notification channel ids and update source configuration.
abstract final class AppConstants {
  static const String appName = 'Telegram Bulk Sender';

  /// GitHub slug used by the in-app updater (releases + checksums).
  static const String updateRepoSlug = 'tukiza7-debug/telegram-bulk-sender';

  static const String telegramApiBase = 'https://api.telegram.org';

  /// Native installer channel (APK install via FileProvider).
  static const String installerChannel =
      'com.telegrambulksender.app/installer';

  // ---- Storage keys -------------------------------------------------
  static const String targetsKey = 'targets.v1';
  static const String historyKey = 'history.v1';
  static const String etagKey = 'update.etag';
  static const String lastNotifiedVersionKey = 'update.lastNotifiedVersion';
  static const String skippedVersionKey = 'update.skippedVersion';
  static const String botUsernameKey = 'bot.username';

  // ---- Background tasks ----------------------------------------------
  static const String updateCheckTaskName =
      'com.telegrambulksender.app.updateCheck';
  static const String updateCheckTaskUniqueName = 'update-check-periodic';

  // ---- Foreground task shared data keys --------------------------------
  static const String fgsConfigKey = 'send.config';
  static const String fgsSnapshotKey = 'send.snapshot';
  static const String fgsResultKey = 'send.result';

  // ---- Notification channels ------------------------------------------
  static const String updatesChannelId = 'app_updates';
  static const String updatesChannelName = 'App updates';
  static const String sendChannelId = 'send_progress';
  static const String sendChannelName = 'Sending progress';
}
