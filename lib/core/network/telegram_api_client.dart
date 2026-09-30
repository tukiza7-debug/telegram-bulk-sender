import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../constants.dart';
import '../sending/models.dart';
import 'telegram_exceptions.dart';
import 'telegram_models.dart';

/// Callback used to surface retry waits (e.g. HTTP 429) to the UI.
typedef RetryWaitListener = void Function(int seconds, String reason);

/// Thin, typed client for the Telegram Bot API with:
///  - HTTP 429 handling (retry_after + 1s, up to [maxRateLimitRetries] times)
///  - exponential backoff for transient (5xx / network) failures
///  - bot token never leaked into error messages
class TelegramApiClient {
  TelegramApiClient(String botToken, {Dio? dio, Future<void> Function(Duration delay)? sleep})
      : _token = botToken,
        _dio = dio ?? _buildDio(botToken),
        _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final String _token;
  final Dio _dio;
  final Future<void> Function(Duration delay) _sleep;

  static Dio _buildDio(String botToken) {
    return Dio(
      BaseOptions(
        baseUrl: '${AppConstants.telegramApiBase}/bot$botToken',
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 90),
        // Large multi-part uploads on slow connections must not be cut off.
        sendTimeout: const Duration(minutes: 10),
        // We parse every response ourselves (Telegram uses 200 + ok:false).
        validateStatus: (status) => status != null && status < 600,
        headers: {'content-type': 'application/json'},
      ),
    );
  }

  static const int maxRateLimitRetries = 8;
  static const int maxTransientRetries = 4;
  static final Random _jitter = Random();

  /// Redacts the bot token from any string destined for logs/UI.
  String sanitize(String input) => input.replaceAll('/bot$_token', '/bot***');

  Future<Map<String, dynamic>> _post(
    String method,
    Future<FormData> Function() buildData, {
    Map<String, dynamic>? query,
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        // A FormData can be consumed by exactly one request — retries must
        // rebuild it (re-reading the file), otherwise every 429/5xx retry
        // after the first attempt fails and the upload never succeeds.
        final response = await _dio.post<dynamic>(
          method,
          data: await buildData(),
          queryParameters: query,
          cancelToken: cancelToken,
        );
        final body = _decode(response);
        if (body['ok'] == true) return body;
        final status = response.statusCode ?? 500;
        final ex = TelegramApiException.fromResponse(status, body);
        if (await _shouldRetry(ex, attempt, onWait,
            cancelToken: cancelToken)) {
          continue;
        }
        throw ex;
      } on TelegramApiException {
        rethrow; // e.g. 'Send canceled' from the interruptible wait
      } on DioException catch (e) {
        if (cancelToken?.isCancelled ?? false) {
          throw TelegramApiException(
            kind: TelegramErrorKind.network,
            description: 'Send canceled',
          );
        }
        final ex = TelegramApiException.network(sanitize(e.message ?? 'Network error'));
        if (await _shouldRetry(ex, attempt, onWait,
            cancelToken: cancelToken)) {
          continue;
        }
        throw ex;
      }
    }
  }

  Future<Map<String, dynamic>> _get(
    String method,
    Map<String, dynamic> query, {
    RetryWaitListener? onWait,
    int transientRetries = maxTransientRetries,
    int timeoutRetries = 0,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      // A timed-out attempt is retried exactly [timeoutRetries] times with
      // a tight 10-second timeout (E_TIMEOUT) before it is reported as a
      // network problem — a hung radio must never read as a bad token.
      final options = attempt > 1 && timeoutRetries > 0
          ? Options(
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            )
          : null;
      try {
        final response = await _dio.get<dynamic>(
          method,
          queryParameters: query,
          options: options,
        );
        final body = _decode(response);
        if (body['ok'] == true) return body;
        final status = response.statusCode ?? 500;
        final ex = TelegramApiException.fromResponse(status, body);
        if (await _shouldRetry(ex, attempt, onWait,
            transientRetries: transientRetries)) {
          continue;
        }
        throw ex;
      } on DioException catch (e) {
        final isTimeout = e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout;
        if (isTimeout && attempt <= timeoutRetries) {
          continue;
        }
        final ex = TelegramApiException.network(sanitize(e.message ?? 'Network error'));
        if (await _shouldRetry(ex, attempt, onWait,
            transientRetries: transientRetries)) {
          continue;
        }
        throw ex;
      }
    }
  }

  Map<String, dynamic> _decode(Response<dynamic> response) {
    final data = response.data;
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      try {
        return jsonDecode(data) as Map<String, dynamic>;
      } on FormatException {
        // HTML or plain text usually means a captive portal, proxy or
        // blocked network — NOT a Telegram answer. Report it as a network
        // error so the user checks the connection instead of the token.
        throw TelegramApiException(
          kind: TelegramErrorKind.network,
          statusCode: response.statusCode,
          description: 'Non-JSON response (proxy, captive portal or blocked '
              'network in front of Telegram)',
        );
      }
    }
    throw TelegramApiException(
      kind: TelegramErrorKind.network,
      statusCode: response.statusCode,
      description: 'Unexpected response type from Telegram',
    );
  }

  /// Interruptible wait used before retries. A cancelled [cancelToken]
  /// aborts the sleep immediately instead of idling through the full
  /// backoff (e.g. the user pressed Cancel during a 429 wait).
  Future<void> _interruptibleSleep(
    Duration total,
    CancelToken? cancelToken,
  ) async {
    if (cancelToken == null) {
      await _sleep(total);
      return;
    }
    var remaining = total;
    const tick = Duration(milliseconds: 100);
    while (remaining > Duration.zero) {
      if (cancelToken.isCancelled) {
        throw TelegramApiException(
          kind: TelegramErrorKind.network,
          description: 'Send canceled',
        );
      }
      final step = remaining < tick ? remaining : tick;
      await _sleep(step);
      remaining -= step;
    }
  }

  Future<bool> _shouldRetry(
    TelegramApiException ex,
    int attempt,
    RetryWaitListener? onWait, {
    int transientRetries = maxTransientRetries,
    CancelToken? cancelToken,
  }) async {
    if (ex.isRateLimited && attempt <= maxRateLimitRetries) {
      final wait = (ex.retryAfter ?? 5) + 1;
      onWait?.call(wait, 'rate limit');
      await _interruptibleSleep(Duration(seconds: wait), cancelToken);
      return true;
    }
    if (ex.isTransient && attempt <= transientRetries) {
      final wait = min(30, 1 << attempt) + _jitter.nextInt(2);
      onWait?.call(wait, 'server error');
      await _interruptibleSleep(Duration(seconds: wait), cancelToken);
      return true;
    }
    return false;
  }

  // ---- Public API -----------------------------------------------------

  /// Validates the bot token. Throws [TelegramApiException] on failure.
  ///
  /// Zero transient retries: an offline connect must fail fast instead of
  /// spinning through minutes of backoff. A TIMEOUT is the one exception —
  /// it is retried once with a tight 10-second timeout and, if it times out
  /// again, reported as a network problem (never as a token problem).
  Future<BotUser> getMe() async {
    final body =
        await _get('getMe', const {}, transientRetries: 0, timeoutRetries: 1);
    return BotUser.fromJson((body['result'] as Map<String, dynamic>));
  }

  /// Resolves a chat by numeric id (string) or @username.
  /// Zero transient retries (same reasoning as [getMe]).
  Future<TgChat> getChat(String chatId) async {
    final body = await _get('getChat', {'chat_id': chatId}, transientRetries: 0);
    final chat = body['result'] as Map<String, dynamic>;
    return TgChat.fromChatJson(chat);
  }

  /// Sends a single photo. Returns the message id.
  Future<int> sendPhoto(
    String chatId,
    String filePath,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  }) async {
    Future<FormData> build() async => FormData.fromMap(<String, dynamic>{
          'chat_id': chatId,
          if (caption != null && caption.isNotEmpty) 'caption': caption,
          'photo': await MultipartFile.fromFile(
            filePath,
            filename: filePath.split('/').last,
          ),
        });
    final body = await _post('sendPhoto', build,
        onWait: onWait, cancelToken: cancelToken);
    return ((body['result'] as Map<String, dynamic>)['message_id'] as int?) ?? 0;
  }

  /// Sends a single video (mp4/mkv/mov/webm/…). Returns the message id.
  Future<int> sendVideo(
    String chatId,
    String filePath,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  }) async {
    Future<FormData> build() async => FormData.fromMap(<String, dynamic>{
          'chat_id': chatId,
          if (caption != null && caption.isNotEmpty) 'caption': caption,
          'supports_streaming': 'true',
          'video': await MultipartFile.fromFile(
            filePath,
            filename: filePath.split('/').last,
          ),
        });
    final body = await _post('sendVideo', build,
        onWait: onWait, cancelToken: cancelToken);
    return ((body['result'] as Map<String, dynamic>)['message_id'] as int?) ?? 0;
  }

  /// Sends any file as a document (PDF, ZIP, GIF, audio, …). Returns the
  /// message id.
  Future<int> sendDocument(
    String chatId,
    String filePath,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  }) async {
    Future<FormData> build() async => FormData.fromMap(<String, dynamic>{
          'chat_id': chatId,
          if (caption != null && caption.isNotEmpty) 'caption': caption,
          'document': await MultipartFile.fromFile(
            filePath,
            filename: filePath.split('/').last,
          ),
        });
    final body = await _post('sendDocument', build,
        onWait: onWait, cancelToken: cancelToken);
    return ((body['result'] as Map<String, dynamic>)['message_id'] as int?) ?? 0;
  }

  /// Sends an album (max 10 items). Photos and videos can be mixed; Telegram
  /// does not allow documents inside media groups, so those are always sent
  /// individually by the engine. Caption is applied to the first item.
  Future<List<int>> sendMediaGroup(
    String chatId,
    List<({String path, SendKind kind})> items,
    String? caption, {
    RetryWaitListener? onWait,
    CancelToken? cancelToken,
  }) async {
    assert(items.isNotEmpty && items.length <= SendSessionConfig.albumMax);
    Future<FormData> build() async {
      final media = <Map<String, dynamic>>[
        for (var i = 0; i < items.length; i++)
          <String, dynamic>{
            'type': items[i].kind == SendKind.video ? 'video' : 'photo',
            'media': 'attach://file$i',
            if (i == 0 && caption != null && caption.isNotEmpty)
              'caption': caption,
          },
      ];
      final map = <String, dynamic>{
        'chat_id': chatId,
        'media': jsonEncode(media),
      };
      for (var i = 0; i < items.length; i++) {
        map['file$i'] = await MultipartFile.fromFile(
          items[i].path,
          filename: items[i].path.split('/').last,
        );
      }
      return FormData.fromMap(map);
    }

    final body = await _post('sendMediaGroup', build,
        onWait: onWait, cancelToken: cancelToken);
    final result = body['result'] as List<dynamic>;
    return [
      for (final item in result)
        (item as Map<String, dynamic>)['message_id'] as int? ?? 0,
    ];
  }

  void dispose() => _dio.close();
}
