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

    test('maps 401 to invalid token', () {
      final ex = TelegramApiException.fromResponse(401, {
        'ok': false,
        'error_code': 401,
        'description': 'Unauthorized',
      });
      expect(ex.kind, TelegramErrorKind.unauthorized);
      expect(ex.friendlyMessage, contains('Invalid bot token'));
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
}
