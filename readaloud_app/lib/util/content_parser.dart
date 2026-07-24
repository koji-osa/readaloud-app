import '../model/parsed_content.dart';
import '../model/raw_content.dart';

/// [RawContent]を[ParsedContent]へ変換するParserの共通インターフェース。
///
/// Markdown, PDF等、取り込み元の記法ごとに実装を分ける想定。
abstract class ContentParser {
  Future<ParsedContent> parse(RawContent raw);
}
