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
      final content = await dataSource.readFile(
        'content://vault/root/note.md',
      );

      expect(content, '# Root Note');
    });

    test('readFile throws when the file cannot be resolved', () async {
      expect(
        () => dataSource.readFile('content://vault/missing.md'),
        throwsStateError,
      );
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

    test(
      'listEntries places entries with unknown lastModified (0) at the end',
      () async {
        final known = _FakeDocmanNode(
          uri: 'content://vault/root4/aaa.md',
          name: 'aaa.md',
          isDirectory: false,
          lastModified: 1000,
        );
        final unknown = _FakeDocmanNode(
          uri: 'content://vault/root4/zzz.md',
          name: 'zzz.md',
          isDirectory: false,
        );
        final root4 = _FakeDocmanNode(
          uri: 'content://vault/root4',
          name: 'root4',
          isDirectory: true,
          // relativePath順ではunknownの方が先に来るはずだが、
          // lastModifiedが不明なので末尾に回されるべき。
          children: [unknown, known],
        );

        final dataSource4 = DocmanVaultDataSource(
          resolver: (uri) async => {
            root4.uri: root4,
            known.uri: known,
            unknown.uri: unknown,
          }[uri],
        );

        final entries = await dataSource4.listEntries('content://vault/root4');

        expect(
          entries.map((e) => e.relativePath).toList(),
          const ['aaa.md', 'zzz.md'],
        );
      },
    );

    test(
      'listEntries sorts entries with known lastModified in descending order',
      () async {
        final oldest = _FakeDocmanNode(
          uri: 'content://vault/root5/oldest.md',
          name: 'oldest.md',
          isDirectory: false,
          lastModified: 1000,
        );
        final newest = _FakeDocmanNode(
          uri: 'content://vault/root5/newest.md',
          name: 'newest.md',
          isDirectory: false,
          lastModified: 3000,
        );
        final middle = _FakeDocmanNode(
          uri: 'content://vault/root5/middle.md',
          name: 'middle.md',
          isDirectory: false,
          lastModified: 2000,
        );
        final root5 = _FakeDocmanNode(
          uri: 'content://vault/root5',
          name: 'root5',
          isDirectory: true,
          children: [oldest, newest, middle],
        );

        final dataSource5 = DocmanVaultDataSource(
          resolver: (uri) async => {
            root5.uri: root5,
            oldest.uri: oldest,
            newest.uri: newest,
            middle.uri: middle,
          }[uri],
        );

        final entries = await dataSource5.listEntries('content://vault/root5');

        expect(
          entries.map((e) => e.relativePath).toList(),
          const ['newest.md', 'middle.md', 'oldest.md'],
        );
      },
    );

    test(
      'listEntries breaks ties on identical lastModified by relativePath '
      'ascending',
      () async {
        final zeta = _FakeDocmanNode(
          uri: 'content://vault/root6/zeta.md',
          name: 'zeta.md',
          isDirectory: false,
          lastModified: 5000,
        );
        final alpha = _FakeDocmanNode(
          uri: 'content://vault/root6/alpha.md',
          name: 'alpha.md',
          isDirectory: false,
          lastModified: 5000,
        );
        final root6 = _FakeDocmanNode(
          uri: 'content://vault/root6',
          name: 'root6',
          isDirectory: true,
          children: [zeta, alpha],
        );

        final dataSource6 = DocmanVaultDataSource(
          resolver: (uri) async => {
            root6.uri: root6,
            zeta.uri: zeta,
            alpha.uri: alpha,
          }[uri],
        );

        final entries = await dataSource6.listEntries('content://vault/root6');

        expect(
          entries.map((e) => e.relativePath).toList(),
          const ['alpha.md', 'zeta.md'],
        );
      },
    );

    test(
      'listEntries excludes .trash/ folder and its contents',
      () async {
        final trashedNote = _FakeDocmanNode(
          uri: 'content://vault/root7/.trash/deleted.md',
          name: 'deleted.md',
          isDirectory: false,
        );
        final trashDir = _FakeDocmanNode(
          uri: 'content://vault/root7/.trash',
          name: '.trash',
          isDirectory: true,
          children: [trashedNote],
        );
        final visibleNote = _FakeDocmanNode(
          uri: 'content://vault/root7/note.md',
          name: 'note.md',
          isDirectory: false,
        );
        final root7 = _FakeDocmanNode(
          uri: 'content://vault/root7',
          name: 'root7',
          isDirectory: true,
          children: [visibleNote, trashDir],
        );

        final dataSource7 = DocmanVaultDataSource(
          resolver: (uri) async => {
            root7.uri: root7,
            visibleNote.uri: visibleNote,
            trashDir.uri: trashDir,
            trashedNote.uri: trashedNote,
          }[uri],
        );

        final entries = await dataSource7.listEntries('content://vault/root7');

        expect(
          entries.map((e) => e.relativePath).toList(),
          const ['note.md'],
        );
      },
    );

    test(
      'listEntries excludes .obsidian/ folder and its contents',
      () async {
        final configFile = _FakeDocmanNode(
          uri: 'content://vault/root8/.obsidian/config.md',
          name: 'config.md',
          isDirectory: false,
        );
        final obsidianDir = _FakeDocmanNode(
          uri: 'content://vault/root8/.obsidian',
          name: '.obsidian',
          isDirectory: true,
          children: [configFile],
        );
        final visibleNote = _FakeDocmanNode(
          uri: 'content://vault/root8/note.md',
          name: 'note.md',
          isDirectory: false,
        );
        final root8 = _FakeDocmanNode(
          uri: 'content://vault/root8',
          name: 'root8',
          isDirectory: true,
          children: [visibleNote, obsidianDir],
        );

        final dataSource8 = DocmanVaultDataSource(
          resolver: (uri) async => {
            root8.uri: root8,
            visibleNote.uri: visibleNote,
            obsidianDir.uri: obsidianDir,
            configFile.uri: configFile,
          }[uri],
        );

        final entries = await dataSource8.listEntries('content://vault/root8');

        expect(
          entries.map((e) => e.relativePath).toList(),
          const ['note.md'],
        );
      },
    );

    test(
      'listEntries terminates and does not duplicate entries when a '
      'directory cycle exists',
      () async {
        // loop/
        //   note.md
        //   (子ディレクトリとしてrootへ循環参照するself)
        final loopNote = _FakeDocmanNode(
          uri: 'content://vault/root3/loop/note.md',
          name: 'note.md',
          isDirectory: false,
        );
        final loopDir = _FakeDocmanNode(
          uri: 'content://vault/root3/loop',
          name: 'loop',
          isDirectory: true,
          // children は後から差し込む（自己参照を組むため）。
        );
        loopDir.setChildrenForCycleTest([loopNote, loopDir]);

        final unsortedDataSource = DocmanVaultDataSource(
          resolver: (uri) async => {
            loopDir.uri: loopDir,
            loopNote.uri: loopNote,
          }[uri],
        );

        final entries =
            await unsortedDataSource.listEntries('content://vault/root3/loop')
                .timeout(const Duration(seconds: 5));

        expect(
          entries.map((e) => e.relativePath).toList(),
          const ['note.md'],
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
    this.lastModified = 0,
  }) : _children = List.of(children);

  @override
  final String uri;

  @override
  final String name;

  @override
  final bool isDirectory;

  @override
  final int lastModified;

  final String content;
  final List<_FakeDocmanNode> _children;

  /// 循環参照テストのため、構築後に子ノード（自己参照を含む）を差し込む。
  void setChildrenForCycleTest(List<_FakeDocmanNode> children) {
    _children
      ..clear()
      ..addAll(children);
  }

  @override
  Future<List<DocmanNode>> listChildren() async => _children;

  @override
  Future<String> readAsString() async => content;
}
