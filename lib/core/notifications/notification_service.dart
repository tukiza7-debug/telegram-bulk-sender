import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../constants.dart';

/// System notifications: update availability + tap handling.
/// Progress during bulk sends is rendered by the foreground service itself.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Set by main() so notification taps can navigate via go_router.
  static void Function(String route)? onNotificationTap;

  Future<void> init() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          onNotificationTap?.call(payload);
        }
      },
    );
    await _createChannels();
  }

  /// Route payload the app was LAUNCHED from, when a notification tap
  /// started a killed process. Must be called after [init]; taps on an
  /// already-running app go through onDidReceiveNotificationResponse
  /// instead. Returns null for normal launches.
  Future<String?> initialPayload() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details == null || !details.didNotificationLaunchApp) return null;
      final payload = details.notificationResponse?.payload;
      return (payload == null || payload.isEmpty) ? null : payload;
    } on Exception {
      // Missing plugin/platform differences must never block startup.
      return null;
    }
  }

  Future<void> _createChannels() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;

    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        AppConstants.updatesChannelId,
        AppConstants.updatesChannelName,
        description: 'Alerts when a new app version is released.',
        importance: Importance.defaultImportance,
      ),
    );
  }

  /// Notifies (once per version) that an update is available.
  Future<void> showUpdateNotification({
    required String version,
    required String body,
  }) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        AppConstants.updatesChannelId,
        AppConstants.updatesChannelName,
        channelDescription: 'Alerts when a new app version is released.',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        styleInformation: BigTextStyleInformation(''),
        icon: '@mipmap/ic_launcher',
      ),
    );
    await _plugin.show(
      // Stable id per version so re-checks do not spam duplicates.
      version.hashCode & 0x7fffffff,
      'Update available: v$version',
      body,
      details,
      payload: '/update',
    );
  }
}
