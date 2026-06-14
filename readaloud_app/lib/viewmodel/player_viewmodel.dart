import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/content.dart';
import '../model/playback_state.dart';
import '../model/bookmark.dart';
import '../repository/playback_repository.dart';
import '../repository/bookmark_repository.dart';
import '../repository/settings_repository.dart';
import '../model/setting.dart';
import '../model/tts_playback_position.dart';
import '../repository/tts/tts_service.dart';
import '../repository/tts/device_tts_service.dart';
import '../usecase/playback/start_playback_usecase.dart';
import '../usecase/playback/stop_playback_usecase.dart';
import '../usecase/playback/save_playback_state_usecase.dart';
import '../usecase/playback/set_ab_repeat_usecase.dart';
import '../usecase/bookmark/add_bookmark_usecase.dart';
import '../usecase/bookmark/delete_bookmark_usecase.dart';
import '../usecase/content/update_content_usecase.dart';
import '../usecase/content/save_content_usecase.dart'; // REQ-034
import '../repository/gemini_service.dart'; // REQ-034
import '../repository/claude_service.dart'; // REQ-034
import '../repository/groq_service.dart'; // REQ-034
import '../usecase/tts/check_tts_limit_usecase.dart';
import '../util/table_debug_logger.dart'; // FIX-056

class PlayerState {
  final Content? content;
  final PlaybackState? playbackState;
  final List<Bookmark> bookmarks;
  final bool isPlaying;
  final int highlightPosition;
  final TtsStatus ttsStatus;
  final TtsLimitStatus ttsLimitStatus;
  final bool isLoading;
  final String? errorMessage;
  final bool tocCreating; // REQ-034
  final bool tocCompleted; // REQ-034

  PlayerState({
    this.content,
    this.playbackState,
    this.bookmarks = const [],
    this.isPlaying = false,
    this.highlightPosition = 0,
    this.ttsStatus = TtsStatus.stopped,
    this.ttsLimitStatus = TtsLimitStatus.normal,
    this.isLoading = false,
    this.errorMessage,
    this.tocCreating = false, // REQ-034
    this.tocCompleted = false, // REQ-034
  });

  PlayerState copyWith({
    Content? content,
    PlaybackState? playbackState,
    List<Bookmark>? bookmarks,
    bool? isPlaying,
    int? highlightPosition,
    TtsStatus? ttsStatus,
    TtsLimitStatus? ttsLimitStatus,
    bool? isLoading,
    String? errorMessage,
    bool? tocCreating, // REQ-034
    bool? tocCompleted, // REQ-034
  }) =>
      PlayerState(
        content: content ?? this.content,
        playbackState: playbackState ?? this.playbackState,
        bookmarks: bookmarks ?? this.bookmarks,
        isPlaying: isPlaying ?? this.isPlaying,
        highlightPosition: highlightPosition ?? this.highlightPosition,
        ttsStatus: ttsStatus ?? this.ttsStatus,
        ttsLimitStatus: ttsLimitStatus ?? this.ttsLimitStatus,
        isLoading: isLoading ?? this.isLoading,
        errorMessage: errorMessage,
        tocCreating: tocCreating ?? this.tocCreating, // REQ-034
        tocCompleted: tocCompleted ?? this.tocCompleted, // REQ-034
      );
}

class PlayerViewModel extends StateNotifier<PlayerState> {
  final StartPlaybackUseCase _startPlayback;
  final StopPlaybackUseCase _stopPlayback;
  final SavePlaybackStateUseCase _savePlaybackState;
  final SetAbRepeatUseCase _setAbRepeat;
  final AddBookmarkUseCase _addBookmark;
  final DeleteBookmarkUseCase _deleteBookmark;
  final UpdateContentUseCase _updateContent;
  final SaveContentUseCase _saveContent; // REQ-034
  // ignore: unused_field
  final CheckTtsLimitUseCase _checkTtsLimit;
  final TtsAudioHandler _audioHandler;
  final PlaybackRepository _playbackRepo;
  final SettingsRepository _settingsRepo;
  final BookmarkRepository _bookmarkRepo;

  StreamSubscription<dynamic>? _playbackStateSubscription;

  PlayerViewModel({
    required StartPlaybackUseCase startPlayback,
    required StopPlaybackUseCase stopPlayback,
    required SavePlaybackStateUseCase savePlaybackState,
    required SetAbRepeatUseCase setAbRepeat,
    required AddBookmarkUseCase addBookmark,
    required DeleteBookmarkUseCase deleteBookmark,
    required UpdateContentUseCase updateContent,
    required SaveContentUseCase saveContent, // REQ-034
    required CheckTtsLimitUseCase checkTtsLimit,
    required TtsAudioHandler audioHandler,
    required PlaybackRepository playbackRepo,
    required SettingsRepository settingsRepo,
    required BookmarkRepository bookmarkRepo,
  })  : _startPlayback = startPlayback,
        _stopPlayback = stopPlayback,
        _savePlaybackState = savePlaybackState,
        _setAbRepeat = setAbRepeat,
        _addBookmark = addBookmark,
        _deleteBookmark = deleteBookmark,
        _updateContent = updateContent,
        _saveContent = saveContent, // REQ-034
        _checkTtsLimit = checkTtsLimit,
        _audioHandler = audioHandler,
        _playbackRepo = playbackRepo,
        _settingsRepo = settingsRepo,
        _bookmarkRepo = bookmarkRepo,
        super(PlayerState()) {
    _listenToStreams();
  }

  void _listenToStreams() {
    _playbackStateSubscription = _audioHandler.customState.listen((data) {
      if (data is! TtsPlaybackPosition) return;
      final content = state.content;
      if (content == null || content.body.isEmpty) return;

      final position = data.charPosition;
      final progressPct =
          (position / content.body.length * 100).clamp(0.0, 100.0);

      state = state.copyWith(
        highlightPosition: position,
        isPlaying: data.isPlaying,
        ttsStatus: data.ttsStatus,
        playbackState: state.playbackState?.copyWith(
          position: position,
          progressPct: progressPct,
        ),
      );
    });
  }

  Future<void> setContent(Content content) async {
    state = state.copyWith(content: content, isLoading: true);
    try {
      final existingState = await _playbackRepo.getByContentId(content.id);
      final PlaybackState playbackState;
      if (existingState != null) {
        playbackState = existingState;
      } else {
        // 初回: 設定画面のデフォルト速度を適用
        final defaultSpeedStr = await _settingsRepo.get(SettingKeys.defaultSpeed) ?? '1.0';
        final defaultSpeed = double.tryParse(defaultSpeedStr) ?? 1.0;
        playbackState = PlaybackState(
          contentId: content.id,
          speed: defaultSpeed,
        );
        // 初回はDBに保存して設定速度を永続化
        await _playbackRepo.save(playbackState);
      }
      // DBからブックマークを読み込む（FIX-025）
      final bookmarks = await _bookmarkRepo.getByContentId(content.id);
      state = state.copyWith(
        content: content,
        playbackState: playbackState,
        highlightPosition: playbackState.position,
        bookmarks: bookmarks,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '再生状態の読み込みに失敗しました: $e',
      );
    }
  }

  Future<void> play() async {
    if (state.content == null) return;
    try {
      await _startPlayback.execute(state.content!.id);
      state = state.copyWith(isPlaying: true);
    } catch (e) {
      state = state.copyWith(errorMessage: '再生に失敗しました: $e');
    }
  }

  Future<void> pause() async {
    if (state.content == null) return;
    // _audioHandler.currentPositionで精度の高い位置を取得（FIX-026）
    await _stopPlayback.pause(
      state.content!.id,
      _audioHandler.currentPosition,
    );
    state = state.copyWith(isPlaying: false);
  }

  Future<void> stop() async {
    if (state.content == null) return;
    // _audioHandler.currentPositionで精度の高い位置を取得（FIX-026）
    await _stopPlayback.execute(
      state.content!.id,
      _audioHandler.currentPosition,
    );
    state = state.copyWith(isPlaying: false);
  }

  Future<void> seekToStart() async {
    if (state.content == null) return;
    final wasPlaying = state.isPlaying;
    state = state.copyWith(isLoading: true);
    try {
      if (wasPlaying) {
        await _stopPlayback.execute(
          state.content!.id,
          state.highlightPosition,
        );
      }
      await _savePlaybackState.execute(
        contentId: state.content!.id,
        position: 0,
        progressPct: 0.0,
      );
      state = state.copyWith(
        highlightPosition: 0,
        playbackState: state.playbackState?.copyWith(
          position: 0,
          progressPct: 0.0,
        ),
        isPlaying: false,
        isLoading: false,
      );
      if (wasPlaying) await play();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '先頭への移動に失敗しました: $e',
      );
    }
  }

  Future<void> seekToEnd() async {
    if (state.content == null) return;
    final wasPlaying = state.isPlaying;
    state = state.copyWith(isLoading: true);
    try {
      if (wasPlaying) {
        await _stopPlayback.execute(
          state.content!.id,
          state.highlightPosition,
        );
      }
      final endPosition = state.content!.body.length;
      await _savePlaybackState.execute(
        contentId: state.content!.id,
        position: endPosition,
        progressPct: 100.0,
      );
      state = state.copyWith(
        highlightPosition: endPosition,
        playbackState: state.playbackState?.copyWith(
          position: endPosition,
          progressPct: 100.0,
        ),
        isPlaying: false,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '末尾への移動に失敗しました: $e',
      );
    }
  }

  Future<void> rewind() async {
    if (state.content == null) return;
    final wasPlaying = state.isPlaying;
    state = state.copyWith(isLoading: true);
    try {
      if (wasPlaying) {
        await _stopPlayback.execute(
          state.content!.id,
          state.highlightPosition,
        );
      }
      final speed = state.playbackState?.speed ?? 1.0;
      final charsPerSecond = (5 * speed).round();
      final rewindChars = 10 * charsPerSecond;
      final newPosition = (state.highlightPosition - rewindChars)
          .clamp(0, state.content!.body.length);
      final progressPct =
          (newPosition / state.content!.body.length * 100).clamp(0.0, 100.0);
      await _savePlaybackState.execute(
        contentId: state.content!.id,
        position: newPosition,
        progressPct: progressPct,
      );
      state = state.copyWith(
        highlightPosition: newPosition,
        playbackState: state.playbackState?.copyWith(
          position: newPosition,
          progressPct: progressPct,
        ),
        isPlaying: false,
        isLoading: false,
      );
      if (wasPlaying) await play();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '巻き戻しに失敗しました: $e',
      );
    }
  }

  Future<void> fastForward() async {
    if (state.content == null) return;
    final wasPlaying = state.isPlaying;
    state = state.copyWith(isLoading: true);
    try {
      if (wasPlaying) {
        await _stopPlayback.execute(
          state.content!.id,
          state.highlightPosition,
        );
      }
      final speed = state.playbackState?.speed ?? 1.0;
      final charsPerSecond = (5 * speed).round();
      final forwardChars = 10 * charsPerSecond;
      final newPosition = (state.highlightPosition + forwardChars)
          .clamp(0, state.content!.body.length);
      final progressPct =
          (newPosition / state.content!.body.length * 100).clamp(0.0, 100.0);
      await _savePlaybackState.execute(
        contentId: state.content!.id,
        position: newPosition,
        progressPct: progressPct,
      );
      state = state.copyWith(
        highlightPosition: newPosition,
        playbackState: state.playbackState?.copyWith(
          position: newPosition,
          progressPct: progressPct,
        ),
        isPlaying: false,
        isLoading: false,
      );
      if (wasPlaying) await play();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '早送りに失敗しました: $e',
      );
    }
  }

  Future<void> changeSpeed(double speed) async {
    if (state.content == null) return;
    final wasPlaying = state.isPlaying;
    state = state.copyWith(isLoading: true);
    try {
      if (wasPlaying) {
        // _audioHandler.currentPositionで精度の高い位置を取得（FIX-026）
        await _stopPlayback.execute(
          state.content!.id,
          _audioHandler.currentPosition,
        );
      }
      await _savePlaybackState.execute(
        contentId: state.content!.id,
        position: _audioHandler.currentPosition,
        progressPct: state.playbackState?.progressPct ?? 0.0,
        speed: speed,
      );
      state = state.copyWith(
        playbackState: state.playbackState?.copyWith(speed: speed),
        isPlaying: false,
        isLoading: false,
      );
      if (wasPlaying) await play();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '速度変更に失敗しました: $e',
      );
    }
  }

  Future<void> changePitch(double pitch) async {
    if (state.content == null) return;
    await _savePlaybackState.execute(
      contentId: state.content!.id,
      position: state.highlightPosition,
      progressPct: state.playbackState?.progressPct ?? 0.0,
      pitch: pitch,
    );
    state = state.copyWith(
      playbackState: state.playbackState?.copyWith(pitch: pitch),
    );
  }

  Future<void> changeVolume(double volume) async {
    if (state.content == null) return;
    await _savePlaybackState.execute(
      contentId: state.content!.id,
      position: state.highlightPosition,
      progressPct: state.playbackState?.progressPct ?? 0.0,
      volume: volume,
    );
    state = state.copyWith(
      playbackState: state.playbackState?.copyWith(volume: volume),
    );
  }

  Future<void> changeVoice(String voiceId) async {
    if (state.content == null) return;
    await _savePlaybackState.execute(
      contentId: state.content!.id,
      position: state.highlightPosition,
      progressPct: state.playbackState?.progressPct ?? 0.0,
      voiceId: voiceId,
    );
    state = state.copyWith(
      playbackState: state.playbackState?.copyWith(voiceId: voiceId),
    );
  }

  Future<void> addBookmark(String? label) async {
    if (state.content == null) return;
    try {
      // FIX-063: 前の句読点直後をpositionにする
      final body = state.content!.body;
      final pos = state.highlightPosition;
      int prevBreak = pos;
      while (prevBreak > 0) {
        final ch = body[prevBreak - 1];
        if (ch == '。' || ch == '、' || ch == '\n') break;
        prevBreak--;
      }
      final adjustedPos = prevBreak;
      final bookmark = await _addBookmark.execute(
        contentId: state.content!.id,
        position: adjustedPos, // FIX-063
        label: label,
      );
      state = state.copyWith(
        bookmarks: [...state.bookmarks, bookmark],
      );
    } catch (e) {
      state = state.copyWith(errorMessage: 'ブックマークの追加に失敗しました: $e');
    }
  }

  /// 表解説テキストを本文に追記（FIX-049）
  Future<void> appendTableDescription({
    required int insertPosition,
    required String description,
    int index = 0, // FIX-056
    int startPosition = 0, // FIX-062
  }) async {
    if (state.content == null) return;
    TableDebugLogger.instance.logInsert( // FIX-056
      index: index, // FIX-056
      insertPosition: insertPosition, // FIX-056
      bodyLengthBefore: state.content!.body.length, // FIX-056
    ); // FIX-056
    try {
      final currentBody = state.content!.body;
      // REQ-036: 表解説テキストに番号付け
      final numberedDescription = description.replaceFirst(
          '表情報の解説：', '表${index}の解説：'); // REQ-036
      final numberedEnd = '以上、表${index}の解説終了。'; // REQ-036
      // ① endPosに解説を挿入（FIX-052・REQ-036）
      final bodyAfterDesc = currentBody.substring(0, insertPosition) +
          '\n\n$numberedDescription\n\n$numberedEnd\n\n' +
          currentBody.substring(insertPosition);
      // ② startPosに表開始テキストを挿入（FIX-062）
      final tableStartText = '\n\n表${index}開始\n\n';
      final newBody = bodyAfterDesc.substring(0, startPosition) +
          tableStartText +
          bodyAfterDesc.substring(startPosition);
      await _updateContent.execute(
        id: state.content!.id,
        body: newBody,
      );
      state = state.copyWith(
        content: state.content!.copyWith(body: newBody),
      );
      TableDebugLogger.instance.logInsertComplete( // FIX-056
        index: index, // FIX-056
        bodyLengthAfter: newBody.length, // FIX-056
      ); // FIX-056
    } catch (e) {
      TableDebugLogger.instance.logInsertError( // FIX-056
        index: index, // FIX-056
        error: e.toString(), // FIX-056
      ); // FIX-056
      state = state.copyWith(errorMessage: 'テキストの更新に失敗しました: $e');
    }
  }

  /// Gemini分析結果のブックマークを直接追加（REQ-011）
  Future<void> addBookmarkDirect(Bookmark bookmark) async {
    try {
      await _bookmarkRepo.save(bookmark);
      state = state.copyWith(
        bookmarks: [...state.bookmarks, bookmark],
      );
    } catch (e) {
      state = state.copyWith(errorMessage: 'ブックマークの追加に失敗しました: $e');
    }
  }

  Future<void> deleteBookmark(String bookmarkId) async {
    try {
      await _deleteBookmark.execute(bookmarkId);
      state = state.copyWith(
        bookmarks: state.bookmarks.where((b) => b.id != bookmarkId).toList(),
      );
    } catch (e) {
      state = state.copyWith(errorMessage: 'ブックマークの削除に失敗しました: $e');
    }
  }

  Future<void> setAbRepeat(int start, int end) async {
    if (state.content == null) return;
    await _setAbRepeat.execute(
      contentId: state.content!.id,
      start: start,
      end: end,
    );
  }

  Future<void> clearAbRepeat() async {
    if (state.content == null) return;
    await _setAbRepeat.clear(state.content!.id);
  }

  Future<void> seekToBookmark(int position) async {
    if (state.content == null || state.content!.body.isEmpty) return;
    final wasPlaying = state.isPlaying;
    // 再生中の場合は正しく停止（TTS使用量カウント含む）（FIX-003）
    if (wasPlaying) {
      await _stopPlayback.execute(
        state.content!.id,
        _audioHandler.currentPosition,
      );
      state = state.copyWith(isPlaying: false);
    }
    final progressPct =
        (position / state.content!.body.length * 100).clamp(0.0, 100.0);
    await seekTo(progressPct);
    // 再生中だった場合は指定位置から再生を再開
    if (wasPlaying) {
      await play();
    }
  }

  Future<void> seekTo(double progressPct) async {
    if (state.content == null) return;
    final position =
        (state.content!.body.length * progressPct / 100).round();
    await _savePlaybackState.execute(
      contentId: state.content!.id,
      position: position,
      progressPct: progressPct,
    );
    state = state.copyWith(
      highlightPosition: position,
      playbackState: state.playbackState?.copyWith(
        position: position,
        progressPct: progressPct,
      ),
    );
  }

  /// 表解説付き新規テキストを作成する（REQ-034）
  Future<Content?> createTableDescriptionContent() async {
    if (state.content == null) return null;
    try {
      final original = state.content!;
      final newTitle = '(表)${original.title}';
      final newContent = await _saveContent.execute(
        body: original.body,
        title: newTitle,
        sourceType: original.sourceType,
        sourceUrl: original.sourceUrl,
        sourceFilename: original.sourceFilename,
      );

      // REQ-036: 表目次を新規テキストに引き継ぎ
      final body = original.body;
      final safeSpeed = state.playbackState?.speed ?? 1.0;
      final safeTotalChars = body.length > 0 ? body.length : 1;
      int tableIndex = 1;
      while (true) {
        final searchText = '表${tableIndex}開始';
        final pos = body.indexOf(searchText);
        if (pos == -1) break;
        final totalSecs = safeTotalChars / (5.0 * safeSpeed);
        final currentSecs = (totalSecs * pos / safeTotalChars).round();
        final minutes = currentSecs ~/ 60;
        final seconds = currentSecs % 60;
        final timeLabel = '$minutes:${seconds.toString().padLeft(2, '0')}';
        final excerptStart = pos + searchText.length;
        final excerptEnd = excerptStart + 25;
        final excerptTrimmed = body.length > excerptStart
            ? body.substring(excerptStart,
                body.length > excerptEnd ? excerptEnd : body.length).trim()
            : '';
        final label = '[$searchText] $timeLabel $excerptTrimmed';
        final bookmark = Bookmark(
          contentId: newContent.id,
          position: pos,
          label: label.length > Bookmark.maxLabelLength
              ? label.substring(0, Bookmark.maxLabelLength)
              : label,
        );
        await _bookmarkRepo.save(bookmark);
        tableIndex++;
      }

      return newContent;
    } catch (e) {
      state = state.copyWith(errorMessage: '新規テキストの作成に失敗しました: $e');
      return null;
    }
  }

  /// バックグラウンドで目次作成を実行する（REQ-034）
  Future<void> createTocInBackground({
    required String contentId,
    required String text,
    required String apiKey,
    required String provider,
    required bool shouldClean,
    required double speed,
    required int totalChars,
    required String tocPrompt,
  }) async {
    state = state.copyWith(tocCreating: true, tocCompleted: false); // REQ-034
    try {
      final List<dynamic> bookmarks;
      if (provider == 'groq') {
        bookmarks = await GroqService().analyzeAndCreateBookmarks(
          contentId: contentId,
          text: text,
          apiKey: apiKey,
          shouldClean: shouldClean,
          speed: speed,
          totalChars: totalChars,
          customPrompt: tocPrompt,
        );
      } else if (provider == 'claude') {
        bookmarks = await ClaudeService().analyzeAndCreateBookmarks(
          contentId: contentId,
          text: text,
          apiKey: apiKey,
          shouldClean: shouldClean,
          speed: speed,
          totalChars: totalChars,
          customPrompt: tocPrompt,
        );
      } else {
        bookmarks = await GeminiService().analyzeAndCreateBookmarks(
          contentId: contentId,
          text: text,
          apiKey: apiKey,
          shouldClean: shouldClean,
          speed: speed,
          totalChars: totalChars,
          customPrompt: tocPrompt,
        );
      }
      for (final bookmark in bookmarks) {
        await addBookmarkDirect(bookmark);
      }
      state = state.copyWith(tocCreating: false, tocCompleted: true); // REQ-034
    } catch (e) {
      state = state.copyWith(
        tocCreating: false,
        tocCompleted: false,
        errorMessage: _tocErrorMessage(e),
      ); // REQ-034
    }
  }

  String _tocErrorMessage(dynamic e) {
    final msg = e.toString();
    if (msg.contains('503')) return 'AI目次作成：サーバーが混雑しています。';
    if (msg.contains('401') || msg.contains('403')) return 'AI目次作成：APIキーが無効です。';
    if (msg.contains('429')) return 'AI目次作成：APIの利用制限に達しました。';
    if (msg.contains('timeout')) return 'AI目次作成：通信がタイムアウトしました。';
    return 'AI目次作成に失敗しました。';
  }

  void clearError() => state = state.copyWith(errorMessage: null);

  @override
  void dispose() {
    _playbackStateSubscription?.cancel();
    _startPlayback.dispose();
    super.dispose();
  }
}
