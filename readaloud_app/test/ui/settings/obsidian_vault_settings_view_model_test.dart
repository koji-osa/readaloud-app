import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/repository/obsidian_repository.dart';
import 'package:readaloud_app/repository/vault_data_source.dart';
import 'package:readaloud_app/ui/settings/settings_screen.dart';

void main() {
  group('ObsidianVaultSettingsViewModel', () {
    test('初期化時にgetVaultUri()の結果が状態に反映される', () async {
      final repository = _FakeObsidianRepository()
        ..vaultUri = 'content://vault/root';

      final viewModel = ObsidianVaultSettingsViewModel(repository);
      await pumpEventQueue();

      expect(viewModel.state, 'content://vault/root');
    });

    test('pickVaultDirectory()で選択に成功すると状態が更新される', () async {
      final repository = _FakeObsidianRepository();
      final viewModel = ObsidianVaultSettingsViewModel(repository);
      await pumpEventQueue();
      expect(viewModel.state, isNull);

      repository.pickResult = 'content://vault/new';
      await viewModel.pickVaultDirectory();

      expect(viewModel.state, 'content://vault/new');
    });

    test('pickVaultDirectory()でユーザーがキャンセルした場合は状態が維持される', () async {
      final repository = _FakeObsidianRepository()
        ..vaultUri = 'content://vault/existing';
      final viewModel = ObsidianVaultSettingsViewModel(repository);
      await pumpEventQueue();
      expect(viewModel.state, 'content://vault/existing');

      repository.pickResult = null; // キャンセル
      await viewModel.pickVaultDirectory();

      expect(viewModel.state, 'content://vault/existing');
    });
  });
}

class _FakeObsidianRepository implements ObsidianRepository {
  String? vaultUri;
  String? pickResult;

  @override
  Future<String?> getVaultUri() async => vaultUri;

  @override
  Future<String?> pickVaultDirectory() async {
    if (pickResult != null) {
      vaultUri = pickResult;
    }
    return pickResult;
  }

  @override
  Future<List<VaultEntry>> listNotes() async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<String> readNoteContent(String uri) async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<void> writeNote(String path, String content) async =>
      throw UnimplementedError('not used in this test');
}
