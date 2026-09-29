import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telegram_bulk_sender/core/network/telegram_api_client.dart';

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
}
