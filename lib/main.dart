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

/// Runs [body] swallowing anything it throws so one broken plugin can never
/// leave the user with a blank app. Logs a short reason without secrets.
Future<void> _guarded(String label, Future<void> Function() body) async {
  try {
    await body();
  } on Exception catch (e) {
    debugPrint('Startup: $label failed — continuing without it. ($e)');
  } catch (e) {
    debugPrint('Startup: $label failed with an unexpected error ($e)');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();

  // System notifications + tap routing.
  await _guarded('NotificationService.init', () async {
    await NotificationService.instance.init();
  });

  // Background update check (periodic, network-constrained).
  await _guarded('Workmanager.initialize', () async {
    await Workmanager().initialize(callbackDispatcher);
  });
  await _guarded('Workmanager.registerPeriodicUpdateCheck', () async {
    await registerPeriodicUpdateCheck();
  });

  // Foreground service for bulk sending (type: dataSync, declared in manifest).
  await _guarded('FlutterForegroundTask.init', () async {
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
  });
  await _guarded('registerSendEventBus', () async {
    registerSendEventBus();
  });

  // Update check when the app opens (notifications fire once per version).
  // Shares its in-flight future with the check in App._bootstrap.
  unawaited(_guarded('UpdateCheckService.run', () async {
    await UpdateCheckService.run(notify: true);
  }));

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const App(),
    ),
  );
}
