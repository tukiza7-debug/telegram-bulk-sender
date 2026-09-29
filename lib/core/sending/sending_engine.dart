import 'dart:io';

import 'package:dio/dio.dart';

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
    CancelToken? cancelToken,
  });

  Future<void> sendVideo(
    String chatId,
    String path,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  });

  Future<void> sendDocument(
    String chatId,
    String path,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  });

  Future<void> sendMediaGroup(
    String chatId,
    List<({String path, SendKind kind})> items,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
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
    CancelToken? cancelToken,
  }) async {
    await _api.sendPhoto(chatId, path, caption,
        onWait: onWait, cancelToken: cancelToken);
  }

  @override
  Future<void> sendVideo(
    String chatId,
    String path,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  }) async {
    await _api.sendVideo(chatId, path, caption,
        onWait: onWait, cancelToken: cancelToken);
  }

  @override
  Future<void> sendDocument(
    String chatId,
    String path,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  }) async {
    await _api.sendDocument(chatId, path, caption,
        onWait: onWait, cancelToken: cancelToken);
  }

  @override
  Future<void> sendMediaGroup(
    String chatId,
    List<({String path, SendKind kind})> items,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  }) async {
    await _api.sendMediaGroup(chatId, items, caption,
        onWait: onWait, cancelToken: cancelToken);
  }
}

/// Orchestrates a bulk send session.
///
/// Work is modeled as (file x recipient) pairs so progress is exact per
/// recipient. Album mode groups each recipient's photos and videos into
/// chunks of 10 (documents cannot join media groups and are always sent
/// one by one); if Telegram rejects a chunk, it is retried file-by-file so
/// one bad image does not sink the whole album.
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
    Duration emitThrottle = const Duration(milliseconds: 500),
  })  : _gateway = gateway,
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _limiter = rateLimiter ?? RateLimiter(),
        _emitInterval = emitThrottle;

  final TelegramGateway _gateway;
  final SendSessionConfig config;
  final void Function(SendProgressSnapshot snapshot)? onSnapshot;
  final Future<String> Function(String path)? prepare;

  final RateLimiter _limiter;
  final Future<void> Function(Duration delay) _sleep;

  /// Cancelled as soon as [cancel] is requested, so in-flight Dio uploads
  /// and 429 backoff waits abort instead of running to completion.
  final CancelToken _cancelToken = CancelToken();

  bool _pauseRequested = false;
  bool _cancelRequested = false;

  /// Set when Telegram rejects the token (401) mid-run. Every remaining
  /// item is marked failed with a clear message instead of silently
  /// retrying against a dead token.
  String? _fatalError;

  List<SendItemState> _liveItems = const [];
  SendProgressSnapshot _snapshot =
      const SendProgressSnapshot(items: [], phase: SendPhase.idle);

  // Throttling: per-item emissions clone the whole item list and JSON-encode
  // it on every emit — O(n) work per item, O(n²) per session. Emit at most
  // once per [_emitInterval] unless the phase/waiting message changed; the
  // final snapshot is always forced through.
  final Duration _emitInterval;
  DateTime _lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Latest snapshot (also valid after the run completes).
  SendProgressSnapshot get snapshot => _snapshot;

  void pause() {
    if (_snapshot.phase == SendPhase.running) _pauseRequested = true;
  }

  void resume() {
    // Always clear the flag: a quick pause -> resume while the run is still
    // processing (not yet in _drainPause) must not pause the run by itself
    // a moment later.
    _pauseRequested = false;
    if (_snapshot.phase == SendPhase.paused) {
      _emit(_current(SendPhase.running, clearWaiting: true));
    }
  }

  void cancel() {
    _cancelRequested = true;
    // Abort in-flight uploads and interruptible retry waits.
    if (!_cancelToken.isCancelled) _cancelToken.cancel('User canceled');
  }

  /// Runs the whole session. Call exactly once per engine instance.
  Future<SendProgressSnapshot> run() async {
    _liveItems = _buildItems();
    _snapshot = _current(SendPhase.running);
    _emit(_snapshot);

    // Preparation phase (compression of oversized photos), once per file.
    // Videos and documents are uploaded as-is.
    if (prepare != null) {
      final prepared = <String, String>{};
      for (final item in _liveItems) {
        if (item.kind != SendKind.photo) continue;
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
      if (!item.status.isFinal) {
        // An invalidated token fails the rest of the run with a message the
        // user can act on; anything else counts as canceled.
        item
          ..status = _fatalError != null
              ? SendItemStatus.failed
              : SendItemStatus.canceled
          ..error = _fatalError;
      }
    }
    _snapshot = _current(
      _cancelRequested ? SendPhase.canceled : SendPhase.finished,
    );
    _emit(_snapshot, force: true);
    return _snapshot;
  }

  /// Expands the config into the flat work list (file x recipient pairs).
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
              kind: assignment.kind,
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
            kind: config.kindAt(i),
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

      final item = targetItems[index];
      if (item.status != SendItemStatus.pending) {
        index++;
        continue;
      }

      // Telegram does not allow documents in media groups — flush any open
      // photo/video chunk and send the document on its own.
      if (item.kind == SendKind.document) {
        await _sendOne(item);
        index++;
        if (index < targetItems.length) {
          await _interruptibleDelay(config.extraDelay);
        }
        continue;
      }

      final chunk = <SendItemState>[];
      // Count the pending media items ahead (up to the next document) to
      // balance the last two chunks: 11 items would otherwise become a full
      // 10-album plus a 1-item "album" — and sendMediaGroup needs 2–10
      // items. 11 -> 6 + 5 keeps every chunk valid.
      var remaining = 0;
      for (var j = index; j < targetItems.length; j++) {
        final n = targetItems[j];
        if (n.kind == SendKind.document) break;
        if (n.status == SendItemStatus.pending) remaining++;
      }
      var cap = SendSessionConfig.albumMax;
      if (remaining == SendSessionConfig.albumMax + 1) {
        cap = (remaining / 2).ceil();
      }
      while (chunk.length < cap && index < targetItems.length) {
        final next = targetItems[index];
        if (next.kind == SendKind.document) break; // handled on its own
        if (next.status == SendItemStatus.pending) chunk.add(next);
        index++;
      }
      if (chunk.isEmpty) continue;

      if (chunk.length == 1) {
        // A 1-item chunk cannot be a media group — send it individually.
        await _sendOne(chunk.single);
      } else {
        await _limiter.acquire(target.chatId, weight: chunk.length);
        if (!await _sendChunkAsAlbum(chunk)) {
          // Fall back to per-file so one bad image doesn't fail all 10.
          for (final chunkItem in chunk) {
            if (_cancelRequested) return;
            await _drainPause();
            await _sendOne(chunkItem);
          }
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
        [for (final i in chunk) (path: i.path, kind: i.kind)],
        config.caption,
        onWait: (seconds, reason) =>
            _emitWaiting('Rate limited — resuming in ${seconds}s'),
        cancelToken: _cancelToken,
      );
      for (final item in chunk) {
        item
          ..status = SendItemStatus.success
          ..error = null;
      }
      _emit(_current(_snapshot.phase));
      return true;
    } on TelegramApiException catch (e) {
      if (e.kind == TelegramErrorKind.unauthorized) {
        // A dead token will fail every per-file fallback too — stop here.
        _fatalError ??= e.friendlyMessage;
        _cancelRequested = true;
        for (final item in chunk) {
          if (!item.status.isFinal) {
            item
              ..status = SendItemStatus.failed
              ..error = e.friendlyMessage;
          }
        }
        _emit(_current(_snapshot.phase));
        return true; // skip the per-file fallback; the run stops anyway
      }
      return false; // caller falls back to individual sends
    } on Exception {
      // A FileSystemException / StateError inside the gateway used to kill
      // the whole run — degrade to per-file sends instead.
      return false;
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
      // Reject oversized uploads up front: videos/documents cannot be
      // compressed here, so a 200 MB file would only burn data and time
      // before Telegram refuses it. Missing files skip this gate and fail
      // in the send call below instead.
      var bytes = 0;
      try {
        bytes = File(item.path).lengthSync();
      } on FileSystemException {
        bytes = 0;
      }
      if (bytes > item.kind.maxBytes) {
        throw TelegramApiException(
          kind: TelegramErrorKind.fileTooLarge,
          description: 'file too big',
        );
      }
      void onWait(int seconds, String reason) {
        _emitWaiting('Rate limited — resuming in ${seconds}s');
      }
      switch (item.kind) {
        case SendKind.photo:
          await _gateway.sendPhoto(item.targetChatId, item.path, config.caption,
              onWait: onWait, cancelToken: _cancelToken);
        case SendKind.video:
          await _gateway.sendVideo(item.targetChatId, item.path, config.caption,
              onWait: onWait, cancelToken: _cancelToken);
        case SendKind.document:
          await _gateway.sendDocument(item.targetChatId, item.path,
              config.caption,
              onWait: onWait, cancelToken: _cancelToken);
      }
      item
        ..status = SendItemStatus.success
        ..error = null;
    } on TelegramApiException catch (e) {
      // A user cancel aborts the in-flight upload — that item is canceled,
      // not failed.
      if (_cancelRequested && e.description.contains('Send canceled')) {
        item
          ..status = SendItemStatus.canceled
          ..error = null;
        _emit(_current(_snapshot.phase));
        return;
      }
      if (e.kind == TelegramErrorKind.unauthorized) {
        _fatalError ??= e.friendlyMessage;
        _cancelRequested = true;
      }
      // Photos with dimensions Telegram refuses (extremely small/large or
      // aspect ratios it cannot process) still make valid documents —
      // retry that exact file via sendDocument before giving up.
      if (item.kind == SendKind.photo &&
          !_cancelRequested &&
          e.kind != TelegramErrorKind.unauthorized &&
          e.description.contains('PHOTO_INVALID_DIMENSIONS')) {
        try {
          await _gateway.sendDocument(item.targetChatId, item.path,
              config.caption,
              onWait: null, cancelToken: _cancelToken);
          item
            ..status = SendItemStatus.success
            ..error = null;
          _emit(_current(_snapshot.phase));
          return;
        } on Exception catch (fallbackError) {
          item
            ..status = SendItemStatus.failed
            ..error = fallbackError is TelegramApiException
                ? fallbackError.friendlyMessage
                : 'Unexpected error: $fallbackError';
          _emit(_current(_snapshot.phase));
          return;
        }
      }
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
            kind: item.kind,
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

  void _emit(SendProgressSnapshot snapshot, {bool force = false}) {
    final phaseOrWaitingChanged = snapshot.phase != _snapshot.phase ||
        snapshot.waitingMessage != _snapshot.waitingMessage;
    if (!force && !phaseOrWaitingChanged) {
      final now = DateTime.now();
      if (now.difference(_lastEmitAt) < _emitInterval) {
        return; // dropped — the next emit carries the accumulated statuses
      }
      _lastEmitAt = now;
    } else {
      _lastEmitAt = DateTime.now();
    }
    _snapshot = snapshot;
    onSnapshot?.call(snapshot);
  }
}
