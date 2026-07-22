import 'vault_data_source.dart';

/// Obsidian Vault(SAF経由で選択したフォルダ)配下のMarkdownノートを
/// 扱うリポジトリ。
abstract class ObsidianRepository {
  /// SAFのフォルダ選択ダイアログを表示し、選択されたVaultのURIを保存する。
  /// ユーザーがキャンセルした場合はnullを返す。
  Future<String?> pickVaultDirectory();

  /// 保存済みのVaultURI配下のMarkdownノート一覧を取得する。
  /// Vaultが未設定の場合は空リストを返す。
  Future<List<VaultEntry>> listNotes();

  /// [uri]が指すノートの本文を読み込む。
  Future<String> readNoteContent(String uri);

  /// [path]にノートを書き込む。Phase1では未実装。
  Future<void> writeNote(String path, String content);
}
