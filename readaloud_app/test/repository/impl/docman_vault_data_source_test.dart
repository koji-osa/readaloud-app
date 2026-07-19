import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/repository/impl/docman_vault_data_source.dart';
import 'package:readaloud_app/repository/vault_data_source.dart';

void main() {
  group('DocmanVaultDataSource', () {
    late Map<String, _FakeDocmanNode> nodesByUri;
    late DocmanVaultDataSource dataSource;

    setUp(() {
      // root/
      //   note.md            (content: "# Root Note")
      //   memo.txt
      //   Projects/
      //     AI/
      //       note.md
      //     empty/
      final aiNote = _FakeDocmanNode(
        uri: 'content://vault/root/Projects/AI/note.md',
        name: 'note.md',
        isDirectory: false,
      );
      final aiDir = _FakeDocmanNode(
        uri: 'content://vault/root/Projects/AI',
        name: 'AI',
        isDirectory: true,
        children: [aiNote],
      );
      final emptyDir = _FakeDocmanNode(
        uri: 'content://vault/root/Projects/empty',
        name: 'empty',
        isDirectory: true,
      );
      final projectsDir = _FakeDocmanNode(
        uri: 'content://vault/root/Projects',
        name: 'Projects',
        isDirectory: true,
        children: [aiDir, emptyDir],
      );
      final rootNote = _FakeDocmanNode(
        uri: 'content://vault/root/note.md',
        name: 'note.md',
        isDirectory: false,
        content: '# Root Note',
      );
      final memo = _FakeDocmanNode(
        uri: 'content://vault/root/memo.txt',
        name: 'memo.txt',
        isDirectory: false,
      );
      final root = _FakeDocmanNode(
        uri: 'content://vault/root',
        name: 'root',
        isDirectory: true,
        children: [rootNote, memo, projectsDir],
      );

      nodesByUri = {
        for (final node in [
          root,
          rootNote,
          memo,
          projectsDir,
          aiDir,
          aiNote,
          emptyDir,
        ])
          node.uri: node,
      };

      // docman.DocumentFile.fromUri相当の解決処理をモック化する。
      dataSource = DocmanVaultDataSource(
        resolver: (uri) async => nodesByUri[uri],
      );
    });

    test(
      'listEntries collects only .md files recursively with relative paths',
      () async {
        final entries = await dataSource.listEntries('content://vault/root');

        expect(entries, hasLength(2));
        expect(
          entries,
          containsAll(const [
            VaultEntry(
              uri: 'content://vault/root/note.md',
              relativePath: 'note.md',
              name: 'note.md',
            ),
            VaultEntry(
              uri: 'content://vault/root/Projects/AI/note.md',
              relativePath: 'Projects/AI/note.md',
              name: 'note.md',
            ),
          ]),
        );
      },
    );

    test('listEntries returns an empty list when root cannot be resolved',
        () async {
      final entries = await dataSource.listEntries('content://unknown');
      expect(entries, isEmpty);
    });

    test('readFile resolves the entry uri and returns its content', () async {
      const entry = VaultEntry(
        uri: 'content://vault/root/note.md',
        relativePath: 'note.md',
        name: 'note.md',
      );

      final content = await dataSource.readFile(entry);

      expect(content, '# Root Note');
    });

    test('readFile throws when the file cannot be resolved', () async {
      const entry = VaultEntry(
        uri: 'content://vault/missing.md',
        relativePath: 'missing.md',
        name: 'missing.md',
      );

      expect(() => dataSource.readFile(entry), throwsStateError);
    });

    test(
      'listEntries returns entries sorted by relativePath regardless of '
      'the order listChildren() returns them in',
      () async {
        // listChildren()がSAFプロバイダ依存の非決定的な順序で返した場合を想定し、
        // ディレクトリ・ファイルをアルファベット順とは逆順に並べたfakeを組む。
        final zNote = _FakeDocmanNode(
          uri: 'content://vault/root2/zeta.md',
          name: 'zeta.md',
          isDirectory: false,
        );
        final bNoteInSub = _FakeDocmanNode(
          uri: 'content://vault/root2/sub/beta.md',
          name: 'beta.md',
          isDirectory: false,
        );
        final subDir = _FakeDocmanNode(
          uri: 'content://vault/root2/sub',
          name: 'sub',
          isDirectory: true,
          children: [bNoteInSub],
        );
        final aNote = _FakeDocmanNode(
          uri: 'content://vault/root2/alpha.md',
          name: 'alpha.md',
          isDirectory: false,
        );
        final root2 = _FakeDocmanNode(
          uri: 'content://vault/root2',
          name: 'root2',
          isDirectory: true,
          // 意図的にrelativePathの昇順とは異なる順序で並べる。
          children: [zNote, subDir, aNote],
        );

        final unsortedDataSource = DocmanVaultDataSource(
          resolver: (uri) async => {
            root2.uri: root2,
            zNote.uri: zNote,
            subDir.uri: subDir,
            bNoteInSub.uri: bNoteInSub,
            aNote.uri: aNote,
          }[uri],
        );

        final entries =
            await unsortedDataSource.listEntries('content://vault/root2');

        expect(
          entries.map((e) => e.relativePath).toList(),
          const ['alpha.md', 'sub/beta.md', 'zeta.md'],
        );
      },
    );
  });
}

/// docmanの`DocumentFile`をモック化するためのフェイク実装。
class _FakeDocmanNode implements DocmanNode {
  _FakeDocmanNode({
    required this.uri,
    required this.name,
    required this.isDirectory,
    List<_FakeDocmanNode> children = const [],
    this.content = '',
  }) : _children = children;

  @override
  final String uri;

  @override
  final String name;

  @override
  final bool isDirectory;

  final String content;
  final List<_FakeDocmanNode> _children;

  @override
  Future<List<DocmanNode>> listChildren() async => _children;

  @override
  Future<String> readAsString() async => content;
}
