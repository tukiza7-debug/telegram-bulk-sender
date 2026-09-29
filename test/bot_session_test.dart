import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telegram_bulk_sender/core/constants.dart';
import 'package:telegram_bulk_sender/core/network/telegram_api_client.dart';
import 'package:telegram_bulk_sender/core/network/telegram_exceptions.dart';
import 'package:telegram_bulk_sender/core/network/telegram_models.dart';
import 'package:telegram_bulk_sender/core/providers.dart';
import 'package:telegram_bulk_sender/core/sending/models.dart';
import 'package:telegram_bulk_sender/core/storage/token_store.dart';

/// In-memory stand-in for the encrypted token store.
class _MemTokenStore implements TokenStore {
  String? value;
  int deleteCalls = 0;

  @override
  Future<void> delete() async {
    deleteCalls++;
    value = null;
  }

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String token) async => value = token;
}

/// Simulates a corrupted keystore: every storage call throws.
class _ThrowingTokenStore implements TokenStore {
  @override
  Future<void> delete() async {}

  @override
  Future<String?> read() async => throw Exception('keystore corrupted');

  @override
  Future<void> write(String token) async =>
      throw Exception('keystore corrupted');
}

/// Controllable Telegram API fake: each token maps to a behaviour.
class _FakeApi implements TelegramApiClient {
  _FakeApi(this.behavior);

  final Future<BotUser> Function() behavior;
  bool disposed = false;
  int getMeCalls = 0;

  static BotUser get okBot => const BotUser(id: 42, username: 'bulk_test_bot');

  @override
  Future<BotUser> getMe() async {
    getMeCalls++;
    return behavior();
  }

  @override
  Future<TgChat> getChat(String chatId) => throw UnimplementedError();

  @override
  Future<int> sendPhoto(
    String chatId,
    String filePath,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  }) =>
      throw UnimplementedError();

  @override
  Future<int> sendVideo(
    String chatId,
    String filePath,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  }) =>
      throw UnimplementedError();

  @override
  Future<int> sendDocument(
    String chatId,
    String filePath,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<int>> sendMediaGroup(
    String chatId,
    List<({String path, SendKind kind})> items,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  }) =>
      throw UnimplementedError();

  @override
  void dispose() => disposed = true;

  @override
  String sanitize(String input) => input;
}

TelegramApiException _unauthorized() => TelegramApiException(
      kind: TelegramErrorKind.unauthorized,
      statusCode: 401,
      description: 'Unauthorized',
    );

Future<ProviderContainer> _container({
  required TokenStore store,
  required _FakeApi Function(String token) apiFor,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      tokenStoreProvider.overrideWithValue(store),
      telegramClientFactoryProvider.overrideWithValue(apiFor),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BotSessionController.restore (launch re-validation)', () {
    test('no saved token -> stays disconnected', () async {
      final store = _MemTokenStore();
      final api = _FakeApi(() async => _FakeApi.okBot);
      final container = await _container(
        store: store,
        apiFor: (_) => api,
      );
      final notifier = container.read(botSessionProvider.notifier);

      await notifier.restore();
      await pumpEventQueue();

      expect(container.read(botSessionProvider), isNull);
      expect(api.getMeCalls, 0);
    });

    test('blank stored value (device quirk) -> not connected, not verified',
        () async {
      final store = _MemTokenStore()..value = '   ';
      final api = _FakeApi(() async => _FakeApi.okBot);
      final container = await _container(store: store, apiFor: (_) => api);
      final notifier = container.read(botSessionProvider.notifier);

      await notifier.restore();
      await pumpEventQueue();

      expect(container.read(botSessionProvider), isNull);
      expect(api.getMeCalls, 0); // never sent to the network
      expect(container.read(botResetNoticeProvider), isFalse);
    });

    test('garbage stored value (no colon) -> discarded and wiped', () async {
      final store = _MemTokenStore()..value = 'null';
      final api = _FakeApi(() async => _FakeApi.okBot);
      final container = await _container(store: store, apiFor: (_) => api);
      final notifier = container.read(botSessionProvider.notifier);

      await notifier.restore();
      await pumpEventQueue();

      expect(container.read(botSessionProvider), isNull);
      expect(api.getMeCalls, 0);
      expect(store.value, isNull); // garbage removed from storage
      expect(store.deleteCalls, 1);
    });

    test('secure storage failure -> starts disconnected instead of crashing',
        () async {
      final container = await _container(
        store: _ThrowingTokenStore(),
        apiFor: (_) => _FakeApi(() async => _FakeApi.okBot),
      );
      final notifier = container.read(botSessionProvider.notifier);

      await notifier.restore();
      await pumpEventQueue();

      expect(container.read(botSessionProvider), isNull);
      expect(container.read(botResetNoticeProvider), isFalse);
    });

    test('saved token + getMe OK -> verified session, username refreshed',
        () async {
      final store = _MemTokenStore()..value = '111:AAAA_old_secret_token';
      final api = _FakeApi(() async => _FakeApi.okBot);
      final container = await _container(
        store: store,
        apiFor: (_) => api,
      );
      final notifier = container.read(botSessionProvider.notifier);

      await notifier.restore();
      final session = container.read(botSessionProvider);
      expect(session, isNotNull); // no start-up flash of "not connected"

      await pumpEventQueue();

      final verified = container.read(botSessionProvider);
      expect(verified?.token, '111:AAAA_old_secret_token');
      expect(verified?.status, BotLinkStatus.verified);
      expect(
        container.read(sharedPreferencesProvider).getString(
              AppConstants.botUsernameKey,
            ),
        'bulk_test_bot',
      );
      expect(api.disposed, isTrue);
    });

    test('saved token revoked in BotFather (401) -> session cleared + notice',
        () async {
      final store = _MemTokenStore()..value = '111:AAAA_dead_secret_token';
      final container = await _container(
        store: store,
        apiFor: (_) => _FakeApi(() async => throw _unauthorized()),
      );
      final notifier = container.read(botSessionProvider.notifier);

      // Simulate a username left behind by the previous (now dead) session.
      await container
          .read(sharedPreferencesProvider)
          .setString(AppConstants.botUsernameKey, '@ghost_bot');

      await notifier.restore();
      await pumpEventQueue();

      expect(container.read(botSessionProvider), isNull);
      expect(store.value, isNull);
      expect(store.deleteCalls, 1);
      expect(container.read(botResetNoticeProvider), isTrue);
      expect(
        container.read(sharedPreferencesProvider).getString(
              AppConstants.botUsernameKey,
            ),
        isNull,
      );
    });

    test('saved token + network failure -> session kept as offline',
        () async {
      final store = _MemTokenStore()..value = '111:AAAA_offline_secret';
      final container = await _container(
        store: store,
        apiFor: (_) =>
            _FakeApi(() async => throw TelegramApiException.network('offline')),
      );
      final notifier = container.read(botSessionProvider.notifier);

      await notifier.restore();
      await pumpEventQueue();

      final session = container.read(botSessionProvider);
      expect(session?.token, '111:AAAA_offline_secret');
      expect(session?.status, BotLinkStatus.offline);
      expect(store.value, '111:AAAA_offline_secret'); // not wiped
      expect(container.read(botResetNoticeProvider), isFalse);
    });

    test('late 401 for the old token never clobbers a newer reconnect',
        () async {
      final oldToken = '111:AAAA_old_secret_token';
      final newToken = '222:BBBB_new_secret_token';
      final store = _MemTokenStore()..value = oldToken;

      final oldApiGate = Completer<BotUser>();
      final oldApi = _FakeApi(() => oldApiGate.future);
      final container = await _container(
        store: store,
        apiFor: (token) =>
            token == oldToken ? oldApi : _FakeApi(() async => _FakeApi.okBot),
      );
      final notifier = container.read(botSessionProvider.notifier);

      await notifier.restore(); // starts unawaited verify on the old token
      await pumpEventQueue();
      expect(container.read(botSessionProvider)?.token, oldToken);

      // User reconnects with a fresh, valid token while the old check is
      // still in flight.
      await notifier.connect(newToken);
      expect(container.read(botSessionProvider)?.token, newToken);

      // The old check finally answers 401 — it must NOT wipe the new session.
      oldApiGate.completeError(_unauthorized());
      await pumpEventQueue();

      expect(container.read(botSessionProvider)?.token, newToken);
      expect(container.read(botSessionProvider)?.status,
          BotLinkStatus.verified);
      expect(store.value, newToken);
      expect(container.read(botResetNoticeProvider), isFalse);
    });

    test('late getMe success for the old token never overwrites the new bot',
        () async {
      final oldToken = '111:AAAA_old_secret_token';
      final newToken = '222:BBBB_new_secret_token';
      final store = _MemTokenStore()..value = oldToken;

      final oldApiGate = Completer<BotUser>();
      final oldApi = _FakeApi(() => oldApiGate.future);
      final container = await _container(
        store: store,
        apiFor: (token) =>
            token == oldToken ? oldApi : _FakeApi(() async => _FakeApi.okBot),
      );
      final notifier = container.read(botSessionProvider.notifier);

      await notifier.restore(); // old-token verify now waits on the gate
      await pumpEventQueue();
      await notifier.connect(newToken); // new bot: bulk_test_bot
      expect(
        container.read(sharedPreferencesProvider).getString(
              AppConstants.botUsernameKey,
            ),
        'bulk_test_bot',
      );

      // The stale check answers with the OLD bot identity — it must not
      // rewrite the stored username of the newly connected bot.
      oldApiGate.complete(
        const BotUser(id: 7, username: 'old_ghost_bot'),
      );
      await pumpEventQueue();

      expect(
        container.read(sharedPreferencesProvider).getString(
              AppConstants.botUsernameKey,
            ),
        'bulk_test_bot',
      );
      expect(container.read(botSessionProvider)?.token, newToken);
      expect(oldApi.disposed, isTrue);
    });
  });

  group('BotSessionController.connect', () {
    test('valid token -> verified session, stored, notice cleared', () async {
      final store = _MemTokenStore();
      final container = await _container(
        store: store,
        apiFor: (_) => _FakeApi(() async => _FakeApi.okBot),
      );
      final notifier = container.read(botSessionProvider.notifier);
      container.read(botResetNoticeProvider.notifier).state = true;

      final bot = await notifier.connect(
        '  Token: `3333:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk`  ',
      );

      expect(bot.mention, '@bulk_test_bot');
      final session = container.read(botSessionProvider);
      expect(session?.token, '3333:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk');
      expect(session?.status, BotLinkStatus.verified);
      expect(store.value, '3333:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk');
      expect(container.read(botResetNoticeProvider), isFalse);
    });

    test('non-token paste is rejected before any network call', () async {
      final store = _MemTokenStore();
      final api = _FakeApi(() async => _FakeApi.okBot);
      final container = await _container(store: store, apiFor: (_) => api);
      final notifier = container.read(botSessionProvider.notifier);

      await expectLater(
        notifier.connect('hello world, no token here'),
        throwsA(isA<TelegramApiException>()),
      );
      expect(api.getMeCalls, 0);
      expect(store.value, isNull);
      expect(container.read(botSessionProvider), isNull);
    });
  });
}
