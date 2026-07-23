/// Obsidian固有ではない、一般的なMarkdown記法を読み上げに適した形へ変換するユーティリティ。
///
/// [ObsidianExtensionProcessor]とは独立して動作するため、Obsidian記法を含まない
/// 一般的なMarkdownファイルに対してもこのクラス単体で使用できる。
class StandardMarkdownConverter {
  // 見出し（# 見出し 〜 ###### 見出し）。レベルは区別せず「【見出し】」に統一する。
  static final _headingPattern = RegExp(r'^#{1,6}[ \t]+(.+)$', multiLine: true);

  // 強調 **text** または __text__。装飾記号のみ除去し中身は残す。
  static final _boldPattern = RegExp(r'\*\*(.+?)\*\*|__(.+?)__');

  // リスト項目 - item / * item / + item。行頭のインデントは考慮しない。
  static final _listItemPattern = RegExp(r'^[ \t]*[-*+][ \t]+(.+)$', multiLine: true);

  String convert(String text) {
    var result = text;

    result = result.replaceAllMapped(
      _headingPattern,
      (m) => '【${m.group(1)}】',
    );

    result = result.replaceAllMapped(
      _boldPattern,
      (m) => m.group(1) ?? m.group(2) ?? '',
    );

    result = result.replaceAllMapped(
      _listItemPattern,
      (m) => '・${m.group(1)}',
    );

    return result;
  }
}
