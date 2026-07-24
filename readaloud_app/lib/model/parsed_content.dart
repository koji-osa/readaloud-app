/// 各種Parser（Markdown, PDF等）による変換後のコンテンツを表す共通データ形式。
class ParsedContent {
  const ParsedContent({required this.body, this.metadata = const {}});

  /// 読み上げに適した形へ変換済みの本文。
  final String body;

  /// 変換過程で取得した付加情報(例: 'tags')。
  final Map<String, dynamic> metadata;
}
