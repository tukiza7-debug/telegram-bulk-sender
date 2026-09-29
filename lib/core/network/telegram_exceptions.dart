/// Typed exceptions for the Telegram Bot API and network layer.
class TelegramApiException implements Exception {
  TelegramApiException({
    required this.kind,
    this.statusCode,
    this.errorCode,
    this.description = '',
    this.retryAfter,
  });

  final TelegramErrorKind kind;
  final int? statusCode;

  /// Telegram's own error_code field, when the body carried one.
  final int? errorCode;
  final String description;

  /// Seconds to wait when the server responded with HTTP 429.
  final int? retryAfter;

  bool get isRateLimited => kind == TelegramErrorKind.rateLimited;
  bool get isTransient =>
      kind == TelegramErrorKind.serverError ||
      kind == TelegramErrorKind.network;

  /// Short, actionable message shown in the UI during a SEND (English).
  String get friendlyMessage {
    switch (kind) {
      case TelegramErrorKind.rateLimited:
        return 'Rate limited by Telegram. The app waits and retries automatically.';
      case TelegramErrorKind.unauthorized:
        return 'The bot token is no longer valid. Reconnect the bot in '
            'Settings → Reconnect token.';
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
        if (description.contains('Already saved')) {
          return 'This chat is already in your recipients.';
        }
        return 'Telegram rejected the request: ${_trim(description)}';
      case TelegramErrorKind.serverError:
        return 'Telegram server error. Retrying…';
      case TelegramErrorKind.network:
        return "Can't reach Telegram. Check your connection or VPN.";
      case TelegramErrorKind.unknown:
        return 'Unexpected error: ${_trim(description)}';
    }
  }

  /// Message shown on the onboarding / reconnect screens. Unlike a failure
  /// during a send, there is no saved bot to "reconnect" yet — the next
  /// step is copying a fresh token from @BotFather.
  String get friendlyMessageOnboarding {
    switch (kind) {
      case TelegramErrorKind.unauthorized:
        return 'Telegram rejected this token. Copy it again from @BotFather '
            '(/mybots → your bot → API Token), or generate a new one.';
      case TelegramErrorKind.chatNotFound:
      case TelegramErrorKind.forbidden:
      case TelegramErrorKind.badRequest:
      case TelegramErrorKind.fileTooLarge:
        return friendlyMessage;
      case TelegramErrorKind.rateLimited:
        return 'Telegram is rate limiting you. Wait a moment and try again.';
      case TelegramErrorKind.serverError:
        return 'Telegram has a temporary problem. Try again in a minute.';
      case TelegramErrorKind.network:
        return "Can't reach Telegram. Check your connection or VPN.";
      case TelegramErrorKind.unknown:
        return 'Unexpected error: ${_trim(description)}';
    }
  }

  /// Technical one-liners for the expandable "Details" section. Never
  /// contains the token (callers pass descriptions through `sanitize()`).
  String get technicalDetails {
    final parts = <String>[
      if (statusCode != null) 'HTTP status: $statusCode',
      if (errorCode != null) 'Telegram error_code: $errorCode',
      if (description.isNotEmpty) 'Description: ${_trim(description)}',
    ];
    return parts.isEmpty ? kind.name : parts.join('\n');
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
    final errorCode = body['error_code'] is int
        ? body['error_code'] as int
        : int.tryParse('${body['error_code']}');

    // 401/404 only mean a bad token when the body is a Telegram JSON error
    // ("ok": false). A proxy, captive portal or blocked network can also
    // answer 401/404 with HTML/JSON that is not from Telegram — that is a
    // network problem, not a token problem.
    final isTelegramJson = body['ok'] == false;
    TelegramErrorKind kind;
    if (!isTelegramJson && (statusCode == 401 || statusCode == 404)) {
      kind = TelegramErrorKind.network;
    } else {
      kind = _kindFor(statusCode, description);
    }

    return TelegramApiException(
      kind: kind,
      statusCode: statusCode,
      errorCode: errorCode,
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
