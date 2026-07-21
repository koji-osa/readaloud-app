import '../../model/setting.dart';
import '../obsidian_repository.dart';
import '../settings_repository.dart';
import '../vault_data_source.dart';

/// [VaultDataSource]と[SettingsRepository]を用いた[ObsidianRepository]の実装。
class ObsidianRepositoryImpl implements ObsidianRepository {
  ObsidianRepositoryImpl(this._vaultDataSource, this._settingsRepository);

  final VaultDataSource _vaultDataSource;
  final SettingsRepository _settingsRepository;

  @override
  Future<String?> pickVaultDirectory() async {
    final uri = await _vaultDataSource.pickDirectory();
    if (uri != null) {
      await _settingsRepository.set(SettingKeys.obsidianVaultUri, uri);
    }
    return uri;
  }

  @override
  Future<List<VaultEntry>> listNotes() async {
    final vaultUri = await _settingsRepository.get(
      SettingKeys.obsidianVaultUri,
    );
    if (vaultUri == null) return [];
    return _vaultDataSource.listEntries(vaultUri);
  }

  @override
  Future<String> readNoteContent(String uri) {
    // SAFのURIは末尾が実際のファイル名と一致する保証がないため推測しない。
    // relativePath/nameはreadFile()の実装(uriのみ参照)では使用されない
    // ため、便宜的に空文字列を設定している。
    final entry = VaultEntry(uri: uri, relativePath: '', name: '');
    return _vaultDataSource.readFile(entry);
  }

  @override
  Future<void> writeNote(String path, String content) {
    throw UnimplementedError('writeNote is not implemented in Phase1');
  }
}
