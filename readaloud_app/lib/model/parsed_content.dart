/// 各種Parser（Markdown, PDF等）による変換後のコンテンツを表す共通データ形式。
class ParsedContent {
  ParsedContent({required this.body, Map<String, dynamic> metadata = const {}})
      : metadata = Map.unmodifiable(metadata);

  /// 読み上げに適した形へ変換済みの本文。
  final String body;

  /// 変換過程で取得した付加情報(例: 'tags')。
  ///
  /// 呼び出し側からの書き換えを防ぐため、常にMap.unmodifiable()でラップされる。
  final Map<String, dynamic> metadata;
}
