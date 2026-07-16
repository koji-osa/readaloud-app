import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:openai_dart/openai_dart.dart';
import '../model/bookmark.dart';
import '../util/table_debug_logger.dart'; // FIX-050

// FIX-071: excerpt_start/excerpt_endに含まれるMarkdown記号(| ** __ ` 行頭の>)の
// 有無の差を吸収する正規化。excerptの正規化専用。元テキスト(text)には適用しない。
String sanitizeExcerpt(String text) {
  var result = text;
  result = result.replaceAll('|', '');
  result = result.replaceAll('**', '');
  result = result.replaceAll('__', '');
  result = result.replaceAll('`', '');
  result = result.replaceAll(RegExp(r'^\s*>\s*', multiLine: true), '');
  result = result.replaceAll('\r\n', '\n');
  result = result.replaceAll('\r', '\n');
  result = result.replaceAll(RegExp(r'[ \t]+'), ' ');
  result = result.replaceAll(RegExp(r'\n+'), '\n');
  return result.trim();
}

// FIX-071: 正規化したexcerptから、Markdown記号の有無を許容する正規表現パターンを作る。
// 元テキスト(text)は一切加工せず、このパターンで直接検索し位置ズレを防ぐ。
RegExp? buildFlexiblePattern(String excerpt) {
  final normalized = sanitizeExcerpt(excerpt);
  if (normalized.isEmpty) return null;
  const separator = r'[|*`>_\s]*';
  final escaped = normalized.split('').map(RegExp.escape).join(separator);
  return RegExp(escaped);
}

// FIX-071: RegExp.firstMatch()にはstart引数がないため、allMatches(text, start)で代用する。
RegExpMatch? firstMatchFrom(RegExp pattern, String input, int start) {
  final matches = pattern.allMatches(input, start);
  return matches.isEmpty ? null : matches.first;
}

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
    String customPrompt = '', // REQ-031
  }) async {
    final stopwatch = Stopwatch()..start(); // FIX-050
    await TableDebugLogger.instance.startAnalysis( // FIX-050
      provider: provider, // FIX-050
      textLength: text.length, // FIX-050
      shouldClean: shouldClean, // FIX-050
    ); // FIX-050
    final sendText = text; // FIX-071: クリーニング有無に関わらず元テキストを使用
    final prompt = customPrompt.isNotEmpty
        ? '$customPrompt\n\nテキスト：\n$sendText'
        : _buildPrompt(sendText);
    TableDebugLogger.instance.logPrompt(prompt.length); // FIX-050

    final String content;
    try { // FIX-050
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
      TableDebugLogger.instance.logResponse(content); // FIX-050
    } catch (e) { // FIX-050
      TableDebugLogger.instance.logApiError(e.toString()); // FIX-050
      await TableDebugLogger.instance.finishAnalysis( // FIX-050
        tableCount: 0, bookmarkCount: 0, elapsedMillis: stopwatch.elapsedMilliseconds); // FIX-050
      rethrow; // FIX-050
    } // FIX-050

    final cleaned = content
        .toString()
        .replaceAll('```json', '')
        .replaceAll('```', '')
        .trim();

    if (cleaned.contains('"result"') && cleaned.contains('表なし')) {
      TableDebugLogger.instance.logParsed(0); // FIX-050
      await TableDebugLogger.instance.finishAnalysis( // FIX-050
        tableCount: 0, bookmarkCount: 0, elapsedMillis: stopwatch.elapsedMilliseconds); // FIX-050
      return TableAnalysisResult(tables: [], noTableFound: true);
    }

    final List<dynamic> items; // FIX-050
    try { // FIX-050
      items = json.decode(cleaned); // FIX-050
      TableDebugLogger.instance.logParsed(items.length); // FIX-050
    } catch (e) { // FIX-050
      TableDebugLogger.instance.logParseError(cleaned); // FIX-050
      await TableDebugLogger.instance.finishAnalysis( // FIX-050
        tableCount: 0, bookmarkCount: 0, elapsedMillis: stopwatch.elapsedMilliseconds); // FIX-050
      rethrow; // FIX-050
    } // FIX-050

    final safeSpeed = speed > 0 ? speed : 1.0;
    final safeTotalChars = totalChars > 0 ? totalChars : 1;

    final tables = <TableAnalysisItem>[];
    final bookmarks = <Bookmark>[];

    // FIX-051: 一時リストに収集してから開始位置でソート・連番付与
    final tempItems = <Map<String, dynamic>>[];

    for (final item in items) {
      final excerptStart = item['excerpt_start']?.toString() ?? '';
      final excerptEnd = item['excerpt_end']?.toString() ?? '';
      final description = item['description']?.toString() ?? '';

      if (excerptStart.isEmpty || description.isEmpty) continue;

      final startPattern = buildFlexiblePattern(excerptStart);
      if (startPattern == null) continue;
      final startMatch = startPattern.firstMatch(text);
      if (startMatch == null) continue;
      final startPos = startMatch.start;

      int endPos = startPos;
      if (excerptEnd.isNotEmpty) {
        final endPattern = buildFlexiblePattern(excerptEnd);
        if (endPattern != null) {
          final endMatch = firstMatchFrom(endPattern, text, startPos);
          if (endMatch != null) {
            endPos = endMatch.end;
          }
        }
      }

      tempItems.add({
        'excerptStart': excerptStart,
        'excerptEnd': excerptEnd,
        'description': description,
        'startPos': startPos,
        'endPos': endPos,
      });
    }

    // 開始位置でソート（FIX-051）
    tempItems.sort((a, b) => (a['startPos'] as int).compareTo(b['startPos'] as int));

    // ソート後に連番を付与（FIX-051）
    for (int i = 0; i < tempItems.length; i++) {
      final t = tempItems[i];
      final index = i + 1; // FIX-051: 1始まりの連番
      final excerptStart = t['excerptStart'] as String;
      final excerptEnd = t['excerptEnd'] as String;
      final description = t['description'] as String;
      final startPos = t['startPos'] as int;
      final endPos = t['endPos'] as int;

      final totalSecs = safeTotalChars / (5.0 * safeSpeed);
      final currentSecs = (totalSecs * startPos / safeTotalChars).round();
      final minutes = currentSecs ~/ 60;
      final seconds = currentSecs % 60;
      final timeLabel = '$minutes:${seconds.toString().padLeft(2, '0')}';
      final excerptTrimmed = excerptStart.length > 30 // FIX-063
          ? excerptStart.substring(0, 30)
          : excerptStart;
      final rawLabel = '[表$index] $timeLabel $excerptTrimmed';
      final label = rawLabel.length > Bookmark.maxLabelLength
          ? rawLabel.substring(0, Bookmark.maxLabelLength)
          : rawLabel;

      // FIX-050: 表全文を抽出してログに記録
      final tableText = endPos > startPos ? text.substring(startPos, endPos) : excerptStart;
      TableDebugLogger.instance.logTableItem( // FIX-050
        index: index, // FIX-050
        startPosition: startPos, // FIX-050
        endPosition: endPos, // FIX-050
        tableText: tableText, // FIX-050
        description: description, // FIX-050
      ); // FIX-050

      bookmarks.add(Bookmark(
        contentId: contentId,
        position: startPos,
        label: label,
      ));

      tables.add(TableAnalysisItem(
        index: index, // FIX-051: 連番
        startPosition: startPos,
        endPosition: endPos,
        excerptStart: excerptStart,
        excerptEnd: excerptEnd,
        description: description,
      ));
    }

    await TableDebugLogger.instance.finishAnalysis( // FIX-050
      tableCount: tables.length, // FIX-050
      bookmarkCount: bookmarks.length, // FIX-050
      elapsedMillis: stopwatch.elapsedMilliseconds, // FIX-050
    ); // FIX-050
    return TableAnalysisResult(
        tables: tables, bookmarks: bookmarks, noTableFound: false);
  }

  Future<String> _callGroq(String apiKey, String prompt) async {
    final client = OpenAIClient(
      baseUrl: 'https://api.groq.com/openai/v1',
      apiKey: apiKey,
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
          responseFormat: ResponseFormat.jsonObject(), // FIX-055
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
        receiveTimeout: const Duration(seconds: 300), // FIX-046
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
        'max_tokens': 8000, // FIX-055: 返答が途中で切れる問題の対策
        'messages': [{'role': 'user', 'content': prompt}],
      },
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
        receiveTimeout: const Duration(seconds: 300), // FIX-046
        connectTimeout: const Duration(seconds: 30),
      ),
    );
    return response.data;
  }

  String _buildPrompt(String text) {
    return '''以下のテキストを分析し、表や数値データが含まれている箇所を特定して、それぞれの内容を日本語で説明してください。

検出対象：
- 行と列の両方に意味のある見出しがあり、その交点に数値があるクロス集計構造のもの
- 形式は問わない（パイプ区切り・カンマ区切り・スペース区切り・タブ区切り・罫線など）
- 例：年度×売上/営業利益/経常利益/当期純利益、地域×製品別販売数、月次×費目別コストなど

判定の除外条件（以下は表として検出しない）：
- 単純な数値を含む説明文や文章（例：「売上は100億円を達成した」）
- 1列のみのリスト（箇条書き・番号付きリストなど）
- 1行のみの数値羅列（クロス集計の構造を持たないもの）（FIX-048追加）
- 行と列の両方に意味のある見出しがなく、クロス集計の構造になっていないもの（FIX-048追加）
- 表の構造（2列以上・2行以上）を持たないもの

ルール：
- 表や数値データが見つかった場合：その内容・意味・特徴を説明する（最大3000文字）
- 複数の表がある場合：それぞれ番号をつけて説明する
- 説明文は「表情報の解説：〇〇〇」の形式で記載する
- excerpt_startは表の最初の行・ヘッダー行の冒頭25文字とする（Markdown記号・パイプ等を原文のまま含めること）（FIX-059）
- excerpt_endは表の最後の行の末尾15文字とする（表の後の説明文・考察・本文は含めない）（Markdown記号・パイプ等を原文のまま含めること）（FIX-059）
- 表や数値データが見つからない場合：[{"result": "表なし"}] のみ返す（FIX-056）
- 返答は必ず角カッコ（[]）で始まる配列形式のJSONのみとする（FIX-056）
- オブジェクト形式（{}で始まる）・説明文・マークダウン記号は一切不要（FIX-056）
- 配列の各要素は必ず index, excerpt_start, excerpt_end, description のキーを持つこと（FIX-056）
- 表の各行（項目）について、以下の順序で記述すること（FIX-061）
  ① 項目名を述べる
  ② 全ての列の数値を年度・期間順に1つずつ明記する（単位を必ず付ける）
- 年度を列挙する場合は「2018年は〇〇、2019年は〇〇、2020年は〇〇です。」の形式で記述し、「〇月期」などの決算期表記は省略すること（FIX-068）
  ③ その項目の特徴・傾向・考察を1〜2文で述べる
  ④ 次の項目へ移る
- 傾向の説明は数値の直後に入れること（全項目を列挙してから説明するのではなく、項目ごとにセットで述べる）（FIX-061）
- 列数・行数が多い場合も省略せず全数値を記述する（FIX-061）
- 解説文（description）中のマイナスの数値は「マイナス〇〇」と記述すること（例：「マイナス309百万円」）※excerpt_start・excerpt_endは原文のまま記載すること（FIX-061）
- 百万円単位の金額は自然な単位に変換して記述すること（例：100百万円→1億円、50百万円→5,000万円、1,234百万円→約12億3,400万円）（FIX-069）

JSONフォーマット：
[
  {
    "index": 1,
    "excerpt_start": "表の冒頭25文字（Markdown原文）",
    "excerpt_end": "表の末尾15文字（Markdown原文）",
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
