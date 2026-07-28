import 'dart:async'; // REQ-034
import '../../providers.dart';
import '../../repository/gemini_service.dart';
import '../../repository/claude_service.dart';
import '../../repository/groq_service.dart';
import '../../repository/table_analysis_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../model/setting.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // REQ-045 REQ-046
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../model/content.dart';
import '../../util/obsidian_launcher.dart';
import '../../viewmodel/player_viewmodel.dart';
import '../../usecase/playback/start_playback_usecase.dart';
import '../../usecase/playback/stop_playback_usecase.dart';
import '../../usecase/playback/save_playback_state_usecase.dart';
import '../../usecase/playback/set_ab_repeat_usecase.dart';
import '../../usecase/bookmark/add_bookmark_usecase.dart';
import '../../usecase/bookmark/delete_bookmark_usecase.dart';
import '../../usecase/content/update_content_usecase.dart';
import '../../usecase/content/save_content_usecase.dart'; // REQ-034
import '../home/home_screen.dart'; // FIX-066
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
    updateContent: UpdateContentUseCase(contentRepo),
    saveContent: SaveContentUseCase(contentRepo), // REQ-034
    bookmarkRepo: bookmarkRepo,
    checkTtsLimit: checkTtsLimit,
    audioHandler: audioHandler,
    playbackRepo: playbackRepo,
  );
});

class PlayerScreen extends ConsumerStatefulWidget {
  final Content content;
  final bool autoPlay;
  final bool autoCreateToc; // REQ-034
  final String? tocProvider; // FIX-065

  const PlayerScreen({super.key, required this.content, this.autoPlay = false, this.autoCreateToc = false, this.tocProvider}); // REQ-034 FIX-065

  /// [content]がObsidian由来かつ「Obsidianで開く」ボタンの表示に
  /// 必要な情報（vaultName・relativePath）を両方とも持っているかを判定する。
  static bool showObsidianButtonFor(Content content) {
    return content.externalType == 'obsidian' &&
        (content.vaultName?.isNotEmpty ?? false) &&
        (content.relativePath?.isNotEmpty ?? false);
  }

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  List<String> _availableVoices = [];
  final ObsidianLauncher _obsidianLauncher = ObsidianLauncher();

  bool get _showObsidianButton =>
      PlayerScreen.showObsidianButtonFor(widget.content);

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
        if (widget.autoCreateToc) { // REQ-034
          final settingsState = ref.read(settingsViewModelProvider);
          final provider = widget.tocProvider ?? settingsState.aiProvider; // FIX-065
          final tocPrompt = settingsState.tocPrompt;
          final apiKey = await const FlutterSecureStorage().read(
            key: provider == 'claude'
                ? SettingKeys.claudeApiKey
                : provider == 'groq'
                ? SettingKeys.groqApiKey
                : SettingKeys.geminiApiKey,
          );
          if (apiKey != null && apiKey.isNotEmpty && mounted) {
            final currentState = ref.read(playerViewModelProvider);
            if (currentState.content != null) {
              unawaited(vm.createTocInBackground(
                contentId: currentState.content!.id,
                text: currentState.content!.body,
                apiKey: apiKey,
                provider: provider,
                shouldClean: true,
                speed: currentState.playbackState?.speed ?? 1.0,
                totalChars: currentState.content!.body.length,
                tocPrompt: tocPrompt,
              ));
            }
          }
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

    // REQ-034: 目次作成完了・エラーを監視して通知
    ref.listen<PlayerState>(playerViewModelProvider, (previous, next) {
      if (previous?.tocCompleted == false && next.tocCompleted == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ 目次も作成しました'),
            backgroundColor: Color(0xFF7C5CBF),
          ),
        );
      }
      if (previous?.errorMessage == null && next.errorMessage != null &&
          next.errorMessage!.contains('AI目次作成')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.errorMessage!),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    });

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
            // コピーボタンエリア（REQ-045・046）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: widget.content.body));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('テキストをコピーしました'),
                            backgroundColor: Color(0xFF7C5CBF),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2A3E),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF3A3A55)),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.copy, size: 14, color: Color(0xFF8888AA)),
                            SizedBox(width: 6),
                            Text('テキストコピー', style: TextStyle(fontSize: 12, color: Color(0xFF8888AA))),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GestureDetector(
                      onTap: state.bookmarks.isEmpty ? null : () {
                        final text = state.bookmarks
                            .map((b) => b.label ?? "位置 ${b.position}")
                            .join('\n');
                        Clipboard.setData(ClipboardData(text: text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('目次をコピーしました'),
                            backgroundColor: Color(0xFF7C5CBF),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2A3E),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF3A3A55)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.copy, size: 14, color: state.bookmarks.isEmpty ? const Color(0xFF44445A) : const Color(0xFF8888AA)),
                            const SizedBox(width: 6),
                            Text('目次コピー', style: TextStyle(fontSize: 12, color: state.bookmarks.isEmpty ? const Color(0xFF44445A) : const Color(0xFF8888AA))),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Obsidianで開くボタン（Obsidian連携コンテンツかつVault情報が揃っている場合のみ表示）
            if (_showObsidianButton)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: GestureDetector(
                  onTap: () => _openInObsidian(context),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A3E),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF3A3A55)),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.open_in_new, size: 14, color: Color(0xFF8888AA)),
                        SizedBox(width: 6),
                        Text('Obsidianで開く', style: TextStyle(fontSize: 12, color: Color(0xFF8888AA))),
                      ],
                    ),
                  ),
                ),
              ),
            // ブックマークパネル（スクロール可能 エリア）
            Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: BookmarkPanel(
                    bookmarks: state.bookmarks,
                    onAdd: () => _showAddBookmarkDialog(context, vm, state),
                    onDelete: (id) => vm.deleteBookmark(id),
                    onJump: (position) => vm.seekToBookmark(position),
                    onAnalyze: () => _showAnalyzeDialog(context, vm, state, settingsState.aiProvider, settingsState.tocPrompt, settingsState.tablePrompt), // REQ-011
                    onCopy: state.bookmarks.isEmpty ? null : () {
                      final text = state.bookmarks
                          .map((b) => b.label ?? "位置 ${b.position}")
                          .join('\n');
                      Clipboard.setData(ClipboardData(text: text));
                    },
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

  Future<void> _openInObsidian(BuildContext context) async {
    final content = widget.content;
    final vaultName = content.vaultName;
    final relativePath = content.relativePath;
    if (vaultName == null || relativePath == null) return;

    final result = await _obsidianLauncher.openNote(
      vaultName: vaultName,
      relativePath: relativePath,
    );

    if (!context.mounted) return;

    switch (result) {
      case ObsidianLaunchResult.success:
        break;
      case ObsidianLaunchResult.notInstalled:
        await _showObsidianNotInstalledDialog(context);
        break;
      case ObsidianLaunchResult.launchFailed:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Obsidianを開けませんでした'),
            backgroundColor: Colors.redAccent,
          ),
        );
        break;
    }
  }

  Future<void> _showObsidianNotInstalledDialog(BuildContext context) async {
    final shouldOpenStore = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A3E),
        title: const Text(
          'Obsidianアプリが見つかりません',
          style: TextStyle(color: Color(0xFFF0F0F8), fontSize: 15),
        ),
        content: const Text(
          'Obsidianアプリがインストールされていないため開けませんでした。ストアからインストールしますか？',
          style: TextStyle(color: Color(0xFF8888AA), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル',
                style: TextStyle(color: Color(0xFF8888AA))),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('ストアを開く',
                style: TextStyle(color: Color(0xFF9B6FE0))),
          ),
        ],
      ),
    );

    if (shouldOpenStore == true) {
      await _obsidianLauncher.openPlayStore();
    }
  }

  Future<void> _showTableAnalysisDialog(
    BuildContext context,
    PlayerViewModel vm,
    PlayerState state,
    String aiProvider,
    String tablePrompt, // REQ-031
  ) async {
    if (state.content == null) return;


    // REQ-033: 表解説はGemini・Claudeのみ対応。groqが選択されている場合はgeminiにフォールバック
    String selectedProvider = (aiProvider == 'groq') ? 'gemini' : aiProvider;
    String selectedTocProvider = aiProvider; // FIX-065
    bool shouldClean = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A3E),
          title: const Text(
            '表の解説作成 - API利用について',
            style: TextStyle(color: Color(0xFFF0F0F8), fontSize: 14),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("使用するAPI（Gemini・Claudeのみ対応）", // REQ-033
                  style: TextStyle(fontSize: 12, color: Color(0xFFF0F0F8))),
              Row(
                children: [
                  Radio<String>(
                    value: 'gemini',
                    groupValue: selectedProvider,
                    onChanged: (v) => setState(() => selectedProvider = v!),
                    activeColor: const Color(0xFF9B6FE0),
                  ),
                  const Text("Gemini", style: TextStyle(fontSize: 12, color: Color(0xFF8888AA))),
                  const SizedBox(width: 8),
                  Radio<String>(
                    value: 'claude',
                    groupValue: selectedProvider,
                    onChanged: (v) => setState(() => selectedProvider = v!),
                    activeColor: const Color(0xFF9B6FE0),
                  ),
                  const Text("Claude", style: TextStyle(fontSize: 12, color: Color(0xFF8888AA))),
                ],
              ),
              Text(
                selectedProvider == 'claude'
                    ? 'Anthropicのサーバーに送信されます。個人情報・機密情報を含むテキストへの使用はご注意ください。'
                    : 'GoogleのAIトレーニングに使用される場合があります。個人情報・機密情報を含むテキストへの使用はご注意ください。', // REQ-033
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
            const SizedBox(height: 12),
            const Text('バックグラウンド目次作成のAPI', // FIX-065
                style: TextStyle(fontSize: 12, color: Color(0xFFF0F0F8))),
            Row(
              children: [
                Radio<String>(
                  value: 'gemini',
                  groupValue: selectedTocProvider,
                  onChanged: (v) => setState(() => selectedTocProvider = v!),
                  activeColor: const Color(0xFF9B6FE0),
                ),
                const Text('Gemini', style: TextStyle(fontSize: 12, color: Color(0xFF8888AA))),
                const SizedBox(width: 8),
                Radio<String>(
                  value: 'claude',
                  groupValue: selectedTocProvider,
                  onChanged: (v) => setState(() => selectedTocProvider = v!),
                  activeColor: const Color(0xFF9B6FE0),
                ),
                const Text('Claude', style: TextStyle(fontSize: 12, color: Color(0xFF8888AA))),
                const SizedBox(width: 8),
                Radio<String>(
                  value: 'groq',
                  groupValue: selectedTocProvider,
                  onChanged: (v) => setState(() => selectedTocProvider = v!),
                  activeColor: const Color(0xFF9B6FE0),
                ),
                const Text('Groq', style: TextStyle(fontSize: 12, color: Color(0xFF8888AA))),
              ],
            ),
            if (selectedTocProvider == 'groq')
              const Text(
                '※Groqはテキスト量が多い場合にエラーが発生することがあります',
                style: TextStyle(fontSize: 11, color: Colors.redAccent),
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
              child: const Text('解析する',
                  style: TextStyle(color: Color(0xFF9B6FE0))),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !context.mounted) return;
    // ダイアログで選択されたAPIのキーを取得（FIX-045）
    const storage = FlutterSecureStorage();
    final apiKey = await storage.read(
      key: selectedProvider == 'claude' ? SettingKeys.claudeApiKey : SettingKeys.geminiApiKey, // REQ-033
    );
    if (!context.mounted) return;
    if (apiKey == null || apiKey.isEmpty) {
      final providerName = selectedProvider == 'claude' ? 'Claude' : 'Gemini'; // REQ-033
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('設定画面で$providerName APIキーを設定してください'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('📊 表を解析中...'),
        duration: Duration(seconds: 120),
        backgroundColor: Color(0xFF7C5CBF),
      ),
    );

    try {
      final service = TableAnalysisService();
      final result = await service.analyzeAndDescribeTables(
        contentId: state.content!.id,
        text: state.content!.body,
        apiKey: apiKey,
        provider: selectedProvider,
        shouldClean: shouldClean,
        speed: state.playbackState?.speed ?? 1.0,
        totalChars: state.content!.body.length,
        customPrompt: tablePrompt, // REQ-031
      );

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (result.noTableFound) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('表が見つかりませんでした'),
            backgroundColor: Color(0xFF7C5CBF),
          ),
        );
        return;
      }

      for (final bookmark in result.bookmarks) {
        await vm.addBookmarkDirect(bookmark);
      }

      // 表解説テキストを本文に追記（FIX-049）
      // 後ろの表から順に挿入することで位置ズレを防ぐ
      final sortedTables = result.tables.toList()
        ..sort((a, b) => b.endPosition.compareTo(a.endPosition));
      for (final table in sortedTables) {
        await vm.appendTableDescription(
          insertPosition: table.endPosition,
          description: table.description,
          index: table.index, // FIX-056
          startPosition: table.startPosition, // FIX-062
        );
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ ${result.tables.length}件の表を検出・解説を追加しました'),
            backgroundColor: const Color(0xFF7C5CBF),
          ),
        );
      }

      // REQ-034: 新規テキストを作成して遷移を提案
      if (!context.mounted) return;
      final newContent = await vm.createTableDescriptionContent();
      if (newContent == null || !context.mounted) return;

      final shouldMove = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A3E),
          title: const Text('新規テキストを作成しました',
              style: TextStyle(color: Color(0xFFF0F0F8))),
          content: Text(
            '「(表)${state.content!.title}」を作成しました。移動しますか？',
            style: const TextStyle(color: Color(0xFF8888AA), fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('いいえ',
                  style: TextStyle(color: Color(0xFF8888AA))),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('はい',
                  style: TextStyle(color: Color(0xFF9B6FE0))),
            ),
          ],
        ),
      );

      if (shouldMove == true && context.mounted) {
        // ホーム画面のコンテンツリストをバックグラウンドで更新（FIX-066）
        ref.read(contentListViewModelProvider.notifier).loadContents();
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => PlayerScreen(content: newContent, autoCreateToc: true, tocProvider: selectedTocProvider), // REQ-034 FIX-065
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

  String _geminiErrorMessage(dynamic e) {
    final msg = e.toString();
    if (msg.contains('503')) return 'サーバーが混雑しています。しばらく待ってから再度お試しください。';
    if (msg.contains('401') || msg.contains('403')) return 'APIキーが無効です。設定画面で確認してください。';
    if (msg.contains('429')) return 'APIの利用制限に達しました。しばらく待ってから再度お試しください。'; // FIX-054
    if (msg.contains('timeout')) return '通信がタイムアウトしました。再度お試しください。';
    if (msg.contains('FormatException') || msg.contains('json')) return 'AIの返答形式が不正でした。再度お試しください。'; // FIX-054
    return '分析に失敗しました（$msg）。再度お試しください。'; // FIX-054: エラー詳細を表示
  }

  Future<void> _showAnalyzeDialog(
    BuildContext context,
    PlayerViewModel vm,
    PlayerState state,
    String aiProvider,
    String tocPrompt, // REQ-031
    String tablePrompt, // REQ-031
  ) async {
    if (state.content == null) return;

    // 前回のSnackBarが残っている場合は消す（FIX-041）
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    // 分析処理選択画面（REQ-012）
    final analysisType = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A3E),
        title: const Text(
          'AI分析処理を選択',
          style: TextStyle(color: Color(0xFFF0F0F8), fontSize: 15),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Text('📋', style: TextStyle(fontSize: 20)),
              title: const Text('自動目次作成',
                  style: TextStyle(color: Color(0xFFF0F0F8))),
              subtitle: const Text('テキストの章・節を自動で目次にする',
                  style: TextStyle(color: Color(0xFF8888AA), fontSize: 12)),
              onTap: () => Navigator.of(context).pop('toc'),
            ),
            ListTile(
              leading: const Text('📊', style: TextStyle(fontSize: 20)),
              title: const Text('表の解説作成',
                  style: TextStyle(color: Color(0xFFF0F0F8))),
              subtitle: const Text('表を検出して説明文を生成する',
                  style: TextStyle(color: Color(0xFF8888AA), fontSize: 12)),
              onTap: () => Navigator.of(context).pop('table'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('キャンセル',
                style: TextStyle(color: Color(0xFF8888AA))),
          ),
        ],
      ),
    );

    if (analysisType == null || !context.mounted) return;
    if (analysisType == 'table') {
      // FIX-067: 表分析済みチェック（本文に「表1開始」が含まれている場合は中断）
      if (state.content != null && state.content!.body.contains('表1開始')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('このテキストはすでに表分析済みです'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }
      await _showTableAnalysisDialog(context, vm, state, aiProvider, tablePrompt); // REQ-031
      return;
    }


    String selectedProvider = aiProvider; // FIX-045
    bool shouldClean = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A3E),
          title: const Text(
            'AI目次作成 - API利用について',
            style: TextStyle(color: Color(0xFFF0F0F8), fontSize: 14),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("使用するAPI", // FIX-058
                  style: TextStyle(fontSize: 12, color: Color(0xFFF0F0F8))),
              Row(
                children: [
                  Radio<String>(
                    value: 'gemini',
                    groupValue: selectedProvider,
                    onChanged: (v) => setState(() => selectedProvider = v!),
                    activeColor: const Color(0xFF9B6FE0),
                  ),
                  const Text("Gemini", style: TextStyle(fontSize: 12, color: Color(0xFF8888AA))),
                  const SizedBox(width: 8),
                  Radio<String>(
                    value: 'claude',
                    groupValue: selectedProvider,
                    onChanged: (v) => setState(() => selectedProvider = v!),
                    activeColor: const Color(0xFF9B6FE0),
                  ),
                  const Text("Claude", style: TextStyle(fontSize: 12, color: Color(0xFF8888AA))),
                  const SizedBox(width: 8),
                  Radio<String>(
                    value: 'groq',
                    groupValue: selectedProvider,
                    onChanged: (v) => setState(() => selectedProvider = v!),
                    activeColor: const Color(0xFF9B6FE0),
                  ),
                  const Text("Groq", style: TextStyle(fontSize: 12, color: Color(0xFF8888AA))),
                ],
              ),
              Text(
                selectedProvider == 'claude'
                    ? 'Anthropicのサーバーに送信されます。個人情報・機密情報を含むテキストへの使用はご注意ください。'
                    : selectedProvider == 'groq'
                    ? 'Groqのサーバーに送信されます。個人情報・機密情報を含むテキストへの使用はご注意ください。' // FIX-058
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

    const storage2 = FlutterSecureStorage();
    final apiKey = await storage2.read(
      key: selectedProvider == 'claude' ? SettingKeys.claudeApiKey : selectedProvider == 'groq' ? SettingKeys.groqApiKey : SettingKeys.geminiApiKey, // FIX-058
    );
    if (!context.mounted) return;
    if (apiKey == null || apiKey.isEmpty) {
      final providerName = selectedProvider == 'claude' ? 'Claude' : selectedProvider == 'groq' ? 'Groq' : 'Gemini'; // FIX-058
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('設定画面で$providerName APIキーを設定してください'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
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
      if (selectedProvider == 'groq') {
        bookmarks = await GroqService().analyzeAndCreateBookmarks(
          contentId: state.content!.id,
          text: state.content!.body,
          apiKey: apiKey,
          shouldClean: shouldClean,
          speed: state.playbackState?.speed ?? 1.0,
          totalChars: state.content!.body.length,
          customPrompt: tocPrompt, // REQ-031
        );
      } else if (selectedProvider == 'claude') {
        bookmarks = await ClaudeService().analyzeAndCreateBookmarks(
          contentId: state.content!.id,
          text: state.content!.body,
          apiKey: apiKey,
          shouldClean: shouldClean,
          speed: state.playbackState?.speed ?? 1.0,
          totalChars: state.content!.body.length,
          customPrompt: tocPrompt, // REQ-031
        );
      } else {
        bookmarks = await GeminiService().analyzeAndCreateBookmarks(
          contentId: state.content!.id,
          text: state.content!.body,
          apiKey: apiKey,
          shouldClean: shouldClean,
          speed: state.playbackState?.speed ?? 1.0,
          totalChars: state.content!.body.length,
          customPrompt: tocPrompt, // REQ-031
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
    // FIX-063: 現在位置のテキスト冒頭10文字をラベルに追加
    final body2 = state.content?.body ?? '';
    final pos2 = state.highlightPosition;
    int prevBreak2 = pos2;
    while (prevBreak2 > 0) {
      final ch = body2[prevBreak2 - 1];
      if (ch == '。' || ch == '、' || ch == '\n') break;
      prevBreak2--;
    }
    final excerpt2 = body2.isEmpty ? '' : body2.substring(
        prevBreak2, (prevBreak2 + 10).clamp(0, body2.length)).trim();
    final controller = TextEditingController(
        text: excerpt2.isEmpty
            ? '$timeLabel $dateLabel'
            : '$timeLabel $dateLabel $excerpt2');
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
