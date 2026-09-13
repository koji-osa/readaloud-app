import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/content.dart';
import '../model/normal_player_session.dart';
import '../model/quick_listen_session.dart';
import '../model/setting.dart';
import '../model/tts_playback_position.dart';
import '../repository/settings_repository.dart';
import '../repository/tts/tts_service.dart';
import '../usecase/content/save_content_usecase.dart';
import '../usecase/tts/count_tts_usage_usecase.dart';
import '../util/debug_logger.dart';
import '../util/share_fingerprint.dart';

class QuickListenState {
  final QuickListenSession? session;
  final bool isPlaying;
  final int highlightPosition;
  final TtsStatus ttsStatus;
  final bool isSaving;
  final Content? savedContent;
  final String? errorMessage;

  const QuickListenState({
    this.session,
    this.isPlaying = false,
    this.highlightPosition = 0,
    this.ttsStatus = TtsStatus.stopped,
    this.isSaving = false,
    this.savedContent,
    this.errorMessage,
  });

  bool get hasSaved => savedContent != null;

  QuickListenState copyWith({
    QuickListenSession? session,
    bool? isPlaying,
    int? highlightPosition,
    TtsStatus? ttsStatus,
    bool? isSaving,
    Content? savedContent,
    String? errorMessage,
  }) =>
      QuickListenState(
        session: session ?? this.session,
        isPlaying: isPlaying ?? this.isPlaying,
        highlightPosition: highlightPosition ?? this.highlightPosition,
        ttsStatus: ttsStatus ?? this.ttsStatus,
        isSaving: isSaving ?? this.isSaving,
        savedContent: savedContent ?? this.savedContent,
        errorMessage: errorMessage,
      );
}

/// Quick Listen専用の再生アダプタ。
///
/// 既存のTtsService(audio_service)をそのまま利用して読み上げを行い、
/// Content DB・PlaybackRepository・BookmarkRepositoryのいずれにも依存しない。
/// 再生位置は外部（TtsAudioHandler.customState）から渡されるstreamで受け取るだけで、
/// DBへは一切書き込まない。
class QuickListenViewModel extends StateNotifier<QuickListenState> {
  final TtsService _ttsService;
  final SettingsRepository _settingsRepo;
  final SaveContentUseCase _saveContent;
  final CountTtsUsageUseCase _countUsage;
  final int Function() _getCurrentPosition;

  StreamSubscription<dynamic>? _positionSubscription;

  // Observability: このViewModelインスタンスがpositionStreamから最初に値を
  // 受け取ったかどうか。BehaviorSubject経由で前セッション/前画面の値が
  // 即座に再送される可能性を切り分けるためのフラグ（症状1のEvidence）。
  bool _hasReceivedPosition = false;

  // 症状1の修正: audioHandler.customState(positionStream)はBehaviorSubject
  // 相当で、購読直後に「前回最後の値」を再送する。さらにstart()内でのstop()も
  // 旧セッション最後のcharPositionを伴うcustomStateを再送しうる。
  // これらは新セッション自身の再生開始と無関係な値のため、以下の2フラグで
  // 「このセッション自身のplay()が実際に再生を開始したと確認できるまで」
  // state.highlightPositionへの反映を止める。
  //
  // _hasCalledPlayForCurrentSession: このセッションでplay()を呼んだか。
  //   play()より前に届くイベントは無条件で無視する（要件: 初回play開始前の
  //   旧Player/旧セッション由来イベントを適用しない）。
  // _acceptPositionUpdates: play()呼び出し後、実際に「このセッションの再生が
  //   始まった」と確認できるisPlaying==trueイベントを受信して初めてtrueになる。
  //   これによりplay()直後に紛れ込む旧stopped/pausedイベント（例: stop()自体が
  //   発生させるcustomState再送）もstateを汚染しない。一度trueになった後は
  //   同一セッション内のpause/resumeも含め通常どおり反映する。
  bool _hasCalledPlayForCurrentSession = false;
  bool _acceptPositionUpdates = false;

  QuickListenViewModel({
    required TtsService ttsService,
    required SettingsRepository settingsRepo,
    required SaveContentUseCase saveContent,
    required CountTtsUsageUseCase countUsage,
    required Stream<dynamic> positionStream,
    required int Function() getCurrentPosition,
  })  : _ttsService = ttsService,
        _settingsRepo = settingsRepo,
        _saveContent = saveContent,
        _countUsage = countUsage,
        _getCurrentPosition = getCurrentPosition,
        super(const QuickListenState()) {
    _positionSubscription = positionStream.listen((data) {
      if (data is! TtsPlaybackPosition) return;
      final isFirstEvent = !_hasReceivedPosition;
      _hasReceivedPosition = true;

      // play()が未呼び出しのイベントは常に無視。play()呼び出し後も、この
      // セッション自身の再生開始を示すisPlaying==trueイベントを受信するまでは
      // 無視し、それを受信した時点で以降のイベントを通常どおり反映する。
      if (!_acceptPositionUpdates &&
          _hasCalledPlayForCurrentSession &&
          data.isPlaying) {
        _acceptPositionUpdates = true;
      }
      final appliedToState = _acceptPositionUpdates;

      unawaited(DebugLogger.instance.logEvent('tts_position_received', {
        'origin': 'quick_listen',
        'sessionId': state.session?.id,
        'charPosition': data.charPosition,
        'isPlaying': data.isPlaying,
        'ttsStatus': data.ttsStatus.name,
        'isFirstEvent': isFirstEvent,
        'appliedToState': appliedToState,
      }));

      if (!appliedToState) return;
      state = state.copyWith(
        highlightPosition: data.charPosition,
        isPlaying: data.isPlaying,
        ttsStatus: data.ttsStatus,
      );
    });
  }

  /// 新しい共有テキストでセッションを開始する。
  /// 既存セッションがある場合はMVP仕様として単純に置き換える（DB操作なし）。
  ///
  /// 置き換え前のセッションが再生中・一時停止中だった場合、明示的に停止しないと
  /// 画面上は新しいテキストを表示しているのに音声だけ旧テキストのまま再生され
  /// 続けてしまう（TtsAudioHandlerは単一インスタンスのため）。そのため置き換え時は
  /// 必ずTTSと使用量カウントを止めてから新しいセッションを設定する。
  void start(QuickListenSession session) {
    final previousSession = state.session;
    final replacedExisting = previousSession != null;
    if (replacedExisting) {
      // ignore: discarded_futures
      _ttsService.stop();
      // v0.4.1 D14: 置換前セッション自身のownerで止める（固定文字列'quick-listen'
      // ではなくsession-derived ownerに統一。CB-3 closure）。
      // ignore: discarded_futures
      _countUsage
          .stopCounting(PlaybackOwnerKey.quickListen(previousSession.id));
    }
    // 直前のセッションに対するsave()が進行中でも、新セッションのsave()は
    // それに相乗りせず必ず新しいSaveContentUseCase呼び出しを行うようにする。
    // （古いFutureの完了結果は_performSave側のセッションIDガードで無視される）
    _pendingSave = null;
    _hasReceivedPosition = false; // Observability: 新セッションの初回受信を判定し直す
    _hasCalledPlayForCurrentSession = false;
    _acceptPositionUpdates = false;
    state = QuickListenState(session: session);
    unawaited(DebugLogger.instance.logEvent('quick_listen_session_started', {
      'sessionId': session.id,
      'charCount': session.text.length,
      'sourceType': session.sourceType,
      'replacedExistingSession': replacedExisting,
      'highlightPositionAtStart': state.highlightPosition,
      // No.94 Observability: session.textはmain.dart _handleSharedPayload()で
      // 既にDart側`.trim()`済みの値（QuickListenScreen(initialText: text)経由）。
      // 比較ルール上、このpayloadHash(raw)は「Dart trimmed hash ↔ Quick Listen
      // raw/session hash」というpost-trim境界の比較に使う値であり、
      // native/plugin境界のprimary identity比較にはshare_classified等の
      // payloadHash(=trim前のDart classify結果)を使うこと（詳細は
      // ShareFingerprintのdocコメント参照）。
      'payloadHash': ShareFingerprint.sha256Hex(session.text),
      'trimmedPayloadHash': ShareFingerprint.sha256Hex(session.text.trim()),
    }));
  }

  Future<void> play() async {
    final session = state.session;
    if (session == null || session.text.trim().isEmpty) return;
    try {
      final defaultSpeedStr =
          await _settingsRepo.get(SettingKeys.defaultSpeed) ?? '1.0';
      final speed = double.tryParse(defaultSpeedStr) ?? 1.0;
      // ログ記録前にhighlightPositionをスナップショットし、CountTtsUsage・
      // ログ・speak()の全てで同じ値を使う。await(_settingsRepo.get/logEvent)の
      // 間にpositionStreamの更新でstateが変化しても、記録値と実際にspeak()へ
      // 渡す値が食い違わないようにするため。
      final startPosition = state.highlightPosition;
      _countUsage.startCounting(
        owner: PlaybackOwnerKey.quickListen(session.id),
        totalChars: session.text.length,
        startPosition: startPosition,
      );
      // Observability(症状1優先): play()直前のhighlightPositionと、
      // speak()へ渡すstartPositionを記録する（本文は含めない）。
      await DebugLogger.instance.logEvent('tts_play_requested', {
        'origin': 'quick_listen',
        'sessionId': session.id,
        'highlightPositionAtPlayCall': startPosition,
        'startPositionPassedToSpeak': startPosition,
      });
      // speak()呼び出し直前にゲートを開ける。これ以降に届くpositionStream
      // イベントのうち、実際にisPlaying==trueとなる最初のイベント（=この
      // セッション自身の再生開始）以降だけがstateへ反映されるようになる。
      _hasCalledPlayForCurrentSession = true;
      await _ttsService.speak(
        text: session.text,
        startPosition: startPosition,
        speed: speed,
      );
      state = state.copyWith(isPlaying: true);
    } catch (e) {
      await DebugLogger.instance.logEvent('error', {
        'context': 'quick_listen_play',
        'errorType': e.runtimeType.toString(),
      });
      state = state.copyWith(errorMessage: '再生に失敗しました: $e');
    }
  }

  Future<void> pause() async {
    final position = _getCurrentPosition();
    final session = state.session;
    if (session != null) {
      await _countUsage.stopCounting(PlaybackOwnerKey.quickListen(session.id));
    }
    await _ttsService.pause();
    state = state.copyWith(isPlaying: false, highlightPosition: position);
  }

  /// セッションを破棄する。TTSを止めるだけでDBへの変更は一切行わない。
  Future<void> close() async {
    final session = state.session;
    if (session != null) {
      await _countUsage.stopCounting(PlaybackOwnerKey.quickListen(session.id));
    }
    await _ttsService.stop();
    state = const QuickListenState();
  }

  Future<Content?>? _pendingSave;

  /// 通常Contentへ昇格保存する（DBへは初めてここで1回だけ書き込む）。
  ///
  /// 既に保存済みならその結果を即返す。保存処理が進行中の場合は新たに
  /// SaveContentUseCaseを呼ばず、進行中のFutureをそのまま返す。
  /// （isSavingフラグだけで早期returnすると、ほぼ同時に呼ばれた2回目の
  /// 呼び出しが「まだ完了していない1回目の結果」を待たずにnullを返してしまい、
  /// concurrent double tapで片方の呼び出し元が保存成功を検知できなくなる。
  /// Futureそのものを共有することで両方の呼び出し元が同じ結果を受け取れる。）
  Future<Content?> save() {
    final session = state.session;
    if (session == null) return Future.value(null);
    if (state.hasSaved) return Future.value(state.savedContent);
    return _pendingSave ??= _performSave(session);
  }

  Future<Content?> _performSave(QuickListenSession session) async {
    state = state.copyWith(isSaving: true, errorMessage: null);
    try {
      final content = await _saveContent.execute(
        body: session.text,
        sourceType: session.sourceType,
        title: session.title,
      );
      // 保存中に新しい共有でセッションが置き換わっていた場合、完了時に
      // 古いセッションの状態で現在の画面を上書きしない（DBへの保存自体は
      // 成功しているのでcontentはそのまま返す）。
      if (state.session?.id == session.id) {
        state = state.copyWith(
          isSaving: false,
          savedContent: content,
          session: session.copyWith(saved: true),
        );
      }
      return content;
    } catch (e) {
      if (state.session?.id == session.id) {
        state = state.copyWith(
          isSaving: false,
          errorMessage: '保存に失敗しました: $e',
        );
      }
      return null;
    } finally {
      _pendingSave = null;
    }
  }

  void clearError() => state = state.copyWith(errorMessage: null);

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _countUsage.dispose();
    super.dispose();
  }
}
