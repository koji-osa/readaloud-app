import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/content.dart';
import '../model/playback_state.dart';
import '../model/bookmark.dart';
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
  // _checkTtsLimitはplayer_screen.dartのonLimitStatusコールバックで処理済み
  // ignore: unused_field
  final CheckTtsLimitUseCase _checkTtsLimit;
  final TtsService _ttsService;

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
  })  : _startPlayback = startPlayback,
        _stopPlayback = stopPlayback,
        _savePlaybackState = savePlaybackState,
        _setAbRepeat = setAbRepeat,
        _addBookmark = addBookmark,
        _deleteBookmark = deleteBookmark,
        _checkTtsLimit = checkTtsLimit,
        _ttsService = ttsService,
        super(PlayerState()) {
    _listenToStreams();
  }

  void _listenToStreams() {
    _positionSubscription = _ttsService.positionStream.listen((position) {
      state = state.copyWith(highlightPosition: position);
    });

    _statusSubscription = _ttsService.statusStream.listen((status) {
      state = state.copyWith(
        ttsStatus: status,
        isPlaying: status == TtsStatus.playing,
      );
    });
  }

  // 再生開始
  Future<void> play() async {
    if (state.content == null) return;
    try {
      await _startPlayback.execute(state.content!.id);
      state = state.copyWith(isPlaying: true);
    } catch (e) {
      state = state.copyWith(errorMessage: '再生に失敗しました: $e');
    }
  }

  // 一時停止
  Future<void> pause() async {
    if (state.content == null) return;
    await _stopPlayback.pause(
      state.content!.id,
      state.highlightPosition,
    );
    state = state.copyWith(isPlaying: false);
  }

  // 停止
  Future<void> stop() async {
    if (state.content == null) return;
    await _stopPlayback.execute(
      state.content!.id,
      state.highlightPosition,
    );
    state = state.copyWith(isPlaying: false);
  }

  // 速度を変更して保存
  Future<void> changeSpeed(double speed) async {
    if (state.content == null) return;
    await _savePlaybackState.execute(
      contentId: state.content!.id,
      position: state.highlightPosition,
      progressPct: state.playbackState?.progressPct ?? 0.0,
      speed: speed,
    );
    state = state.copyWith(
      playbackState: state.playbackState?.copyWith(speed: speed),
    );
  }

  // 音程を変更して保存
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

  // 音量を変更して保存
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

  // 声の種類を変更して保存
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

  // ブックマーク追加
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

  // ブックマーク削除
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

  // A-Bリピート設定
  Future<void> setAbRepeat(int start, int end) async {
    if (state.content == null) return;
    await _setAbRepeat.execute(
      contentId: state.content!.id,
      start: start,
      end: end,
    );
  }

  // A-Bリピート解除
  Future<void> clearAbRepeat() async {
    if (state.content == null) return;
    await _setAbRepeat.clear(state.content!.id);
  }

  // シークバーで位置を変更
  Future<void> seekTo(double progressPct) async {
    if (state.content == null) return;
    final position =
        (state.content!.body.length * progressPct / 100).round();
    await _savePlaybackState.execute(
      contentId: state.content!.id,
      position: position,
      progressPct: progressPct,
    );
    state = state.copyWith(highlightPosition: position);
  }

  // コンテンツをセット（initState時に呼び出す）
  void setContent(Content content) {
    state = state.copyWith(content: content);
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


