import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/folder_child.dart';
import '../model/setting.dart';
import '../repository/folder_children_lister.dart';
import '../repository/impl/settings_repository_impl.dart';
import '../repository/settings_repository.dart';
import '../repository/sources_library_lookup.dart';
import '../repository/impl/docman_vault_data_source.dart';
import '../repository/vault_data_source.dart';
import '../usecase/sources/recent_folder_grouping.dart';
import '../util/debug_logger.dart';

final sourcesSettingsProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepositoryImpl(),
);

final sourcesVaultProvider = Provider<VaultDataSource>(
  (ref) => DocmanVaultDataSource(),
);

final sourcesFolderListerProvider = Provider<FolderChildrenLister>(
  (ref) => NativeFolderChildrenLister(),
);

final sourcesLibraryLookupProvider = Provider<SourcesLibraryLookup>(
  (ref) => ContentDaoSourcesLibraryLookup(),
);

/// Sources 画面の表示状態。
sealed class SourcesScreenData {
  const SourcesScreenData();
}

class SourcesNotConfigured extends SourcesScreenData {
  const SourcesNotConfigured();
}

class SourcesUnavailable extends SourcesScreenData {
  const SourcesUnavailable({required this.folderName, required this.permissionLost});

  final String? folderName;

  /// true: 権限喪失（フォルダを選び直す必要がある）。false: 到達不能。
  final bool permissionLost;
}

class SourcesLoaded extends SourcesScreenData {
  const SourcesLoaded({
    required this.folderName,
    required this.selection,
    required this.savedUris,
    required this.now,
  });

  final String? folderName;
  final RecentFolderSelection selection;
  final Set<String> savedUris;
  final DateTime now;

  bool isSaved(FolderChild item) => savedUris.contains(item.uri);
}

/// 設定済みフォルダの直下を列挙し、Recent 表示用の状態を組み立てる。
/// 本文は読まない。一覧生成は metadata のみで行う。
final sourcesScreenProvider = FutureProvider.autoDispose<SourcesScreenData>((ref) async {
  // 計測範囲は provider entry から（Sources open → direct-child Recent list）。
  final total = Stopwatch()..start();
  final settings = ref.read(sourcesSettingsProvider);
  final vault = ref.read(sourcesVaultProvider);
  final lister = ref.read(sourcesFolderListerProvider);
  final lookup = ref.read(sourcesLibraryLookupProvider);

  final folderUri = await settings.get(SettingKeys.sourcesFolderUri);
  if (folderUri == null) return const SourcesNotConfigured();

  final folderNameWatch = Stopwatch()..start();
  final folderName = await _folderNameOrNull(vault, folderUri);
  final folderNameMs = folderNameWatch.elapsedMilliseconds;

  // listMs は native direct-child listing の時間のみ。
  final list = Stopwatch()..start();
  final List<FolderChild> children;
  try {
    children = await lister.listDirectChildren(folderUri);
  } on FolderPermissionLostException {
    return SourcesUnavailable(folderName: folderName, permissionLost: true);
  } on FolderUnavailableException {
    return SourcesUnavailable(folderName: folderName, permissionLost: false);
  }
  final listMs = list.elapsedMilliseconds;

  final now = DateTime.now();
  final selection = RecentFolderGrouping.select(children, now: now);
  final lookupWatch = Stopwatch()..start();
  final savedUris = await lookup.savedFolderSourceUris();
  final lookupMs = lookupWatch.elapsedMilliseconds;

  // ログには URI・ファイル名・本文を含めない（件数と時間のみ）。
  unawaited(DebugLogger.instance.logEvent('source_discovery_completed', {
    'totalMs': total.elapsedMilliseconds,
    'folderNameMs': folderNameMs,
    'listMs': listMs,
    'lookupMs': lookupMs,
    'entryCount': children.length,
    'recentCount': selection.groups.fold<int>(0, (n, g) => n + g.items.length),
    'authority': Uri.tryParse(folderUri)?.host ?? 'unknown',
  }));

  return SourcesLoaded(
    folderName: folderName,
    selection: selection,
    savedUris: savedUris,
    now: now,
  );
});

Future<String?> _folderNameOrNull(VaultDataSource vault, String folderUri) async {
  try {
    return await vault.getDirectoryName(folderUri);
  } catch (_) {
    return null;
  }
}

/// フォルダを SAF で選び直し、Sources 専用の設定値として保存する。
/// キャンセル時は何もしない。Obsidian Vault 設定には触れない。
Future<bool> pickSourcesFolder(WidgetRef ref) async {
  final uri = await ref.read(sourcesVaultProvider).pickDirectory();
  if (uri == null) return false;
  await ref.read(sourcesSettingsProvider).set(SettingKeys.sourcesFolderUri, uri);
  ref.invalidate(sourcesScreenProvider);
  return true;
}
