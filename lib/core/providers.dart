import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background/send_task.dart';
import 'background/update_check_service.dart';
import 'constants.dart';
import 'network/telegram_api_client.dart';
import 'network/telegram_exceptions.dart';
import 'network/telegram_models.dart';
import 'sending/image_preparation.dart';
import 'sending/models.dart';
import 'sending/sending_engine.dart';
import 'storage/history_store.dart';
import 'storage/targets_store.dart';
import 'storage/token_store.dart';
import 'updates/apk_download_service.dart';
import 'updates/github_release_service.dart';
import 'updates/installer_channel.dart';

// ---------------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------------

/// Overridden with the real instance in main() before runApp.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('Override in main()'),
);

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final targetsStoreProvider = Provider<TargetsStore>((ref) {
  return TargetsStore(ref.watch(sharedPreferencesProvider));
});

final historyStoreProvider = Provider<HistoryStore>((ref) {
  return HistoryStore(ref.watch(sharedPreferencesProvider));
});

final installerProvider = Provider<InstallerChannel>((ref) => InstallerChannel());

final apkDownloaderProvider = Provider<ApkDownloadService>(
  (ref) => ApkDownloadService(),
);

/// Bridge for progress events emitted by the foreground task isolate.
class SendEventBus {
  SendEventBus._();

  static final SendEventBus instance = SendEventBus._();

  final _controller = StreamController<SendProgressSnapshot>.broadcast();

  Stream<SendProgressSnapshot> get stream => _controller.stream;

  void push(SendProgressSnapshot snapshot) {
    if (!_controller.isClosed) _controller.add(snapshot);
  }
}

/// Called from main() so events from the task isolate reach the bus.
void registerSendEventBus() {
  FlutterForegroundTask.addTaskDataCallback((data) {
    if (data is String && data.startsWith('{"items"')) {
      try {
        SendEventBus.instance.push(SendProgressSnapshot.decode(data));
      } on FormatException {
        // Ignore malformed payloads.
      }
    }
  });
}

// ---------------------------------------------------------------------------
// Saved recipients
// ---------------------------------------------------------------------------

class TargetsController extends Notifier<List<TgChat>> {
  @override
  List<TgChat> build() {
    return ref.watch(targetsStoreProvider).load();
  }

  Future<void> _persist(List<TgChat> targets) =>
      ref.read(targetsStoreProvider).save(targets);

  Future<bool> add(String rawInput, TelegramApiClient api) async {
    final input = rawInput.trim();
    if (input.isEmpty) return false;
    try {
      final chat = await api.getChat(input);
      final targets = [...state];
      if (targets.any((t) => t.chatId == chat.chatId)) {
        throw TelegramApiException(
          kind: TelegramErrorKind.badRequest,
          description: 'Already saved',
        );
      }
      targets.add(chat);
      state = targets;
      await _persist(targets);
      return true;
    } on TelegramApiException {
      rethrow;
    }
  }

  Future<void> remove(TgChat target) async {
    final targets = state.where((t) => t.chatId != target.chatId).toList();
    state = targets;
    await _persist(targets);
  }

  Future<void> rename(TgChat target, String newTitle) async {
    final title = newTitle.trim();
    if (title.isEmpty) return;
    final targets = [
      for (final t in state)
        t.chatId == target.chatId
            ? TgChat(chatId: t.chatId, title: title, type: t.type)
            : t,
    ];
    state = targets;
    await _persist(targets);
  }
}

final targetsProvider =
    NotifierProvider<TargetsController, List<TgChat>>(TargetsController.new);

// ---------------------------------------------------------------------------
// Bot session
// ---------------------------------------------------------------------------

class BotSessionController extends Notifier<String?> {
  @override
  String? build() => null; // Loaded asynchronously via restore().

  Future<void> restore() async {
    state = await ref.read(tokenStoreProvider).read();
  }

  TelegramApiClient? client() {
    final token = state;
    if (token == null) return null;
    return TelegramApiClient(token);
  }

  Future<BotUser> connect(String token) async {
    final api = TelegramApiClient(token.trim());
    final bot = await api.getMe();
    await ref.read(tokenStoreProvider).write(token.trim());
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(AppConstants.botUsernameKey, bot.username);
    state = token.trim();
    api.dispose();
    return bot;
  }

  Future<void> disconnect() async {
    await ref.read(tokenStoreProvider).delete();
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.remove(AppConstants.botUsernameKey);
    state = null;
  }
}

final botSessionProvider =
    NotifierProvider<BotSessionController, String?>(BotSessionController.new);

final botUsernameProvider = FutureProvider<String>((ref) async {
  final prefs = ref.watch(sharedPreferencesProvider);
  return prefs.getString(AppConstants.botUsernameKey) ?? '';
});

// ---------------------------------------------------------------------------
// Pending photos
// ---------------------------------------------------------------------------

class PendingPhotosController extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  void addAll(List<String> paths) {
    final merged = [...state];
    for (final path in paths) {
      if (!merged.contains(path)) merged.add(path);
    }
    state = merged;
  }

  void removeAt(int index) {
    final updated = [...state]..removeAt(index);
    state = updated;
  }

  void reorder({required int oldIndex, required int newIndex}) {
    final updated = [...state];
    if (newIndex > oldIndex) newIndex -= 1;
    final item = updated.removeAt(oldIndex);
    updated.insert(newIndex, item);
    state = updated;
  }

  void clear() => state = const [];
}

final pendingPhotosProvider =
    NotifierProvider<PendingPhotosController, List<String>>(
  PendingPhotosController.new,
);

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

class SendUiState {
  const SendUiState({
    this.snapshot,
    this.inService = false,
    this.starting = false,
    this.fatalError,
  });

  final SendProgressSnapshot? snapshot;
  final bool inService;
  final bool starting;
  final String? fatalError;

  bool get running => starting || snapshot?.phase == SendPhase.running ||
      snapshot?.phase == SendPhase.paused;

  SendUiState copyWith({
    SendProgressSnapshot? snapshot,
    bool? inService,
    bool? starting,
    String? fatalError,
    bool clearFatal = false,
  }) {
    return SendUiState(
      snapshot: snapshot ?? this.snapshot,
      inService: inService ?? this.inService,
      starting: starting ?? this.starting,
      fatalError: clearFatal ? null : (fatalError ?? this.fatalError),
    );
  }
}

class SendController extends Notifier<SendUiState> {
  SendingEngine? _localEngine;
  StreamSubscription<SendProgressSnapshot>? _sub;

  @override
  SendUiState build() {
    ref.onDispose(() => _sub?.cancel());
    return const SendUiState();
  }

  /// Re-attaches the UI to a session that may already be running in the
  /// foreground service (e.g. app restarted while sending).
  Future<void> reattach() async {
    if (_sub != null) return;
    _sub = SendEventBus.instance.stream.listen((snapshot) {
      state = state.copyWith(snapshot: snapshot);
    });
    final running = await FlutterForegroundTask.isRunningService;
    if (running) {
      final raw =
          await FlutterForegroundTask.getData<String>(key: AppConstants.fgsSnapshotKey);
      if (raw != null) {
        state = state.copyWith(
          snapshot: SendProgressSnapshot.decode(raw),
          inService: true,
        );
      }
    }
  }

  Future<void> start(SendSessionConfig config) async {
    if (state.running) return;
    state = const SendUiState(starting: true);

    _sub?.cancel();
    _sub = SendEventBus.instance.stream.listen((snapshot) {
      state = state.copyWith(snapshot: snapshot);
    });

    await FlutterForegroundTask.saveData(
      key: AppConstants.fgsConfigKey,
      value: config.encode(),
    );
    final result = await FlutterForegroundTask.startService(
      serviceId: 42,
      notificationTitle: 'Sending photos…',
      notificationText: 'Starting bulk send',
      notificationButtons: const [
        NotificationButton(id: 'pause', text: 'Pause'),
        NotificationButton(id: 'cancel', text: 'Cancel'),
      ],
      callback: sendTaskCallback,
    );

    if (result is ServiceRequestSuccess) {
      state = state.copyWith(inService: true, starting: false);
      return;
    }

    // Fallback: run in the main isolate (app must stay open).
    final token = ref.read(botSessionProvider);
    if (token == null) {
      state = const SendUiState(
        fatalError: 'Bot is not connected. Reconnect and try again.',
      );
      return;
    }
    final api = TelegramApiClient(token);
    final engine = SendingEngine(
      gateway: TelegramGatewayImpl(api),
      config: config,
      prepare: (path) => ImagePreparer.prepare(path),
      onSnapshot: (snapshot) {
        state = state.copyWith(snapshot: snapshot);
      },
    );
    _localEngine = engine;
    state = state.copyWith(starting: false);

    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final snapshot = await engine.run();
    await ref.read(historyStoreProvider).add(
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
  }

  void pause() {
    if (state.inService) {
      FlutterForegroundTask.sendDataToTask('pause');
    } else {
      _localEngine?.pause();
    }
  }

  void resume() {
    if (state.inService) {
      FlutterForegroundTask.sendDataToTask('resume');
    } else {
      _localEngine?.resume();
    }
  }

  void cancel() {
    if (state.inService) {
      FlutterForegroundTask.sendDataToTask('cancel');
    } else {
      _localEngine?.cancel();
    }
  }

  void clearFinished() {
    _sub?.cancel();
    _sub = null;
    _localEngine = null;
    state = const SendUiState();
  }

  /// Builds a retry session from the failed (photo, recipient) pairs of the
  /// last snapshot — only what failed is re-sent, to the same recipients.
  SendSessionConfig? buildRetryConfig() {
    final snapshot = state.snapshot;
    if (snapshot == null) return null;
    final failed = snapshot.items
        .where((item) => item.status == SendItemStatus.failed)
        .toList();
    if (failed.isEmpty) return null;

    final targets = <SendTarget>[];
    final assignments = <SendAssignment>[];
    for (final item in failed) {
      var index = targets.indexWhere((t) => t.chatId == item.targetChatId);
      if (index == -1) {
        targets.add(
          SendTarget(chatId: item.targetChatId, title: item.targetTitle),
        );
        index = targets.length - 1;
      }
      assignments.add(
        SendAssignment(
          targetIndex: index,
          path: item.path,
          photoIndex: item.photoIndex,
        ),
      );
    }
    return SendSessionConfig(
      targets: targets,
      filePaths: [for (final a in assignments) a.path],
      mode: SendMode.individual,
      assignments: assignments,
    );
  }
}

final sendProvider =
    NotifierProvider<SendController, SendUiState>(SendController.new);

// ---------------------------------------------------------------------------
// Updates
// ---------------------------------------------------------------------------

enum UpdatePhase { idle, checking, available, upToDate, downloading, verifying, ready, installing, error }

class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.release,
    this.currentVersion = '',
    this.downloadProgress = 0,
    this.downloadedPath,
    this.error,
    this.skippedVersion,
    this.installPermissionMissing = false,
  });

  final UpdatePhase phase;
  final GithubRelease? release;
  final String currentVersion;
  final double downloadProgress; // 0..1
  final String? downloadedPath;
  final String? error;
  final String? skippedVersion;
  final bool installPermissionMissing;

  UpdateState copyWith({
    UpdatePhase? phase,
    GithubRelease? release,
    String? currentVersion,
    double? downloadProgress,
    String? downloadedPath,
    String? error,
    String? skippedVersion,
    bool clearError = false,
    bool? installPermissionMissing,
  }) {
    return UpdateState(
      phase: phase ?? this.phase,
      release: release ?? this.release,
      currentVersion: currentVersion ?? this.currentVersion,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      downloadedPath: downloadedPath ?? this.downloadedPath,
      error: clearError ? null : (error ?? this.error),
      skippedVersion: skippedVersion ?? this.skippedVersion,
      installPermissionMissing:
          installPermissionMissing ?? this.installPermissionMissing,
    );
  }
}

class UpdateController extends Notifier<UpdateState> {
  GithubReleaseService? _github;

  @override
  UpdateState build() {
    _github = GithubReleaseService();
    _loadCurrentVersion();
    _loadSkipped();
    return const UpdateState();
  }

  Future<void> _loadCurrentVersion() async {
    final info = await PackageInfo.fromPlatform();
    state = state.copyWith(currentVersion: info.version);
  }

  Future<void> _loadSkipped() async {
    final prefs = ref.read(sharedPreferencesProvider);
    state = state.copyWith(
      skippedVersion: prefs.getString(AppConstants.skippedVersionKey),
    );
  }

  Future<void> checkNow({bool notifyIfNewer = false}) async {
    state = state.copyWith(phase: UpdatePhase.checking, clearError: true);
    final release = await UpdateCheckService.run(notify: notifyIfNewer);
    if (release == null) {
      state = state.copyWith(phase: UpdatePhase.upToDate);
    } else {
      state = state.copyWith(phase: UpdatePhase.available, release: release);
    }
  }

  Future<void> refreshFromBackgroundCheck() async {
    final release = await UpdateCheckService.run(notify: false);
    if (release != null) {
      state = state.copyWith(phase: UpdatePhase.available, release: release);
    }
  }

  Future<void> download() async {
    final release = state.release;
    if (release == null) return;

    final installer = ref.read(installerProvider);
    if (!await installer.canRequestInstall()) {
      state = state.copyWith(installPermissionMissing: true);
      return;
    }

    state = state.copyWith(phase: UpdatePhase.downloading, downloadProgress: 0);
    try {
      final fileName = release.apkUrl.split('/').last;
      String? expectedHash;
      if (release.checksumUrl != null) {
        expectedHash = await _github!.fetchExpectedChecksum(
          release.checksumUrl!,
          fileName,
        );
      }
      final path = await ref.read(apkDownloaderProvider).download(
            release.apkUrl,
            fileName,
            onProgress: (received, total) {
              if (total > 0) {
                state = state.copyWith(downloadProgress: received / total);
              }
            },
          );
      state = state.copyWith(phase: UpdatePhase.verifying);
      if (expectedHash != null) {
        await ref.read(apkDownloaderProvider).verify(path, expectedHash);
      }
      state = state.copyWith(
        phase: UpdatePhase.ready,
        downloadedPath: path,
      );
    } on Exception catch (e) {
      state = state.copyWith(
        phase: UpdatePhase.error,
        error: 'Download failed: $e',
      );
    } on StateError catch (e) {
      state = state.copyWith(
        phase: UpdatePhase.error,
        error: e.message,
      );
    }
  }

  Future<void> install() async {
    final path = state.downloadedPath;
    if (path == null) return;
    final installer = ref.read(installerProvider);
    state = state.copyWith(phase: UpdatePhase.installing);
    try {
      await installer.installApk(path);
      state = state.copyWith(phase: UpdatePhase.ready);
    } on PlatformException {
      state = state.copyWith(
        phase: UpdatePhase.error,
        error: 'Could not start the installer. Check "Install unknown apps" '
            'permission and try again.',
        installPermissionMissing: true,
      );
    }
  }

  Future<void> recheckInstallPermission() async {
    final installer = ref.read(installerProvider);
    final granted = await installer.canRequestInstall();
    state = state.copyWith(installPermissionMissing: !granted);
    if (granted && state.phase == UpdatePhase.available) {
      await download();
    }
  }

  Future<void> skipThisVersion() async {
    final tag = state.release?.tag;
    if (tag == null) return;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(AppConstants.skippedVersionKey, tag);
    await prefs.setString(AppConstants.lastNotifiedVersionKey, tag);
    state = state.copyWith(
      skippedVersion: tag,
      phase: UpdatePhase.idle,
      release: null,
    );
  }

  Future<void> unskip() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final skipped = prefs.getString(AppConstants.skippedVersionKey);
    await prefs.remove(AppConstants.skippedVersionKey);
    if (skipped != null) {
      await prefs.remove(AppConstants.lastNotifiedVersionKey);
    }
    state = state.copyWith(skippedVersion: null);
    await checkNow(notifyIfNewer: false);
  }
}

final updateProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

class HistoryController extends Notifier<List<HistoryEntry>> {
  @override
  List<HistoryEntry> build() => ref.watch(historyStoreProvider).load();

  Future<void> clear() async {
    await ref.read(historyStoreProvider).clear();
    state = const [];
  }

  void refresh() {
    state = ref.read(historyStoreProvider).load();
  }
}

final historyProvider =
    NotifierProvider<HistoryController, List<HistoryEntry>>(
  HistoryController.new,
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Formats file sizes for UI display.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

int directoryBytes(List<String> paths) {
  var total = 0;
  for (final path in paths) {
    try {
      total += File(path).lengthSync();
    } on FileSystemException {
      // File disappeared since selection; treat as 0.
    }
  }
  return total;
}
