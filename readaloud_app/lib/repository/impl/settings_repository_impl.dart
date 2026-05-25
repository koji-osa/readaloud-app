import '../../db/dao/settings_dao.dart';
import '../settings_repository.dart';

// TODO: Firebase同期を追加する
// 同期除外: tts_api_key / device_id / tts_used_chars / tts_reset_date
// 同期対象: その他の設定キー
// 同期タイミング: アプリ起動時
class SettingsRepositoryImpl implements SettingsRepository {
  final SettingsDao _dao = SettingsDao();

  @override
  Future<String?> get(String key) => _dao.get(key);

  @override
  Future<void> set(String key, String value) => _dao.set(key, value);

  @override
  Future<void> delete(String key) => _dao.delete(key);

  @override
  Future<Map<String, String>> getAll() => _dao.getAll();
}
