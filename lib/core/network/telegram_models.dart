/// Minimal models for Telegram Bot API responses.
class BotUser {
  const BotUser({required this.id, required this.username, this.firstName});

  final int id;
  final String username;
  final String? firstName;

  String get mention => '@$username';

  factory BotUser.fromJson(Map<String, dynamic> json) => BotUser(
        id: json['id'] as int,
        username: (json['username'] as String?) ?? '',
        firstName: json['first_name'] as String?,
      );
}

/// A resolved chat/channel the bot can post to.
class TgChat {
  const TgChat({required this.chatId, required this.title, required this.type});

  /// Numeric id as string (can be negative for groups/channels) or @username.
  final String chatId;
  final String title;
  final String type; // private | group | supergroup | channel

  bool get isChannel => type == 'channel';
  bool get isGroup => type == 'group' || type == 'supergroup';

  factory TgChat.fromChatJson(Map<String, dynamic> chat) {
    final type = chat['type'] as String? ?? 'private';
    String title;
    switch (type) {
      case 'channel':
        title = (chat['title'] as String?) ?? 'Channel';
        break;
      case 'group':
      case 'supergroup':
        title = (chat['title'] as String?) ?? 'Group';
        break;
      default:
        final first = chat['first_name'] as String? ?? '';
        final last = chat['last_name'] as String? ?? '';
        title = '$first $last'.trim();
        if (title.isEmpty) title = chat['username'] as String? ?? 'Chat';
    }
    return TgChat(
      chatId: '${chat['id']}',
      title: title,
      type: type,
    );
  }

  Map<String, dynamic> toJson() =>
      {'chatId': chatId, 'title': title, 'type': type};

  factory TgChat.fromJson(Map<String, dynamic> json) => TgChat(
        chatId: json['chatId'] as String,
        title: json['title'] as String,
        type: json['type'] as String,
      );
}
