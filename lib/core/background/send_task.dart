import 'dart:convert';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../network/telegram_api_client.dart';
import '../sending/image_preparation.dart';
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

  /// Guards so history and the final snapshot are written exactly once,
  /// no matter whether the run ends normally, is canceled, or crashes.
  bool _historySaved = false;
  int _startedAt = 0;
  SendSessionConfig? _config;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _startedAt = DateTime.now().millisecondsSinceEpoch;
    try {
      final configRaw =
          await FlutterForegroundTask.getData<String>(key: AppConstants.fgsConfigKey);
      if (configRaw == null) {
        await _stop();
        return;
      }
      final config = SendSessionConfig.decode(configRaw);
      _config = config;

      final token = await TokenStore().read();
      if (token == null) {
        await _stop();
        return;
      }

      final api = TelegramApiClient(token);
      final engine = SendingEngine(
        gateway: TelegramGatewayImpl(api),
        config: config,
        // Oversized photos (>10 MB) and non-JPEG formats (HEIC/HEIF/BMP) are
        // compressed/re-encoded before upload. The task isolate runs inside a
        // full FlutterEngine, so flutter_image_compress platform channels work
        // here exactly as in the main isolate.
        prepare: (path) => ImagePreparer.prepare(path),
        onSnapshot: (snapshot) async {
          await _onSnapshot(snapshot);
        },
      );
      _engine = engine;

      final snapshot = await engine.run();

      await FlutterForegroundTask.saveData(
        key: AppConstants.fgsResultKey,
        value: jsonEncode({
          'phase': snapshot.phase.name,
          'success': snapshot.successCount,
          'failed': snapshot.failedCount,
        }),
      );
      // Give the UI a beat to receive the final event, then stop the service.
      await Future<void>.delayed(const Duration(milliseconds: 800));
    } on Exception catch (e) {
      // A crashed onStart used to leave the service hanging forever with a
      // stale notification. Persist what we know and shut down cleanly.
      await _pushFinalSnapshot(
        waitingMessage: 'Sending stopped unexpectedly: $e',
      );
    } finally {
      await _saveHistoryAndFinish();
      await _stop();
    }
  }

  /// Writes the session to history (once) and pushes a final snapshot so
  /// the UI always leaves the running state.
  Future<void> _saveHistoryAndFinish() async {
    final snapshot = _engine?.snapshot;
    if (_historySaved) return;
    _historySaved = true;
    try {
      final config = _config;
      if (config != null && snapshot != null) {
        final prefs = await SharedPreferences.getInstance();
        await HistoryStore(prefs).add(
          HistoryEntry(
            id: '$_startedAt',
            startedAtMs: _startedAt,
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
      }
      await _pushFinalSnapshot();
    } on Exception {
      // Never let bookkeeping crash the shutdown path.
    }
  }

  /// Pushes the last known state to the UI/fgs data. Used both for the
  /// normal end of a run and for the crash path.
  Future<void> _pushFinalSnapshot({String? waitingMessage}) async {
    final snapshot = _engine?.snapshot;
    if (snapshot == null) return;
    final finalSnapshot = waitingMessage == null
        ? snapshot
        : snapshot.copyWith(waitingMessage: waitingMessage);
    await FlutterForegroundTask.saveData(
      key: AppConstants.fgsSnapshotKey,
      value: finalSnapshot.encode(),
    );
    FlutterForegroundTask.sendDataToMain(finalSnapshot.encode());
  }

  /// Throttled progress handling: snapshots arrive often (every item), but
  /// the on-disk snapshot (saveData) is a JSON blob of the whole session and
  /// Android notification updates are not free either — persist at most
  /// every 3 s, always at the end / on phase change. Every event is still
  /// forwarded to the UI, so live progress stays smooth.
  DateTime _lastSaveAt = DateTime.fromMillisecondsSinceEpoch(0);
  SendPhase _lastNotifiedPhase = SendPhase.idle;
  bool _lastNotifPaused = false;

  Future<void> _onSnapshot(SendProgressSnapshot snapshot) async {
    final now = DateTime.now();
    final finalPhase = snapshot.phase != SendPhase.running &&
        snapshot.phase != SendPhase.paused;
    final phaseChanged = snapshot.phase != _lastNotifiedPhase;

    if (finalPhase || phaseChanged || now.difference(_lastSaveAt).inMilliseconds >= 3000) {
      await FlutterForegroundTask.saveData(
        key: AppConstants.fgsSnapshotKey,
        value: snapshot.encode(),
      );
      _lastSaveAt = now;
      _lastNotifiedPhase = snapshot.phase;
    }
    FlutterForegroundTask.sendDataToMain(snapshot.encode());

    // Swap Pause <-> Resume so the notification always offers the action
    // that is currently possible.
    final paused = snapshot.phase == SendPhase.paused;
    final done = snapshot.successCount;
    final failed = snapshot.failedCount;
    final buttonsChanged = paused != _lastNotifPaused || phaseChanged;
    await FlutterForegroundTask.updateService(
      notificationText: snapshot.waitingMessage ??
          '$done sent${failed > 0 ? ', $failed failed' : ''} '
              'of ${snapshot.total}',
      notificationButtons: buttonsChanged
          ? [
              NotificationButton(
                  id: paused ? 'resume' : 'pause',
                  text: paused ? 'Resume' : 'Pause'),
              const NotificationButton(id: 'cancel', text: 'Cancel'),
            ]
          : null,
    );
    _lastNotifPaused = paused;
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
    // Android can destroy the service at any point (task removed, timeout,
    // system pressure). Cancel the engine and make sure the partial session
    // still lands in history so the user can retry the missing files.
    _engine?.cancel();
    await _saveHistoryAndFinish();
    _engine = null;
  }
}
