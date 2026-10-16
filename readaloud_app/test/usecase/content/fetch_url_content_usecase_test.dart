// RA-WEB-IMP01: URL body construction (pure part of FetchUrlContentUseCase).
// Synthetic HTML only; the network part (Dio) is intentionally not exercised.
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:readaloud_app/usecase/content/fetch_url_content_usecase.dart';
import 'package:readaloud_app/util/web_content_extractor.dart';

String body(String text, [int n = 300]) {
  final b = StringBuffer(text);
  while (b.length < n) {
    b.write('合成検証用の文章です。');
  }
  return '<p>$b</p>';
}

String page(String head, String inner) =>
    '<!doctype html><html><head><meta charset="utf-8">$head</head><body>$inner</body></html>';

String bodyOf(String html) => urlBodyFromDocument(html_parser.parse(html));

void main() {
  const meta =
      '<meta property="og:title" content="Alpha Report 2026 | Acme Daily"><title>Alpha Report 2026 | Acme Daily</title>';

  test('lost title is restored once and spoken form has no Markdown markers', () {
    final out = bodyOf(page(meta,
        '<article><header><h1>Alpha Report 2026</h1></header><h2>Section</h2>${body('BODYONE_')}<ul><li>item</li></ul></article>'));
    expect(out, startsWith('【Alpha Report 2026】\n\n【Section】'));
    expect('Alpha Report 2026'.allMatches(out).length, 1);
    expect(out, contains('・item'));
    expect(RegExp(r'^#', multiLine: true).hasMatch(out), isFalse);
  });

  test('Lifehacker-type empty first article falls back to body text', () {
    final out = bodyOf(page(meta,
        '<h1>Alpha Report 2026</h1><article></article><div>${body('RECOVERED_')}</div>'));
    expect(out, contains('RECOVERED_'));
    expect(out, isNotEmpty);
  });

  test('body equals the S1+N2 text passed through StandardMarkdownConverter only',
      () {
    final html = page(meta,
        '<article><header><h1>Alpha Report 2026</h1></header>${body('SAME_')}</article>');
    final raw = extractWebContent(html).text;
    expect(raw, startsWith('# Alpha Report 2026'));
    expect(bodyOf(html), raw.replaceFirst('# Alpha Report 2026', '【Alpha Report 2026】'));
  });

  test('does not mutate the document passed in', () {
    final doc = html_parser.parse(page(meta,
        '<article><header><h1>Alpha Report 2026</h1></header>${body('IMM_')}</article>'));
    final before = doc.outerHtml;
    urlBodyFromDocument(doc);
    expect(doc.outerHtml, before);
  });
}
