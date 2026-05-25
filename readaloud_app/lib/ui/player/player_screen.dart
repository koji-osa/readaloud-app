import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../model/content.dart';
import '../../model/bookmark.dart';
import '../../viewmodel/player_viewmodel.dart';
import '../../usecase/playback/start_playback_usecase.dart';
import '../../usecase/playback/stop_playback_usecase.dart';
import '../../usecase/playback/save_playback_state_usecase.dart';
import '../../usecase/playback/set_ab_repeat_usecase.dart';
import '../../usecase/bookmark/add_bookmark_usecase.dart';
import '../../usecase/bookmark/delete_bookmark_usecase.dart';
import '../../usecase/tts/check_tts_limit_usecase.dart';
import '../../usecase/tts/count_tts_usage_usecase.dart';
import '../../repository/impl/content_repository_impl.dart';
import '../../repository/impl/playback_repository_impl.dart';
import '../../repository/impl/bookmark_repository_impl.dart';
import '../../repository/impl/settings_repository_impl.dart';
import '../../repository/tts/device_tts_service.dart';
import '../../util/notification_helper.dart';
import 'widgets/highlight_text.dart';
import 'widgets/seek_bar.dart';
import 'widgets/playback_controls.dart';
import 'widgets/bookmark_panel.dart';

final playerViewModelProvider =
    StateNotifierProvider.autoDispose<PlayerViewModel, PlayerState>((ref) {
  final contentRepo   = ContentRepositoryImpl();
  final playbackRepo  = PlaybackRepositoryImpl();
  final bookmarkRepo  = BookmarkRepositoryImpl();
  final settingsRepo  = SettingsRepositoryImpl();
  final ttsService    = DeviceTtsService();

  final checkTtsLimit = CheckTtsLimitUseCase(
    settingsRepo: settingsRepo,
    onLimitStatus: (status) {
      // 閾値到達時にプッシュ通知を送信
      NotificationHelper.notifyTtsLimit(status);
    },
  );
  final countTtsUsage = CountTtsUsageUseCase(
    settingsRepo: settingsRepo,
    checkLimit: checkTtsLimit,
  );
  final savePlaybackState = SavePlaybackStateUseCase(
    playbackRepo: playbackRepo,
    contentRepo: contentRepo,
  );

  return PlayerViewModel(
    startPlayback: StartPlaybackUseCase(
      contentRepo: contentRepo,
      playbackRepo: playbackRepo,
      ttsService: ttsService,
      countUsage: countTtsUsage,
    ),
    stopPlayback: StopPlaybackUseCase(
      playbackRepo: playbackRepo,
      ttsService: ttsService,
      countUsage: countTtsUsage,
      saveState: savePlaybackState,
    ),
    savePlaybackState: savePlaybackState,
    setAbRepeat: SetAbRepeatUseCase(playbackRepo),
    addBookmark: AddBookmarkUseCase(bookmarkRepo),
    deleteBookmark: DeleteBookmarkUseCase(bookmarkRepo),
    checkTtsLimit: checkTtsLimit,
    ttsService: ttsService,
  );
});

class PlayerScreen extends ConsumerStatefulWidget {
  final Content content;

  const PlayerScreen({super.key, required this.content});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  @override
  void initState() {
    super.initState();
    // 画面表示後にコンテンツをViewModelにセット
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(playerViewModelProvider.notifier).setContent(widget.content);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(playerViewModelProvider);
    final vm    = ref.read(playerViewModelProvider.notifier);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // ヘッダー
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 18, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back,
                        color: Color(0xFF8888AA)),
                    onPressed: () {
                      vm.stop();
                      Navigator.of(context).pop();
                    },
                  ),
                  Expanded(
                    child: Text(
                      widget.content.title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF0F0F8),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            // テキスト表示（ハイライト付き）
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: HighlightText(
                  text: widget.content.body,
                  highlightPosition: state.highlightPosition,
                ),
              ),
            ),
            // シークバー
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SeekBar(
                progress: state.playbackState?.progressPct ?? 0.0,
                onChanged: (value) async {
                  await vm.pause();
                  await vm.seekTo(value);
                },
              ),
            ),
            // ブックマークパネル
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: BookmarkPanel(
                bookmarks: state.bookmarks,
                onAdd: () => _showAddBookmarkDialog(context, vm),
                onDelete: (id) => vm.deleteBookmark(id),
              ),
            ),
            // 再生コントロール
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: PlaybackControls(
                isPlaying: state.isPlaying,
                speed: state.playbackState?.speed ?? 1.0,
                voiceId: state.playbackState?.voiceId,
                onPlay: vm.play,
                onPause: vm.pause,
                onStop: vm.stop,
                onSpeedChange: vm.changeSpeed,
                onVoiceChange: vm.changeVoice,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddBookmarkDialog(
    BuildContext context,
    PlayerViewModel vm,
  ) async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A3E),
        title: const Text(
          'ブックマークを追加',
          style: TextStyle(color: Color(0xFFF0F0F8)),
        ),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'ラベル（任意）',
            hintStyle: TextStyle(color: Color(0xFF44445A)),
          ),
          style: const TextStyle(color: Color(0xFFF0F0F8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル',
                style: TextStyle(color: Color(0xFF8888AA))),
          ),
          TextButton(
            onPressed: () {
              vm.addBookmark(
                controller.text.isEmpty ? null : controller.text,
              );
              Navigator.of(context).pop();
            },
            child: const Text('追加',
                style: TextStyle(color: Color(0xFF9B6FE0))),
          ),
        ],
      ),
    );
  }
}
