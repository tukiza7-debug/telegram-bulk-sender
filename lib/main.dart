import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'core/background/update_check_service.dart';
import 'core/background/workmanager_dispatcher.dart';
import 'core/constants.dart';
import 'core/notifications/notification_service.dart';
import 'core/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();

  // System notifications + tap routing.
  await NotificationService.instance.init();

  // Background update check (periodic, network-constrained).
  await Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: false,
  );
  await registerPeriodicUpdateCheck();

  // Foreground service for bulk sending (type: dataSync, declared in manifest).
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: AppConstants.sendChannelId,
      channelName: AppConstants.sendChannelName,
      channelDescription:
          'Shows progress while photos are being sent in the background.',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      showBadge: false,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      allowWakeLock: true,
    ),
  );
  FlutterForegroundTask.initCommunicationPort();
  registerSendEventBus();

  // Update check when the app opens (notifications fire once per version).
  unawaited(UpdateCheckService.run(notify: true));

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const App(),
    ),
  );
}
