/// Folder Source 直下の子要素1件の metadata（本文は含まない）。
class FolderChild {
  const FolderChild({
    required this.uri,
    required this.name,
    required this.mimeType,
    required this.lastModified,
    required this.isDirectory,
  });

  /// 正規の child SAF URI（`DocumentsContract.buildDocumentUriUsingTree`）。
  final String uri;
  final String name;
  final String mimeType;

  /// epoch ミリ秒。取得できない場合は 0（不明）。
  final int lastModified;
  final bool isDirectory;
}
