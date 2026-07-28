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
  Future<String?> getVaultUri() {
    return _settingsRepository.get(SettingKeys.obsidianVaultUri);
  }

  @override
  Future<String?> getVaultName() async {
    final vaultUri = await getVaultUri();
    if (vaultUri == null) return null;
    try {
      return await _vaultDataSource.getDirectoryName(vaultUri);
    } catch (_) {
      return null;
    }
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
    return _vaultDataSource.readFile(uri);
  }

  @override
  Future<void> writeNote(String path, String content) {
    throw UnimplementedError('writeNote is not implemented in Phase1');
  }
}
