import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../viewmodel/content_list_viewmodel.dart';
import '../../usecase/content/get_all_contents_usecase.dart';
import '../../usecase/content/delete_content_usecase.dart';
import '../../usecase/content/update_content_usecase.dart';
import '../../repository/impl/content_repository_impl.dart';
import '../../repository/impl/playback_repository_impl.dart';
import '../../model/content.dart';
import '../add/add_screen.dart';
import '../settings/settings_screen.dart';
import '../player/player_screen.dart';
import 'widgets/content_card.dart';
import 'widgets/tts_usage_banner.dart';

final contentListViewModelProvider =
    StateNotifierProvider<ContentListViewModel, ContentListState>((ref) {
  final repo = ContentRepositoryImpl();
  return ContentListViewModel(
    getAllContents: GetAllContentsUseCase(repo),
    deleteContent: DeleteContentUseCase(repo),
    updateContent: UpdateContentUseCase(repo),
    playbackRepo: PlaybackRepositoryImpl(),
  );
});

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _isSelectMode = false;
  final Set<String> _selectedIds = {};

  void _enterSelectMode(String id) {
    setState(() {
      _isSelectMode = true;
      _selectedIds.add(id);
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _exitSelectMode() {
    setState(() {
      _isSelectMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _deleteSelected(BuildContext context) async {
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A3E),
        title: const Text('一括削除', style: TextStyle(color: Color(0xFFF0F0F8))),
        content: Text(
          '$count件のテキストを削除しますか？',
          style: const TextStyle(color: Color(0xFF8888AA)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル', style: TextStyle(color: Color(0xFF8888AA))),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('削除', style: TextStyle(color: Color(0xFFF87171))),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      for (final id in _selectedIds.toList()) {
        if (!mounted) break;
        await ref.read(contentListViewModelProvider.notifier).deleteContent(id);
      }
      if (mounted) _exitSelectMode();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(contentListViewModelProvider);
    final vm = ref.read(contentListViewModelProvider.notifier);

    return PopScope(
      canPop: !_isSelectMode,
      onPopInvoked: (didPop) {
        if (!didPop && _isSelectMode) {
          _exitSelectMode();
        }
      },
      child: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // ヘッダー
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'ライブラリ',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFF0F0F8),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings, color: Color(0xFF8888AA)),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    ),
                  ),
                ],
              ),
            ),
            // TTS使用量バナー
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: TtsUsageBanner(),
            ),
            // フィルター
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ('all', 'すべて'),
                    ('unread', '未読'),
                    ('in_progress', '読書中'),
                    ('completed', '完了'),
                  ].map((f) {
                    final isSelected = state.selectedFilter == f.$1;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(f.$2),
                        selected: isSelected,
                        onSelected: (_) => vm.changeFilter(f.$1),
                        selectedColor: const Color(0xFF7C5CBF),
                        backgroundColor: const Color(0xFF2A2A3E),
                        labelStyle: TextStyle(
                          color: isSelected
                              ? Colors.white
                              : const Color(0xFF8888AA),
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        side: BorderSide(
                          color: isSelected
                              ? const Color(0xFF7C5CBF)
                              : const Color(0xFF3A3A55),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            // コンテンツ一覧
            Expanded(
              child: state.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : state.contents.isEmpty
                      ? const Center(
                          child: Text(
                            'コンテンツがありません\n＋ボタンから追加してください',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Color(0xFF8888AA)),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(14),
                          itemCount: state.contents.length,
                          itemBuilder: (context, index) {
                            final content = state.contents[index];
                            return ContentCard(
                              content: content,
                              onTap: () => _isSelectMode
                                  ? _toggleSelect(content.id)
                                  : _openPlayer(context, ref, content),
                              onDelete: () =>
                                  _confirmDelete(context, ref, content),
                              onEditTitle: (currentTitle) =>
                                  _showEditTitleDialog(context, ref, content.id, currentTitle),
                              progressPct: state.progressMap[content.id] ?? 0.0,
                              isSelectMode: _isSelectMode,
                              isSelected: _selectedIds.contains(content.id),
                              onLongPress: () => _isSelectMode
                                  ? _toggleSelect(content.id)
                                  : _enterSelectMode(content.id),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      floatingActionButton: _isSelectMode
          ? Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'cancel',
                  onPressed: _exitSelectMode,
                  backgroundColor: const Color(0xFF323248),
                  label: const Text('キャンセル', style: TextStyle(color: Color(0xFFF0F0F8))),
                ),
                const SizedBox(width: 12),
                FloatingActionButton.extended(
                  heroTag: 'delete',
                  onPressed: _selectedIds.isEmpty ? null : () => _deleteSelected(context),
                  backgroundColor: _selectedIds.isEmpty ? const Color(0xFF323248) : const Color(0xFFF87171),
                  label: Text(
                    '削除 (${_selectedIds.length})',
                    style: const TextStyle(color: Color(0xFFF0F0F8)),
                  ),
                ),
              ],
            )
          : FloatingActionButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AddScreen()),
                );
                ref.read(contentListViewModelProvider.notifier).loadContents();
              },
              backgroundColor: const Color(0xFF7C5CBF),
              child: const Text('+', style: TextStyle(fontSize: 24, color: Colors.white)),
            ),
    ),
    );
  }

  Future<void> _showEditTitleDialog(BuildContext context, WidgetRef ref, String contentId, String currentTitle) async {
    final controller = TextEditingController(text: currentTitle);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A3E),
        title: const Text('タイトルを編集', style: TextStyle(color: Color(0xFFF0F0F8))),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'タイトルを入力',
            hintStyle: TextStyle(color: Color(0xFF44445A)),
          ),
          style: const TextStyle(color: Color(0xFFF0F0F8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル', style: TextStyle(color: Color(0xFF8888AA))),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存', style: TextStyle(color: Color(0xFF9B6FE0))),
          ),
        ],
      ),
    );
    if (newTitle != null && newTitle.isNotEmpty && mounted) {
      ref.read(contentListViewModelProvider.notifier).updateTitle(contentId, newTitle);
    }
  }

  Future<void> _openPlayer(BuildContext context, WidgetRef ref, Content content) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlayerScreen(content: content)),
    );
    // PlayerScreenから戻った時にコンテンツ一覧を更新
    ref.read(contentListViewModelProvider.notifier).loadContents();
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Content content,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A3E),
        title: const Text(
          '削除の確認',
          style: TextStyle(color: Color(0xFFF0F0F8)),
        ),
        content: Text(
          '「${content.title}」を削除しますか？\n削除すると元に戻せません。',
          style: const TextStyle(color: Color(0xFF8888AA)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル',
                style: TextStyle(color: Color(0xFF8888AA))),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('削除する',
                style: TextStyle(color: Color(0xFFF87171))),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(contentListViewModelProvider.notifier).deleteContent(content.id);
    }
  }
}
