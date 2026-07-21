import 'package:docman/docman.dart' as docman;

import '../vault_data_source.dart';

/// docmanの`DocumentFile`を抽象化したノード。
///
/// [DocmanVaultDataSource]はdocmanの型を直接扱わずこのインターフェース越しに
/// アクセスすることで、テスト時に実際のSAFアクセスを行わずに差し替えられる。
abstract class DocmanNode {
  String get uri;
  String get name;
  bool get isDirectory;
  Future<List<DocmanNode>> listChildren();
  Future<String> readAsString();
}

/// URIから[DocmanNode]を解決する関数。
typedef DocmanNodeResolver = Future<DocmanNode?> Function(String uri);

/// SAFのフォルダ選択ダイアログを表示し、選択されたディレクトリのURIを返す関数。
/// キャンセル時はnullを返す。
typedef DocmanDirectoryPicker = Future<String?> Function();

/// SAF (Storage Access Framework) 経由でVault配下の.mdファイルを
/// 取得するデータソース。
///
/// docmanパッケージへの依存はこのファイル内に閉じ込め、
/// 他のクラスからdocmanを直接importさせない。
class DocmanVaultDataSource implements VaultDataSource {
  DocmanVaultDataSource({
    DocmanNodeResolver? resolver,
    DocmanDirectoryPicker? directoryPicker,
  })  : _resolve = resolver ?? _resolveDocmanNode,
        _pickDirectory = directoryPicker ?? _pickDocmanDirectory;

  final DocmanNodeResolver _resolve;
  final DocmanDirectoryPicker _pickDirectory;

  static const _markdownExtensions = <String>{'.md'};

  @override
  Future<String?> pickDirectory() => _pickDirectory();

  @override
  Future<List<VaultEntry>> listEntries(String rootUri) async {
    final root = await _resolve(rootUri);
    if (root == null) return [];

    final entries = <VaultEntry>[];
    final visited = <String>{};
    await _collect(root, '', entries, visited);
    // docmanのlistDocuments()の順序はAndroidのSAFプロバイダ依存で非決定的なため、
    // relativePathで明示的にソートする。
    entries.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return entries;
  }

  Future<void> _collect(
    DocmanNode dir,
    String relativeDir,
    List<VaultEntry> entries,
    Set<String> visited,
  ) async {
    // シンボリックリンク等でディレクトリ構造が循環している場合に
    // 無限再帰へ陥るのを防ぐ。
    if (!visited.add(dir.uri)) return;

    final children = await dir.listChildren();
    for (final child in children) {
      final relativePath =
          relativeDir.isEmpty ? child.name : '$relativeDir/${child.name}';
      if (child.isDirectory) {
        await _collect(child, relativePath, entries, visited);
      } else if (_markdownExtensions
          .any((ext) => child.name.toLowerCase().endsWith(ext))) {
        entries.add(
          VaultEntry(
            uri: child.uri,
            relativePath: relativePath,
            name: child.name,
          ),
        );
      }
    }
  }

  @override
  Future<String> readFile(VaultEntry entry) async {
    final node = await _resolve(entry.uri);
    if (node == null) {
      throw StateError('ファイルが見つかりません: ${entry.uri}');
    }
    return node.readAsString();
  }
}

Future<DocmanNode?> _resolveDocmanNode(String uri) async {
  final file = await docman.DocumentFile.fromUri(uri);
  if (file == null) return null;
  return _DocmanFileNode(file);
}

Future<String?> _pickDocmanDirectory() async {
  final directory = await docman.DocMan.pick.directory();
  return directory?.uri;
}

class _DocmanFileNode implements DocmanNode {
  _DocmanFileNode(this._file);

  final docman.DocumentFile _file;

  @override
  String get uri => _file.uri;

  @override
  String get name => _file.name;

  @override
  bool get isDirectory => _file.isDirectory;

  @override
  Future<List<DocmanNode>> listChildren() async {
    final children = await _file.listDocuments();
    return children.map((child) => _DocmanFileNode(child)).toList();
  }

  @override
  Future<String> readAsString() async {
    final chunks = await _file.readAsString().toList();
    return chunks.join();
  }
}
