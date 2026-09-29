import 'dart:convert';

/// Domain models for the sending pipeline. Plain, JSON-serializable classes
/// so they can cross isolate boundaries (foreground service <-> UI).

enum SendMode { album, individual }

enum SendItemStatus {
  pending,
  preparing,
  sending,
  waiting,
  success,
  failed,
  canceled;

  bool get isFinal =>
      this == SendItemStatus.success ||
      this == SendItemStatus.failed ||
      this == SendItemStatus.canceled;
}

enum SendPhase { idle, running, paused, finished, canceled }

/// A resolved recipient snapshot for a session.
class SendTarget {
  const SendTarget({required this.chatId, required this.title});

  final String chatId;
  final String title;

  Map<String, dynamic> toJson() => {'chatId': chatId, 'title': title};

  factory SendTarget.fromJson(Map<String, dynamic> json) => SendTarget(
        chatId: json['chatId'] as String,
        title: json['title'] as String,
      );
}

/// A specific (photo, recipient) pair — used by retry sessions so only the
/// failed pairs are re-sent, exactly as they were addressed before.
class SendAssignment {
  const SendAssignment({
    required this.targetIndex,
    required this.path,
    required this.photoIndex,
  });

  final int targetIndex;
  final String path;
  final int photoIndex;

  Map<String, dynamic> toJson() => {
        'targetIndex': targetIndex,
        'path': path,
        'photoIndex': photoIndex,
      };

  factory SendAssignment.fromJson(Map<String, dynamic> json) =>
      SendAssignment(
        targetIndex: json['targetIndex'] as int,
        path: json['path'] as String,
        photoIndex: json['photoIndex'] as int,
      );
}

/// Session configuration: what to send, where, and how.
class SendSessionConfig {
  const SendSessionConfig({
    required this.targets,
    required this.filePaths,
    required this.mode,
    this.caption,
    this.extraDelay = const Duration(milliseconds: 1200),
    this.assignments,
  });

  final List<SendTarget> targets;
  final List<String> filePaths;
  final SendMode mode;
  final String? caption;
  final Duration extraDelay;

  /// When set, the engine sends exactly these (target, photo) pairs instead
  /// of the full cross product. Used by "retry failed".
  final List<SendAssignment>? assignments;

  static const int albumMax = 10;

  Map<String, dynamic> toJson() => {
        'targets': [for (final t in targets) t.toJson()],
        'filePaths': filePaths,
        'mode': mode.name,
        'caption': caption,
        'extraDelayMs': extraDelay.inMilliseconds,
        if (assignments != null)
          'assignments': [
            for (final a in assignments!) a.toJson(),
          ],
      };

  factory SendSessionConfig.fromJson(Map<String, dynamic> json) =>
      SendSessionConfig(
        targets: [
          for (final t in (json['targets'] as List<dynamic>))
            SendTarget.fromJson(t as Map<String, dynamic>),
        ],
        filePaths: [
          for (final p in (json['filePaths'] as List<dynamic>)) p as String,
        ],
        mode: SendMode.values.byName(json['mode'] as String),
        caption: json['caption'] as String?,
        extraDelay:
            Duration(milliseconds: json['extraDelayMs'] as int? ?? 1200),
        assignments: json['assignments'] == null
            ? null
            : [
                for (final a in (json['assignments'] as List<dynamic>))
                  SendAssignment.fromJson(a as Map<String, dynamic>),
              ],
      );

  String encode() => jsonEncode(toJson());

  static SendSessionConfig decode(String raw) =>
      SendSessionConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// Per-item runtime state inside a session. One item = one photo going to
/// one recipient (photo x recipient pair).
class SendItemState {
  SendItemState({
    required this.path,
    this.photoIndex = 1,
    this.targetChatId = '',
    this.targetTitle = '',
    this.status = SendItemStatus.pending,
    this.error,
  });

  /// Mutable so the engine can swap in the compressed file path.
  String path;

  /// 1-based position of the photo within its recipient's batch.
  final int photoIndex;
  final String targetChatId;
  final String targetTitle;
  SendItemStatus status;
  String? error;

  Map<String, dynamic> toJson() => {
        'path': path,
        'photoIndex': photoIndex,
        'targetChatId': targetChatId,
        'targetTitle': targetTitle,
        'status': status.name,
        'error': error,
      };

  factory SendItemState.fromJson(Map<String, dynamic> json) => SendItemState(
        path: json['path'] as String,
        photoIndex: json['photoIndex'] as int? ?? 1,
        targetChatId: json['targetChatId'] as String? ?? '',
        targetTitle: json['targetTitle'] as String? ?? '',
        status: SendItemStatus.values.byName(json['status'] as String),
        error: json['error'] as String?,
      );
}

/// Immutable progress snapshot emitted by the engine and rendered by the UI.
class SendProgressSnapshot {
  const SendProgressSnapshot({
    required this.items,
    required this.phase,
    this.waitingMessage,
  });

  final List<SendItemState> items;
  final SendPhase phase;
  final String? waitingMessage;

  int get total => items.length;
  int get successCount =>
      items.where((i) => i.status == SendItemStatus.success).length;
  int get failedCount =>
      items.where((i) => i.status == SendItemStatus.failed).length;
  int get canceledCount =>
      items.where((i) => i.status == SendItemStatus.canceled).length;
  int get doneCount => successCount + failedCount;

  double get progress => total == 0 ? 0 : doneCount / total;

  SendProgressSnapshot copyWith({
    List<SendItemState>? items,
    SendPhase? phase,
    String? waitingMessage,
    bool clearWaiting = false,
  }) {
    return SendProgressSnapshot(
      items: items ?? this.items,
      phase: phase ?? this.phase,
      waitingMessage:
          clearWaiting ? null : (waitingMessage ?? this.waitingMessage),
    );
  }

  Map<String, dynamic> toJson() => {
        'items': [for (final i in items) i.toJson()],
        'phase': phase.name,
        'waitingMessage': waitingMessage,
      };

  factory SendProgressSnapshot.fromJson(Map<String, dynamic> json) =>
      SendProgressSnapshot(
        items: [
          for (final i in (json['items'] as List<dynamic>))
            SendItemState.fromJson(i as Map<String, dynamic>),
        ],
        phase: SendPhase.values.byName(json['phase'] as String),
        waitingMessage: json['waitingMessage'] as String?,
      );

  String encode() => jsonEncode(toJson());

  static SendProgressSnapshot decode(String raw) =>
      SendProgressSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// Summary persisted to history when a session ends.
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.startedAtMs,
    required this.finishedAtMs,
    required this.mode,
    required this.targetTitles,
    required this.total,
    required this.success,
    required this.failed,
    this.errors = const [],
  });

  final String id;
  final int startedAtMs;
  final int finishedAtMs;
  final SendMode mode;
  final List<String> targetTitles;
  final int total;
  final int success;
  final int failed;
  final List<String> errors;

  Map<String, dynamic> toJson() => {
        'id': id,
        'startedAtMs': startedAtMs,
        'finishedAtMs': finishedAtMs,
        'mode': mode.name,
        'targetTitles': targetTitles,
        'total': total,
        'success': success,
        'failed': failed,
        'errors': errors,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        id: json['id'] as String,
        startedAtMs: json['startedAtMs'] as int,
        finishedAtMs: json['finishedAtMs'] as int,
        mode: SendMode.values.byName(json['mode'] as String),
        targetTitles: [
          for (final t in (json['targetTitles'] as List<dynamic>))
            t as String,
        ],
        total: json['total'] as int,
        success: json['success'] as int,
        failed: json['failed'] as int,
        errors: [
          if (json['errors'] != null)
            for (final e in (json['errors'] as List<dynamic>)) e as String,
        ],
      );
}
