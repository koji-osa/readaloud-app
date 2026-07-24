import '../model/parsed_content.dart';
import '../model/raw_content.dart';
import 'content_parser.dart';
import 'obsidian_extension_processor.dart';
import 'standard_markdown_converter.dart';

/// MarkdownのRawContentをParsedContentへ変換するParser。
///
/// [obsidianExtensions]がtrueの場合のみ[ObsidianExtensionProcessor]による
/// Obsidian固有記法の変換・metadata抽出を行う。標準Markdown変換
/// （[StandardMarkdownConverter]）はどちらの場合も必ず最後に適用する。
class MarkdownContentParser implements ContentParser {
  MarkdownContentParser({this.obsidianExtensions = false});

  final bool obsidianExtensions;

  final _obsidianProcessor = ObsidianExtensionProcessor();
  final _standardConverter = StandardMarkdownConverter();

  // Parser共通インターフェース（ContentParser）として、将来追加され得るPDF Parser等、
  // 非同期処理が必要な実装とシグネチャを揃えるためFuture<ParsedContent>を返す。
  @override
  Future<ParsedContent> parse(RawContent raw) async {
    String text = raw.text;
    Map<String, dynamic> metadata = raw.metadata;

    if (obsidianExtensions) {
      final result = _obsidianProcessor.process(text);
      text = result.processedText;
      metadata = {...raw.metadata, ...result.extractedMetadata};
    }

    final body = _standardConverter.convert(text);

    return ParsedContent(body: body, metadata: metadata);
  }
}
