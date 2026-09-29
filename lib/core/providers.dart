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
import 'network/bot_token.dart';
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

/// Connection health of the bot link, as last checked against the real
/// Telegram API (getMe).
enum BotLinkStatus {
  /// Restored from storage; verification is still in flight.
  checking,

  /// getMe succeeded in this session — the token is genuinely alive.
  verified,

  /// Could not be verified because of a network/server problem. The token
  /// is kept (it may still be valid) but the UI knows it is unconfirmed.
  offline,
}

/// The connected-bot session. `null` means no bot is connected.
class BotSession {
  const BotSession({required this.token, this.status = BotLinkStatus.checking});

  final String token;
  final BotLinkStatus status;
}

/// Injectable Telegram client factory so tests can stub the API.
final telegramClientFactoryProvider =
    Provider<TelegramApiClient Function(String token)>(
  (ref) => (token) => TelegramApiClient(token),
);

/// One-shot notice: the previously saved token was found to be no longer
/// valid on launch (regenerated/revoked in @BotFather) and has been cleared.
/// The not-connected home state surfaces this so the user understands why
/// the app asked them to connect again.
final botResetNoticeProvider = StateProvider<bool>((ref) => false);

class BotSessionController extends Notifier<BotSession?> {
  @override
  BotSession? build() => null; // Loaded asynchronously via restore().

  /// Restores the saved token and RE-VERIFIES it against the live API.
  ///
  /// Previously the saved token was trusted blindly, so a bot whose token
  /// had been regenerated or revoked in @BotFather still showed as
  /// "connected" while every send failed with 401. Now the app only claims
  /// a connection it can actually prove.
  ///
  /// Hardened: on some devices flutter_secure_storage returns an empty
  /// string (or a corrupted leftover) instead of null when nothing was ever
  /// stored — that made a freshly installed app boot straight into a fake
  /// "connected" home. Anything blank, unreadable or structurally
  /// impossible is discarded, so the app always starts at "Bot not
  /// connected" unless a real token is actually stored and verified.
  Future<void> restore() async {
    String? saved;
    try {
      saved = await ref.read(tokenStoreProvider).read();
    } on Exception {
      // Corrupted keystore / unreadable secure storage: treat as empty.
      saved = null;
    }

    var token = saved?.trim();
    if (token != null && token.isEmpty) token = null;

    // Structural sanity: a bot token always contains a colon. Values like
    // "null", "true" or other storage leftovers are garbage — remove them
    // from storage so they cannot resurface, and start disconnected.
    if (token != null && !BotTokenSanitizer.mightBeToken(token)) {
      try {
        await ref.read(tokenStoreProvider).delete();
      } on Exception {
        // Best effort cleanup; the in-memory session stays empty anyway.
      }
      token = null;
    }

    if (token == null) {
      state = null;
      return;
    }
    // Show the restored session immediately (no start-up flash), then
    // verify it silently in the background.
    state = BotSession(token: token);
    unawaited(verifySaved());
  }

  /// Re-validates the saved token with getMe.
  ///
  ///  - 401 (dead token): the session is wiped and a clear notice is set.
  ///  - Network/server problems: the session is kept as [BotLinkStatus.offline].
  Future<void> verifySaved() async {
    final current = state;
    if (current == null) return;
    final api = ref.read(telegramClientFactoryProvider)(current.token);
    try {
      final bot = await api.getMe();
      // The user may have reconnected with a different token while the
      // check was in flight — never touch a newer session's data.
      if (state?.token != current.token) return;
      final prefs = ref.read(sharedPreferencesProvider);
      await prefs.setString(AppConstants.botUsernameKey, bot.username);
      state = BotSession(token: current.token, status: BotLinkStatus.verified);
      ref.invalidate(botUsernameProvider);
    } on TelegramApiException catch (e) {
      if (e.kind == TelegramErrorKind.unauthorized) {
        // The saved token is dead — stop pretending the bot is connected.
        if (state?.token == current.token) {
          try {
            await ref.read(tokenStoreProvider).delete();
          } on Exception {
            // Storage may be broken; the in-memory reset below still holds.
          }
          final prefs = ref.read(sharedPreferencesProvider);
          await prefs.remove(AppConstants.botUsernameKey);
          state = null;
          ref.invalidate(botUsernameProvider);
          ref.read(botResetNoticeProvider.notifier).state = true;
        }
      } else if (state?.token == current.token) {
        state = BotSession(token: current.token, status: BotLinkStatus.offline);
      }
    } finally {
      api.dispose();
    }
  }

  Future<BotUser> connect(String rawToken) async {
    // Real-token fix: clean the paste BEFORE it ever reaches the network.
    // Tokens copied out of BotFather messages, URLs or password managers
    // often carry labels, backticks, quotes, zero-width characters or
    // internal whitespace that used to cause spurious 401s.
    final token = BotTokenSanitizer.normalize(rawToken);
    if (token == null || !BotTokenSanitizer.mightBeToken(token)) {
      throw TelegramApiException(
        kind: TelegramErrorKind.badRequest,
        description: 'NOT_A_TOKEN',
      );
    }
    final api = ref.read(telegramClientFactoryProvider)(token);
    BotUser bot;
    try {
      bot = await api.getMe();
    } on TelegramApiException catch (e) {
      // Re-throw with the token redacted so the screens' "Details" section
      // can show the raw technical info safely.
      throw TelegramApiException(
        kind: e.kind,
        statusCode: e.statusCode,
        errorCode: e.errorCode,
        description: api.sanitize(e.description),
        retryAfter: e.retryAfter,
      );
    }
    await ref.read(tokenStoreProvider).write(token);
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(AppConstants.botUsernameKey, bot.username);
    state = BotSession(token: token, status: BotLinkStatus.verified);
    api.dispose();
    ref.invalidate(botUsernameProvider);
    ref.read(botResetNoticeProvider.notifier).state = false;
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
    NotifierProvider<BotSessionController, BotSession?>(
  BotSessionController.new,
);

final botUsernameProvider = FutureProvider<String>((ref) async {
  final prefs = ref.watch(sharedPreferencesProvider);
  return prefs.getString(AppConstants.botUsernameKey) ?? '';
});

// ---------------------------------------------------------------------------
// Pending files (photos, videos, documents)
// ---------------------------------------------------------------------------

/// One file queued for sending. [kind] decides the Bot API method and the
/// size limit applied later by the engine.
class PendingFile {
  const PendingFile({required this.path, required this.kind});

  final String path;
  final SendKind kind;

  @override
  bool operator ==(Object other) => other is PendingFile && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

class PendingFilesController extends Notifier<List<PendingFile>> {
  @override
  List<PendingFile> build() => const [];

  void addAll(List<PendingFile> files) {
    final merged = [...state];
    for (final file in files) {
      if (!merged.any((f) => f.path == file.path)) merged.add(file);
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

final pendingFilesProvider =
    NotifierProvider<PendingFilesController, List<PendingFile>>(
  PendingFilesController.new,
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

  /// The config of the last started session, so "Retry failed" can reuse
  /// the original caption, pacing and mode.
  SendSessionConfig? _lastConfig;

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
      return;
    }
    // The service is gone but a stale snapshot may still claim a live run
    // (process killed mid-send, Android 15 dataSync timeout, crash…).
    // Mark it interrupted so the UI leaves the running state and the user
    // can start again.
    final raw =
        await FlutterForegroundTask.getData<String>(key: AppConstants.fgsSnapshotKey);
    if (raw == null) return;
    final snapshot = SendProgressSnapshot.decode(raw);
    if (snapshot.phase == SendPhase.running ||
        snapshot.phase == SendPhase.paused) {
      state = state.copyWith(
        snapshot: snapshot.copyWith(
          phase: SendPhase.canceled,
          waitingMessage: 'Sending was interrupted before it finished. '
              'Use "Retry failed" to send the missing files.',
        ),
        inService: false,
      );
    }
  }

  Future<void> start(SendSessionConfig config) async {
    if (state.running) return;
    state = const SendUiState(starting: true);
    _lastConfig = config;

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
      notificationTitle: 'Sending files…',
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
    final token = ref.read(botSessionProvider)?.token;
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

    // Run in the background so the UI can navigate to /progress right away;
    // history is persisted inside _runLocalFallback once the run settles.
    unawaited(_runLocalFallback(engine, config, api));
  }

  Future<void> _runLocalFallback(
    SendingEngine engine,
    SendSessionConfig config,
    TelegramApiClient api,
  ) async {
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    try {
      final snapshot = await engine.run();
      try {
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
      } finally {
        api.dispose();
        // Notify history + any other listeners that the session settled.
        SendEventBus.instance.push(snapshot);
      }
    } on Exception catch (e) {
      api.dispose();
      state = state.copyWith(
        fatalError: 'Sending failed unexpectedly: $e',
        starting: false,
      );
    }
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

  /// Builds a retry session from the failed (file, recipient) pairs of the
  /// last snapshot — only what failed is re-sent, to the same recipients,
  /// with the ORIGINAL caption, pacing and mode.
  SendSessionConfig? buildRetryConfig() {
    return buildRetrySessionConfig(
      snapshot: state.snapshot,
      original: _lastConfig,
    );
  }
}

/// Pure helper so retry-config building is unit-testable without Riverpod.
SendSessionConfig? buildRetrySessionConfig({
  required SendProgressSnapshot? snapshot,
  SendSessionConfig? original,
}) {
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
        kind: item.kind,
      ),
    );
  }
  return SendSessionConfig(
    targets: targets,
    filePaths: [for (final a in assignments) a.path],
    mode: original?.mode ?? SendMode.individual,
    caption: original?.caption,
    extraDelay:
        original?.extraDelay ?? const Duration(milliseconds: 1200),
    assignments: assignments,
  );
}

final sendProvider =
    NotifierProvider<SendController, SendUiState>(SendController.new);

// ---------------------------------------------------------------------------
// Updates
// ---------------------------------------------------------------------------

enum UpdatePhase { idle, checking, available, upToDate, skipped, downloading, verifying, ready, installing, error }

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
    bool clearRelease = false,
    bool clearSkipped = false,
    bool? installPermissionMissing,
  }) {
    return UpdateState(
      phase: phase ?? this.phase,
      release: clearRelease ? null : (release ?? this.release),
      currentVersion: currentVersion ?? this.currentVersion,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      downloadedPath: downloadedPath ?? this.downloadedPath,
      error: clearError ? null : (error ?? this.error),
      skippedVersion:
          clearSkipped ? null : (skippedVersion ?? this.skippedVersion),
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
    // Load the skipped version synchronously from the (already initialized)
    // prefs instance — the previous async variant read a default state in
    // the meantime, so a stored "skip" briefly looked like "no skip".
    final skipped =
        ref.read(sharedPreferencesProvider).getString(AppConstants.skippedVersionKey);
    return UpdateState(skippedVersion: skipped);
  }

  Future<void> _loadCurrentVersion() async {
    final info = await PackageInfo.fromPlatform();
    state = state.copyWith(currentVersion: info.version);
  }

  Future<void> checkNow({bool notifyIfNewer = false}) async {
    state = state.copyWith(phase: UpdatePhase.checking, clearError: true);
    final result = await UpdateCheckService.run(
      notify: notifyIfNewer,
      force: true, // manual check must not trust a cached ETag
    );
    switch (result.status) {
      case UpdateCheckStatus.available:
        state = state.copyWith(
          phase: UpdatePhase.available,
          release: result.release,
        );
      case UpdateCheckStatus.skipped:
        state = state.copyWith(
          phase: UpdatePhase.skipped,
          release: result.release,
        );
      case UpdateCheckStatus.upToDate:
        state = state.copyWith(phase: UpdatePhase.upToDate);
      case UpdateCheckStatus.failed:
        state = state.copyWith(
          phase: UpdatePhase.error,
          error: "Couldn't check for updates. Check your connection and try "
              'again.',
        );
    }
  }

  Future<void> refreshFromBackgroundCheck() async {
    final result = await UpdateCheckService.run(notify: false);
    if (result.status == UpdateCheckStatus.available) {
      state = state.copyWith(
        phase: UpdatePhase.available,
        release: result.release,
      );
    } else if (result.status == UpdateCheckStatus.skipped) {
      state = state.copyWith(
        phase: UpdatePhase.skipped,
        release: result.release,
      );
    }
    // upToDate / failed leave the current banner state untouched: a failed
    // silent check must not wipe a banner the user can still act on.
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
      phase: UpdatePhase.skipped,
      clearRelease: true,
    );
  }

  Future<void> unskip() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final skipped = prefs.getString(AppConstants.skippedVersionKey);
    await prefs.remove(AppConstants.skippedVersionKey);
    if (skipped != null) {
      await prefs.remove(AppConstants.lastNotifiedVersionKey);
    }
    state = state.copyWith(clearSkipped: true);
    await checkNow(notifyIfNewer: false);
  }
}

final updateProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

class HistoryController extends Notifier<List<HistoryEntry>> {
  StreamSubscription<SendProgressSnapshot>? _sub;

  @override
  List<HistoryEntry> build() {
    ref.onDispose(() => _sub?.cancel());
    // History is written by the foreground-service isolate (and the
    // workmanager isolate) through their own SharedPreferences instances.
    // When their final snapshot arrives on the event bus, reload from disk
    // instead of reading a stale in-memory cache.
    _sub = SendEventBus.instance.stream.listen((snapshot) {
      if (snapshot.phase == SendPhase.finished ||
          snapshot.phase == SendPhase.canceled) {
        refresh();
      }
    });
    return ref.watch(historyStoreProvider).load();
  }

  Future<void> clear() async {
    await ref.read(historyStoreProvider).clear();
    state = const [];
  }

  void refresh() {
    ref.read(sharedPreferencesProvider).reload();
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
