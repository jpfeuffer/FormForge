import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// OS-backed storage (Keystore / Keychain / DPAPI) for tokens and API keys.
class Secrets {
  Secrets([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const llmApiKey = 'llm.apiKey';
  static const garminOauth1 = 'garmin.oauth1';
  static const garminOauth2 = 'garmin.oauth2';

  Future<String?> read(String key) => _storage.read(key: key);

  Future<void> write(String key, String? value) => value == null || value.isEmpty
      ? _storage.delete(key: key)
      : _storage.write(key: key, value: value);
}
