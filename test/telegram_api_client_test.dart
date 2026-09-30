import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telegram_bulk_sender/core/network/telegram_api_client.dart';
import 'package:telegram_bulk_sender/core/network/telegram_exceptions.dart';

class FakeTelegramAdapter implements HttpClientAdapter {
  FakeTelegramAdapter(this.responses);

  /// One entry per expected request attempt.
  final List<ResponseBody> responses;
  final List<FormData> bodies = [];
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index = calls;
    calls++;
    // Capture the FormData instance to prove each attempt gets a fresh one.
    if (options.data is FormData) bodies.add(options.data as FormData);
    if (index >= responses.length) {
      return ResponseBody.fromString(
        jsonEncode({'ok': false, 'error_code': 500, 'description': 'no more stubs'}),
        500,
      );
    }
    return responses[index];
  }

  @override
  void close({bool force = false}) {}
}

Future<File> makeTempFile(String name) async {
  final dir = await Directory.systemTemp.createTemp('tg_client_test');
  return File('${dir.path}/$name')..writeAsStringSync('hello');
}

ResponseBody okBody() => ResponseBody.fromString(
      jsonEncode({'ok': true, 'result': {'message_id': 7}}),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );

class _ThrowingAdapter implements HttpClientAdapter {
  _ThrowingAdapter(this.error);

  final DioException error;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    throw error;
  }

  @override
  void close({bool force = false}) {}
}

/// Throws [error] on the first call, then returns [second]; records the
/// per-attempt connect timeout so tests can prove the retry tightened it.
class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.error, this.second);

  final DioException error;
  final ResponseBody second;
  int calls = 0;
  final List<Duration?> connectTimeouts = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    connectTimeouts.add(options.connectTimeout);
    if (calls == 1) throw error;
    return second;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('429 retry_after then 200 — the file is re-sent on the second attempt',
      () async {
    final file = await makeTempFile('photo.jpg');
    addTearDown(() => file.parent.delete(recursive: true).ignore());

    final adapter = FakeTelegramAdapter([
      ResponseBody.fromString(
        jsonEncode({
          'ok': false,
          'error_code': 429,
          'description': 'Too Many Requests: retry after 3',
          'parameters': {'retry_after': 3},
        }),
        429,
        headers: {Headers.contentTypeHeader: ['application/json']},
      ),
      okBody(),
    ]);
    final waits = <Duration>[];
    final client = TelegramApiClient(
      '1234:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      dio: Dio(BaseOptions(
        baseUrl: 'https://api.telegram.org/',
        validateStatus: (status) => status != null && status < 600,
      ))
        ..httpClientAdapter = adapter,
      sleep: (d) async => waits.add(d),
    );

    final messageId = await client.sendPhoto('@testchat', file.path, null);

    expect(messageId, 7);
    expect(adapter.calls, 2, reason: 'the 429 must be retried');
    expect(waits.single, const Duration(seconds: 4));
    expect(adapter.bodies.length, 2);
    expect(identical(adapter.bodies[0], adapter.bodies[1]), isFalse,
        reason: 'a FormData can only be used once — the retry must rebuild it');
    client.dispose();
  });

  test('500 then 200 — transient retry re-sends the file and succeeds',
      () async {
    final file = await makeTempFile('video.mp4');
    addTearDown(() => file.parent.delete(recursive: true).ignore());

    final adapter = FakeTelegramAdapter([
      ResponseBody.fromString(
        jsonEncode({'ok': false, 'error_code': 500, 'description': 'oops'}),
        500,
        headers: {Headers.contentTypeHeader: ['application/json']},
      ),
      okBody(),
    ]);
    final client = TelegramApiClient(
      '1234:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      dio: Dio(BaseOptions(
        baseUrl: 'https://api.telegram.org/',
        validateStatus: (status) => status != null && status < 600,
      ))
        ..httpClientAdapter = adapter,
      sleep: (_) async {},
    );

    final messageId = await client.sendVideo('@testchat', file.path, null);

    expect(messageId, 7);
    expect(adapter.calls, 2);
    expect(adapter.bodies.length, 2);
    expect(identical(adapter.bodies[0], adapter.bodies[1]), isFalse);
    client.dispose();
  });

  test('exhausted 5xx retries surface a server error to the caller',
      () async {
    final file = await makeTempFile('doc.pdf');
    addTearDown(() => file.parent.delete(recursive: true).ignore());

    final adapter = FakeTelegramAdapter(List.generate(
      6,
      (_) => ResponseBody.fromString(
        jsonEncode({'ok': false, 'error_code': 502, 'description': 'bad gateway'}),
        502,
        headers: {Headers.contentTypeHeader: ['application/json']},
      ),
    ));
    final client = TelegramApiClient(
      '1234:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      dio: Dio(BaseOptions(
        baseUrl: 'https://api.telegram.org/',
        validateStatus: (status) => status != null && status < 600,
      ))
        ..httpClientAdapter = adapter,
      sleep: (_) async {},
    );

    await expectLater(
      client.sendDocument('@testchat', file.path, null),
      throwsA(isA<Exception>()),
    );
    // 1 initial + maxTransientRetries (4) attempts.
    expect(adapter.calls, 5);
    client.dispose();
  });

  // Shared builder for the error-classification tests below.
  TelegramApiClient clientFor(FakeTelegramAdapter adapter) {
    return TelegramApiClient(
      '1234:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      dio: Dio(BaseOptions(
        baseUrl: 'https://api.telegram.org/',
        validateStatus: (status) => status != null && status < 600,
      ))
        ..httpClientAdapter = adapter,
      sleep: (_) async {},
    );
  }

  test('JSON 401 from Telegram maps to a token error', () async {
    final adapter = FakeTelegramAdapter([
      ResponseBody.fromString(
        jsonEncode({'ok': false, 'error_code': 401, 'description': 'Unauthorized'}),
        401,
        headers: {Headers.contentTypeHeader: ['application/json']},
      ),
    ]);
    final client = clientFor(adapter);

    await expectLater(
      client.getMe(),
      throwsA(
        isA<TelegramApiException>()
            .having((e) => e.kind, 'kind', TelegramErrorKind.unauthorized)
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.errorCode, 'errorCode', 401),
      ),
    );
    client.dispose();
  });

  test('JSON 404 from Telegram maps to a token error (wrong token path)',
      () async {
    final adapter = FakeTelegramAdapter([
      ResponseBody.fromString(
        jsonEncode({'ok': false, 'error_code': 404, 'description': 'Not Found'}),
        404,
        headers: {Headers.contentTypeHeader: ['application/json']},
      ),
    ]);
    final client = clientFor(adapter);

    await expectLater(
      client.getMe(),
      throwsA(isA<TelegramApiException>()
          .having((e) => e.kind, 'kind', TelegramErrorKind.unauthorized)),
    );
    client.dispose();
  });

  test('HTML 404 (captive portal / proxy) maps to a network error', () async {
    final adapter = FakeTelegramAdapter([
      ResponseBody.fromString(
        '<html><body><h1>404 Not Found</h1></body></html>',
        404,
        headers: {Headers.contentTypeHeader: ['text/html']},
      ),
    ]);
    final client = clientFor(adapter);

    await expectLater(
      client.getMe(),
      throwsA(isA<TelegramApiException>()
          .having((e) => e.kind, 'kind', TelegramErrorKind.network)),
    );
    client.dispose();
  });

  test('a timeout is retried once with a 10s timeout, then reported as E_NET',
      () async {
    final adapter = _ThrowingAdapter(
      DioException.connectionTimeout(
        timeout: const Duration(milliseconds: 50),
        requestOptions: RequestOptions(path: '/getMe'),
      ),
    );
    final dio = Dio(BaseOptions(
      baseUrl: 'https://api.telegram.org/',
      validateStatus: (status) => status != null && status < 600,
    ))..httpClientAdapter = adapter;
    final client = TelegramApiClient(
      '1234:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      dio: dio,
      sleep: (_) async {},
    );

    await expectLater(
      client.getMe(),
      throwsA(isA<TelegramApiException>()
          .having((e) => e.kind, 'kind', TelegramErrorKind.network)
          .having((e) => e.friendlyMessageOnboarding, 'message',
              contains('NOT a token problem'))),
    );
    expect(adapter.calls, 2,
        reason: 'E_TIMEOUT: exactly ONE retry before reporting E_NET');
    client.dispose();
  });

  test('a timeout then success — the retry runs with the 10s timeout',
      () async {
    final adapter = _SequenceAdapter(
      DioException.connectionTimeout(
        timeout: const Duration(milliseconds: 50),
        requestOptions: RequestOptions(path: '/getMe'),
      ),
      ResponseBody.fromString(
        jsonEncode({
          'ok': true,
          'result': {
            'id': 42,
            'username': 'bulk_test_bot',
            'first_name': 'Bulk',
          },
        }),
        200,
        headers: {Headers.contentTypeHeader: ['application/json']},
      ),
    );
    final dio = Dio(BaseOptions(
      baseUrl: 'https://api.telegram.org/',
      validateStatus: (status) => status != null && status < 600,
    ))..httpClientAdapter = adapter;
    final client = TelegramApiClient(
      '1234:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      dio: dio,
      sleep: (_) async {},
    );

    final bot = await client.getMe();
    expect(bot.username, 'bulk_test_bot');
    expect(adapter.calls, 2);
    expect(adapter.connectTimeouts[0], isNull,
        reason: 'the first attempt keeps the client defaults');
    expect(adapter.connectTimeouts[1], const Duration(seconds: 10),
        reason: 'the retry is bounded by the tight 10s timeout');
    client.dispose();
  });

  test('cancelling during a 429 wait aborts without a second request',
      () async {
    final file = await makeTempFile('big.jpg');
    addTearDown(() => file.parent.delete(recursive: true).ignore());

    final adapter = FakeTelegramAdapter([
      ResponseBody.fromString(
        jsonEncode({
          'ok': false,
          'error_code': 429,
          'description': 'Too Many Requests: retry after 30',
          'parameters': {'retry_after': 30},
        }),
        429,
        headers: {Headers.contentTypeHeader: ['application/json']},
      ),
      okBody(), // must never be reached
    ]);
    final cancelToken = CancelToken();
    final client = TelegramApiClient(
      '1234:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      dio: Dio(BaseOptions(
        baseUrl: 'https://api.telegram.org/',
        validateStatus: (status) => status != null && status < 600,
      ))
        ..httpClientAdapter = adapter,
      // Simulate the user pressing Cancel while the client idles in the
      // 429 backoff: the first wait tick cancels the token.
      sleep: (_) async => cancelToken.cancel('User canceled'),
    );

    await expectLater(
      client.sendPhoto('@chat', file.path, null, cancelToken: cancelToken),
      throwsA(isA<TelegramApiException>()
          .having((e) => e.kind, 'kind', TelegramErrorKind.network)
          .having((e) => e.description, 'description', contains('canceled'))),
    );
    expect(adapter.calls, 1,
        reason: 'a cancelled wait must not produce another request');
    client.dispose();
  });

  test("a getChat failure with 0 transient retries doesn't spin either",
      () async {
    final adapter = FakeTelegramAdapter([
      ResponseBody.fromString(
        jsonEncode({'ok': false, 'error_code': 500, 'description': 'boom'}),
        500,
        headers: {Headers.contentTypeHeader: ['application/json']},
      ),
    ]);
    final client = clientFor(adapter);

    await expectLater(
      client.getChat('@chat'),
      throwsA(isA<TelegramApiException>()
          .having((e) => e.kind, 'kind', TelegramErrorKind.serverError)),
    );
    expect(adapter.calls, 1);
    client.dispose();
  });

  test('sanitize() redacts the token from network messages', () async {
    const token = '1234:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk';
    final client = TelegramApiClient(token);
    final redacted = client.sanitize('/bot$token failed');
    expect(redacted.contains(token), isFalse);
    expect(redacted.contains('/bot***'), isTrue);
    client.dispose();
  });
}
