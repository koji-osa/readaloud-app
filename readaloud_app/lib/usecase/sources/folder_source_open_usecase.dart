import '../../model/content.dart';
import '../../model/folder_child.dart';
import '../../model/playback_request.dart';
import '../../repository/vault_data_source.dart';
import '../../util/standard_markdown_converter.dart';
import '../../util/text_cleaner.dart';

/// タップされた1件の本文を解決できなかった理由。
class FolderSourceResolveException implements Exception {
  const FolderSourceResolveException(this.reason);

  final String reason;

  @override
  String toString() => 'FolderSourceResolveException($reason)';
}

/// Sources 画面単位の「最後にユーザーが意図した open だけを有効にする」ガード
/// （last user intent wins）。tile ごとではなく画面全体で1つを共有する。
///
/// 新しい項目タップで [claim] が generation を進め、フォルダ変更・再読み込み
/// 開始時に [invalidate] で進行中の open を無効化する。
class FolderSourceOpenGate {
  int _generation = 0;

  /// 新しい open 意図を登録し、その generation を返す。
  int claim() => ++_generation;

  /// 進行中の open をすべて無効化する（フォルダ変更・再読み込み開始時）。
  void invalidate() => _generation++;

  bool isCurrent(int generation) => generation == _generation;
}

/// [FolderSourceOpenUseCase.open] の結果。
enum FolderSourceOpenResult {
  /// 解決に成功し、openTransient を呼んだ。
  opened,

  /// 画面を離れた、または新しい意図に置き換えられたため破棄した（何もしない）。
  stale,

  /// 本文を解決できなかった（読み取り失敗・空本文）。
  failed,
}

/// Folder Source の1件を on-demand で解決し、Transient 再生要求へ変換する。
///
/// 順序: read → frontmatter-only 除去 → standard Markdown 変換 → clean → PlaybackRequest。
/// Folder Source は generic Markdown として扱い、Obsidian 固有記法（`$…$` / `%%…%%` /
/// code block 等）の変換は適用しない。
class FolderSourceOpenUseCase {
  FolderSourceOpenUseCase({required VaultDataSource vault}) : _vault = vault;

  final VaultDataSource _vault;

  /// 先頭の YAML frontmatter（`---` ... `---`）だけに一致する。
  static final _leadingFrontmatter = RegExp(r'^---\s*\r?\n[\s\S]*?\r?\n---\s*\r?\n?');

  Future<PlaybackRequest> resolve({
    required FolderChild item,
    required String? folderName,
  }) async {
    final String raw;
    try {
      raw = await _vault.readFile(item.uri);
    } catch (_) {
      throw const FolderSourceResolveException('read_failed');
    }

    final body = StandardMarkdownConverter().convert(raw.replaceFirst(_leadingFrontmatter, ''));
    final cleaned = TextCleaner.clean(body);
    if (cleaned.trim().isEmpty) {
      throw const FolderSourceResolveException('empty_body');
    }

    return PlaybackRequest(
      target: const TransientTarget(),
      text: cleaned,
      title: _titleFor(item.name),
      startPosition: 0,
      source: SourceDescriptor(
        sourceType: 'folder',
        sourceUrl: item.uri,
        sourceFilename: item.name,
        externalType: null,
        vaultName: folderName,
        relativePath: item.name,
      ),
    );
  }

  /// 項目を開く。順序は必ず resolve → guard → openTransient。
  ///
  /// guard は「画面が mounted」かつ「この open が最新の意図」の両方を満たす場合のみ
  /// 通す。古い／破棄済みの resolve 完了は [FolderSourceOpenResult.stale] として
  /// 何もせず返し、既存 Playback には一切触れない。
  Future<FolderSourceOpenResult> open({
    required FolderChild item,
    required String? folderName,
    required FolderSourceOpenGate gate,
    required bool Function() isMounted,
    required Future<void> Function(PlaybackRequest request) openTransient,
  }) async {
    final generation = gate.claim();

    final PlaybackRequest request;
    try {
      request = await resolve(item: item, folderName: folderName);
    } on FolderSourceResolveException {
      return _isLive(gate, generation, isMounted)
          ? FolderSourceOpenResult.failed
          : FolderSourceOpenResult.stale;
    }

    if (!_isLive(gate, generation, isMounted)) return FolderSourceOpenResult.stale;
    await openTransient(request);
    return FolderSourceOpenResult.opened;
  }

  bool _isLive(FolderSourceOpenGate gate, int generation, bool Function() isMounted) =>
      isMounted() && gate.isCurrent(generation);

  String _titleFor(String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    return stem.length > Content.maxTitleLength
        ? stem.substring(0, Content.maxTitleLength)
        : stem;
  }
}
