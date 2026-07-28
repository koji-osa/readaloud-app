import '../../model/content.dart';
import '../../model/raw_content.dart';
import '../../util/content_parser.dart';
import '../../util/text_cleaner.dart';
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
    bool shouldClean = false,
  }) async {
    final parsed = await parser.parse(raw);

    // ObsidianImporterはVaultEntry.name(実ファイル名、拡張子除く)を
    // metadata['title']に設定する。未設定の場合はSaveContentUseCase側の
    // フォールバックでタイトル生成される。
    final metadataTitle = parsed.metadata['title'];

    // externalType/vaultName/relativePathはObsidian取り込み時のみ
    // ObsidianImporterがmetadataに設定する。それ以外のsourceType(url/file/
    // text/share)ではmetadataにキー自体が存在しないため、いずれもnullのまま
    // SaveContentUseCaseへ渡る。
    final metadataExternalType = parsed.metadata['externalType'];
    final metadataVaultName = parsed.metadata['vaultName'];
    final metadataRelativePath = parsed.metadata['relativePath'];

    // shouldCleanはparser.parse()による変換(frontmatterのtags抽出、wikilinkの
    // リンク先展開等)より後のbodyに対して適用する。変換前の生テキストに適用すると、
    // URLや長い英数字を含むタグ・ノートタイトルが変換される前に誤って
    // 省略されてしまうため。
    final body = shouldClean ? TextCleaner.clean(parsed.body) : parsed.body;

    return _saveContent.execute(
      body: body,
      sourceType: sourceType,
      title: metadataTitle is String ? metadataTitle : null,
      sourceUrl: sourceUrl,
      sourceFilename: sourceFilename,
      externalType: metadataExternalType is String ? metadataExternalType : null,
      vaultName: metadataVaultName is String ? metadataVaultName : null,
      relativePath: metadataRelativePath is String ? metadataRelativePath : null,
    );
  }
}
