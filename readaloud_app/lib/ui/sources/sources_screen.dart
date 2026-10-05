import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../model/folder_child.dart';
import '../../usecase/playback/shared_playback_transport.dart';
import '../../usecase/sources/folder_source_open_usecase.dart';
import '../../usecase/sources/recent_folder_grouping.dart';
import '../../util/player_entry_coordinator.dart';
import '../../viewmodel/sources_viewmodel.dart';

/// Sources 画面（Phase 1: 表示 View は1つ）。
/// 一覧はファイル名のみ。タップされた1件だけを on-demand で解決して再生する。
class SourcesScreen extends ConsumerWidget {
  const SourcesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(sourcesScreenProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sources'),
        actions: [
          IconButton(
            tooltip: 'フォルダを選択',
            icon: const Icon(Icons.folder_open),
            onPressed: () => _pick(context, ref),
          ),
          IconButton(
            tooltip: '再読み込み',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(sourcesScreenProvider),
          ),
        ],
      ),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const _Message('フォルダを読み込めませんでした'),
        data: (value) => switch (value) {
          SourcesNotConfigured() => _NotConfigured(onPick: () => _pick(context, ref)),
          SourcesUnavailable(:final permissionLost) => _Message(
              permissionLost
                  ? 'フォルダへのアクセス権が失われました。フォルダを選び直してください。'
                  : 'フォルダに到達できません',
            ),
          SourcesLoaded loaded => _Loaded(data: loaded),
        },
      ),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    await pickSourcesFolder(ref);
  }
}

class _NotConfigured extends StatelessWidget {
  const _NotConfigured({required this.onPick});

  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Sources のフォルダが未設定です'),
          const SizedBox(height: 12),
          FilledButton(onPressed: onPick, child: const Text('フォルダを選択')),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
  }
}

class _Loaded extends ConsumerWidget {
  const _Loaded({required this.data});

  final SourcesLoaded data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = data.selection;
    switch (selection.state) {
      case FolderSourceState.noMarkdown:
        return const _Message('このフォルダには Markdown ファイルがありません');
      case FolderSourceState.noRecent:
        return const _Message('直近7日以内の Markdown ファイルはありません');
      case FolderSourceState.modifiedTimeUnavailable:
        return const _Message('更新日時を取得できないため一覧を生成できません');
      case FolderSourceState.ok:
        break;
    }

    return ListView(
      children: [
        for (final group in selection.groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              RecentFolderGrouping.labelFor(group.day, now: data.now),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final item in group.items)
            _ItemTile(item: item, saved: data.isSaved(item), folderName: data.folderName),
        ],
      ],
    );
  }
}

class _ItemTile extends ConsumerWidget {
  const _ItemTile({required this.item, required this.saved, required this.folderName});

  final FolderChild item;
  final bool saved;
  final String? folderName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      title: Text(item.name),
      trailing: saved ? const Text('保存済み') : null,
      onTap: () => _open(context, ref),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final coordinator = ref.read(playerEntryCoordinatorProvider);
    final usecase = FolderSourceOpenUseCase(vault: ref.read(sourcesVaultProvider));
    final flowId = 'source-${const Uuid().v4()}';
    try {
      await usecase.open(
        item: item,
        folderName: folderName ?? '',
        openTransient: (request) => coordinator.openTransient(
          context: context,
          isMounted: () => context.mounted,
          request: request,
          flowId: flowId,
          reason: TeardownReason.shareTeardown,
        ),
      );
    } on FolderSourceResolveException {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('この項目を開けませんでした')),
      );
    }
  }
}
