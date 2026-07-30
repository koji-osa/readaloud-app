import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/ui/widgets/folder_tree_view.dart';

class _Item {
  const _Item(this.path, this.id, [this.modifiedAt = 0]);
  final String path;
  final String id;
  final int modifiedAt;
}

void main() {
  group('buildTree', () {
    test('パスを階層化し、ディレクトリ→ファイル・名前順にソートする', () {
      final items = [
        const _Item('b.md', 'id-b'),
        const _Item('Projects/AI/note.md', 'id-note'),
        const _Item('Projects/readme.md', 'id-readme'),
        const _Item('a.md', 'id-a'),
      ];

      final root = buildTree<_Item>(items: items, pathOf: (i) => i.path);

      expect(root.children.map((n) => n.name), ['Projects', 'a.md', 'b.md']);

      final projects = root.children.first;
      expect(projects.isDirectory, isTrue);
      expect(projects.children.map((n) => n.name), ['AI', 'readme.md']);

      final ai = projects.children.first;
      expect(ai.isDirectory, isTrue);
      expect(ai.children, hasLength(1));
      expect(ai.children.first.name, 'note.md');
      expect(ai.children.first.isDirectory, isFalse);
      expect(ai.children.first.value?.id, 'id-note');
      expect(ai.children.first.path, 'Projects/AI/note.md');
    });

    test('同じディレクトリを共有する複数ファイルは1つのノードにまとめられる', () {
      final items = [
        const _Item('folder/a.md', 'id-a'),
        const _Item('folder/b.md', 'id-b'),
      ];

      final root = buildTree<_Item>(items: items, pathOf: (i) => i.path);

      expect(root.children, hasLength(1));
      expect(root.children.first.children, hasLength(2));
    });

    test('sortKeyOfを渡すと同一階層内のファイルはその値の降順(新しい順)に並ぶ', () {
      final items = [
        const _Item('a.md', 'id-a', 100),
        const _Item('b.md', 'id-b', 300),
        const _Item('c.md', 'id-c', 200),
      ];

      final root = buildTree<_Item>(
        items: items,
        pathOf: (i) => i.path,
        sortKeyOf: (i) => i.modifiedAt,
      );

      expect(root.children.map((n) => n.name), ['b.md', 'c.md', 'a.md']);
    });

    test('sortKeyOfは階層ごとに独立して適用される', () {
      final items = [
        const _Item('folder/a.md', 'id-a', 100),
        const _Item('folder/b.md', 'id-b', 300),
        const _Item('z.md', 'id-z', 1),
      ];

      final root = buildTree<_Item>(
        items: items,
        pathOf: (i) => i.path,
        sortKeyOf: (i) => i.modifiedAt,
      );

      // フォルダは常に先頭(名前順)、ファイルはsortKeyOfの降順。
      expect(root.children.map((n) => n.name), ['folder', 'z.md']);
      final folder = root.children.first;
      expect(folder.children.map((n) => n.name), ['b.md', 'a.md']);
    });

    test('sortKeyOfを渡さない場合は従来通り名前順のまま', () {
      final items = [
        const _Item('b.md', 'id-b', 300),
        const _Item('a.md', 'id-a', 100),
        const _Item('c.md', 'id-c', 200),
      ];

      final root = buildTree<_Item>(items: items, pathOf: (i) => i.path);

      expect(root.children.map((n) => n.name), ['a.md', 'b.md', 'c.md']);
    });

    test('フォルダは常に名前順で、ファイルより先に並ぶ(sortKeyOf指定時も維持)', () {
      final items = [
        const _Item('zeta/note.md', 'id-zeta', 1),
        const _Item('alpha/note.md', 'id-alpha', 1),
        const _Item('newest.md', 'id-newest', 999),
      ];

      final root = buildTree<_Item>(
        items: items,
        pathOf: (i) => i.path,
        sortKeyOf: (i) => i.modifiedAt,
      );

      expect(root.children.map((n) => n.name), ['alpha', 'zeta', 'newest.md']);
    });
  });

  group('flattenVisibleNodes', () {
    test('展開されていないディレクトリの子は含まれない', () {
      final items = [
        const _Item('folder/a.md', 'id-a'),
        const _Item('b.md', 'id-b'),
      ];
      final root = buildTree<_Item>(items: items, pathOf: (i) => i.path);

      final visible = flattenVisibleNodes<_Item>(root, {});

      expect(visible.map((v) => v.node.name), ['folder', 'b.md']);
    });

    test('展開されたディレクトリの子は深さ+1で含まれる', () {
      final items = [
        const _Item('folder/a.md', 'id-a'),
        const _Item('folder/sub/c.md', 'id-c'),
      ];
      final root = buildTree<_Item>(items: items, pathOf: (i) => i.path);

      final visible = flattenVisibleNodes<_Item>(root, {'folder'});

      expect(visible.map((v) => v.node.name), ['folder', 'sub', 'a.md']);
      expect(visible.firstWhere((v) => v.node.name == 'folder').depth, 0);
      expect(visible.firstWhere((v) => v.node.name == 'a.md').depth, 1);
      expect(visible.firstWhere((v) => v.node.name == 'sub').depth, 1);
    });

    test('孫階層もそのディレクトリが展開されていれば含まれる', () {
      final items = [const _Item('folder/sub/c.md', 'id-c')];
      final root = buildTree<_Item>(items: items, pathOf: (i) => i.path);

      final visible = flattenVisibleNodes<_Item>(root, {'folder', 'folder/sub'});

      expect(visible.map((v) => v.node.name), ['folder', 'sub', 'c.md']);
      expect(visible.firstWhere((v) => v.node.name == 'c.md').depth, 2);
    });
  });

  group('collectLeafIds / folderCheckState', () {
    late TreeNode<_Item> root;

    setUp(() {
      final items = [
        const _Item('folder/a.md', 'id-a'),
        const _Item('folder/b.md', 'id-b'),
        const _Item('other/c.md', 'id-c'),
      ];
      root = buildTree<_Item>(items: items, pathOf: (i) => i.path);
    });

    test('collectLeafIdsはディレクトリ配下の全葉ノードのidを返す', () {
      final folder = root.children.firstWhere((n) => n.name == 'folder');
      final ids = collectLeafIds<_Item>(folder, (i) => i.id);
      expect(ids, ['id-a', 'id-b']);
    });

    test('folderCheckStateは未選択ならfalse', () {
      final folder = root.children.firstWhere((n) => n.name == 'folder');
      expect(folderCheckState<_Item>(folder, {}, (i) => i.id), isFalse);
    });

    test('folderCheckStateは全選択ならtrue', () {
      final folder = root.children.firstWhere((n) => n.name == 'folder');
      expect(
        folderCheckState<_Item>(folder, {'id-a', 'id-b'}, (i) => i.id),
        isTrue,
      );
    });

    test('folderCheckStateは一部選択ならnull(中間状態)', () {
      final folder = root.children.firstWhere((n) => n.name == 'folder');
      expect(
        folderCheckState<_Item>(folder, {'id-a'}, (i) => i.id),
        isNull,
      );
    });
  });

  group('FolderTreeView (widget)', () {
    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: child));

    final items = [
      const _Item('folder/a.md', 'id-a'),
      const _Item('folder/b.md', 'id-b'),
      const _Item('root.md', 'id-root'),
    ];

    testWidgets('初期状態はフォルダが閉じており、子ノートは表示されない', (tester) async {
      await tester.pumpWidget(wrap(FolderTreeView<_Item>(
        items: items,
        pathOf: (i) => i.path,
        idOf: (i) => i.id,
        selectedIds: const {},
        onSelectionChanged: (_, __) {},
      )));

      expect(find.text('folder'), findsOneWidget);
      expect(find.text('root.md'), findsOneWidget);
      expect(find.text('a.md'), findsNothing);
      expect(find.text('b.md'), findsNothing);
    });

    testWidgets('開閉アイコンをタップするとフォルダが展開/折りたたみされる', (tester) async {
      await tester.pumpWidget(wrap(FolderTreeView<_Item>(
        items: items,
        pathOf: (i) => i.path,
        idOf: (i) => i.id,
        selectedIds: const {},
        onSelectionChanged: (_, __) {},
      )));

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      expect(find.text('a.md'), findsOneWidget);
      expect(find.text('b.md'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();

      expect(find.text('a.md'), findsNothing);
    });

    testWidgets('葉ノードの行タップで単体選択のコールバックが呼ばれる', (tester) async {
      List<String>? calledIds;
      bool? calledSelected;

      await tester.pumpWidget(wrap(FolderTreeView<_Item>(
        items: items,
        pathOf: (i) => i.path,
        idOf: (i) => i.id,
        selectedIds: const {},
        onSelectionChanged: (ids, selected) {
          calledIds = ids;
          calledSelected = selected;
        },
      )));

      await tester.tap(find.text('root.md'));
      await tester.pumpAndSettle();

      expect(calledIds, ['id-root']);
      expect(calledSelected, isTrue);
    });

    testWidgets('未選択フォルダの行タップで配下全件がまとめて選択される', (tester) async {
      List<String>? calledIds;
      bool? calledSelected;

      await tester.pumpWidget(wrap(FolderTreeView<_Item>(
        items: items,
        pathOf: (i) => i.path,
        idOf: (i) => i.id,
        selectedIds: const {},
        onSelectionChanged: (ids, selected) {
          calledIds = ids;
          calledSelected = selected;
        },
      )));

      await tester.tap(find.text('folder'));
      await tester.pumpAndSettle();

      expect(calledIds, unorderedEquals(['id-a', 'id-b']));
      expect(calledSelected, isTrue);
    });

    testWidgets('全選択済みフォルダの行タップで配下全件がまとめて解除される', (tester) async {
      List<String>? calledIds;
      bool? calledSelected;

      await tester.pumpWidget(wrap(FolderTreeView<_Item>(
        items: items,
        pathOf: (i) => i.path,
        idOf: (i) => i.id,
        selectedIds: const {'id-a', 'id-b'},
        onSelectionChanged: (ids, selected) {
          calledIds = ids;
          calledSelected = selected;
        },
      )));

      await tester.tap(find.text('folder'));
      await tester.pumpAndSettle();

      expect(calledIds, unorderedEquals(['id-a', 'id-b']));
      expect(calledSelected, isFalse);
    });

    testWidgets('sortKeyOfを渡すと展開したフォルダ内のファイルが降順で表示される', (tester) async {
      final sortedItems = [
        const _Item('folder/old.md', 'id-old', 100),
        const _Item('folder/new.md', 'id-new', 300),
      ];

      await tester.pumpWidget(wrap(FolderTreeView<_Item>(
        items: sortedItems,
        pathOf: (i) => i.path,
        idOf: (i) => i.id,
        selectedIds: const {},
        onSelectionChanged: (_, __) {},
        sortKeyOf: (i) => i.modifiedAt,
      )));

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      final newOffset = tester.getTopLeft(find.text('new.md')).dy;
      final oldOffset = tester.getTopLeft(find.text('old.md')).dy;
      expect(newOffset, lessThan(oldOffset));
    });
  });
}
