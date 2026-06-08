import '../../providers.dart';
import '../../repository/gemini_service.dart';
import '../../repository/claude_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../model/setting.dart';
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
import '../home/widgets/tts_usage_banner.dart';

import 'widgets/highlight_text.dart';
import 'widgets/seek_bar.dart';
import 'widgets/playback_controls.dart';
import 'widgets/bookmark_panel.dart';
import '../../model/bookmark.dart';

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
    final settingsState = ref.watch(settingsViewModelProvider);

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
            // テキスト表示（ハイライト付き・高さ固定）
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.40,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: HighlightText(
                  text: widget.content.body,
                  highlightPosition: state.highlightPosition,
                  onTap: (position) => vm.seekToBookmark(position), // REQ-001
                ),
              ),
            ),
            // シークバー（ローディング完了後に正しい位置で表示・FIX-033）
            if (!state.isLoading)
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
            // ブックマークパネル（スクロール可能エリア）
            Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: BookmarkPanel(
                    bookmarks: state.bookmarks,
                    onAdd: () => _showAddBookmarkDialog(context, vm, state),
                    onDelete: (id) => vm.deleteBookmark(id),
                    onJump: (position) => vm.seekToBookmark(position),
                    onAnalyze: () => _showAnalyzeDialog(context, vm, state, settingsState.aiProvider), // REQ-011
                  ),
                ),
              ),
            ),
            // 再生コントロール（常に表示・固定）
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

  String _geminiErrorMessage(dynamic e) {
    final msg = e.toString();
    if (msg.contains('503')) return 'サーバーが混雑しています。しばらく待ってから再度お試しください。';
    if (msg.contains('401') || msg.contains('403')) return 'APIキーが無効です。設定画面で確認してください。';
    if (msg.contains('timeout')) return '通信がタイムアウトしました。再度お試しください。';
    return '分析に失敗しました。再度お試しください。';
  }

  Future<void> _showAnalyzeDialog(
    BuildContext context,
    PlayerViewModel vm,
    PlayerState state,
    String aiProvider,
  ) async {
    if (state.content == null) return;

    // 前回のSnackBarが残っている場合は消す（FIX-041）
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    const storage = FlutterSecureStorage();
    final apiKeySettingKey = aiProvider == 'claude'
        ? SettingKeys.claudeApiKey
        : SettingKeys.geminiApiKey;
    final apiKey = await storage.read(key: apiKeySettingKey);
    if (!context.mounted) return;

    if (apiKey == null || apiKey.isEmpty) {
      final providerName = aiProvider == 'claude' ? 'Claude' : 'Gemini';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('設定画面で$providerName APIキーを設定してください'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    bool shouldClean = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A3E),
          title: Text(
            aiProvider == 'claude'
                ? 'AI目次作成 - Claude API利用について'
                : 'AI目次作成 - Gemini API利用について',
            style: const TextStyle(color: Color(0xFFF0F0F8), fontSize: 14),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                aiProvider == 'claude'
                    ? 'Anthropicのサーバーに送信されます。個人情報・機密情報を含むテキストへの使用はご注意ください。'
                    : 'GoogleのAIトレーニングに使用される場合があります。個人情報・機密情報を含むテキストへの使用はご注意ください。',
                style: const TextStyle(fontSize: 12, color: Color(0xFF8888AA)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Checkbox(
                    value: shouldClean,
                    onChanged: (v) => setState(() => shouldClean = v ?? true),
                    activeColor: const Color(0xFF7C5CBF),
                    side: const BorderSide(color: Color(0xFF3A3A55)),
                  ),
                  const Expanded(
                    child: Text(
                      'URLや長い英数字・記号を省略して送信する',
                      style: TextStyle(fontSize: 12, color: Color(0xFF8888AA)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('キャンセル',
                  style: TextStyle(color: Color(0xFF8888AA))),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('分析する',
                  style: TextStyle(color: Color(0xFF9B6FE0))),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🤖 テキストを分析中...'),
        duration: Duration(seconds: 120),
        backgroundColor: Color(0xFF7C5CBF),
      ),
    );

    try {
      final List<Bookmark> bookmarks;
      if (aiProvider == 'claude') {
        bookmarks = await ClaudeService().analyzeAndCreateBookmarks(
          contentId: state.content!.id,
          text: state.content!.body,
          apiKey: apiKey,
          shouldClean: shouldClean,
          speed: state.playbackState?.speed ?? 1.0,
          totalChars: state.content!.body.length,
        );
      } else {
        bookmarks = await GeminiService().analyzeAndCreateBookmarks(
          contentId: state.content!.id,
          text: state.content!.body,
          apiKey: apiKey,
          shouldClean: shouldClean,
          speed: state.playbackState?.speed ?? 1.0,
          totalChars: state.content!.body.length,
        );
      }
      for (final bookmark in bookmarks) {
        await vm.addBookmarkDirect(bookmark);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ ${bookmarks.length}件のブックマークを追加しました'),
            backgroundColor: const Color(0xFF7C5CBF),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_geminiErrorMessage(e)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
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
    final now = DateTime.now();
    final dateLabel = '${now.month}/${now.day} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final controller = TextEditingController(text: '$timeLabel $dateLabel');
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
