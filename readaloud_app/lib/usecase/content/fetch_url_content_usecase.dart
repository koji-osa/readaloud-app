import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as htmlParser;

import '../../util/standard_markdown_converter.dart';
import '../../util/web_content_extractor.dart';

class FetchUrlContentUseCase {
  final Dio _dio = Dio();

  Future<FetchUrlResult> execute(String url) async {
    try {
      final response = await _dio.get(
        url,
        options: Options(
          headers: {'User-Agent': 'Mozilla/5.0'},
          responseType: ResponseType.plain,
        ),
      );

      final document = htmlParser.parse(response.data);

      // タイトルを取得
      final titleElement = document.querySelector('title');
      final title = titleElement?.text.trim() ?? '';

      // 本文を抽出（凍結済み S1 + N2。詳細は web_content_extractor.dart）
      final cleanText = urlBodyFromDocument(document);

      return FetchUrlResult(title: title, body: cleanText);
    } catch (e) {
      throw Exception('URLの取得に失敗しました: $e');
    }
  }
}

/// 解析済みHTMLから読み上げ本文を作る（ネットワーク非依存）。
///
/// 検証済みパイプライン = S1+N2 抽出 → [StandardMarkdownConverter]（見出し
/// `# x` → `【x】`、`- x` → `・x`）。検証（R01〜N2S）は変換後テキストで評価
/// されており、Markdownファイル経路（folder_source_open_usecase）と同じ変換を使う。
/// TextCleaner（REQ-008）はここでは適用しない（利用者設定に委ねる別の方針）。
String urlBodyFromDocument(Document document) =>
    StandardMarkdownConverter().convert(extractWebContentFromDocument(document).text);

class FetchUrlResult {
  final String title;
  final String body;

  FetchUrlResult({required this.title, required this.body});
}
