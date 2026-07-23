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

  // インラインコード `code`。中身は見出し・強調・リストの変換対象から除外する。
  static final _inlineCodePattern = RegExp(r'`([^`\n]+?)`');

  // プレースホルダーの目印。NUL文字(\u0000)で挟むことで、通常の
  // Markdown本文（数字・記号を含む）には出現しない一意な文字列にする。
  static const _placeholderPrefix = '\u0000INLINECODE';
  static const _placeholderSuffix = '\u0000';

  String convert(String text) {
    // ブロック要素（見出し・リスト等）→インライン要素（強調等）の順で変換する。
    // インラインコードの中身は他の記法の変換に反応させないよう、変換前に
    // プレースホルダーへ退避し、他の記法の変換がすべて終わった後に
    // バッククォートを外しただけの状態で復元する。
    final codeContents = <String>[];
    var result = text.replaceAllMapped(_inlineCodePattern, (m) {
      final index = codeContents.length;
      codeContents.add(m.group(1) ?? '');
      return '$_placeholderPrefix$index$_placeholderSuffix';
    });

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

    for (var i = 0; i < codeContents.length; i++) {
      result = result.replaceAll(
        '$_placeholderPrefix$i$_placeholderSuffix',
        codeContents[i],
      );
    }

    return result;
  }
}
