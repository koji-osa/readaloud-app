import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/util/obsidian_extension_processor.dart';

void main() {
  group('ObsidianExtensionProcessor', () {
    late ObsidianExtensionProcessor processor;

    setUp(() {
      processor = ObsidianExtensionProcessor();
    });

    test('frontmatterを除去し、tagsをインライン形式で抽出できる', () {
      const input = '---\n'
          'title: Test Note\n'
          'tags: [foo, bar, baz]\n'
          '---\n'
          '本文です。';

      final result = processor.process(input);

      expect(result.processedText, '本文です。');
      expect(result.extractedMetadata['tags'], ['foo', 'bar', 'baz']);
    });

    test('frontmatterのtagsをYAMLリスト形式で抽出できる', () {
      const input = '---\n'
          'title: Test Note\n'
          'tags:\n'
          '  - foo\n'
          '  - bar\n'
          '---\n'
          '本文です。';

      final result = processor.process(input);

      expect(result.processedText, '本文です。');
      expect(result.extractedMetadata['tags'], ['foo', 'bar']);
    });

    test('内容が不正なfrontmatterでも例外を投げず、tagsは空のまま処理が継続される', () {
      const input = '---\n'
          'title: [unclosed\n'
          'tags: broken, no, brackets\n'
          'weird: >>>\n'
          '---\n'
          '本文です。';

      expect(() => processor.process(input), returnsNormally);

      final result = processor.process(input);
      expect(result.processedText, '本文です。');
      expect(result.extractedMetadata['tags'], []);
    });

    test('閉じの---がない壊れたfrontmatterでも例外を投げず処理が継続される', () {
      const input = '---\n'
          'title: no closing delimiter\n'
          '本文です。';

      expect(() => processor.process(input), returnsNormally);

      final result = processor.process(input);
      expect(result.processedText, contains('title: no closing delimiter'));
      expect(result.extractedMetadata.containsKey('tags'), isFalse);
    });

    test('コメント %%非表示%% を中身ごと除外する', () {
      const input = '見える部分%%これは非表示%%続きの部分';

      final result = processor.process(input);

      expect(result.processedText, '見える部分続きの部分');
    });

    test('コードブロックを中身ごと除外する', () {
      const input = "説明文\n```dart\nprint('hello');\n```\n続きの説明";

      final result = processor.process(input);

      expect(result.processedText, '説明文\n\n続きの説明');
    });

    test('数式 \$...\$ を中身ごと除外する', () {
      const input = r'計算結果は $x + y = z$ です。';

      final result = processor.process(input);

      expect(result.processedText, '計算結果は  です。');
    });

    test('ブロック数式 \$\$...\$\$ を中身ごと除外する', () {
      const input = r'説明文$$x + y = z$$続きの説明';

      final result = processor.process(input);

      expect(result.processedText, '説明文続きの説明');
    });

    test('複数行にまたがるブロック数式 \$\$...\$\$ を中身ごと除外する', () {
      const input = '説明文\n\$\$\nx + y = z\n\\sum_{i=0}^n i\n\$\$\n続きの説明';

      final result = processor.process(input);

      expect(result.processedText, '説明文\n\n続きの説明');
    });

    test('ブロック数式とインライン数式が混在してもそれぞれ正しく除外する', () {
      const input = r'ブロック: $$a + b$$ インライン: $x + y$ 終わり';

      final result = processor.process(input);

      expect(result.processedText, 'ブロック:  インライン:  終わり');
    });

    test('Mermaid図を中身ごと除外する', () {
      const input = '説明\n```mermaid\ngraph TD; A-->B;\n```\n続き';

      final result = processor.process(input);

      expect(result.processedText, '説明\n\n続き');
    });

    test('埋め込み ![[Note]] を「リンク先: Note」に変換する', () {
      const input = '参照: ![[MyNote]]';

      final result = processor.process(input);

      expect(result.processedText, '参照: リンク先: MyNote');
    });

    test('Wikilink（見出し参照） [[Note#Heading]] はNoteのみ抽出する', () {
      const input = '詳細は[[MyNote#セクション1]]を参照。';

      final result = processor.process(input);

      expect(result.processedText, '詳細はMyNoteを参照。');
    });

    test('Wikilink（別名） [[Note|表示名]] は表示名に変換する', () {
      const input = '詳細は[[MyNote|わかりやすい表示名]]を参照。';

      final result = processor.process(input);

      expect(result.processedText, '詳細はわかりやすい表示名を参照。');
    });

    test('Wikilink（通常） [[Note]] はNoteに変換する', () {
      const input = '詳細は[[MyNote]]を参照。';

      final result = processor.process(input);

      expect(result.processedText, '詳細はMyNoteを参照。');
    });

    test('Calloutを整形して本文のみのテキストにする', () {
      const input = '> [!note] 重要\n'
          '> これは注記の本文です。\n'
          '> 二行目です。\n'
          '通常の段落。';

      final result = processor.process(input);

      expect(
        result.processedText,
        '注記：これは注記の本文です。 二行目です。\n通常の段落。',
      );
    });

    test('チェックボックス - [ ] を「未完了：」に変換する', () {
      const input = '- [ ] タスク1';

      final result = processor.process(input);

      expect(result.processedText, '未完了：タスク1');
    });

    test('チェックボックス - [x] を「完了：」に変換する', () {
      const input = '- [x] タスク2';

      final result = processor.process(input);

      expect(result.processedText, '完了：タスク2');
    });

    test('ハイライト ==text== をtextに変換する', () {
      const input = 'これは==重要な部分==です。';

      final result = processor.process(input);

      expect(result.processedText, 'これは重要な部分です。');
    });

    test('ブロック参照 ^block-id を除外する', () {
      const input = 'これは参照可能な段落です。 ^block-id-123';

      final result = processor.process(input);

      expect(result.processedText, 'これは参照可能な段落です。');
    });

    test('複数の記法が混在する実際のノートに近いテキストを統合的に変換する', () {
      const input = r'''---
title: 統合テスト
tags: [readaloud, obsidian]
---
# 見出し

これは==重要な==メモです。%%これは非表示コメント%%

```dart
void main() {
  print('コード内の$記号や%%は無視される');
}
```

数式は$a^2 + b^2 = c^2$です。

- [ ] 未完了タスク
- [x] 完了タスク

埋め込み: ![[関連ノート]]
見出し参照: [[別のノート#セクション]]
別名リンク: [[元のノート|表示名]]
通常リンク: [[普通のノート]]

> [!note] 補足
> これは補足事項です。

本文の続きです。 ^ref-abc123
''';

      final result = processor.process(input);

      expect(result.extractedMetadata['tags'], ['readaloud', 'obsidian']);
      expect(result.processedText, contains('# 見出し'));
      expect(result.processedText, contains('これは重要なメモです。'));
      expect(result.processedText, isNot(contains('%%')));
      expect(result.processedText, isNot(contains('```')));
      expect(result.processedText, isNot(contains(r'$')));
      expect(result.processedText, contains('未完了：未完了タスク'));
      expect(result.processedText, contains('完了：完了タスク'));
      expect(result.processedText, contains('リンク先: 関連ノート'));
      expect(result.processedText, contains('見出し参照: 別のノート'));
      expect(result.processedText, contains('別名リンク: 表示名'));
      expect(result.processedText, contains('通常リンク: 普通のノート'));
      expect(result.processedText, contains('注記：これは補足事項です。'));
      expect(result.processedText, isNot(contains('^ref-abc123')));
    });

    test('extractedMetadataは変更不可（書き込みを試みるとエラーになる）', () {
      const input = '---\n'
          'title: Test Note\n'
          'tags: [foo, bar]\n'
          '---\n'
          '本文です。';

      final result = processor.process(input);

      expect(
        () => result.extractedMetadata['tags'] = ['hacked'],
        throwsUnsupportedError,
      );
      expect(
        () => result.extractedMetadata['newKey'] = 'value',
        throwsUnsupportedError,
      );
    });
  });
}
