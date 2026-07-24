import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/raw_content.dart';
import 'package:readaloud_app/repository/obsidian_repository.dart';
import 'package:readaloud_app/repository/vault_data_source.dart';
import 'package:readaloud_app/usecase/content/import_content_usecase.dart';
import 'package:readaloud_app/usecase/obsidian/obsidian_importer.dart';
import 'package:readaloud_app/util/content_parser.dart';
import 'package:readaloud_app/viewmodel/obsidian_import_viewmodel.dart';

void main() {
  group('ObsidianImportViewModel', () {
    late _FakeObsidianRepository repository;
    late _FakeObsidianImporter importer;
    late _FakeImportContentUseCase importContent;
    late ObsidianImportViewModel viewModel;

    setUp(() {
      repository = _FakeObsidianRepository();
      importer = _FakeObsidianImporter();
      importContent = _FakeImportContentUseCase();
      viewModel = ObsidianImportViewModel(
        repository: repository,
        importer: importer,
        importContent: importContent,
      );
    });

    test('loadNotes()でVault設定済みの場合はノート一覧が状態に反映される', () async {
      repository.vaultUri = 'content://vault/root';
      repository.notes = const [
        VaultEntry(uri: 'content://vault/a.md', relativePath: 'a.md', name: 'a.md'),
        VaultEntry(uri: 'content://vault/b.md', relativePath: 'folder/b.md', name: 'b.md'),
      ];

      await viewModel.loadNotes();

      expect(viewModel.state.vaultConfigured, isTrue);
      expect(viewModel.state.isLoading, isFalse);
      expect(viewModel.state.notes, hasLength(2));
    });

    test('loadNotes()でVault未設定の場合はvaultConfiguredがfalseになる', () async {
      repository.vaultUri = null;
      repository.notes = const [];

      await viewModel.loadNotes();

      expect(viewModel.state.vaultConfigured, isFalse);
      expect(viewModel.state.isLoading, isFalse);
      expect(viewModel.state.notes, isEmpty);
    });

    test('toggleSelection()で選択/選択解除が切り替わる', () async {
      viewModel.toggleSelection('content://vault/a.md');
      expect(viewModel.state.selectedUris, {'content://vault/a.md'});

      viewModel.toggleSelection('content://vault/b.md');
      expect(viewModel.state.selectedUris, {
        'content://vault/a.md',
        'content://vault/b.md',
      });

      viewModel.toggleSelection('content://vault/a.md');
      expect(viewModel.state.selectedUris, {'content://vault/b.md'});
    });

    test('importSelected()で複数選択して取り込むと成功/失敗が正しく集計される', () async {
      viewModel.toggleSelection('content://vault/a.md');
      viewModel.toggleSelection('content://vault/b.md');
      viewModel.toggleSelection('content://vault/c.md');

      importer.results = [
        ImportNoteResult(
          noteUri: 'content://vault/a.md',
          content: const RawContent(text: '# A'),
        ),
        ImportNoteResult(
          noteUri: 'content://vault/b.md',
          error: Exception('read failed'),
        ),
        ImportNoteResult(
          noteUri: 'content://vault/c.md',
          content: const RawContent(text: '# C'),
        ),
      ];

      await viewModel.importSelected();

      expect(viewModel.state.importResult?.successCount, 2);
      expect(viewModel.state.importResult?.failureCount, 1);
      expect(viewModel.state.selectedUris, isEmpty);
      expect(viewModel.state.isImporting, isFalse);
      expect(importContent.executedRaws, hasLength(2));
    });

    test('importSelected()でImportContentUseCase側が失敗した場合も失敗として集計される', () async {
      viewModel.toggleSelection('content://vault/a.md');

      importer.results = [
        ImportNoteResult(
          noteUri: 'content://vault/a.md',
          content: const RawContent(text: '# A'),
        ),
      ];
      importContent.shouldThrow = true;

      await viewModel.importSelected();

      expect(viewModel.state.importResult?.successCount, 0);
      expect(viewModel.state.importResult?.failureCount, 1);
    });

    test('loadNotes()でlistNotes()が例外を投げてもisLoadingがfalseに戻る', () async {
      repository.vaultUri = 'content://vault/root';
      repository.shouldThrowOnListNotes = true;

      await expectLater(viewModel.loadNotes(), throwsException);

      expect(viewModel.state.isLoading, isFalse);
    });

    test('importSelected()でimporter.importNotes()が例外を投げてもisImportingがfalseに戻る', () async {
      viewModel.toggleSelection('content://vault/a.md');
      importer.shouldThrow = true;

      await expectLater(viewModel.importSelected(), throwsException);

      expect(viewModel.state.isImporting, isFalse);
    });

    test('clearImportResult()でimportResultがnullに戻る', () async {
      viewModel.toggleSelection('content://vault/a.md');
      importer.results = [
        ImportNoteResult(
          noteUri: 'content://vault/a.md',
          content: const RawContent(text: '# A'),
        ),
      ];

      await viewModel.importSelected();
      expect(viewModel.state.importResult, isNotNull);

      viewModel.clearImportResult();
      expect(viewModel.state.importResult, isNull);
    });
  });
}

class _FakeObsidianRepository implements ObsidianRepository {
  String? vaultUri;
  List<VaultEntry> notes = const [];
  bool shouldThrowOnListNotes = false;

  @override
  Future<String?> getVaultUri() async => vaultUri;

  @override
  Future<List<VaultEntry>> listNotes() async {
    if (shouldThrowOnListNotes) {
      throw Exception('list notes failed');
    }
    return notes;
  }

  @override
  Future<String?> pickVaultDirectory() async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<String> readNoteContent(String uri) async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<void> writeNote(String path, String content) async =>
      throw UnimplementedError('not used in this test');
}

class _FakeObsidianImporter implements ObsidianImporter {
  List<ImportNoteResult> results = const [];
  bool shouldThrow = false;

  @override
  Future<List<ImportNoteResult>> importNotes(List<String> noteUris) async {
    if (shouldThrow) {
      throw Exception('import notes failed');
    }
    return results;
  }
}

class _FakeImportContentUseCase implements ImportContentUseCase {
  final List<RawContent> executedRaws = [];
  bool shouldThrow = false;

  @override
  Future<Content> execute({
    required RawContent raw,
    required ContentParser parser,
    required String sourceType,
    String? sourceUrl,
    String? sourceFilename,
  }) async {
    if (shouldThrow) {
      throw Exception('save failed');
    }
    executedRaws.add(raw);
    return Content(title: 'dummy', body: raw.text, sourceType: sourceType);
  }
}
