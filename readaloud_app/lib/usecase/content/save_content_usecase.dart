import '../../model/content.dart';
import '../../repository/content_repository.dart';
import '../../util/auto_title.dart';

class SaveContentUseCase {
  final ContentRepository _repository;

  SaveContentUseCase(this._repository);

  Future<Content> execute({
    required String body,
    required String sourceType,
    String? title,
    String? sourceUrl,
    String? sourceFilename,
    String? externalType,
    String? vaultName,
    String? relativePath,
  }) async {
    // タイトル自動生成ロジック（PD-3: Transient見出しと同一の純関数へ委譲）
    final generatedTitle = title ??
        autoTitleFromBody(
          body,
          sourceType,
          sourceUrl: sourceUrl,
          sourceFilename: sourceFilename,
        );

    final content = Content(
      title: generatedTitle,
      body: body,
      sourceType: sourceType,
      sourceUrl: sourceUrl,
      sourceFilename: sourceFilename,
      externalType: externalType,
      vaultName: vaultName,
      relativePath: relativePath,
    );

    await _repository.save(content);
    return content;
  }
}
