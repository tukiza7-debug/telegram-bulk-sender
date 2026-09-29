import 'package:flutter_test/flutter_test.dart';
import 'package:telegram_bulk_sender/core/providers.dart';
import 'package:telegram_bulk_sender/core/sending/models.dart';

void main() {
  group('buildRetrySessionConfig', () {
    test('keeps the original caption, extra delay and mode', () {
      final snapshot = SendProgressSnapshot(
        items: [
          SendItemState(
            path: '/tmp/ok.jpg',
            kind: SendKind.photo,
            targetChatId: 'chat-1',
            targetTitle: 'Chat 1',
            status: SendItemStatus.success,
          ),
          SendItemState(
            path: '/tmp/bad.jpg',
            kind: SendKind.photo,
            photoIndex: 2,
            targetChatId: 'chat-1',
            targetTitle: 'Chat 1',
            status: SendItemStatus.failed,
            error: 'rate limited',
          ),
        ],
        phase: SendPhase.finished,
      );
      final original = SendSessionConfig(
        targets: [SendTarget(chatId: 'chat-1', title: 'Chat 1')],
        filePaths: ['/tmp/ok.jpg', '/tmp/bad.jpg'],
        fileKinds: const [SendKind.photo, SendKind.photo],
        mode: SendMode.album,
        caption: 'Hello world',
        extraDelay: const Duration(seconds: 4),
      );

      final retry = buildRetrySessionConfig(
        snapshot: snapshot,
        original: original,
      );

      expect(retry, isNotNull);
      expect(retry!.caption, 'Hello world');
      expect(retry.extraDelay, const Duration(seconds: 4));
      expect(retry.mode, SendMode.album);
      // Only the failed pair is retried.
      expect(retry.filePaths, ['/tmp/bad.jpg']);
      expect(retry.targets.single.chatId, 'chat-1');
      expect(retry.assignments!.single.kind, SendKind.photo);
      expect(retry.assignments!.single.photoIndex, 2);
    });

    test('regroups failed pairs per target', () {
      final snapshot = SendProgressSnapshot(
        items: [
          SendItemState(
            path: '/tmp/a.jpg',
            targetChatId: 'chat-1',
            targetTitle: 'A',
            status: SendItemStatus.failed,
            error: 'x',
          ),
          SendItemState(
            path: '/tmp/b.jpg',
            targetChatId: 'chat-2',
            targetTitle: 'B',
            status: SendItemStatus.failed,
            error: 'x',
          ),
          SendItemState(
            path: '/tmp/c.jpg',
            targetChatId: 'chat-1',
            targetTitle: 'A',
            status: SendItemStatus.failed,
            error: 'x',
          ),
        ],
        phase: SendPhase.finished,
      );

      final retry = buildRetrySessionConfig(snapshot: snapshot);

      expect(retry, isNotNull);
      expect(retry!.targets.map((t) => t.chatId), ['chat-1', 'chat-2']);
      expect(retry.assignments, hasLength(3));
      expect(
        retry.assignments!.map((a) => a.targetIndex),
        [0, 1, 0],
        reason: 'chat-1 failures share one target entry',
      );
    });

    test('returns null when nothing failed or there is no snapshot', () {
      expect(buildRetrySessionConfig(snapshot: null), isNull);
      final allDone = SendProgressSnapshot(
        items: [
          SendItemState(
            path: '/tmp/ok.jpg',
            targetChatId: 'chat-1',
            targetTitle: 'A',
            status: SendItemStatus.success,
          ),
        ],
        phase: SendPhase.finished,
      );
      expect(buildRetrySessionConfig(snapshot: allDone), isNull);
    });

    test('falls back to individual mode with the default delay when the '
        'original config is unknown (legacy path)', () {
      final snapshot = SendProgressSnapshot(
        items: [
          SendItemState(
            path: '/tmp/a.jpg',
            targetChatId: 'chat-1',
            targetTitle: 'A',
            status: SendItemStatus.failed,
            error: 'x',
          ),
        ],
        phase: SendPhase.finished,
      );

      final retry = buildRetrySessionConfig(snapshot: snapshot);

      expect(retry!.mode, SendMode.individual);
      expect(retry.caption, isNull);
      expect(retry.extraDelay, const Duration(milliseconds: 1200));
    });
  });
}
