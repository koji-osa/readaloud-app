import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/obsidian_repository.dart';
import 'package:readaloud_app/repository/vault_data_source.dart';
import 'package:readaloud_app/ui/add/add_screen.dart';
import 'package:readaloud_app/usecase/content/import_content_usecase.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/usecase/obsidian/obsidian_importer.dart';
import 'package:readaloud_app/viewmodel/obsidian_import_viewmodel.dart';

class _FakeObsidianRepository implements ObsidianRepository {
  _FakeObsidianRepository(this.notes);
  final List<VaultEntry> notes;

  @override
  Future<String?> pickVaultDirectory() async => null;

  @override
  Future<String?> getVaultUri() async => 'content://fake-vault';

  @override
  Future<String?> getVaultName() async => 'FakeVault';

  @override
  Future<List<VaultEntry>> listNotes() async => notes;

  @override
  Future<String> readNoteContent(String uri) async => '';

  @override
  Future<void> writeNote(String path, String content) async {}
}

class _FakeContentRepository implements ContentRepository {
  @override
  Future<List<Content>> getAll() async => [];

  @override
  Future<List<Content>> getByStatus(String status) async => [];

  @override
  Future<Content?> getById(String id) async => null;

  @override
  Future<void> save(Content content) async {}

  @override
  Future<void> update(Content content) async {}

  @override
  Future<void> delete(String id) async {}
}

void main() {
  testWidgets('Obsidianタブでモードを切り替えても選択状態(selectedUris)は維持される', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final fakeRepo = _FakeObsidianRepository([
      VaultEntry(
        uri: 'uri-a',
        relativePath: 'Projects/a.md',
        name: 'a.md',
        lastModified: now,
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          obsidianImportViewModelProvider.overrideWith(
            (ref) => ObsidianImportViewModel(
              repository: fakeRepo,
              importer: ObsidianImporter(fakeRepo),
              importContent:
                  ImportContentUseCase(SaveContentUseCase(_FakeContentRepository())),
            ),
          ),
        ],
        child: const MaterialApp(home: AddScreen()),
      ),
    );

    await tester.pumpAndSettle();

    // Obsidianタブへ切り替え
    await tester.tap(find.text('Obsidian'));
    await tester.pumpAndSettle();

    // 初期状態: フォルダモードでノートが表示される(展開が必要)
    expect(find.text('フォルダで探す'), findsOneWidget);
    expect(find.text('日付で探す'), findsOneWidget);

    // 日付モードに切り替えてノートを選択する
    await tester.tap(find.text('日付で探す'));
    await tester.pumpAndSettle();

    // 日付モードではフォルダ階層を含むrelativePathではなく、ファイル名のみが表示される
    expect(find.text('Projects/a.md'), findsNothing);
    expect(find.text('a.md'), findsOneWidget);
    await tester.tap(find.text('a.md'));
    await tester.pumpAndSettle();

    expect(find.textContaining('選択したノートを取り込む (1件)'), findsOneWidget);

    // フォルダモードに戻しても選択件数は維持される
    await tester.tap(find.text('フォルダで探す'));
    await tester.pumpAndSettle();

    expect(find.textContaining('選択したノートを取り込む (1件)'), findsOneWidget);
  });
}
