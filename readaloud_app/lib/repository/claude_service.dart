import 'dart:convert';
import 'package:dio/dio.dart';
import '../model/bookmark.dart';
import '../util/text_cleaner.dart';

/// REQ-023: Claude API連携・テキスト自動構造分析・ブックマーク自動作成
class ClaudeService {
  static const String _model = 'claude-haiku-4-5';
  static const String _baseUrl = 'https://api.anthropic.com/v1/messages';

  final Dio _dio = Dio();

  /// テキストを分析してブックマークリストを生成する
  Future<List<Bookmark>> analyzeAndCreateBookmarks({
    required String contentId,
    required String text,
    required String apiKey,
    required bool shouldClean,
    required double speed,
    required int totalChars,
    String customPrompt = '', // REQ-031
  }) async {
    final sendText = shouldClean ? TextCleaner.clean(text) : text;
    final prompt = customPrompt.isNotEmpty
        ? '$customPrompt\n\nテキスト：\n$sendText'
        : _buildPrompt(sendText);

    final response = await _dio.post(
      _baseUrl,
      data: {
        'model': _model,
        'max_tokens': 2000,
        'messages': [
          {
            'role': 'user',
            'content': prompt,
          }
        ],
      },
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
        receiveTimeout: const Duration(seconds: 120),
        connectTimeout: const Duration(seconds: 30),
      ),
    );

    // レスポンスのパース
    final content = response.data['content'][0]['text'];
    final cleaned = content
        .toString()
        .replaceAll('```json', '')
        .replaceAll('```', '')
        .trim();
    final List<dynamic> items = json.decode(cleaned);

    // ゼロ除算対策
    final safeSpeed = speed > 0 ? speed : 1.0;
    final safeTotalChars = totalChars > 0 ? totalChars : 1;

    // ブックマーク生成
    final bookmarks = <Bookmark>[];
    for (final item in items) {
      int position = item['position'] as int;
      final excerpt = item['excerpt']?.toString() ?? '';

      // excerptをテキスト全体から検索（FIX-036）
      if (excerpt.isEmpty) continue;
      final globalFound = text.indexOf(excerpt);
      if (globalFound < 0) continue;
      position = globalFound;

      // ブックマーク名: [目次] 分:秒 抜粋テキスト
      final totalSecs = safeTotalChars / (5.0 * safeSpeed);
      final currentSecs = (totalSecs * position / safeTotalChars).round();
      final minutes = currentSecs ~/ 60;
      final seconds = currentSecs % 60;
      final timeLabel = '$minutes:${seconds.toString().padLeft(2, '0')}';
      final excerptTrimmed =
          excerpt.length > 25 ? excerpt.substring(0, 25) : excerpt;
      final rawLabel = '[目次] $timeLabel $excerptTrimmed';
      final label = rawLabel.length > Bookmark.maxLabelLength
          ? rawLabel.substring(0, Bookmark.maxLabelLength)
          : rawLabel;

      bookmarks.add(Bookmark(
        contentId: contentId,
        position: position,
        label: label,
      ));
    }

    return bookmarks;
  }

  String _buildPrompt(String text) {
    return '''以下のテキストを分析し、章・節・重要ポイントの区切りを特定してください。

区切りの目印となる記号・パターン（例）：
- 数字+ピリオド（1. 2. 3.）
- 数字+スペース（1 2 3）
- 見出し記号（# ## ###）
- 箇条書き記号（● ◯）
- 括弧見出し（【】）
- 丸数字（① ② ③）
- アルファベット（A. B. C.）
- ローマ数字（Ⅰ Ⅱ Ⅲ）
- 改行+字下げによる段落区切り

ルール：
- テキストが1,000文字未満の場合は3箇所程度
- テキストが1,000文字以上の場合は5〜15箇所程度
- 各区切りの文字位置（0始まりのインデックス）とその箇所の冒頭25文字を返す
- 見出しの階層を1〜3の数字で返す（1=大見出し・章、2=中見出し・節、3=小見出し・項）（REQ-031）
- 階層構造がない場合は全て level=1 とする（REQ-031）
- 必ずJSON形式のみで返す（説明文・マークダウン記号不要）

JSONフォーマット：
[
  {"position": 0, "excerpt": "冒頭25文字", "level": 1},
  {"position": 150, "excerpt": "次の区切りの25文字", "level": 2}
]

テキスト：
$text''';
  }
}
