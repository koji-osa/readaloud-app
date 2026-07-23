import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/util/standard_markdown_converter.dart';

void main() {
  group('StandardMarkdownConverter', () {
    late StandardMarkdownConverter converter;

    setUp(() {
      converter = StandardMarkdownConverter();
    });

    test('見出し（#）を【見出し】に変換できる', () {
      expect(converter.convert('# 見出し'), '【見出し】');
    });

    test('見出しレベルに関わらず【】に統一される', () {
      expect(converter.convert('## 見出し'), '【見出し】');
      expect(converter.convert('###### 見出し'), '【見出し】');
    });

    test('強調 **text** の装飾記号のみを除去できる', () {
      expect(converter.convert('これは**重要**です。'), 'これは重要です。');
    });

    test('強調 __text__ の装飾記号のみを除去できる', () {
      expect(converter.convert('これは__重要__です。'), 'これは重要です。');
    });

    test('リスト項目（-）を・itemに変換できる', () {
      expect(converter.convert('- item'), '・item');
    });

    test('リスト項目（*, +）を・itemに変換できる', () {
      expect(converter.convert('* item'), '・item');
      expect(converter.convert('+ item'), '・item');
    });

    test('見出し・強調・リストが混在するテキストをまとめて変換できる', () {
      const input = '# タイトル\n'
          '本文中の**強調**と__別の強調__。\n'
          '- 項目1\n'
          '* 項目2\n'
          '+ 項目3';

      const expected = '【タイトル】\n'
          '本文中の強調と別の強調。\n'
          '・項目1\n'
          '・項目2\n'
          '・項目3';

      expect(converter.convert(input), expected);
    });
  });
}
