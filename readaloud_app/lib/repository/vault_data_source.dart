/// SAF (Storage Access Framework) 等、ディレクトリベースのストレージから
/// 取得したMarkdownファイル1件を表す。
class VaultEntry {
  const VaultEntry({
    required this.uri,
    required this.relativePath,
    required this.name,
    this.lastModified = 0,
  });

  /// SAFのcontent URIなど、ファイルを一意に指す識別子。
  final String uri;

  /// 選択したルートフォルダからの相対パス。例: "Projects/AI/note.md"
  final String relativePath;

  /// ファイル名。例: "note.md"
  final String name;

  /// 最終更新日時(epochミリ秒)。取得できない場合は0(不明)。
  /// Android SAFのプロバイダによっては取得できない場合がある。
  final int lastModified;

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
      'VaultEntry(uri: $uri, relativePath: $relativePath, name: $name, '
      'lastModified: $lastModified)';
}

/// ディレクトリベースのファイルストレージをSAF経由で扱うためのデータソース。
///
/// Obsidian専用ではなく、ユーザーがSAFで選択したフォルダ配下から
/// Markdownファイルを収集・読み込みできる汎用的な抽象とする。
abstract class VaultDataSource {
  /// SAFのフォルダ選択ダイアログを表示し、選択されたディレクトリのURIを返す。
  /// ユーザーがキャンセルした場合はnullを返す。
  Future<String?> pickDirectory();

  /// [rootUri]配下を再帰的に走査し、Markdown(.md)ファイルのみを収集する。
  Future<List<VaultEntry>> listEntries(String rootUri);

  /// [uri]が指すファイルの本文を読み込む。
  Future<String> readFile(String uri);

  /// [uri]が指すディレクトリ(またはファイル)の表示名を取得する。
  /// 解決できない場合はnullを返す。
  Future<String?> getDirectoryName(String uri);
}
