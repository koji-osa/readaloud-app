import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/raw_content.dart';
import 'package:readaloud_app/util/markdown_content_parser.dart';

void main() {
  group('MarkdownContentParser', () {
    test('obsidianExtensions: false の場合、標準Markdown変換のみが適用される', () async {
      final parser = MarkdownContentParser();
      const raw = RawContent(
        text: '# 見出し\n[[Note]]について**説明**します。',
      );

      final parsed = await parser.parse(raw);

      // wikilinkは変換されず素通りし、見出しと強調のみ標準変換される。
      expect(parsed.body, '【見出し】\n[[Note]]について説明します。');
      expect(parsed.metadata, isEmpty);
    });

    test(
      'obsidianExtensions: true の場合、Obsidian記法とMarkdown記法の両方が変換される',
      () async {
        final parser = MarkdownContentParser(obsidianExtensions: true);
        const raw = RawContent(
          text: '---\ntags: [foo, bar]\n---\n'
              '# [[Note]]について\n'
              'これは**重要**です。',
        );

        final parsed = await parser.parse(raw);

        expect(parsed.metadata['tags'], ['foo', 'bar']);
        expect(parsed.body, '【Noteについて】\nこれは重要です。');
      },
    );

    test(
      'obsidianExtensions: true でも、Obsidian処理後に標準Markdown変換が正しく適用される',
      () async {
        final parser = MarkdownContentParser(obsidianExtensions: true);
        const raw = RawContent(text: '# [[Note]]');

        final parsed = await parser.parse(raw);

        // wikilinkの変換結果である「Note」を含む見出しが【】で囲まれること。
        expect(parsed.body, '【Note】');
      },
    );

    test(
      'obsidianExtensions: false でも、raw.metadataがParsedContent.metadataに引き継がれる',
      () async {
        final parser = MarkdownContentParser();
        const raw = RawContent(
          text: '# 見出し',
          metadata: {'noteUri': 'obsidian://vault/note'},
        );

        final parsed = await parser.parse(raw);

        expect(parsed.metadata['noteUri'], 'obsidian://vault/note');
      },
    );

    test(
      'obsidianExtensions: true の場合、raw.metadataとObsidian抽出metadataがマージされる',
      () async {
        final parser = MarkdownContentParser(obsidianExtensions: true);
        const raw = RawContent(
          text: '---\ntags: [foo, bar]\n---\n# 見出し',
          metadata: {'noteUri': 'obsidian://vault/note'},
        );

        final parsed = await parser.parse(raw);

        expect(parsed.metadata['noteUri'], 'obsidian://vault/note');
        expect(parsed.metadata['tags'], ['foo', 'bar']);
      },
    );
  });
}
