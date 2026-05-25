import 'package:dio/dio.dart';
import 'package:html/parser.dart' as htmlParser;

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

      // 本文を抽出（article・main・bodyの順で試みる）
      final article = document.querySelector('article');
      final main = document.querySelector('main');
      final body = document.querySelector('body');

      final targetElement = article ?? main ?? body;
      final rawText = targetElement?.text ?? '';

      // 空白・改行を整理
      final cleanText = rawText
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .replaceAll(RegExp(r' {2,}'), ' ')
          .trim();

      return FetchUrlResult(title: title, body: cleanText);
    } catch (e) {
      throw Exception('URLの取得に失敗しました: $e');
    }
  }
}

class FetchUrlResult {
  final String title;
  final String body;

  FetchUrlResult({required this.title, required this.body});
}
