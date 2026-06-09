import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:openai_dart/openai_dart.dart';
import '../model/bookmark.dart';
import '../util/text_cleaner.dart';

/// REQ-012: 表の自動分析・説明文章作成
class TableAnalysisService {
  final Dio _dio = Dio();

  Future<TableAnalysisResult> analyzeAndDescribeTables({
    required String contentId,
    required String text,
    required String apiKey,
    required String provider,
    required bool shouldClean,
    required double speed,
    required int totalChars,
  }) async {
    final sendText = shouldClean ? TextCleaner.clean(text) : text;
    final prompt = _buildPrompt(sendText);

    final String content;
    if (provider == 'groq') {
      content = await _callGroq(apiKey, prompt);
    } else {
      final dynamic responseData;
      if (provider == 'claude') {
        responseData = await _callClaude(apiKey, prompt);
      } else {
        responseData = await _callGemini(apiKey, prompt);
      }
      content = provider == 'claude'
          ? responseData['content'][0]['text']
          : responseData['candidates'][0]['content']['parts'][0]['text'];
    }

    final cleaned = content
        .toString()
        .replaceAll('```json', '')
        .replaceAll('```', '')
        .trim();

    if (cleaned.contains('"result"') && cleaned.contains('表なし')) {
      return TableAnalysisResult(tables: [], noTableFound: true);
    }

    final List<dynamic> items = json.decode(cleaned);

    final safeSpeed = speed > 0 ? speed : 1.0;
    final safeTotalChars = totalChars > 0 ? totalChars : 1;

    final tables = <TableAnalysisItem>[];
    final bookmarks = <Bookmark>[];

    for (final item in items) {
      final excerptStart = item['excerpt_start']?.toString() ?? '';
      final excerptEnd = item['excerpt_end']?.toString() ?? '';
      final description = item['description']?.toString() ?? '';
      final index = item['index'] as int? ?? 0;

      if (excerptStart.isEmpty || description.isEmpty) continue;

      final startPos = text.indexOf(excerptStart);
      if (startPos < 0) continue;

      int endPos = startPos;
      if (excerptEnd.isNotEmpty) {
        final foundEnd = text.indexOf(excerptEnd, startPos);
        if (foundEnd >= 0) {
          endPos = foundEnd + excerptEnd.length;
        }
      }

      final totalSecs = safeTotalChars / (5.0 * safeSpeed);
      final currentSecs = (totalSecs * startPos / safeTotalChars).round();
      final minutes = currentSecs ~/ 60;
      final seconds = currentSecs % 60;
      final timeLabel = '$minutes:${seconds.toString().padLeft(2, '0')}';
      final excerptTrimmed = excerptStart.length > 25
          ? excerptStart.substring(0, 25)
          : excerptStart;
      final rawLabel = '[表$index] $timeLabel $excerptTrimmed';
      final label = rawLabel.length > Bookmark.maxLabelLength
          ? rawLabel.substring(0, Bookmark.maxLabelLength)
          : rawLabel;

      bookmarks.add(Bookmark(
        contentId: contentId,
        position: startPos,
        label: label,
      ));

      tables.add(TableAnalysisItem(
        index: index,
        startPosition: startPos,
        endPosition: endPos,
        excerptStart: excerptStart,
        excerptEnd: excerptEnd,
        description: description,
      ));
    }

    return TableAnalysisResult(
        tables: tables, bookmarks: bookmarks, noTableFound: false);
  }

  Future<String> _callGroq(String apiKey, String prompt) async {
    final client = OpenAIClient(
      baseUrl: 'https://api.groq.com/openai/v1',
      headers: {'api-key': apiKey},
    );
    try {
      final res = await client.createChatCompletion(
        request: CreateChatCompletionRequest(
          model: ChatCompletionModel.modelId('llama-3.3-70b-versatile'),
          messages: [
            ChatCompletionMessage.user(
              content: ChatCompletionUserMessageContent.string(prompt),
            ),
          ],
          maxTokens: 6000,
        ),
      );
      return res.choices.first.message.content ?? '';
    } finally {
      client.endSession();
    }
  }

  Future<dynamic> _callGemini(String apiKey, String prompt) async {
    const model = 'gemini-2.5-flash';
    const baseUrl = 'https://generativelanguage.googleapis.com/v1beta/models';
    final response = await _dio.post(
      '$baseUrl/$model:generateContent?key=$apiKey',
      data: {
        'contents': [{'parts': [{'text': prompt}]}],
        'generationConfig': {'responseMimeType': 'application/json'},
      },
      options: Options(
        headers: {'Content-Type': 'application/json'},
        receiveTimeout: const Duration(seconds: 120),
        connectTimeout: const Duration(seconds: 30),
      ),
    );
    return response.data;
  }

  Future<dynamic> _callClaude(String apiKey, String prompt) async {
    const model = 'claude-haiku-4-5';
    const baseUrl = 'https://api.anthropic.com/v1/messages';
    final response = await _dio.post(
      baseUrl,
      data: {
        'model': model,
        'max_tokens': 6000,
        'messages': [{'role': 'user', 'content': prompt}],
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
    return response.data;
  }

  String _buildPrompt(String text) {
    return '''以下のテキストを分析し、表や数値データが含まれている箇所を特定して、それぞれの内容を日本語で説明してください。

表・数値データの目印となるパターン（例）：
- パイプ区切り（| 項目 | 値 | のようなMarkdown形式）
- カンマ区切り（項目A,項目B,項目C のようなCSV形式）
- タブ区切り（項目A\t項目B\t項目C のようなTSV形式）
- スペース区切りの数値（100 200 300 のように数値が並ぶ行）
- 罫線文字（┌─┬─┐ などの罫線を使った表）
- 見出し+数値の繰り返しパターン（売上: 100万円、利益: 20万円 など）

判定の除外条件（以下は表として検出しない）：
- 単純な数値を含む説明文や文章（例：「売上は100億円を達成した」）
- 1列のみのリスト（箇条書き・番号付きリストなど）
- 1行のみのデータ
- 表の構造（2列以上・2行以上）を持たないもの

ルール：
- 表や数値データが見つかった場合：その内容・意味・特徴を説明する（最大3000文字）
- 複数の表がある場合：それぞれ番号をつけて説明する
- 説明文は「表情報の解説：〇〇〇」の形式で記載する
- 表や数値データが見つからない場合：{"result": "表なし"} のみ返す
- 必ずJSON形式のみで返す（説明文・マークダウン記号不要）

JSONフォーマット：
[
  {
    "index": 1,
    "position": 150,
    "excerpt_start": "表の冒頭25文字",
    "excerpt_end": "表の末尾25文字",
    "description": "表情報の解説：〇〇〇"
  }
]

テキスト：
$text''';
  }
}

class TableAnalysisResult {
  final List<TableAnalysisItem> tables;
  final List<Bookmark> bookmarks;
  final bool noTableFound;

  TableAnalysisResult({
    required this.tables,
    this.bookmarks = const [],
    required this.noTableFound,
  });
}

class TableAnalysisItem {
  final int index;
  final int startPosition;
  final int endPosition;
  final String excerptStart;
  final String excerptEnd;
  final String description;

  TableAnalysisItem({
    required this.index,
    required this.startPosition,
    required this.endPosition,
    required this.excerptStart,
    required this.excerptEnd,
    required this.description,
  });
}
