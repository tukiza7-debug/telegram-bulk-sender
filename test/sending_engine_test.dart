import 'package:flutter_test/flutter_test.dart';
import 'package:telegram_bulk_sender/core/network/telegram_api_client.dart'
    show RetryWaitListener;
import 'package:telegram_bulk_sender/core/network/telegram_exceptions.dart';
import 'package:telegram_bulk_sender/core/sending/models.dart';
import 'package:telegram_bulk_sender/core/sending/rate_limiter.dart';
import 'package:telegram_bulk_sender/core/sending/sending_engine.dart';

class FakeGateway implements TelegramGateway {
  FakeGateway({this.failAlbumOnceFor, this.rateLimitTimes = 0});

  final List<String> sentPhotos = [];
  final List<List<String>> sentAlbums = [];
  final int rateLimitTimes;

  /// When set, the first album call for this chat fails (simulating one bad
  /// photo) and the caller falls back to individual sends.
  final String? failAlbumOnceFor;
  final Set<String> _failedAlbumChats = {};
  int _rateLimitedCalls = 0;

  @override
  Future<void> sendPhoto(
    String chatId,
    String path,
    String? caption, {
    RetryWaitListener? onWait,
  }) async {
    // Simulates the real client: 429 is surfaced via onWait, retried
    // transparently, and the request eventually succeeds.
    if (_rateLimitedCalls < rateLimitTimes) {
      _rateLimitedCalls++;
      onWait?.call(2, 'rate limit');
    }
    sentPhotos.add(path);
  }

  @override
  Future<void> sendMediaGroup(
    String chatId,
    List<String> paths,
    String? caption, {
    RetryWaitListener? onWait,
  }) async {
    sentAlbums.add(paths);
    final trigger = failAlbumOnceFor;
    if (trigger != null &&
        chatId == trigger &&
        !_failedAlbumChats.contains(chatId) &&
        paths.length > 1) {
      _failedAlbumChats.add(chatId);
      throw TelegramApiException(
        kind: TelegramErrorKind.badRequest,
        statusCode: 400,
        description: 'Bad Request: album rejected',
      );
    }
  }
}

SendSessionConfig config({
  required List<String> paths,
  required int targetCount,
  SendMode mode = SendMode.album,
}) {
  return SendSessionConfig(
    targets: [
      for (var i = 0; i < targetCount; i++)
        SendTarget(chatId: 'chat-$i', title: 'Chat $i'),
    ],
    filePaths: paths,
    mode: mode,
  );
}

const instantSleep = _instantSleep;
Future<void> _instantSleep(Duration d) async {}

void main() {
  group('SendingEngine', () {
    test('album mode chunks 25 photos into 10/10/5 per target', () async {
      final gateway = FakeGateway();
      final paths = [for (var i = 0; i < 25; i++) '/tmp/p$i.jpg'];
      final engine = SendingEngine(
        gateway: gateway,
        config: config(paths: paths, targetCount: 1),
        sleep: instantSleep,
        rateLimiter: RateLimiter(sleep: instantSleep),
      );

      await engine.run();

      // 3 album calls, chunks of 10, 10, 5.
      expect(gateway.sentAlbums.length, 3);
      expect(gateway.sentAlbums[0].length, 10);
      expect(gateway.sentAlbums[1].length, 10);
      expect(gateway.sentAlbums[2].length, 5);
      expect(engine.snapshot.successCount, 25);
      expect(engine.snapshot.phase, SendPhase.finished);
    });

    test('individual mode sends one message per photo', () async {
      final gateway = FakeGateway();
      final paths = [for (var i = 0; i < 12; i++) '/tmp/p$i.jpg'];
      final engine = SendingEngine(
        gateway: gateway,
        config: config(paths: paths, targetCount: 2, mode: SendMode.individual),
        sleep: instantSleep,
        rateLimiter: RateLimiter(sleep: instantSleep),
      );

      await engine.run();

      expect(gateway.sentPhotos.length, 24);
      expect(gateway.sentAlbums, isEmpty);
      expect(engine.snapshot.successCount, 24);
    });

    test('album failure falls back to per-photo and isolates errors', () async {
      final gateway = FakeGateway(failAlbumOnceFor: 'chat-0');
      final paths = ['/tmp/a.jpg', '/tmp/b.jpg', '/tmp/c.jpg'];
      final engine = SendingEngine(
        gateway: gateway,
        config: config(paths: paths, targetCount: 1),
        sleep: instantSleep,
        rateLimiter: RateLimiter(sleep: instantSleep),
      );

      await engine.run();

      // The album attempt failed once, then 3 individual sends succeeded.
      expect(gateway.sentAlbums.length, 1);
      expect(gateway.sentPhotos.length, 3);
      expect(engine.snapshot.failedCount, 0);
    });

    test('cancel marks remaining photos and stops early', () async {
      final gateway = FakeGateway();
      final paths = [for (var i = 0; i < 30; i++) '/tmp/p$i.jpg'];
      // Cancel as soon as the first album chunk succeeds.
      final hooks = <void Function(SendProgressSnapshot)>[];
      final engine = SendingEngine(
        gateway: gateway,
        config: config(paths: paths, targetCount: 1),
        sleep: instantSleep,
        rateLimiter: RateLimiter(sleep: instantSleep),
        onSnapshot: (snapshot) {
          for (final hook in hooks) {
            hook(snapshot);
          }
        },
      );
      hooks.add((snapshot) {
        if (snapshot.successCount >= 10) engine.cancel();
      });

      final result = await engine.run();

      expect(result.phase, SendPhase.canceled);
      expect(result.successCount, 10);
      expect(result.canceledCount, 20);
      expect(gateway.sentAlbums.length, 1);
    });

    test('429 wait is surfaced to the UI and the send still completes', () async {
      final gateway = FakeGateway(rateLimitTimes: 1);
      final paths = ['/tmp/only.jpg'];
      final waitingMessages = <String>[];
      final engine = SendingEngine(
        gateway: gateway,
        config: config(paths: paths, targetCount: 1, mode: SendMode.individual),
        sleep: instantSleep,
        rateLimiter: RateLimiter(sleep: instantSleep),
        onSnapshot: (snapshot) {
          if (snapshot.waitingMessage != null) {
            waitingMessages.add(snapshot.waitingMessage!);
          }
        },
      );

      await engine.run();

      // The rate-limit wait reached the snapshot stream and the photo sent.
      expect(engine.snapshot.phase, SendPhase.finished);
      expect(engine.snapshot.successCount, 1);
      expect(waitingMessages, isNotEmpty);
      expect(waitingMessages.first, contains('2s'));
    });

    test('pause/resume completes the session', () async {
      final gateway = FakeGateway();
      final paths = ['/tmp/x.jpg', '/tmp/y.jpg'];
      final seenPaused = <bool>[];
      final hooks = <void Function(SendProgressSnapshot)>[];
      final engine = SendingEngine(
        gateway: gateway,
        config: config(paths: paths, targetCount: 1, mode: SendMode.individual),
        sleep: instantSleep,
        rateLimiter: RateLimiter(sleep: instantSleep),
        onSnapshot: (snapshot) {
          for (final hook in hooks) {
            hook(snapshot);
          }
        },
      );
      var pausedOnce = false;
      hooks.add((snapshot) {
        seenPaused.add(snapshot.phase == SendPhase.paused);
        if (!pausedOnce &&
            snapshot.successCount == 1 &&
            snapshot.phase == SendPhase.running) {
          pausedOnce = true;
          engine.pause();
        }
        // Resume deterministically as soon as the paused state is observed.
        if (snapshot.phase == SendPhase.paused) {
          engine.resume();
        }
      });

      await engine.run();
      expect(engine.snapshot.phase, SendPhase.finished);
      expect(engine.snapshot.successCount, 2);
      expect(seenPaused.contains(true), isTrue);
    });
  });
}
