abstract class SettingsRepository {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> delete(String key);
  Future<Map<String, String>> getAll();
}
