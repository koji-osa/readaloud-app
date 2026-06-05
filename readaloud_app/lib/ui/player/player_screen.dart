import '../../model/tts_playback_position.dart';
import '../../providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../model/content.dart';
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

import 'widgets/highlight_text.dart';
import 'widgets/seek_bar.dart';
import 'widgets/playback_controls.dart';
import 'widgets/bookmark_panel.dart';

final playerViewModelProvider =
    StateNotifierProvider.autoDispose<PlayerViewModel, PlayerState>((ref) {
  final contentRepo  = ContentRepositoryImpl();
  final playbackRepo = PlaybackRepositoryImpl();
  final bookmarkRepo = BookmarkRepositoryImpl();
  final settingsRepo = SettingsRepositoryImpl();
  final audioHandler = ref.read(audioHandlerProvider);

  final checkTtsLimit = CheckTtsLimitUseCase(
    settingsRepo: settingsRepo,
    onLimitStatus: (status) {
      // 通知不要（バナーで表示）
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
    settingsRepo: settingsRepo,
    startPlayback: StartPlaybackUseCase(
      contentRepo: contentRepo,
      playbackRepo: playbackRepo,
      ttsHandler: audioHandler,
      ttsService: audioHandler,
      countUsage: countTtsUsage,
    ),
    stopPlayback: StopPlaybackUseCase(
      playbackRepo: playbackRepo,
      ttsService: audioHandler,
      countUsage: countTtsUsage,
      saveState: savePlaybackState,
    ),
    savePlaybackState: savePlaybackState,
    setAbRepeat: SetAbRepeatUseCase(playbackRepo),
    addBookmark: AddBookmarkUseCase(bookmarkRepo),
    deleteBookmark: DeleteBookmarkUseCase(bookmarkRepo),
    bookmarkRepo: bookmarkRepo,
    checkTtsLimit: checkTtsLimit,
    audioHandler: audioHandler,
    playbackRepo: playbackRepo,
  );
});

class PlayerScreen extends ConsumerStatefulWidget {
  final Content content;
  final bool autoPlay;

  const PlayerScreen({super.key, required this.content, this.autoPlay = false});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  List<String> _availableVoices = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final vm = ref.read(playerViewModelProvider.notifier);
        await vm.setContent(widget.content);
        await _loadAvailableVoices();
        if (widget.autoPlay) {
          await vm.play();
        }
      } catch (e) {
        // ViewModelのerrorMessageで表示されるため基本的には不要
      }
    });
  }

  Future<void> _loadAvailableVoices() async {
    final audioHandler = ref.read(audioHandlerProvider);
    try {
      final voices = await audioHandler.getAvailableVoices();
      final jaVoices = voices
          .where((v) => v.languageCode.startsWith('ja'))
          .map((v) => v.id)
          .toList();
      if (mounted) {
        setState(() {
          _availableVoices = jaVoices;
        });
      }
    } catch (_) {
    }
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
            // デバッグ表示（customState確認用）
            StreamBuilder(
              stream: ref.read(audioHandlerProvider).customState,
              builder: (context, snapshot) {
                final data = snapshot.data;
                final pos = data is TtsPlaybackPosition ? data.charPosition.toString() : 'N/A';
                final playing = data is TtsPlaybackPosition ? data.isPlaying.toString() : 'N/A';
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  color: const Color(0xFF1A1A2E),
                  child: Text(
                    'DEBUG pos=$pos playing=$playing',
                    style: const TextStyle(fontSize: 10, color: Color(0xFF9B6FE0)),
                  ),
                );
              },
            ),
            // ローディング表示
            if (state.isLoading)
              const LinearProgressIndicator(
                color: Color(0xFF7C5CBF),
                backgroundColor: Color(0xFF2A2A3E),
              ),
            // エラーメッセージ表示
            if (state.errorMessage != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        state.errorMessage!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          color: Colors.redAccent, size: 16),
                      onPressed: vm.clearError,
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
                totalChars: widget.content.body.length,
                speed: state.playbackState?.speed ?? 1.0,
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
                onAdd: () => _showAddBookmarkDialog(context, vm, state),
                onDelete: (id) => vm.deleteBookmark(id),
                onJump: (position) => vm.seekToBookmark(position),
              ),
            ),
            // 再生コントロール
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: PlaybackControls(
                isPlaying: state.isPlaying,
                speed: state.playbackState?.speed ?? 1.0,
                voiceId: state.playbackState?.voiceId,
                availableVoices: _availableVoices,
                onPlay: vm.play,
                onPause: vm.pause,
                onStop: vm.stop,
                onSeekToStart: vm.seekToStart,
                onSeekToEnd: vm.seekToEnd,
                onRewind: vm.rewind,
                onFastForward: vm.fastForward,
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
    PlayerState state,
  ) async {
    // 現在の再生時間を初期値として設定（REQ-018）
    final totalChars = state.content?.body.length ?? 0;
    final speed = (state.playbackState?.speed ?? 1.0).clamp(0.1, 10.0);
    final progressPct = state.playbackState?.progressPct ?? 0.0;
    final totalSecs = totalChars / (5.0 * speed);
    final currentSecs = (totalSecs * progressPct / 100).round();
    final minutes = currentSecs ~/ 60;
    final seconds = currentSecs % 60;
    final timeLabel = '$minutes:${seconds.toString().padLeft(2, '0')}';
    final controller = TextEditingController(text: timeLabel);
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
