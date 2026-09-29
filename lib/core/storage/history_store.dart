import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../sending/models.dart';

/// Simple, capped in-app history of sending sessions.
class HistoryStore {
  HistoryStore(this._prefs);

  final SharedPreferences _prefs;

  static const int maxEntries = 50;
  static const String _key = 'history.v1';

  List<HistoryEntry> load() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final item in list)
          HistoryEntry.fromJson(item as Map<String, dynamic>),
      ];
    } on FormatException {
      return [];
    }
  }

  Future<void> add(HistoryEntry entry) async {
    final entries = load()..insert(0, entry);
    if (entries.length > maxEntries) {
      entries.removeRange(maxEntries, entries.length);
    }
    await _prefs.setString(
      _key,
      jsonEncode([for (final e in entries) e.toJson()]),
    );
  }

  Future<void> clear() async {
    await _prefs.remove(_key);
  }
}
