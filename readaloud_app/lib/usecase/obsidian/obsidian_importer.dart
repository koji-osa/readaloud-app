import '../../model/raw_content.dart';
import '../../repository/obsidian_repository.dart';
import '../../repository/vault_data_source.dart';

/// [ObsidianRepository]を用いてVault内のノートを読み込み、
/// 共通データ形式[RawContent]に変換するユースケース。
class ObsidianImporter {
  ObsidianImporter(this._repository);

  final ObsidianRepository _repository;

  /// [entries]の各ノートを読み込み、[RawContent]に変換する。
  /// 各エントリを個別にtry-catchするため、1件の読み込みが失敗しても
  /// 他の件の処理は止まらない。結果は成功/失敗の別に関わらず、
  /// 呼び出し時の順序で[ImportNoteResult]のリストとして返す。
  Future<List<ImportNoteResult>> importNotes(List<VaultEntry> entries) async {
    final results = <ImportNoteResult>[];

    for (final entry in entries) {
      try {
        final text = await _repository.readNoteContent(entry.uri);
        results.add(
          ImportNoteResult(
            entry: entry,
            content: RawContent(
              text: text,
              metadata: {'noteUri': entry.uri, 'title': _titleFor(entry)},
            ),
          ),
        );
      } catch (e) {
        results.add(ImportNoteResult(entry: entry, error: e));
      }
    }

    return results;
  }

  /// [entry.name]から拡張子を除いたものをタイトルとする。
  /// SaveContentUseCase._generateTitle()のsourceType='file'と同様のロジックとし、
  /// 拡張子の扱いに一貫性を持たせる。
  String _titleFor(VaultEntry entry) {
    final name = entry.name;
    final dotIndex = name.lastIndexOf('.');
    return dotIndex > 0 ? name.substring(0, dotIndex) : name;
  }
}

/// 1件のノート取り込みの結果。
/// 成功時は[content]のみ、失敗時は[error]のみが値を持つ。
class ImportNoteResult {
  ImportNoteResult({required this.entry, this.content, this.error});

  final VaultEntry entry;
  final RawContent? content;
  final Object? error;

  /// [entry.uri]へのショートハンド。
  String get noteUri => entry.uri;

  bool get isSuccess => content != null;
}
