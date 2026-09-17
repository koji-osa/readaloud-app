/// 本文・由来から自動タイトルを生成する純関数（PD-3）。
///
/// `SaveContentUseCase` の保存時自動タイトルと Transient 画面の見出しが
/// 同一ロジックを共有するために切り出した（保存結果は従来と同一）。
String autoTitleFromBody(
  String body,
  String sourceType, {
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
    case 'obsidian':
    case 'text':
    case 'share':
    default:
      // テキスト・共有・Obsidianの場合は本文の先頭30文字
      final trimmed = body.trim().replaceAll('\n', ' ');
      return trimmed.substring(0, trimmed.length.clamp(0, 30));
  }
}
