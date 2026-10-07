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
class SourcesScreen extends ConsumerStatefulWidget {
  const SourcesScreen({super.key});

  @override
  ConsumerState<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends ConsumerState<SourcesScreen> {
  /// 画面全体で共有する open 意図のガード（tile 個別ではない）。
  final _openGate = FolderSourceOpenGate();

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(sourcesScreenProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sources'),
        actions: [
          IconButton(
            tooltip: 'フォルダを選択',
            icon: const Icon(Icons.folder_open),
            onPressed: () => _pick(),
          ),
          IconButton(
            tooltip: '再読み込み',
            icon: const Icon(Icons.refresh),
            onPressed: () => _refresh(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: data.when(
          loading: () => _pullableFill(const Center(child: CircularProgressIndicator())),
          error: (_, __) => _pullableFill(const _Message('フォルダを読み込めませんでした')),
          data: (value) => switch (value) {
            SourcesNotConfigured() => _pullableFill(_NotConfigured(onPick: () => _pick())),
            SourcesUnavailable(:final permissionLost) => _pullableFill(
                _Message(
                  permissionLost
                      ? 'フォルダへのアクセス権が失われました。フォルダを選び直してください。'
                      : 'フォルダに到達できません',
                ),
              ),
            SourcesLoaded loaded => _Loaded(data: loaded, onOpen: _openItem),
          },
        ),
      ),
    );
  }

  /// フォルダを選び直す。開始時点で進行中の open は無効化する。
  Future<void> _pick() async {
    _openGate.invalidate();
    await pickSourcesFolder(ref);
  }

  /// 再読み込み（AppBar / pull-to-refresh 共通）。開始時に進行中の open を無効化する。
  Future<void> _refresh() async {
    _openGate.invalidate();
    ref.invalidate(sourcesScreenProvider);
    try {
      await ref.read(sourcesScreenProvider.future);
    } catch (_) {
      // エラーは data.when の error 表示に任せる（pull の完了だけを返す）。
    }
  }

  /// 1件を解決し、最新の意図かつ mounted な場合だけ Transient 再生を開始する。
  Future<void> _openItem(FolderChild item, String? folderName) async {
    final coordinator = ref.read(playerEntryCoordinatorProvider);
    final usecase = FolderSourceOpenUseCase(vault: ref.read(sourcesVaultProvider));
    final flowId = 'source-${const Uuid().v4()}';
    final result = await usecase.open(
      item: item,
      folderName: folderName,
      gate: _openGate,
      isMounted: () => mounted,
      openTransient: (request) => coordinator.openTransient(
        context: context,
        isMounted: () => mounted,
        request: request,
        flowId: flowId,
        reason: TeardownReason.shareTeardown,
      ),
    );
    if (result == FolderSourceOpenResult.failed && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('この項目を開けませんでした')),
      );
    }
  }
}

/// 固定表示（空・エラー等）も pull-to-refresh できるよう、画面高さ分の
/// スクロール領域に載せる。
Widget _pullableFill(Widget child) {
  return LayoutBuilder(
    builder: (context, constraints) => ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [SizedBox(height: constraints.maxHeight, child: child)],
    ),
  );
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

class _Loaded extends StatelessWidget {
  const _Loaded({required this.data, required this.onOpen});

  final SourcesLoaded data;
  final void Function(FolderChild item, String? folderName) onOpen;

  @override
  Widget build(BuildContext context) {
    final selection = data.selection;
    switch (selection.state) {
      case FolderSourceState.noMarkdown:
        return _pullableFill(const _Message('このフォルダには Markdown ファイルがありません'));
      case FolderSourceState.noRecent:
        return _pullableFill(const _Message('直近7日以内の Markdown ファイルはありません'));
      case FolderSourceState.modifiedTimeUnavailable:
        return _pullableFill(const _Message('更新日時を取得できないため一覧を生成できません'));
      case FolderSourceState.ok:
        break;
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
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
            _ItemTile(
              item: item,
              saved: data.isSaved(item),
              onTap: () => onOpen(item, data.folderName),
            ),
        ],
      ],
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item, required this.saved, required this.onTap});

  final FolderChild item;
  final bool saved;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(item.name),
      trailing: saved ? const Text('保存済み') : null,
      onTap: onTap,
    );
  }
}
