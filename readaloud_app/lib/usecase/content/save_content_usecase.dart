import '../../model/content.dart';
import '../../repository/content_repository.dart';

class SaveContentUseCase {
  final ContentRepository _repository;

  SaveContentUseCase(this._repository);

  Future<Content> execute({
    required String body,
    required String sourceType,
    String? title,
    String? sourceUrl,
    String? sourceFilename,
  }) async {
    // タイトル自動生成ロジック
    final generatedTitle = title ?? _generateTitle(
      body: body,
      sourceType: sourceType,
      sourceUrl: sourceUrl,
      sourceFilename: sourceFilename,
    );

    final content = Content(
      title: generatedTitle,
      body: body,
      sourceType: sourceType,
      sourceUrl: sourceUrl,
      sourceFilename: sourceFilename,
    );

    await _repository.save(content);
    return content;
  }

  String _generateTitle({
    required String body,
    required String sourceType,
    String? sourceUrl,
    String? sourceFilename,
  }) {
    switch (sourceType) {
      case 'url':
        // URLの場合はWebページのタイトルを使用（取得済みの場合）
        // タイトルが取得できない場合はURLをそのまま使用
        return sourceUrl ?? body.substring(0, body.length.clamp(0, 30));
      case 'file':
        // ファイル名から拡張子を除いたものをタイトルに使用
        if (sourceFilename != null) {
          final dotIndex = sourceFilename.lastIndexOf('.');
          return dotIndex >= 0
              ? sourceFilename.substring(0, dotIndex)
              : sourceFilename;
        }
        return body.substring(0, body.length.clamp(0, 30));
      case 'text':
      case 'share':
      default:
        // テキスト・共有の場合は本文の先頭30文字
        final trimmed = body.trim().replaceAll('\n', ' ');
        return trimmed.substring(0, trimmed.length.clamp(0, 30));
    }
  }
}
