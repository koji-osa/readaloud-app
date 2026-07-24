import '../../model/content.dart';
import '../../model/raw_content.dart';
import '../../util/content_parser.dart';
import 'save_content_usecase.dart';

/// [ContentParser]による変換と[SaveContentUseCase]による保存をまとめた薄いユースケース。
///
/// Repositoryの存在やImporterには関与せず、取得済みの[RawContent]とParserを
/// 受け取って変換・保存を行うだけの層として設計している。
class ImportContentUseCase {
  ImportContentUseCase(this._saveContent);
  final SaveContentUseCase _saveContent;

  Future<Content> execute({
    required RawContent raw,
    required ContentParser parser,
    required String sourceType,
    String? sourceUrl,
    String? sourceFilename,
  }) async {
    final parsed = await parser.parse(raw);

    // ObsidianImporter側でVaultEntry.name(実ファイル名)をmetadata['title']に
    // 設定する対応は未実装のため、現状は常にnull(SaveContentUseCase側の
    // フォールバックでタイトル生成)になる。
    final metadataTitle = parsed.metadata['title'];

    return _saveContent.execute(
      body: parsed.body,
      sourceType: sourceType,
      title: metadataTitle is String ? metadataTitle : null,
      sourceUrl: sourceUrl,
      sourceFilename: sourceFilename,
    );
  }
}
