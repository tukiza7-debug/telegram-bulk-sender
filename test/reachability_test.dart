import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telegram_bulk_sender/core/network/reachability.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.body, this.status,
      {this.contentType = 'application/json'});

  final String body;
  final int status;
  final String contentType;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body,
      status,
      headers: {Headers.contentTypeHeader: [contentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

class _DeadAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    throw DioException.connectionTimeout(
      timeout: const Duration(milliseconds: 20),
      requestOptions: options,
    );
  }

  @override
  void close({bool force = false}) {}
}

TelegramReachability _with(HttpClientAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://api.telegram.org',
      validateStatus: (status) => status != null && status < 600,
    ),
  )..httpClientAdapter = adapter;
  return TelegramReachability(dio: dio);
}

void main() {
  test('a Telegram JSON answer (even ok:false) proves reachability', () async {
    final result = await _with(_StubAdapter(
      '{"ok":false,"error_code":401,"description":"Unauthorized"}',
      401,
    )).probe();

    expect(result.reachable, isTrue,
        reason: 'the probe token is fake — ok:false is still Telegram');
    expect(result.captivePortal, isFalse);
    expect(result.httpStatus, 401);
    expect(result.latencyMs, isNotNull);
    expect(result.summary, contains('reachable'));
  });

  test('an HTML answer is flagged as a captive portal / proxy', () async {
    final result = await _with(_StubAdapter(
      '<html><body>Please log in to the wifi</body></html>',
      200,
      contentType: 'text/html',
    )).probe();

    expect(result.reachable, isFalse);
    expect(result.captivePortal, isTrue);
    expect(result.summary, contains('captive portal'));
  });

  test('a connection failure is unreachable and never a token problem',
      () async {
    final adapter = _DeadAdapter();
    final result = await _with(adapter).probe();

    expect(result.reachable, isFalse);
    expect(result.captivePortal, isFalse);
    expect(adapter.calls, 1);
    expect(result.summary, contains('unreachable'));
  });
}
