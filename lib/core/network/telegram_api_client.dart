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
  TelegramApiClient(String botToken, {Dio? dio})
      : _token = botToken,
        _dio = dio ?? _buildDio(botToken);

  final String _token;
  final Dio _dio;

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
    FormData? data, {
    Map<String, dynamic>? query,
    RetryWaitListener? onWait,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final response = await _dio.post<dynamic>(
          method,
          data: data,
          queryParameters: query,
        );
        final body = _decode(response);
        if (body['ok'] == true) return body;
        final status = response.statusCode ?? 500;
        final ex = TelegramApiException.fromResponse(status, body);
        if (await _shouldRetry(ex, attempt, onWait)) continue;
        throw ex;
      } on DioException catch (e) {
        final ex = TelegramApiException.network(sanitize(e.message ?? 'Network error'));
        if (await _shouldRetry(ex, attempt, onWait)) continue;
        throw ex;
      }
    }
  }

  Future<Map<String, dynamic>> _get(
    String method,
    Map<String, dynamic> query, {
    RetryWaitListener? onWait,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final response = await _dio.get<dynamic>(
          method,
          queryParameters: query,
        );
        final body = _decode(response);
        if (body['ok'] == true) return body;
        final status = response.statusCode ?? 500;
        final ex = TelegramApiException.fromResponse(status, body);
        if (await _shouldRetry(ex, attempt, onWait)) continue;
        throw ex;
      } on DioException catch (e) {
        final ex = TelegramApiException.network(sanitize(e.message ?? 'Network error'));
        if (await _shouldRetry(ex, attempt, onWait)) continue;
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
        throw TelegramApiException(
          kind: TelegramErrorKind.serverError,
          statusCode: response.statusCode,
          description: 'Malformed response from Telegram',
        );
      }
    }
    throw TelegramApiException(
      kind: TelegramErrorKind.serverError,
      statusCode: response.statusCode,
      description: 'Unexpected response type from Telegram',
    );
  }

  Future<bool> _shouldRetry(
    TelegramApiException ex,
    int attempt,
    RetryWaitListener? onWait,
  ) async {
    if (ex.isRateLimited && attempt <= maxRateLimitRetries) {
      final wait = (ex.retryAfter ?? 5) + 1;
      onWait?.call(wait, 'rate limit');
      await Future<void>.delayed(Duration(seconds: wait));
      return true;
    }
    if (ex.isTransient && attempt <= maxTransientRetries) {
      final wait = min(30, 1 << attempt) + _jitter.nextInt(2);
      onWait?.call(wait, 'server error');
      await Future<void>.delayed(Duration(seconds: wait));
      return true;
    }
    return false;
  }

  // ---- Public API -----------------------------------------------------

  /// Validates the bot token. Throws [TelegramApiException] on failure.
  Future<BotUser> getMe() async {
    final body = await _get('getMe', const {});
    return BotUser.fromJson((body['result'] as Map<String, dynamic>));
  }

  /// Resolves a chat by numeric id (string) or @username.
  Future<TgChat> getChat(String chatId) async {
    final body = await _get('getChat', {'chat_id': chatId});
    final chat = body['result'] as Map<String, dynamic>;
    return TgChat.fromChatJson(chat);
  }

  /// Sends a single photo. Returns the message id.
  Future<int> sendPhoto(
    String chatId,
    String filePath,
    String? caption, {
    RetryWaitListener? onWait,
  }) async {
    final formData = FormData.fromMap(<String, dynamic>{
      'chat_id': chatId,
      if (caption != null && caption.isNotEmpty) 'caption': caption,
      'photo': await MultipartFile.fromFile(
        filePath,
        filename: filePath.split('/').last,
      ),
    });
    final body = await _post('sendPhoto', formData, onWait: onWait);
    return ((body['result'] as Map<String, dynamic>)['message_id'] as int?) ?? 0;
  }

  /// Sends a single video (mp4/mkv/mov/webm/…). Returns the message id.
  Future<int> sendVideo(
    String chatId,
    String filePath,
    String? caption, {
    RetryWaitListener? onWait,
  }) async {
    final formData = FormData.fromMap(<String, dynamic>{
      'chat_id': chatId,
      if (caption != null && caption.isNotEmpty) 'caption': caption,
      'supports_streaming': 'true',
      'video': await MultipartFile.fromFile(
        filePath,
        filename: filePath.split('/').last,
      ),
    });
    final body = await _post('sendVideo', formData, onWait: onWait);
    return ((body['result'] as Map<String, dynamic>)['message_id'] as int?) ?? 0;
  }

  /// Sends any file as a document (PDF, ZIP, GIF, audio, …). Returns the
  /// message id.
  Future<int> sendDocument(
    String chatId,
    String filePath,
    String? caption, {
    RetryWaitListener? onWait,
  }) async {
    final formData = FormData.fromMap(<String, dynamic>{
      'chat_id': chatId,
      if (caption != null && caption.isNotEmpty) 'caption': caption,
      'document': await MultipartFile.fromFile(
        filePath,
        filename: filePath.split('/').last,
      ),
    });
    final body = await _post('sendDocument', formData, onWait: onWait);
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
  }) async {
    assert(items.isNotEmpty && items.length <= SendSessionConfig.albumMax);
    final media = <Map<String, dynamic>>[
      for (var i = 0; i < items.length; i++)
        <String, dynamic>{
          'type': items[i].kind == SendKind.video ? 'video' : 'photo',
          'media': 'attach://file$i',
          if (i == 0 && caption != null && caption.isNotEmpty) 'caption': caption,
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
    final body = await _post('sendMediaGroup', FormData.fromMap(map), onWait: onWait);
    final result = body['result'] as List<dynamic>;
    return [
      for (final item in result) (item as Map<String, dynamic>)['message_id'] as int? ?? 0,
    ];
  }

  void dispose() => _dio.close();
}
