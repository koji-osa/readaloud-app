/// SAF (Storage Access Framework) 等、ディレクトリベースのストレージから
/// 取得したMarkdownファイル1件を表す。
class VaultEntry {
  const VaultEntry({
    required this.uri,
    required this.relativePath,
    required this.name,
  });

  /// SAFのcontent URIなど、ファイルを一意に指す識別子。
  final String uri;

  /// 選択したルートフォルダからの相対パス。例: "Projects/AI/note.md"
  final String relativePath;

  /// ファイル名。例: "note.md"
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VaultEntry &&
          runtimeType == other.runtimeType &&
          uri == other.uri &&
          relativePath == other.relativePath &&
          name == other.name;

  @override
  int get hashCode => Object.hash(uri, relativePath, name);

  @override
  String toString() =>
      'VaultEntry(uri: $uri, relativePath: $relativePath, name: $name)';
}

/// ディレクトリベースのファイルストレージをSAF経由で扱うためのデータソース。
///
/// Obsidian専用ではなく、ユーザーがSAFで選択したフォルダ配下から
/// Markdownファイルを収集・読み込みできる汎用的な抽象とする。
abstract class VaultDataSource {
  /// [rootUri]配下を再帰的に走査し、Markdown(.md)ファイルのみを収集する。
  Future<List<VaultEntry>> listEntries(String rootUri);

  /// [entry]が指すファイルの本文を読み込む。
  Future<String> readFile(VaultEntry entry);
}
