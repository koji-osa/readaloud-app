import '../../model/content.dart';
import '../../model/folder_child.dart';
import '../../model/playback_request.dart';
import '../../model/raw_content.dart';
import '../../repository/vault_data_source.dart';
import '../../util/markdown_content_parser.dart';
import '../../util/text_cleaner.dart';

/// タップされた1件の本文を解決できなかった理由。
class FolderSourceResolveException implements Exception {
  const FolderSourceResolveException(this.reason);

  final String reason;

  @override
  String toString() => 'FolderSourceResolveException($reason)';
}

/// Folder Source の1件を on-demand で解決し、Transient 再生要求へ変換する。
///
/// 順序: read → Markdown parse（frontmatter 除去）→ clean → PlaybackRequest。
/// 解決に失敗した場合は例外を投げ、[open] は再生経路（openTransient）を呼ばない。
class FolderSourceOpenUseCase {
  FolderSourceOpenUseCase({required VaultDataSource vault}) : _vault = vault;

  final VaultDataSource _vault;

  Future<PlaybackRequest> resolve({
    required FolderChild item,
    required String folderName,
  }) async {
    final String raw;
    try {
      raw = await _vault.readFile(item.uri);
    } catch (_) {
      throw const FolderSourceResolveException('read_failed');
    }

    final parsed = await MarkdownContentParser(obsidianExtensions: true)
        .parse(RawContent(text: raw, metadata: const {}));
    final cleaned = TextCleaner.clean(parsed.body);
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

  /// 解決に成功した場合にのみ [openTransient] を呼ぶ。
  /// 失敗時は例外を伝播し、呼び出し側の既存 Playback には一切触れない。
  Future<void> open({
    required FolderChild item,
    required String folderName,
    required Future<void> Function(PlaybackRequest request) openTransient,
  }) async {
    final request = await resolve(item: item, folderName: folderName);
    await openTransient(request);
  }

  String _titleFor(String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    return stem.length > Content.maxTitleLength
        ? stem.substring(0, Content.maxTitleLength)
        : stem;
  }
}
