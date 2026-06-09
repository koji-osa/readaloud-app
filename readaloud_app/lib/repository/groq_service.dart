import 'dart:convert';
import 'package:openai_dart/openai_dart.dart';
import '../model/bookmark.dart';
import '../util/text_cleaner.dart';

/// REQ-030: Groq API連携・テキスト自動構造分析・ブックマーク自動作成
class GroqService {
  static const String _model = 'llama-3.3-70b-versatile';
  static const String _baseUrl = 'https://api.groq.com/openai/v1';

  Future<List<Bookmark>> analyzeAndCreateBookmarks({
    required String contentId,
    required String text,
    required String apiKey,
    required bool shouldClean,
    required double speed,
    required int totalChars,
  }) async {
    final sendText = shouldClean ? TextCleaner.clean(text) : text;
    final prompt = _buildPrompt(sendText);

    final client = OpenAIClient(
      baseUrl: _baseUrl,
      headers: {'api-key': apiKey},
    );

    try {
      final res = await client.createChatCompletion(
        request: CreateChatCompletionRequest(
          model: ChatCompletionModel.modelId(_model),
          messages: [
            ChatCompletionMessage.user(
              content: ChatCompletionUserMessageContent.string(prompt),
            ),
          ],
          maxTokens: 2000,
        ),
      );

      final content = res.choices.first.message.content ?? '';
      final cleaned = content
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();

      final List<dynamic> items = json.decode(cleaned) as List<dynamic>;

      final safeSpeed = speed > 0 ? speed : 1.0;
      final safeTotalChars = totalChars > 0 ? totalChars : 1;

      final bookmarks = <Bookmark>[];
      for (final item in items) {
        int position = item['position'] as int;
        final excerpt = item['excerpt']?.toString() ?? '';

        if (excerpt.isEmpty) continue;
        final globalFound = text.indexOf(excerpt);
        if (globalFound < 0) continue;
        position = globalFound;

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
    } finally {
      client.endSession();
    }
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
- 必ずJSON形式のみで返す（説明文・マークダウン記号不要）

JSONフォーマット：
[
  {"position": 0, "excerpt": "冒頭25文字"},
  {"position": 150, "excerpt": "次の区切りの25文字"}
]

テキスト：
$text''';
  }
}
