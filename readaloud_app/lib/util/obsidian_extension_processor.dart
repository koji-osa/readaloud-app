/// Obsidianのノート変換結果。
class ObsidianProcessResult {
  final String processedText;
  final Map<String, dynamic> extractedMetadata;

  const ObsidianProcessResult({
    required this.processedText,
    required this.extractedMetadata,
  });
}

/// Obsidian固有のMarkdown記法を読み上げに適した形へ変換するユーティリティ。
///
/// 正規表現ベースで実装しており、本格的なYAMLパーサーは使用しない。
/// frontmatterが壊れている場合でも例外を投げず、読み上げ本文の生成を必ず成功させる。
class ObsidianExtensionProcessor {
  // frontmatter（--- ... ---）を検出するパターン。テキスト先頭にのみマッチする。
  // 閉じの "---" が見つからない壊れたfrontmatterにはマッチしないため、その場合は
  // 本文をそのまま扱う（ブロックの誤除去を避ける）。
  static final _frontmatterPattern = RegExp(
    r'^---\s*\r?\n([\s\S]*?)\r?\n---\s*\r?\n?',
  );

  // frontmatter内の tags: [a, b, c] 形式（インライン配列）
  static final _tagsInlinePattern = RegExp(r'tags:\s*\[(.*?)\]');

  // frontmatter内の tags:\n  - a\n  - b 形式（YAMLリスト）
  static final _tagsListPattern = RegExp(
    r'tags:\s*\n((?:[ \t]*-[ \t]*.+\n?)+)',
  );

  // タグ値の前後についたクォートを除去
  static final _quotePattern = RegExp('''^['"]|['"]\$''');

  // コードブロック（```...```）。mermaid（```mermaid ... ```）も同じフェンス記法のため
  // このパターンで併せて除外する。
  static final _codeBlockPattern = RegExp(r'```[\s\S]*?```');

  // ブロック数式 $$...$$（複数行にまたがる場合あり）。
  // インライン数式より先に処理しないと、$$のうち片方だけがインライン数式パターンに
  // 誤ってマッチしてしまう。
  static final _mathBlockPattern = RegExp(r'\$\$[\s\S]*?\$\$');

  // インライン数式 $...$（改行をまたがない範囲）
  static final _mathInlinePattern = RegExp(r'\$([^\$\n]+?)\$');

  // コメント %%非表示%%
  static final _commentPattern = RegExp(r'%%[\s\S]*?%%');

  // 埋め込み ![[Note]]。通常のWikilinkより先に処理しないと "!" が残ってしまう。
  static final _embedPattern = RegExp(r'!\[\[(.*?)\]\]');

  // Wikilink（見出し参照） [[Note#Heading]]
  static final _wikilinkHeadingPattern = RegExp(r'\[\[([^\]|#]+)#[^\]|]*\]\]');

  // Wikilink（別名） [[Note|表示名]]
  static final _wikilinkAliasPattern = RegExp(r'\[\[[^\]|#]+\|([^\]]+)\]\]');

  // Wikilink（通常） [[Note]]。見出し参照・別名より後に処理する。
  static final _wikilinkNormalPattern = RegExp(r'\[\[([^\]]+)\]\]');

  // Callout > [!note] タイトル\n> 本文... タイトル行の後に続く "> " 始まりの行を本文とみなす。
  static final _calloutPattern = RegExp(
    r'^>\s*\[!\w+\][^\n]*\n((?:^>.*(?:\n|$))*)',
    multiLine: true,
  );

  // チェックボックス。Calloutの本文中に含まれる場合もあるため行頭アンカーは付けない。
  static final _checkboxUncheckedPattern = RegExp(r'-\s\[\s\]\s*');
  static final _checkboxCheckedPattern = RegExp(r'-\s\[[xX]\]\s*');

  // ハイライト ==text==
  static final _highlightPattern = RegExp(r'==(.+?)==');

  // ブロック参照 ^block-id（行末）
  static final _blockReferencePattern = RegExp(
    r'\s?\^[a-zA-Z0-9-]+\s*$',
    multiLine: true,
  );

  ObsidianProcessResult process(String text) {
    final metadata = <String, dynamic>{};
    String result = _extractAndRemoveFrontmatter(text, metadata);

    // 除外系はコードブロック（mermaid含む）→ブロック数式→インライン数式→コメントの
    // 順で処理する。コードブロック内に $ や %% を含むサンプルコードがあっても、
    // 先にブロックごと除去することで誤って部分的に変換されないようにする。
    // ブロック数式をインライン数式より先に処理しないと、$$の片方だけが
    // インライン数式パターンに誤ってマッチする可能性がある。
    result = result.replaceAll(_codeBlockPattern, '');
    result = result.replaceAll(_mathBlockPattern, '');
    result = result.replaceAll(_mathInlinePattern, '');
    result = result.replaceAll(_commentPattern, '');

    // 埋め込みは通常のWikilinkのスーパーセットなので先に処理する。
    result = result.replaceAllMapped(
      _embedPattern,
      (m) => 'リンク先: ${m.group(1)}',
    );
    result = result.replaceAllMapped(
      _wikilinkHeadingPattern,
      (m) => m.group(1)!,
    );
    result = result.replaceAllMapped(
      _wikilinkAliasPattern,
      (m) => m.group(1)!,
    );
    result = result.replaceAllMapped(
      _wikilinkNormalPattern,
      (m) => m.group(1)!,
    );

    // Calloutの本文中にチェックボックスが含まれる場合があるため、
    // Calloutの整形をチェックボックス変換より先に行う。
    result = result.replaceAllMapped(_calloutPattern, (m) {
      final body = (m.group(1) ?? '')
          .split('\n')
          .map((line) => line.replaceFirst(RegExp(r'^>\s?'), '').trim())
          .where((line) => line.isNotEmpty)
          .join(' ');
      return '注記：$body\n';
    });

    result = result.replaceAll(_checkboxUncheckedPattern, '未完了：');
    result = result.replaceAll(_checkboxCheckedPattern, '完了：');

    result = result.replaceAllMapped(_highlightPattern, (m) => m.group(1)!);

    result = result.replaceAll(_blockReferencePattern, '');

    return ObsidianProcessResult(
      processedText: result.trim(),
      extractedMetadata: Map.unmodifiable(metadata),
    );
  }

  static String _extractAndRemoveFrontmatter(
    String text,
    Map<String, dynamic> metadata,
  ) {
    final match = _frontmatterPattern.firstMatch(text);
    if (match == null) {
      return text;
    }

    final frontmatterContent = match.group(1) ?? '';
    metadata['tags'] = _extractTags(frontmatterContent);

    return text.substring(match.end);
  }

  static List<String> _extractTags(String frontmatterContent) {
    try {
      final inlineMatch = _tagsInlinePattern.firstMatch(frontmatterContent);
      if (inlineMatch != null) {
        return (inlineMatch.group(1) ?? '')
            .split(',')
            .map((t) => t.trim().replaceAll(_quotePattern, ''))
            .where((t) => t.isNotEmpty)
            .toList();
      }

      final listMatch = _tagsListPattern.firstMatch(frontmatterContent);
      if (listMatch != null) {
        return (listMatch.group(1) ?? '')
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.startsWith('-'))
            .map(
              (line) => line.substring(1).trim().replaceAll(_quotePattern, ''),
            )
            .where((t) => t.isNotEmpty)
            .toList();
      }

      return [];
    } catch (_) {
      return [];
    }
  }
}
