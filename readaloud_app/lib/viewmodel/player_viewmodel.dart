import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/content.dart';
import '../model/normal_player_session.dart';
import '../model/playback_state.dart';
import '../model/bookmark.dart';
import '../repository/playback_repository.dart';
import '../repository/bookmark_repository.dart';
import '../repository/settings_repository.dart';
import '../model/setting.dart';
import '../repository/tts/tts_service.dart';
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
import '../util/normal_player_session_tracker.dart';
import '../util/table_debug_logger.dart'; // FIX-056
import '../util/debug_logger.dart';

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

/// Normal Player の ViewModel。
///
/// v0.4.1: すべての public async mutation は [PlayerOriginToken] を必須引数で
/// 受け取り、実行の直前・await 後の各 effect boundary で origin の
/// currentness を検証する（D9）。origin に既定値は無く、VM 内部の mutable な
/// 紐付け（[_attachedSessionId]）を origin の代用にはしない（NRR-12）。
class PlayerViewModel extends StateNotifier<PlayerState> {
  final SavePlaybackStateUseCase _savePlaybackState;
  final SetAbRepeatUseCase _setAbRepeat;
  final AddBookmarkUseCase _addBookmark;
  final DeleteBookmarkUseCase _deleteBookmark;
  final UpdateContentUseCase _updateContent;
  final SaveContentUseCase _saveContent; // REQ-034
  // ignore: unused_field
  final CheckTtsLimitUseCase _checkTtsLimit;
  // FIX-026等の位置取得（保存操作向け）専用。ライブ更新パイプラインでは
  // 使わない（Detailed Design v1.2 FINAL §8.4.2: これは「位置の読み取り」で
  // あり、ライブpipelineではない — 変更不要）。
  final int Function() _getCurrentPosition;
  final PlaybackRepository _playbackRepo;
  final SettingsRepository _settingsRepo;
  final BookmarkRepository _bookmarkRepo;
  final NormalPlayerPlaybackGate _playbackGate;

  /// tracker.isEffectCurrent を束縛した述語。VM は tracker クラスを直接
  /// import しない（層分離・テスト容易性のため注入で受け取る）。
  final bool Function(String sessionId) _isEffectCurrent;

  /// Normal Player の唯一の live-position pipeline（Detailed Design v1.2
  /// FINAL §8.4.1, RT-7 / INV-18）。attach中のsessionへ`setContent`ごとに
  /// 無条件で（adoptionの成否に関わらず）張り直す。D15受理判定はTransport側
  /// （gate.liveUpdatesの供給源＝acceptedPositions）が唯一の権威であり、
  /// VM側に重複したgateは存在しない。
  StreamSubscription<PersistentLiveUpdate>? _liveSubscription;

  /// ② VM↔session の現在の紐付け（mutable）。origin-bound な判定の代用には
  /// しない。ambient write（live update）と attach 整合性の二次検査にのみ
  /// 使う（D1/D9）。
  String? _attachedSessionId;

  PlayerViewModel({
    required NormalPlayerPlaybackGate playbackGate,
    required bool Function(String sessionId) isEffectCurrent,
    required SavePlaybackStateUseCase savePlaybackState,
    required SetAbRepeatUseCase setAbRepeat,
    required AddBookmarkUseCase addBookmark,
    required DeleteBookmarkUseCase deleteBookmark,
    required UpdateContentUseCase updateContent,
    required SaveContentUseCase saveContent, // REQ-034
    required CheckTtsLimitUseCase checkTtsLimit,
    required int Function() getCurrentPosition,
    required PlaybackRepository playbackRepo,
    required SettingsRepository settingsRepo,
    required BookmarkRepository bookmarkRepo,
  })  : _playbackGate = playbackGate,
        _isEffectCurrent = isEffectCurrent,
        _savePlaybackState = savePlaybackState,
        _setAbRepeat = setAbRepeat,
        _addBookmark = addBookmark,
        _deleteBookmark = deleteBookmark,
        _updateContent = updateContent,
        _saveContent = saveContent, // REQ-034
        _checkTtsLimit = checkTtsLimit,
        _getCurrentPosition = getCurrentPosition,
        _playbackRepo = playbackRepo,
        _settingsRepo = settingsRepo,
        _bookmarkRepo = bookmarkRepo,
        super(PlayerState());

  /// 唯一の state 書込み口。disposed / superseded / re-owned のいずれでも
  /// 例外を出さず false を返して縮退する（NRR-13）。origin に既定値は無い。
  bool _write(
    PlayerOriginToken origin,
    PlayerState Function(PlayerState prev) update, {
    required String stage,
  }) {
    if (!mounted) {
      _diag(stage, origin, 'notifier_disposed');
      return false;
    }
    if (!_isEffectCurrent(origin.sessionId)) {
      _diag(stage, origin, 'session_not_effect_current');
      return false;
    }
    if (_attachedSessionId != origin.sessionId) {
      _diag(stage, origin, 'vm_reowned');
      return false;
    }
    state = update(state);
    return true;
  }

  /// origin-bound な副作用（DB write 等）を開始してよいかの同期判定。
  /// await を跨いだ後に書込み先を再導出しないため、DB 呼び出しの前に必ずこれで
  /// guard する（`_write` は state 反映時の二次防御）。
  bool _isOriginEffectCurrent(PlayerOriginToken origin) =>
      _isEffectCurrent(origin.sessionId) &&
      _attachedSessionId == origin.sessionId;

  void _diag(String stage, PlayerOriginToken origin, String reason) {
    unawaited(DebugLogger.instance.logEvent('player_effect_discarded', {
      'sessionId': origin.sessionId,
      'stage': stage,
      'reason': reason,
    }));
  }

  /// Normal Player の唯一の live-position pipeline上のevent handler
  /// （Detailed Design v1.2 FINAL §8.4.3）。`_accepted`はsync:trueな
  /// broadcast controllerのため、このhandlerは`_onPosition`の内部から
  /// 同期的に呼ばれうる — Transportへ同期的にcall backしてはならない
  /// （§8.2.6 (2)）。ここではVM stateの書込みだけを行うため安全である。
  void _onLiveUpdate(PlayerOriginToken origin, PersistentLiveUpdate u) {
    if (!mounted || !_isEffectCurrent(origin.sessionId)) return;
    final content = state.content;
    final progressPct = (content != null && content.body.isNotEmpty)
        ? (u.position / content.body.length * 100).clamp(0.0, 100.0)
        : state.playbackState?.progressPct ?? 0.0;
    _write(
      origin,
      (s) => s.copyWith(
        highlightPosition: u.position,
        isPlaying: u.isPlaying,
        ttsStatus: u.ttsStatus,
        playbackState: s.playbackState?.copyWith(
          position: u.position,
          progressPct: progressPct,
        ),
      ),
      stage: 'live_update',
    );
  }

  /// session attach 操作（D1/D10）。`copyWith` ではなく新規 [PlayerState] を
  /// 構築することで、明示的に渡さないすべての field を既定値へ戻し、旧
  /// session の残存 state（`tocCreating`/`tocCompleted`/bookmarks 等）を
  /// 引き継がない。
  Future<void> setContent({
    required PlayerOriginToken origin,
    required Content content,
  }) async {
    if (!mounted) return;
    if (!_isEffectCurrent(origin.sessionId)) {
      _diag('attach', origin, 'session_not_effect_current');
      return;
    }
    _attachedSessionId = origin.sessionId;
    state = PlayerState(content: content, isLoading: true); // fresh構築（D10）

    // Detailed Design v1.2 FINAL §8.4.1 [RT-7] / INV-18: adoptionの成否に
    // 関わらず無条件でliveUpdatesへ購読する。D15受理はTransport（gateの
    // 供給源＝acceptedPositions）が唯一の権威であり、VM側に重複したgateは
    // 置かない。通常の新規Playとadoptされたrebindは同じpipelineを使う。
    unawaited(_liveSubscription?.cancel());
    _liveSubscription = _playbackGate
        .liveUpdates(sessionId: origin.sessionId)
        .listen((u) => _onLiveUpdate(origin, u));

    try {
      final live = await _playbackGate.adoptLiveSession(
        sessionId: origin.sessionId,
        contentId: content.id,
      );

      final existingState = await _playbackRepo.getByContentId(content.id);
      final PlaybackState playbackState;
      if (existingState != null) {
        playbackState = existingState;
      } else {
        // 初回: 設定画面のデフォルト速度を適用
        final defaultSpeedStr =
            await _settingsRepo.get(SettingKeys.defaultSpeed) ?? '1.0';
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

      // Race A: DB read後・書込み直前にもう一度読み直す。live overlayは
      // 必ずDB値の後に適用する（§8.4.3 step 5-6）。
      final latest = live == null
          ? null
          : _playbackGate.liveSnapshotFor(sessionId: origin.sessionId);

      _write(
        origin,
        (s) => s.copyWith(
          content: content,
          playbackState: latest == null
              ? playbackState
              : playbackState.copyWith(
                  position: latest.position,
                  speed: latest.voice.speed, // [RT-6]: latest.speedではない
                ),
          highlightPosition: latest?.position ?? playbackState.position,
          isPlaying: latest?.isPlaying ?? false,
          ttsStatus: latest?.ttsStatus ?? TtsStatus.stopped,
          bookmarks: bookmarks,
          isLoading: false,
        ),
        stage: 'attach_load',
      );
    } catch (e) {
      _write(
        origin,
        (s) => s.copyWith(
          isLoading: false,
          errorMessage: '再生状態の読み込みに失敗しました: $e',
        ),
        stage: 'attach_load_error',
      );
    }
  }

  Future<void> play({required PlayerOriginToken origin}) async {
    if (!_isOriginEffectCurrent(origin)) {
      _diag('play', origin, 'session_not_effect_current');
      return;
    }
    if (state.content == null || state.content!.id != origin.contentId) return;
    try {
      await _playbackGate.start(
          sessionId: origin.sessionId, contentId: origin.contentId);
      _write(origin, (s) => s.copyWith(isPlaying: true), stage: 'play');
    } catch (e) {
      _write(origin, (s) => s.copyWith(errorMessage: '再生に失敗しました: $e'),
          stage: 'play_error');
    }
  }

  Future<void> pause({required PlayerOriginToken origin}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    // _getCurrentPosition()で精度の高い位置を取得（FIX-026）
    final outcome = await _playbackGate.pause(
      sessionId: origin.sessionId,
      contentId: origin.contentId,
      position: _getCurrentPosition(),
    );
    _write(
      origin,
      (s) => outcome.ttsStopSucceeded
          ? s.copyWith(isPlaying: false)
          : s.copyWith(isPlaying: false, errorMessage: '一時停止に失敗しました'),
      stage: 'pause',
    );
  }

  Future<void> stop({required PlayerOriginToken origin}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    // _getCurrentPosition()で精度の高い位置を取得（FIX-026）
    final outcome = await _playbackGate.stopForSession(
      sessionId: origin.sessionId,
      contentId: origin.contentId,
      position: _getCurrentPosition(),
    );
    _write(
      origin,
      (s) => outcome.ttsStopSucceeded
          ? s.copyWith(isPlaying: false)
          : s.copyWith(isPlaying: false, errorMessage: '停止に失敗しました'),
      stage: 'stop',
    );
  }

  Future<void> seekToStart({required PlayerOriginToken origin}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    final wasPlaying = state.isPlaying;
    _write(origin, (s) => s.copyWith(isLoading: true), stage: 'seek_to_start');
    try {
      if (wasPlaying) {
        await _playbackGate.stopForSession(
          sessionId: origin.sessionId,
          contentId: origin.contentId,
          position: state.highlightPosition,
        );
      }
      if (!_isOriginEffectCurrent(origin)) return;
      await _savePlaybackState.execute(
        contentId: origin.contentId,
        position: 0,
        progressPct: 0.0,
      );
      _write(
        origin,
        (s) => s.copyWith(
          highlightPosition: 0,
          playbackState:
              s.playbackState?.copyWith(position: 0, progressPct: 0.0),
          isPlaying: false,
          isLoading: false,
        ),
        stage: 'seek_to_start_complete',
      );
      if (wasPlaying) await play(origin: origin);
    } catch (e) {
      _write(
        origin,
        (s) => s.copyWith(isLoading: false, errorMessage: '先頭への移動に失敗しました: $e'),
        stage: 'seek_to_start_error',
      );
    }
  }

  Future<void> seekToEnd({required PlayerOriginToken origin}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    final wasPlaying = state.isPlaying;
    _write(origin, (s) => s.copyWith(isLoading: true), stage: 'seek_to_end');
    try {
      if (wasPlaying) {
        await _playbackGate.stopForSession(
          sessionId: origin.sessionId,
          contentId: origin.contentId,
          position: state.highlightPosition,
        );
      }
      if (!_isOriginEffectCurrent(origin)) return;
      final endPosition = state.content?.body.length ?? 0;
      await _savePlaybackState.execute(
        contentId: origin.contentId,
        position: endPosition,
        progressPct: 100.0,
      );
      _write(
        origin,
        (s) => s.copyWith(
          highlightPosition: endPosition,
          playbackState: s.playbackState
              ?.copyWith(position: endPosition, progressPct: 100.0),
          isPlaying: false,
          isLoading: false,
        ),
        stage: 'seek_to_end_complete',
      );
    } catch (e) {
      _write(
        origin,
        (s) => s.copyWith(isLoading: false, errorMessage: '末尾への移動に失敗しました: $e'),
        stage: 'seek_to_end_error',
      );
    }
  }

  Future<void> rewind({required PlayerOriginToken origin}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    final wasPlaying = state.isPlaying;
    _write(origin, (s) => s.copyWith(isLoading: true), stage: 'rewind');
    try {
      if (wasPlaying) {
        await _playbackGate.stopForSession(
          sessionId: origin.sessionId,
          contentId: origin.contentId,
          position: state.highlightPosition,
        );
      }
      if (!_isOriginEffectCurrent(origin) || state.content == null) return;
      final speed = state.playbackState?.speed ?? 1.0;
      final charsPerSecond = (5 * speed).round();
      final rewindChars = 10 * charsPerSecond;
      final newPosition = (state.highlightPosition - rewindChars)
          .clamp(0, state.content!.body.length);
      final progressPct =
          (newPosition / state.content!.body.length * 100).clamp(0.0, 100.0);
      await _savePlaybackState.execute(
        contentId: origin.contentId,
        position: newPosition,
        progressPct: progressPct,
      );
      _write(
        origin,
        (s) => s.copyWith(
          highlightPosition: newPosition,
          playbackState: s.playbackState
              ?.copyWith(position: newPosition, progressPct: progressPct),
          isPlaying: false,
          isLoading: false,
        ),
        stage: 'rewind_complete',
      );
      if (wasPlaying) await play(origin: origin);
    } catch (e) {
      _write(
        origin,
        (s) => s.copyWith(isLoading: false, errorMessage: '巻き戻しに失敗しました: $e'),
        stage: 'rewind_error',
      );
    }
  }

  Future<void> fastForward({required PlayerOriginToken origin}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    final wasPlaying = state.isPlaying;
    _write(origin, (s) => s.copyWith(isLoading: true), stage: 'fast_forward');
    try {
      if (wasPlaying) {
        await _playbackGate.stopForSession(
          sessionId: origin.sessionId,
          contentId: origin.contentId,
          position: state.highlightPosition,
        );
      }
      if (!_isOriginEffectCurrent(origin) || state.content == null) return;
      final speed = state.playbackState?.speed ?? 1.0;
      final charsPerSecond = (5 * speed).round();
      final forwardChars = 10 * charsPerSecond;
      final newPosition = (state.highlightPosition + forwardChars)
          .clamp(0, state.content!.body.length);
      final progressPct =
          (newPosition / state.content!.body.length * 100).clamp(0.0, 100.0);
      await _savePlaybackState.execute(
        contentId: origin.contentId,
        position: newPosition,
        progressPct: progressPct,
      );
      _write(
        origin,
        (s) => s.copyWith(
          highlightPosition: newPosition,
          playbackState: s.playbackState
              ?.copyWith(position: newPosition, progressPct: progressPct),
          isPlaying: false,
          isLoading: false,
        ),
        stage: 'fast_forward_complete',
      );
      if (wasPlaying) await play(origin: origin);
    } catch (e) {
      _write(
        origin,
        (s) => s.copyWith(isLoading: false, errorMessage: '早送りに失敗しました: $e'),
        stage: 'fast_forward_error',
      );
    }
  }

  Future<void> changeSpeed(
      {required PlayerOriginToken origin, required double speed}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    final wasPlaying = state.isPlaying;
    _write(origin, (s) => s.copyWith(isLoading: true), stage: 'change_speed');
    try {
      if (wasPlaying) {
        // _getCurrentPosition()で精度の高い位置を取得（FIX-026）
        await _playbackGate.stopForSession(
          sessionId: origin.sessionId,
          contentId: origin.contentId,
          position: _getCurrentPosition(),
        );
      }
      if (!_isOriginEffectCurrent(origin)) return;
      await _savePlaybackState.execute(
        contentId: origin.contentId,
        position: _getCurrentPosition(),
        progressPct: state.playbackState?.progressPct ?? 0.0,
        speed: speed,
      );
      _write(
        origin,
        (s) => s.copyWith(
          playbackState: s.playbackState?.copyWith(speed: speed),
          isPlaying: false,
          isLoading: false,
        ),
        stage: 'change_speed_complete',
      );
      if (wasPlaying) await play(origin: origin);
    } catch (e) {
      _write(
        origin,
        (s) => s.copyWith(isLoading: false, errorMessage: '速度変更に失敗しました: $e'),
        stage: 'change_speed_error',
      );
    }
  }

  Future<void> changePitch(
      {required PlayerOriginToken origin, required double pitch}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    await _savePlaybackState.execute(
      contentId: origin.contentId,
      position: state.highlightPosition,
      progressPct: state.playbackState?.progressPct ?? 0.0,
      pitch: pitch,
    );
    _write(
        origin,
        (s) =>
            s.copyWith(playbackState: s.playbackState?.copyWith(pitch: pitch)),
        stage: 'change_pitch');
  }

  Future<void> changeVolume(
      {required PlayerOriginToken origin, required double volume}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    await _savePlaybackState.execute(
      contentId: origin.contentId,
      position: state.highlightPosition,
      progressPct: state.playbackState?.progressPct ?? 0.0,
      volume: volume,
    );
    _write(
        origin,
        (s) => s.copyWith(
            playbackState: s.playbackState?.copyWith(volume: volume)),
        stage: 'change_volume');
  }

  Future<void> changeVoice(
      {required PlayerOriginToken origin, required String voiceId}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    await _savePlaybackState.execute(
      contentId: origin.contentId,
      position: state.highlightPosition,
      progressPct: state.playbackState?.progressPct ?? 0.0,
      voiceId: voiceId,
    );
    _write(
        origin,
        (s) => s.copyWith(
            playbackState: s.playbackState?.copyWith(voiceId: voiceId)),
        stage: 'change_voice');
  }

  Future<void> addBookmark(
      {required PlayerOriginToken origin, String? label}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
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
        contentId: origin.contentId,
        position: adjustedPos, // FIX-063
        label: label,
      );
      _write(origin, (s) => s.copyWith(bookmarks: [...s.bookmarks, bookmark]),
          stage: 'add_bookmark');
    } catch (e) {
      _write(origin, (s) => s.copyWith(errorMessage: 'ブックマークの追加に失敗しました: $e'),
          stage: 'add_bookmark_error');
    }
  }

  /// 表解説テキストを本文に追記（FIX-049）
  Future<void> appendTableDescription({
    required PlayerOriginToken origin,
    required int insertPosition,
    required String description,
    int index = 0, // FIX-056
    int startPosition = 0, // FIX-062
  }) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    // await前の同期スナップショット（origin検証直後・await境界の前なので安全）。
    final currentBody = state.content!.body;
    TableDebugLogger.instance.logInsert(
      // FIX-056
      index: index, // FIX-056
      insertPosition: insertPosition, // FIX-056
      bodyLengthBefore: currentBody.length, // FIX-056
    ); // FIX-056
    try {
      // REQ-036: 表解説テキストに番号付け
      final numberedDescription =
          description.replaceFirst('表情報の解説：', '表${index}の解説：'); // REQ-036
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
        id: origin.contentId,
        body: newBody,
      );
      _write(
        origin,
        (s) => (s.content != null && s.content!.id == origin.contentId)
            ? s.copyWith(content: s.content!.copyWith(body: newBody))
            : s,
        stage: 'w1_append_table_description',
      );
      TableDebugLogger.instance.logInsertComplete(
        // FIX-056
        index: index, // FIX-056
        bodyLengthAfter: newBody.length, // FIX-056
      ); // FIX-056
    } catch (e) {
      TableDebugLogger.instance.logInsertError(
        // FIX-056
        index: index, // FIX-056
        error: e.toString(), // FIX-056
      ); // FIX-056
      _write(origin, (s) => s.copyWith(errorMessage: 'テキストの更新に失敗しました: $e'),
          stage: 'w1_append_table_description_error');
    }
  }

  /// Gemini分析結果のブックマークを直接追加（REQ-011）
  Future<void> addBookmarkDirect(
      {required PlayerOriginToken origin, required Bookmark bookmark}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    try {
      await _bookmarkRepo.save(bookmark);
      _write(origin, (s) => s.copyWith(bookmarks: [...s.bookmarks, bookmark]),
          stage: 'add_bookmark_direct');
    } catch (e) {
      _write(origin, (s) => s.copyWith(errorMessage: 'ブックマークの追加に失敗しました: $e'),
          stage: 'add_bookmark_direct_error');
    }
  }

  Future<void> deleteBookmark(
      {required PlayerOriginToken origin, required String bookmarkId}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    try {
      await _deleteBookmark.execute(bookmarkId);
      _write(
        origin,
        (s) => s.copyWith(
            bookmarks: s.bookmarks.where((b) => b.id != bookmarkId).toList()),
        stage: 'delete_bookmark',
      );
    } catch (e) {
      _write(origin, (s) => s.copyWith(errorMessage: 'ブックマークの削除に失敗しました: $e'),
          stage: 'delete_bookmark_error');
    }
  }

  Future<void> setAbRepeat(
      {required PlayerOriginToken origin,
      required int start,
      required int end}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    await _setAbRepeat.execute(
        contentId: origin.contentId, start: start, end: end);
  }

  Future<void> clearAbRepeat({required PlayerOriginToken origin}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    await _setAbRepeat.clear(origin.contentId);
  }

  Future<void> seekToBookmark(
      {required PlayerOriginToken origin, required int position}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null ||
        state.content!.body.isEmpty ||
        state.content!.id != origin.contentId) {
      return;
    }
    final wasPlaying = state.isPlaying;
    // 再生中の場合は正しく停止（TTS使用量カウント含む）（FIX-003）
    if (wasPlaying) {
      final outcome = await _playbackGate.stopForSession(
        sessionId: origin.sessionId,
        contentId: origin.contentId,
        position: _getCurrentPosition(),
      );
      _write(
        origin,
        (s) => outcome.ttsStopSucceeded
            ? s.copyWith(isPlaying: false)
            : s.copyWith(isPlaying: false, errorMessage: '停止に失敗しました'),
        stage: 'seek_to_bookmark_stop',
      );
    }
    if (!_isOriginEffectCurrent(origin) || state.content == null) return;
    final progressPct =
        (position / state.content!.body.length * 100).clamp(0.0, 100.0);
    await seekTo(origin: origin, progressPct: progressPct);
    // 再生中だった場合は指定位置から再生を再開
    if (wasPlaying) {
      await play(origin: origin);
    }
  }

  Future<void> seekTo(
      {required PlayerOriginToken origin, required double progressPct}) async {
    if (!_isOriginEffectCurrent(origin)) return;
    if (state.content == null || state.content!.id != origin.contentId) return;
    final position = (state.content!.body.length * progressPct / 100).round();
    await _savePlaybackState.execute(
      contentId: origin.contentId,
      position: position,
      progressPct: progressPct,
    );
    _write(
      origin,
      (s) => s.copyWith(
        highlightPosition: position,
        playbackState: s.playbackState
            ?.copyWith(position: position, progressPct: progressPct),
      ),
      stage: 'seek_to',
    );
  }

  /// 表解説付き新規テキストを作成する（REQ-034）
  Future<Content?> createTableDescriptionContent(
      {required PlayerOriginToken origin}) async {
    if (!_isOriginEffectCurrent(origin)) return null;
    if (state.content == null || state.content!.id != origin.contentId) {
      return null;
    }
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
      return newContent;
    } catch (e) {
      _write(origin, (s) => s.copyWith(errorMessage: '新規テキストの作成に失敗しました: $e'),
          stage: 'w1_create_table_description_content_error');
      return null;
    }
  }

  /// バックグラウンドで目次作成を実行する（REQ-034）
  /// 契約上 throw しない（呼び出し側は `unawaited(...)` で起動する）。
  Future<void> createTocInBackground({
    required PlayerOriginToken origin,
    required String text,
    required String apiKey,
    required String provider,
    required bool shouldClean,
    required double speed,
    required int totalChars,
    required String tocPrompt,
  }) async {
    if (!_isOriginEffectCurrent(origin)) return;
    _write(origin, (s) => s.copyWith(tocCreating: true, tocCompleted: false),
        stage: 'w3_start'); // REQ-034
    try {
      final List<dynamic> bookmarks;
      if (provider == 'groq') {
        bookmarks = await GroqService().analyzeAndCreateBookmarks(
          contentId: origin.contentId,
          text: text,
          apiKey: apiKey,
          shouldClean: shouldClean,
          speed: speed,
          totalChars: totalChars,
          customPrompt: tocPrompt,
        );
      } else if (provider == 'claude') {
        bookmarks = await ClaudeService().analyzeAndCreateBookmarks(
          contentId: origin.contentId,
          text: text,
          apiKey: apiKey,
          shouldClean: shouldClean,
          speed: speed,
          totalChars: totalChars,
          customPrompt: tocPrompt,
        );
      } else {
        bookmarks = await GeminiService().analyzeAndCreateBookmarks(
          contentId: origin.contentId,
          text: text,
          apiKey: apiKey,
          shouldClean: shouldClean,
          speed: speed,
          totalChars: totalChars,
          customPrompt: tocPrompt,
        );
      }
      for (final bookmark in bookmarks) {
        if (!_isOriginEffectCurrent(origin)) return; // 次の副作用前に再検証、失効なら即停止
        await addBookmarkDirect(origin: origin, bookmark: bookmark);
      }
      _write(origin, (s) => s.copyWith(tocCreating: false, tocCompleted: true),
          stage: 'w3_complete'); // REQ-034
    } catch (e) {
      _write(
        origin,
        (s) => s.copyWith(
          tocCreating: false,
          tocCompleted: false,
          errorMessage: _tocErrorMessage(e),
        ),
        stage: 'w3_error',
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
    _liveSubscription?.cancel();
    // R-7: 共有 playback gate（および共有 position 購読）は app-shared provider
    // の所有物。autoDispose される VM からは破棄しない（破棄は
    // normalPlayerPlaybackGateProvider の ref.onDispose のみ）。
    super.dispose();
  }
}
