import 'dart:convert';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../network/telegram_api_client.dart';
import '../sending/models.dart';
import '../sending/sending_engine.dart';
import '../storage/history_store.dart';
import '../storage/token_store.dart';

/// Entry point for the foreground task isolate (service type: dataSync).
/// The whole bulk-send session runs here, so it keeps going when the app is
/// minimized or the user swipes it away.
@pragma('vm:entry-point')
void sendTaskCallback() {
  FlutterForegroundTask.setTaskHandler(SendTaskHandler());
}

class SendTaskHandler extends TaskHandler {
  SendingEngine? _engine;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final configRaw =
        await FlutterForegroundTask.getData<String>(key: AppConstants.fgsConfigKey);
    if (configRaw == null) {
      await _stop();
      return;
    }
    final config = SendSessionConfig.decode(configRaw);

    final token = await TokenStore().read();
    if (token == null) {
      await _stop();
      return;
    }

    final api = TelegramApiClient(token);
    final engine = SendingEngine(
      gateway: TelegramGatewayImpl(api),
      config: config,
      onSnapshot: (snapshot) async {
        await FlutterForegroundTask.saveData(
          key: AppConstants.fgsSnapshotKey,
          value: snapshot.encode(),
        );
        FlutterForegroundTask.sendDataToMain(snapshot.encode());
        final done = snapshot.successCount;
        final failed = snapshot.failedCount;
        await FlutterForegroundTask.updateService(
          notificationText: snapshot.waitingMessage ??
              '$done sent${failed > 0 ? ', $failed failed' : ''} '
                  'of ${snapshot.total}',
        );
      },
    );
    _engine = engine;

    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final result = await engine.run();
    final snapshot = result;

    final prefs = await SharedPreferences.getInstance();
    await HistoryStore(prefs).add(
      HistoryEntry(
        id: '$startedAt',
        startedAtMs: startedAt,
        finishedAtMs: DateTime.now().millisecondsSinceEpoch,
        mode: config.mode,
        targetTitles: [for (final t in config.targets) t.title],
        total: snapshot.total,
        success: snapshot.successCount,
        failed: snapshot.failedCount,
        errors: [
          for (final item in snapshot.items)
            if (item.error != null) '${item.error}',
        ],
      ),
    );
    await FlutterForegroundTask.saveData(
      key: AppConstants.fgsResultKey,
      value: jsonEncode({
        'phase': snapshot.phase.name,
        'success': snapshot.successCount,
        'failed': snapshot.failedCount,
      }),
    );
    FlutterForegroundTask.sendDataToMain(snapshot.encode());

    // Give the UI a beat to receive the final event, then stop the service.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _stop();
  }

  Future<void> _stop() async {
    await FlutterForegroundTask.stopService();
  }

  @override
  void onReceiveData(Object data) {
    switch (data) {
      case 'pause':
        _engine?.pause();
      case 'resume':
        _engine?.resume();
      case 'cancel':
        _engine?.cancel();
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    switch (id) {
      case 'pause':
        _engine?.pause();
      case 'resume':
        _engine?.resume();
      case 'cancel':
        _engine?.cancel();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _engine?.cancel();
    _engine = null;
  }
}
