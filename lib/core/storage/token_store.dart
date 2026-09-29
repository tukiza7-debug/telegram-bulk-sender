import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores the bot token encrypted on-device (EncryptedSharedPreferences /
/// Tink-backed Keystore). The token never leaves the device except to
/// api.telegram.org over HTTPS.
class TokenStore {
  TokenStore();

  static const _key = 'bot.token';
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<String?> read() => _storage.read(key: _key);

  Future<void> write(String token) => _storage.write(key: _key, value: token);

  Future<void> delete() => _storage.delete(key: _key);
}
