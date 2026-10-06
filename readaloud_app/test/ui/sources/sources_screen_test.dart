import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/folder_child.dart';
import 'package:readaloud_app/repository/folder_children_lister.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/sources_library_lookup.dart';
import 'package:readaloud_app/repository/vault_data_source.dart';
import 'package:readaloud_app/ui/sources/sources_screen.dart';
import 'package:readaloud_app/viewmodel/sources_viewmodel.dart';

class _FakeSettings implements SettingsRepository {
  @override
  Future<String?> get(String key) async => 'content://tree/briefings';

  @override
  Future<void> set(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}

  @override
  Future<Map<String, String>> getAll() async => const {};
}

class _FakeVault implements VaultDataSource {
  @override
  Future<String?> pickDirectory() async => null;

  @override
  Future<List<VaultEntry>> listEntries(String rootUri) async => const [];

  @override
  Future<String> readFile(String uri) async => '';

  @override
  Future<String?> getDirectoryName(String uri) async => 'Briefings';
}

/// 直下 0 件（noMarkdown）を返し、列挙回数を数える。
class _CountingLister implements FolderChildrenLister {
  int calls = 0;

  @override
  Future<List<FolderChild>> listDirectChildren(String treeUri) async {
    calls++;
    return const [];
  }
}

class _FakeLookup implements SourcesLibraryLookup {
  @override
  Future<Set<String>> savedFolderSourceUris() async => <String>{};
}

void main() {
  testWidgets('空フォルダ（noMarkdown）でも pull-to-refresh で再列挙できる', (tester) async {
    final lister = _CountingLister();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourcesSettingsProvider.overrideWithValue(_FakeSettings()),
          sourcesVaultProvider.overrideWithValue(_FakeVault()),
          sourcesFolderListerProvider.overrideWithValue(lister),
          sourcesLibraryLookupProvider.overrideWithValue(_FakeLookup()),
        ],
        child: const MaterialApp(home: SourcesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    const message = 'このフォルダには Markdown ファイルがありません';
    expect(find.text(message), findsOneWidget);
    expect(lister.calls, 1);

    await tester.fling(find.text(message), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();

    expect(lister.calls, 2);
    expect(find.text(message), findsOneWidget);
  });
}
