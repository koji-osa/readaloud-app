import 'package:flutter/material.dart';

/// スラッシュ区切りのパスを持つ項目群を階層構造で表現する汎用ツリーノード。
///
/// ドメイン固有の型に依存しないよう、値は型パラメータ[T]として保持する。
/// ディレクトリノードと葉(リーフ)ノードを[isDirectory]フラグで区別する
/// (種類ごとにクラスを分けるほどの複雑さは現状不要なため)。
class TreeNode<T> {
  TreeNode({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.value,
  }) : children = [];

  /// このノード自身の表示名(パスの最後のセグメント)。
  final String name;

  /// ルートからのフルパス。展開状態のキーや同一ディレクトリの判定に使う。
  final String path;

  final bool isDirectory;

  /// 葉ノードの場合のみ値を持つ。ディレクトリノードはnull。
  final T? value;

  /// ディレクトリノードの子。葉ノードでは常に空。
  final List<TreeNode<T>> children;
}

/// [items]を[pathOf]でパス分解し、階層化した木を構築する。
///
/// 戻り値はパスを持たない仮想的なルートノード(表示はされず、
/// その子要素がツリーのトップレベルとして扱われる)。
/// 各階層内は「ディレクトリが先(名前順)、ファイルが後」に並ぶ。
/// ファイル同士の順序は[sortKeyOf]が返す値の降順。[sortKeyOf]がnullの場合は
/// ディレクトリと同じく名前順にフォールバックする。
TreeNode<T> buildTree<T>({
  required List<T> items,
  required String Function(T item) pathOf,
  Comparable Function(T item)? sortKeyOf,
}) {
  final root = TreeNode<T>(name: '', path: '', isDirectory: true);

  for (final item in items) {
    final segments =
        pathOf(item).split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) continue;

    var current = root;
    var currentPath = '';
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      currentPath = currentPath.isEmpty ? segment : '$currentPath/$segment';
      final isLeaf = i == segments.length - 1;

      if (isLeaf) {
        current.children.add(TreeNode<T>(
          name: segment,
          path: currentPath,
          isDirectory: false,
          value: item,
        ));
        continue;
      }

      TreeNode<T>? child;
      for (final c in current.children) {
        if (c.isDirectory && c.path == currentPath) {
          child = c;
          break;
        }
      }
      if (child == null) {
        child = TreeNode<T>(name: segment, path: currentPath, isDirectory: true);
        current.children.add(child);
      }
      current = child;
    }
  }

  _sortChildrenRecursively(root, sortKeyOf);
  return root;
}

void _sortChildrenRecursively<T>(
  TreeNode<T> node,
  Comparable Function(T item)? sortKeyOf,
) {
  node.children.sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    if (!a.isDirectory && sortKeyOf != null) {
      // ファイル同士は更新日時などのsortKeyOfの降順(新しい順)に並べる。
      return sortKeyOf(b.value as T).compareTo(sortKeyOf(a.value as T));
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  for (final child in node.children) {
    if (child.isDirectory) _sortChildrenRecursively(child, sortKeyOf);
  }
}

/// [flattenVisibleNodes]が返す1行分のデータ。表示上のインデント計算に[depth]を使う。
class VisibleTreeNode<T> {
  const VisibleTreeNode({required this.node, required this.depth});

  final TreeNode<T> node;
  final int depth;
}

/// [expandedPaths]に含まれるディレクトリだけを展開した状態で、
/// 表示すべきノードを深さ優先・平坦なリストに変換する。
///
/// 深くネストされたWidgetツリーを作らず、ListView.builderでそのまま
/// 描画できる形にするための変換ロジック。
List<VisibleTreeNode<T>> flattenVisibleNodes<T>(
  TreeNode<T> root,
  Set<String> expandedPaths,
) {
  final result = <VisibleTreeNode<T>>[];

  void visit(TreeNode<T> node, int depth) {
    for (final child in node.children) {
      result.add(VisibleTreeNode<T>(node: child, depth: depth));
      if (child.isDirectory && expandedPaths.contains(child.path)) {
        visit(child, depth + 1);
      }
    }
  }

  visit(root, 0);
  return result;
}

/// [node]配下(自分自身が葉ノードの場合は自分自身)にある全葉ノードのIDを集める。
List<String> collectLeafIds<T>(TreeNode<T> node, String Function(T item) idOf) {
  final ids = <String>[];

  void visit(TreeNode<T> n) {
    if (n.isDirectory) {
      for (final child in n.children) {
        visit(child);
      }
    } else if (n.value != null) {
      ids.add(idOf(n.value as T));
    }
  }

  visit(node);
  return ids;
}

/// ディレクトリノードのチェックボックス表示状態を判定する。
///
/// 配下の葉ノードが1件もselectedIdsに含まれなければfalse、
/// 全件含まれればtrue、一部のみ含まれればnull(中間状態)を返す。
bool? folderCheckState<T>(
  TreeNode<T> node,
  Set<String> selectedIds,
  String Function(T item) idOf,
) {
  final leafIds = collectLeafIds(node, idOf);
  if (leafIds.isEmpty) return false;

  final selectedCount = leafIds.where(selectedIds.contains).length;
  if (selectedCount == 0) return false;
  if (selectedCount == leafIds.length) return true;
  return null;
}

/// フラットなパス付きアイテムのリストを、開閉可能なフォルダツリーとして
/// 表示する汎用ウィジェット。ドメイン固有の型に依存しないジェネリクス設計。
///
/// - [pathOf]: 各アイテムのルートからの相対パス(`/`区切り)を返す。
/// - [idOf]: 選択状態の管理に使う一意なIDを返す(例: URI)。
/// - [selectedIds]: 選択中の葉ノードIDの集合。呼び出し側(ViewModel等)が保持する。
/// - [onSelectionChanged]: チェックボックス操作時に呼ばれる。
///   フォルダをタップした場合は配下の全葉ノードIDがまとめて渡される。
/// - [sortKeyOf]: 同一階層内のファイル同士の並び替えキーを返す(降順)。
///   省略した場合は従来通り名前順になる(汎用ウィジェットとしての後方互換性のため)。
class FolderTreeView<T> extends StatefulWidget {
  const FolderTreeView({
    super.key,
    required this.items,
    required this.pathOf,
    required this.idOf,
    required this.selectedIds,
    required this.onSelectionChanged,
    this.sortKeyOf,
  });

  final List<T> items;
  final String Function(T item) pathOf;
  final String Function(T item) idOf;
  final Set<String> selectedIds;
  final void Function(List<String> ids, bool selected) onSelectionChanged;
  final Comparable Function(T item)? sortKeyOf;

  @override
  State<FolderTreeView<T>> createState() => _FolderTreeViewState<T>();
}

class _FolderTreeViewState<T> extends State<FolderTreeView<T>> {
  // 初期状態は全て閉じておく(ノート数が多いVaultでの情報過多を避けるため)。
  final Set<String> _expandedPaths = {};

  @override
  Widget build(BuildContext context) {
    final root = buildTree<T>(
      items: widget.items,
      pathOf: widget.pathOf,
      sortKeyOf: widget.sortKeyOf,
    );
    final visibleNodes = flattenVisibleNodes<T>(root, _expandedPaths);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: visibleNodes.length,
      itemBuilder: (context, index) {
        final visible = visibleNodes[index];
        final expanded = _expandedPaths.contains(visible.node.path);

        return _TreeRow<T>(
          visible: visible,
          idOf: widget.idOf,
          selectedIds: widget.selectedIds,
          expanded: expanded,
          onToggleExpand: () {
            setState(() {
              if (expanded) {
                _expandedPaths.remove(visible.node.path);
              } else {
                _expandedPaths.add(visible.node.path);
              }
            });
          },
          onToggleSelection: () {
            final node = visible.node;
            if (node.isDirectory) {
              final leafIds = collectLeafIds<T>(node, widget.idOf);
              final checkState =
                  folderCheckState<T>(node, widget.selectedIds, widget.idOf);
              widget.onSelectionChanged(leafIds, checkState != true);
            } else {
              final id = widget.idOf(node.value as T);
              final alreadySelected = widget.selectedIds.contains(id);
              widget.onSelectionChanged([id], !alreadySelected);
            }
          },
        );
      },
    );
  }
}

class _TreeRow<T> extends StatelessWidget {
  const _TreeRow({
    required this.visible,
    required this.idOf,
    required this.selectedIds,
    required this.expanded,
    required this.onToggleExpand,
    required this.onToggleSelection,
  });

  final VisibleTreeNode<T> visible;
  final String Function(T item) idOf;
  final Set<String> selectedIds;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final VoidCallback onToggleSelection;

  static const double _indentUnit = 20;
  static const double _chevronSlot = 32;

  @override
  Widget build(BuildContext context) {
    final node = visible.node;
    final isDirectory = node.isDirectory;

    final bool? checkValue = isDirectory
        ? folderCheckState<T>(node, selectedIds, idOf)
        : selectedIds.contains(idOf(node.value as T));

    return SizedBox(
      height: 44,
      child: Row(
        children: [
          SizedBox(width: visible.depth * _indentUnit),
          SizedBox(
            width: _chevronSlot,
            // 開閉アイコンのタップは開閉専用。選択トグルとは領域を分ける。
            child: isDirectory
                ? IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      expanded
                          ? Icons.keyboard_arrow_down
                          : Icons.chevron_right,
                      color: const Color(0xFF8888AA),
                      size: 20,
                    ),
                    onPressed: onToggleExpand,
                  )
                : null,
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggleSelection,
              child: Row(
                children: [
                  // Checkbox自体はタップを奪わせず、行全体のGestureDetectorに一本化する。
                  IgnorePointer(
                    child: Checkbox(
                      value: checkValue,
                      tristate: isDirectory,
                      onChanged: (_) {},
                      activeColor: const Color(0xFF7C5CBF),
                      side: const BorderSide(color: Color(0xFF3A3A55)),
                    ),
                  ),
                  Icon(
                    isDirectory
                        ? (expanded ? Icons.folder_open : Icons.folder)
                        : Icons.description_outlined,
                    size: 18,
                    color: const Color(0xFF8888AA),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      node.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFFF0F0F8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
