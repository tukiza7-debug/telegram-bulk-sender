import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telegram_bulk_sender/core/network/telegram_exceptions.dart';
import 'package:telegram_bulk_sender/core/network/telegram_models.dart';
import 'package:telegram_bulk_sender/core/storage/history_store.dart';
import 'package:telegram_bulk_sender/core/storage/targets_store.dart';
import 'package:telegram_bulk_sender/core/sending/models.dart';

void main() {
  group('TelegramApiException.friendlyMessage', () {
    test('maps chat-not-found to actionable guidance', () {
      final ex = TelegramApiException.fromResponse(400, {
        'ok': false,
        'error_code': 400,
        'description': 'Bad Request: chat not found',
      });
      expect(ex.kind, TelegramErrorKind.chatNotFound);
      expect(ex.friendlyMessage, contains('bot can see this chat'));
    });

    test('maps 403 forbidden to admin hint', () {
      final ex = TelegramApiException.fromResponse(403, {
        'ok': false,
        'error_code': 403,
        'description': 'Forbidden: bot is not a member of the channel chat',
      });
      expect(ex.kind, TelegramErrorKind.forbidden);
      expect(ex.friendlyMessage, contains('admin'));
    });

    test('maps 429 and keeps retry_after', () {
      final ex = TelegramApiException.fromResponse(429, {
        'ok': false,
        'error_code': 429,
        'description': 'Too Many Requests: retry after 31',
        'parameters': {'retry_after': 31},
      });
      expect(ex.kind, TelegramErrorKind.rateLimited);
      expect(ex.retryAfter, 31);
      expect(ex.friendlyMessage, contains('waits and retries'));
    });

    test('maps 401 to a token error with send + onboarding messages', () {
      final ex = TelegramApiException.fromResponse(401, {
        'ok': false,
        'error_code': 401,
        'description': 'Unauthorized',
      });
      expect(ex.kind, TelegramErrorKind.unauthorized);
      // During a send the message points at reconnecting in Settings.
      expect(ex.friendlyMessage, contains('Reconnect the bot in'));
      // On onboarding the next step is copying a fresh token.
      expect(ex.friendlyMessageOnboarding, contains('Telegram rejected this token'));
      expect(ex.technicalDetails, contains('HTTP status: 401'));
    });

    test('404 with a non-Telegram body is a network error, not a token error',
        () {
      final ex = TelegramApiException.fromResponse(404, {
        'message': 'Resource not found', // e.g. a proxy JSON error
      });
      expect(ex.kind, TelegramErrorKind.network);
      expect(ex.friendlyMessage, contains("Can't reach Telegram"));
    });
  });

  group('TgChat', () {
    test('parses channel/group/private chats', () {
      final channel = TgChat.fromChatJson({
        'id': -100123,
        'type': 'channel',
        'title': 'News',
      });
      expect(channel.isChannel, isTrue);
      expect(channel.title, 'News');

      final group = TgChat.fromChatJson({
        'id': -456,
        'type': 'supergroup',
        'title': 'Family',
      });
      expect(group.isGroup, isTrue);

      final user = TgChat.fromChatJson({
        'id': 789,
        'type': 'private',
        'first_name': 'Ali',
        'last_name': 'Abu',
      });
      expect(user.title, 'Ali Abu');
    });
  });

  group('Stores', () {
    test('targets round-trip through JSON', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = TargetsStore(prefs);

      expect(store.load(), isEmpty);
      await store.save([
        const TgChat(chatId: '-100123', title: 'News', type: 'channel'),
      ]);
      final loaded = store.load();
      expect(loaded.length, 1);
      expect(loaded.first.chatId, '-100123');
      expect(loaded.first.title, 'News');
    });

    test('history caps entries at 50', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = HistoryStore(prefs);

      for (var i = 0; i < 60; i++) {
        await store.add(
          HistoryEntry(
            id: '$i',
            startedAtMs: i,
            finishedAtMs: i,
            mode: SendMode.album,
            targetTitles: const ['Chat'],
            total: 1,
            success: 1,
            failed: 0,
          ),
        );
      }
      final entries = store.load();
      expect(entries.length, 50);
      expect(entries.first.id, '59');
    });
  });

  group('SendSessionConfig JSON', () {
    test('round-trips fileKinds (v1.1.0 payload)', () {
      const config = SendSessionConfig(
        targets: [
          SendTarget(chatId: '-100123', title: 'News'),
          SendTarget(chatId: '789', title: 'Ali'),
        ],
        filePaths: ['/tmp/a.jpg', '/tmp/b.mp4', '/tmp/c.pdf'],
        fileKinds: [SendKind.photo, SendKind.video, SendKind.document],
        mode: SendMode.album,
        caption: 'Hello',
        extraDelay: Duration(milliseconds: 1500),
      );

      final decoded = SendSessionConfig.decode(config.encode());

      expect(decoded.fileKinds, config.fileKinds);
      expect(decoded.filePaths, config.filePaths);
      expect(decoded.targets.length, 2);
      expect(decoded.targets[1].title, 'Ali');
      expect(decoded.caption, 'Hello');
      expect(decoded.extraDelay, const Duration(milliseconds: 1500));
    });

    test('legacy v1.0.0 payload (no fileKinds) falls back to extension detection', () {
      const legacyJson = '''
      {
        "targets": [{"chatId": "-100123", "title": "News"}],
        "filePaths": ["/tmp/old.jpg", "/tmp/clip.mp4"],
        "mode": "individual",
        "caption": null,
        "extraDelayMs": 1200
      }
      ''';

      final decoded = SendSessionConfig.decode(legacyJson);

      expect(decoded.kindAt(0), SendKind.photo);
      expect(decoded.kindAt(1), SendKind.video);
    });

    test('assignments carry their kind through JSON (retry sessions)', () {
      const config = SendSessionConfig(
        targets: [SendTarget(chatId: '-100123', title: 'News')],
        filePaths: ['/tmp/report.pdf'],
        mode: SendMode.individual,
        assignments: [
          SendAssignment(
            targetIndex: 0,
            path: '/tmp/report.pdf',
            photoIndex: 1,
            kind: SendKind.document,
          ),
        ],
      );

      final decoded = SendSessionConfig.decode(config.encode());

      expect(decoded.assignments!.single.kind, SendKind.document);
    });

    test('SendKind.fromPath maps common extensions', () {
      expect(SendKind.fromPath('/x/photo.jpeg'), SendKind.photo);
      expect(SendKind.fromPath('/x/photo.webp'), SendKind.photo);
      expect(SendKind.fromPath('/x/video.mp4'), SendKind.video);
      expect(SendKind.fromPath('/x/video.MKV'), SendKind.video);
      expect(SendKind.fromPath('/x/file.pdf'), SendKind.document);
      expect(SendKind.fromPath('/x/anim.gif'), SendKind.document);
      expect(SendKind.fromPath('/x/noext'), SendKind.document);
    });

    test('size caps: photos 10 MB, videos and documents 50 MB', () {
      expect(SendKind.photo.maxBytes, 10 * 1024 * 1024);
      expect(SendKind.video.maxBytes, 50 * 1024 * 1024);
      expect(SendKind.document.maxBytes, 50 * 1024 * 1024);
    });
  });
}
