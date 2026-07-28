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
          entry: const VaultEntry(
            uri: 'content://vault/a.md',
            relativePath: 'a.md',
            name: 'a.md',
          ),
          content: const RawContent(text: '# A'),
        ),
        ImportNoteResult(
          entry: const VaultEntry(
            uri: 'content://vault/b.md',
            relativePath: 'b.md',
            name: 'b.md',
          ),
          error: Exception('read failed'),
        ),
        ImportNoteResult(
          entry: const VaultEntry(
            uri: 'content://vault/c.md',
            relativePath: 'c.md',
            name: 'c.md',
          ),
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

    test('importSelected(shouldClean: true)はImportContentUseCase.execute()にshouldClean:trueを渡す', () async {
      viewModel.toggleSelection('content://vault/a.md');
      importer.results = [
        ImportNoteResult(
          entry: const VaultEntry(
            uri: 'content://vault/a.md',
            relativePath: 'a.md',
            name: 'a.md',
          ),
          content: const RawContent(text: '# A'),
        ),
      ];

      await viewModel.importSelected(shouldClean: true);

      expect(importContent.capturedShouldCleans, [true]);
    });

    test('importSelected()をshouldClean未指定で呼ぶとImportContentUseCase.execute()にshouldClean:falseを渡す', () async {
      viewModel.toggleSelection('content://vault/a.md');
      importer.results = [
        ImportNoteResult(
          entry: const VaultEntry(
            uri: 'content://vault/a.md',
            relativePath: 'a.md',
            name: 'a.md',
          ),
          content: const RawContent(text: '# A'),
        ),
      ];

      await viewModel.importSelected();

      expect(importContent.capturedShouldCleans, [false]);
    });

    test('importSelected()でImportContentUseCase側が失敗した場合も失敗として集計される', () async {
      viewModel.toggleSelection('content://vault/a.md');

      importer.results = [
        ImportNoteResult(
          entry: const VaultEntry(
            uri: 'content://vault/a.md',
            relativePath: 'a.md',
            name: 'a.md',
          ),
          content: const RawContent(text: '# A'),
        ),
      ];
      importContent.shouldThrow = true;

      await viewModel.importSelected();

      expect(viewModel.state.importResult?.successCount, 0);
      expect(viewModel.state.importResult?.failureCount, 1);
    });

    test('importSelected()はstate.notesから選択URIに対応するVaultEntryを引き当ててImporterへ渡す', () async {
      repository.vaultUri = 'content://vault/root';
      repository.notes = const [
        VaultEntry(uri: 'content://vault/a.md', relativePath: 'a.md', name: 'a.md'),
        VaultEntry(uri: 'content://vault/b.md', relativePath: 'folder/b.md', name: 'b.md'),
      ];
      await viewModel.loadNotes();

      viewModel.toggleSelection('content://vault/b.md');
      importer.results = [
        ImportNoteResult(
          entry: const VaultEntry(
            uri: 'content://vault/b.md',
            relativePath: 'folder/b.md',
            name: 'b.md',
          ),
          content: const RawContent(text: '# B'),
        ),
      ];

      await viewModel.importSelected();

      expect(importer.capturedEntries, hasLength(1));
      expect(importer.capturedEntries.single.uri, 'content://vault/b.md');
      expect(importer.capturedEntries.single.name, 'b.md');
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
          entry: const VaultEntry(
            uri: 'content://vault/a.md',
            relativePath: 'a.md',
            name: 'a.md',
          ),
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
  Future<String?> getVaultName() async =>
      throw UnimplementedError('not used in this test');

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
  final List<VaultEntry> capturedEntries = [];

  @override
  Future<List<ImportNoteResult>> importNotes(List<VaultEntry> entries) async {
    capturedEntries.addAll(entries);
    if (shouldThrow) {
      throw Exception('import notes failed');
    }
    return results;
  }
}

class _FakeImportContentUseCase implements ImportContentUseCase {
  final List<RawContent> executedRaws = [];
  final List<bool> capturedShouldCleans = [];
  bool shouldThrow = false;

  @override
  Future<Content> execute({
    required RawContent raw,
    required ContentParser parser,
    required String sourceType,
    String? sourceUrl,
    String? sourceFilename,
    bool shouldClean = false,
  }) async {
    if (shouldThrow) {
      throw Exception('save failed');
    }
    executedRaws.add(raw);
    capturedShouldCleans.add(shouldClean);
    return Content(title: 'dummy', body: raw.text, sourceType: sourceType);
  }
}
