import '../../model/raw_content.dart';
import '../../repository/obsidian_repository.dart';

/// [ObsidianRepository]を用いてVault内のノートを読み込み、
/// 共通データ形式[RawContent]に変換するユースケース。
class ObsidianImporter {
  ObsidianImporter(this._repository);

  final ObsidianRepository _repository;

  /// [noteUris]の各ノートを読み込み、[RawContent]に変換する。
  /// 各URIを個別にtry-catchするため、1件の読み込みが失敗しても
  /// 他の件の処理は止まらない。結果は成功/失敗の別に関わらず、
  /// 呼び出し時の順序で[ImportNoteResult]のリストとして返す。
  Future<List<ImportNoteResult>> importNotes(List<String> noteUris) async {
    final results = <ImportNoteResult>[];

    for (final uri in noteUris) {
      try {
        final text = await _repository.readNoteContent(uri);
        results.add(
          ImportNoteResult(
            noteUri: uri,
            content: RawContent(text: text, metadata: {'noteUri': uri}),
          ),
        );
      } catch (e) {
        results.add(ImportNoteResult(noteUri: uri, error: e));
      }
    }

    return results;
  }
}

/// 1件のノート取り込みの結果。
/// 成功時は[content]のみ、失敗時は[error]のみが値を持つ。
class ImportNoteResult {
  ImportNoteResult({required this.noteUri, this.content, this.error});

  final String noteUri;
  final RawContent? content;
  final Object? error;

  bool get isSuccess => content != null;
}
