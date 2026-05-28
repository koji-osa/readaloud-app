import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/content.dart';
import '../model/playback_state.dart';
import '../model/bookmark.dart';
import '../repository/playback_repository.dart';
import '../repository/settings_repository.dart';
import '../model/setting.dart';
import '../repository/tts/tts_service.dart';
import '../usecase/playback/start_playback_usecase.dart';
import '../usecase/playback/stop_playback_usecase.dart';
import '../usecase/playback/save_playback_state_usecase.dart';
import '../usecase/playback/set_ab_repeat_usecase.dart';
import '../usecase/bookmark/add_bookmark_usecase.dart';
import '../usecase/bookmark/delete_bookmark_usecase.dart';
import '../usecase/tts/check_tts_limit_usecase.dart';

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
      );
}

class PlayerViewModel extends StateNotifier<PlayerState> {
  final StartPlaybackUseCase _startPlayback;
  final StopPlaybackUseCase _stopPlayback;
  final SavePlaybackStateUseCase _savePlaybackState;
  final SetAbRepeatUseCase _setAbRepeat;
  final AddBookmarkUseCase _addBookmark;
  final DeleteBookmarkUseCase _deleteBookmark;
  // ignore: unused_field
  final CheckTtsLimitUseCase _checkTtsLimit;
  final TtsService _ttsService;
  final PlaybackRepository _playbackRepo;
  final SettingsRepository _settingsRepo;

  StreamSubscription<int>? _positionSubscription;
  StreamSubscription<TtsStatus>? _statusSubscription;

  PlayerViewModel({
    required StartPlaybackUseCase startPlayback,
    required StopPlaybackUseCase stopPlayback,
    required SavePlaybackStateUseCase savePlaybackState,
    required SetAbRepeatUseCase setAbRepeat,
    required AddBookmarkUseCase addBookmark,
    required DeleteBookmarkUseCase deleteBookmark,
    required CheckTtsLimitUseCase checkTtsLimit,
    required TtsService ttsService,
    required PlaybackRepository playbackRepo,
    required SettingsRepository settingsRepo,
  })  : _startPlayback = startPlayback,
        _stopPlayback = stopPlayback,
        _savePlaybackState = savePlaybackState,
        _setAbRepeat = setAbRepeat,
        _addBookmark = addBookmark,
        _deleteBookmark = deleteBookmark,
        _checkTtsLimit = checkTtsLimit,
        _ttsService = ttsService,
        _playbackRepo = playbackRepo,
        _settingsRepo = settingsRepo,
        super(PlayerState()) {
    _listenToStreams();
  }

  void _listenToStreams() {
    _positionSubscription = _ttsService.positionStream.listen((position) {
      final content = state.content;
      if (content == null || content.body.isEmpty) return;
      final progressPct =
          (position / content.body.length * 100).clamp(0.0, 100.0);
      state = state.copyWith(
        highlightPosition: position,
        playbackState: state.playbackState?.copyWith(
          position: position,
          progressPct: progressPct,
        ),
      );
    });

    _statusSubscription = _ttsService.statusStream.listen((status) {
      state = state.copyWith(
        ttsStatus: status,
        isPlaying: status == TtsStatus.playing,
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
      }
      state = state.copyWith(
        content: content,
        playbackState: playbackState,
        highlightPosition: playbackState.position,
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
    await _stopPlayback.pause(
      state.content!.id,
      state.highlightPosition,
    );
    state = state.copyWith(isPlaying: false);
  }

  Future<void> stop() async {
    if (state.content == null) return;
    await _stopPlayback.execute(
      state.content!.id,
      state.highlightPosition,
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
        await _stopPlayback.execute(
          state.content!.id,
          state.highlightPosition,
        );
      }
      await _savePlaybackState.execute(
        contentId: state.content!.id,
        position: state.highlightPosition,
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
      final bookmark = await _addBookmark.execute(
        contentId: state.content!.id,
        position: state.highlightPosition,
        label: label,
      );
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

  void clearError() => state = state.copyWith(errorMessage: null);

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _statusSubscription?.cancel();
    _startPlayback.dispose();
    super.dispose();
  }
}
