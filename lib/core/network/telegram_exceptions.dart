/// Typed exceptions for the Telegram Bot API and network layer.
class TelegramApiException implements Exception {
  TelegramApiException({
    required this.kind,
    this.statusCode,
    this.description = '',
    this.retryAfter,
  });

  final TelegramErrorKind kind;
  final int? statusCode;
  final String description;

  /// Seconds to wait when the server responded with HTTP 429.
  final int? retryAfter;

  bool get isRateLimited => kind == TelegramErrorKind.rateLimited;
  bool get isTransient =>
      kind == TelegramErrorKind.serverError ||
      kind == TelegramErrorKind.network;

  /// Short, actionable message shown in the UI (English).
  String get friendlyMessage {
    switch (kind) {
      case TelegramErrorKind.rateLimited:
        return 'Rate limited by Telegram. The app waits and retries automatically.';
      case TelegramErrorKind.unauthorized:
        return 'Invalid bot token. Reconnect the bot in Settings.';
      case TelegramErrorKind.chatNotFound:
        return 'Chat not found. Check the ID/username and make sure the bot can see this chat (send it a message or add it as admin).';
      case TelegramErrorKind.forbidden:
        return 'The bot is not allowed to post here. Add the bot as an admin of the chat/channel.';
      case TelegramErrorKind.fileTooLarge:
        return 'The file is too large for Telegram bots (photos max 10 MB, '
            'videos and documents max 50 MB). Try removing it.';
      case TelegramErrorKind.badRequest:
        if (description.contains('NOT_A_TOKEN')) {
          return "That doesn't look like a bot token. Copy the full token "
              'from @BotFather — it looks like 123456789:AAH3x…';
        }
        if (description.contains('PHOTO_INVALID_DIMENSIONS')) {
          return 'A photo has invalid dimensions for Telegram.';
        }
        if (description.contains('MEDIA_GROUP_INVALID')) {
          return 'Telegram rejected this album. Try sending individually.';
        }
        return 'Telegram rejected the request: ${_trim(description)}';
      case TelegramErrorKind.serverError:
        return 'Telegram server error. Retrying…';
      case TelegramErrorKind.network:
        return 'Network error. Check your connection and try again.';
      case TelegramErrorKind.unknown:
        return 'Unexpected error: ${_trim(description)}';
    }
  }

  String _trim(String s) =>
      s.length > 140 ? '${s.substring(0, 140)}…' : s;

  factory TelegramApiException.fromResponse(
    int statusCode,
    Map<String, dynamic> body,
  ) {
    final description =
        (body['description'] as String?) ?? 'Unknown Telegram error';
    final parameters = body['parameters'] as Map<String, dynamic>?;
    final retryAfter = parameters?['retry_after'] as int?;

    return TelegramApiException(
      kind: _kindFor(statusCode, description),
      statusCode: statusCode,
      description: description,
      retryAfter: retryAfter,
    );
  }

  factory TelegramApiException.network([String message = 'Network error']) {
    return TelegramApiException(
      kind: TelegramErrorKind.network,
      description: message,
    );
  }

  static TelegramErrorKind _kindFor(int statusCode, String description) {
    final lower = description.toLowerCase();
    if (statusCode == 429) return TelegramErrorKind.rateLimited;
    if (statusCode == 401 || statusCode == 404) {
      // 404 from a wrong base path also indicates a bad token.
      return TelegramErrorKind.unauthorized;
    }
    if (statusCode == 403) return TelegramErrorKind.forbidden;
    if (statusCode >= 500) return TelegramErrorKind.serverError;
    if (statusCode == 413 ||
        lower.contains('file is too big') ||
        lower.contains('request entity too large')) {
      return TelegramErrorKind.fileTooLarge;
    }
    if (lower.contains('chat not found') ||
        lower.contains('channel not found') ||
        lower.contains('peer id invalid')) {
      return TelegramErrorKind.chatNotFound;
    }
    if (statusCode == 400) return TelegramErrorKind.badRequest;
    return TelegramErrorKind.unknown;
  }

  @override
  String toString() =>
      'TelegramApiException(${kind.name}, $statusCode): $description';
}

enum TelegramErrorKind {
  rateLimited,
  unauthorized,
  chatNotFound,
  forbidden,
  fileTooLarge,
  badRequest,
  serverError,
  network,
  unknown,
}
