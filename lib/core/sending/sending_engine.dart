import '../network/telegram_api_client.dart';
import '../network/telegram_exceptions.dart';
import 'models.dart';
import 'rate_limiter.dart';

/// Gateway abstraction so the engine can be tested without network I/O.
abstract class TelegramGateway {
  Future<void> sendPhoto(
    String chatId,
    String path,
    String? caption, {
    RetryWaitListener? onWait,
  });

  Future<void> sendMediaGroup(
    String chatId,
    List<String> paths,
    String? caption, {
    RetryWaitListener? onWait,
  });
}

class TelegramGatewayImpl implements TelegramGateway {
  TelegramGatewayImpl(this._api);

  final TelegramApiClient _api;

  @override
  Future<void> sendPhoto(
    String chatId,
    String path,
    String? caption, {
    RetryWaitListener? onWait,
  }) async {
    await _api.sendPhoto(chatId, path, caption, onWait: onWait);
  }

  @override
  Future<void> sendMediaGroup(
    String chatId,
    List<String> paths,
    String? caption, {
    RetryWaitListener? onWait,
  }) async {
    await _api.sendMediaGroup(chatId, paths, caption, onWait: onWait);
  }
}

/// Orchestrates a bulk send session.
///
/// Work is modeled as (photo x recipient) pairs so progress is exact per
/// recipient. Album mode groups each recipient's photos into chunks of 10;
/// if Telegram rejects a chunk, it is retried photo-by-photo so one bad
/// image does not sink the whole album.
///
/// Honors 429 retry_after (via the client's retry loop, surfaced through
/// wait messages), adds user-configured pacing between batches, supports
/// pause / resume / cancel, and emits immutable progress snapshots.
class SendingEngine {
  SendingEngine({
    required TelegramGateway gateway,
    required this.config,
    this.onSnapshot,
    this.prepare,
    Future<void> Function(Duration delay)? sleep,
    RateLimiter? rateLimiter,
  })  : _gateway = gateway,
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _limiter = rateLimiter ?? RateLimiter();

  final TelegramGateway _gateway;
  final SendSessionConfig config;
  final void Function(SendProgressSnapshot snapshot)? onSnapshot;
  final Future<String> Function(String path)? prepare;

  final RateLimiter _limiter;
  final Future<void> Function(Duration delay) _sleep;

  bool _pauseRequested = false;
  bool _cancelRequested = false;
  List<SendItemState> _liveItems = const [];
  SendProgressSnapshot _snapshot =
      const SendProgressSnapshot(items: [], phase: SendPhase.idle);

  /// Latest snapshot (also valid after the run completes).
  SendProgressSnapshot get snapshot => _snapshot;

  void pause() {
    if (_snapshot.phase == SendPhase.running) _pauseRequested = true;
  }

  void resume() {
    if (_snapshot.phase == SendPhase.paused) {
      _pauseRequested = false;
      _emit(_current(SendPhase.running, clearWaiting: true));
    }
  }

  void cancel() => _cancelRequested = true;

  /// Runs the whole session. Call exactly once per engine instance.
  Future<SendProgressSnapshot> run() async {
    _liveItems = _buildItems();
    _snapshot = _current(SendPhase.running);
    _emit(_snapshot);

    // Preparation phase (compression of oversized photos), once per file.
    if (prepare != null) {
      final prepared = <String, String>{};
      for (final item in _liveItems) {
        if (prepared.containsKey(item.path)) {
          item.path = prepared[item.path]!;
          continue;
        }
        item.status = SendItemStatus.preparing;
        _emit(_current(SendPhase.running));
        try {
          final newPath = await prepare!(item.path);
          prepared[item.path] = newPath;
          item.path = newPath;
        } on Exception catch (e) {
          item.status = SendItemStatus.failed;
          item.error = 'Could not prepare photo: $e';
        }
      }
    }

    for (final target in config.targets) {
      if (_cancelRequested) break;
      final targetItems =
          _liveItems.where((i) => i.targetChatId == target.chatId).toList();
      if (targetItems.every((i) => i.status.isFinal)) continue;

      if (config.mode == SendMode.album) {
        await _sendAlbum(target, targetItems);
      } else {
        await _sendIndividual(target, targetItems);
      }
    }

    for (final item in _liveItems) {
      if (!item.status.isFinal) item.status = SendItemStatus.canceled;
    }
    _snapshot = _current(
      _cancelRequested ? SendPhase.canceled : SendPhase.finished,
    );
    _emit(_snapshot);
    return _snapshot;
  }

  /// Expands the config into the flat work list (photo x recipient pairs).
  List<SendItemState> _buildItems() {
    final assignments = config.assignments;
    if (assignments != null && assignments.isNotEmpty) {
      return [
        for (final assignment in assignments)
          () {
            final target = config.targets[assignment.targetIndex];
            return SendItemState(
              path: assignment.path,
              photoIndex: assignment.photoIndex,
              targetChatId: target.chatId,
              targetTitle: target.title,
            );
          }(),
      ];
    }
    return [
      for (final target in config.targets)
        for (var i = 0; i < config.filePaths.length; i++)
          SendItemState(
            path: config.filePaths[i],
            photoIndex: i + 1,
            targetChatId: target.chatId,
            targetTitle: target.title,
          ),
    ];
  }

  Future<void> _sendAlbum(
    SendTarget target,
    List<SendItemState> targetItems,
  ) async {
    var index = 0;
    while (index < targetItems.length) {
      if (_cancelRequested) return;
      await _drainPause();
      if (_cancelRequested) return;

      final chunk = <SendItemState>[];
      while (chunk.length < SendSessionConfig.albumMax &&
          index < targetItems.length) {
        final item = targetItems[index];
        if (item.status == SendItemStatus.pending) chunk.add(item);
        index++;
      }
      if (chunk.isEmpty) break;

      await _limiter.acquire(target.chatId);
      if (!await _sendChunkAsAlbum(chunk)) {
        // Fall back to per-photo so one bad image doesn't fail all 10.
        for (final item in chunk) {
          if (_cancelRequested) return;
          await _drainPause();
          await _sendOne(item);
        }
      }

      if (index < targetItems.length) {
        await _interruptibleDelay(config.extraDelay);
      }
    }
  }

  /// Returns true when the whole album chunk succeeded.
  Future<bool> _sendChunkAsAlbum(List<SendItemState> chunk) async {
    for (final item in chunk) {
      item.status = SendItemStatus.sending;
    }
    _emit(_current(_snapshot.phase));
    try {
      await _gateway.sendMediaGroup(
        chunk.first.targetChatId,
        [for (final i in chunk) i.path],
        config.caption,
        onWait: (seconds, reason) =>
            _emitWaiting('Rate limited — resuming in ${seconds}s'),
      );
      for (final item in chunk) {
        item
          ..status = SendItemStatus.success
          ..error = null;
      }
      _emit(_current(_snapshot.phase));
      return true;
    } on TelegramApiException {
      return false; // caller falls back to individual sends
    }
  }

  Future<void> _sendIndividual(
    SendTarget target,
    List<SendItemState> targetItems,
  ) async {
    var first = true;
    for (final item in targetItems) {
      if (_cancelRequested) return;
      await _drainPause();
      if (_cancelRequested) return;
      if (item.status != SendItemStatus.pending) continue;

      if (!first) {
        await _interruptibleDelay(config.extraDelay);
        if (_cancelRequested) return;
        await _drainPause();
      }
      first = false;

      await _sendOne(item);
    }
  }

  Future<void> _sendOne(SendItemState item) async {
    await _limiter.acquire(item.targetChatId);
    item.status = SendItemStatus.sending;
    _emit(_current(_snapshot.phase));
    try {
      await _gateway.sendPhoto(
        item.targetChatId,
        item.path,
        config.caption,
        onWait: (seconds, reason) =>
            _emitWaiting('Rate limited — resuming in ${seconds}s'),
      );
      item
        ..status = SendItemStatus.success
        ..error = null;
    } on TelegramApiException catch (e) {
      item
        ..status = SendItemStatus.failed
        ..error = e.friendlyMessage;
    } on Exception catch (e) {
      item
        ..status = SendItemStatus.failed
        ..error = 'Unexpected error: $e';
    }
    _emit(_current(_snapshot.phase));
  }

  Future<void> _interruptibleDelay(Duration delay) async {
    if (delay <= Duration.zero) return;
    var remaining = delay;
    const tick = Duration(milliseconds: 100);
    while (remaining > Duration.zero && !_cancelRequested) {
      if (remaining < tick) {
        await _sleep(remaining);
        remaining = Duration.zero;
      } else {
        await _sleep(tick);
        remaining -= tick;
      }
    }
  }

  Future<void> _drainPause() async {
    if (!_pauseRequested) return;
    _emit(_current(SendPhase.paused, waiting: 'Paused'));
    while (_pauseRequested && !_cancelRequested) {
      await _sleep(const Duration(milliseconds: 150));
    }
    if (!_cancelRequested) {
      _emit(_current(SendPhase.running, clearWaiting: true));
    }
  }

  void _emitWaiting(String message) {
    _emit(_current(_snapshot.phase, waiting: message));
  }

  /// Builds an immutable snapshot from the LIVE item list (statuses are
  /// always read from the live objects, never from previous snapshots).
  SendProgressSnapshot _current(
    SendPhase phase, {
    String? waiting,
    bool clearWaiting = false,
  }) {
    return SendProgressSnapshot(
      items: [
        for (final item in _liveItems)
          SendItemState(
            path: item.path,
            photoIndex: item.photoIndex,
            targetChatId: item.targetChatId,
            targetTitle: item.targetTitle,
            status: item.status,
            error: item.error,
          ),
      ],
      phase: phase,
      waitingMessage: clearWaiting ? null : (waiting ?? _snapshot.waitingMessage),
    );
  }

  void _emit(SendProgressSnapshot snapshot) {
    _snapshot = snapshot;
    onSnapshot?.call(snapshot);
  }
}
