import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../network/telegram_models.dart';

/// CRUD for the saved recipient list (chats/channels/groups).
class TargetsStore {
  TargetsStore(this._prefs);

  final SharedPreferences _prefs;

  List<TgChat> load() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final item in list)
          TgChat.fromJson(item as Map<String, dynamic>),
      ];
    } on FormatException {
      return [];
    }
  }

  Future<void> save(List<TgChat> targets) async {
    await _prefs.setString(
      _key,
      jsonEncode([for (final t in targets) t.toJson()]),
    );
  }

  static const String _key = 'targets.v1';
}
