import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/content.dart';
import '../model/normal_player_session.dart';
import '../model/playback_request.dart';
import '../model/quick_listen_session.dart';
import '../repository/tts/tts_service.dart';
import '../usecase/content/library_promotion_service.dart';
import '../usecase/playback/playback_defaults_reader.dart';
import '../usecase/playback/playback_usage_accounting.dart';
import '../usecase/playback/seek_math.dart';
import '../usecase/playback/shared_playback_transport.dart';
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

/// Transient session controller（実装名 QuickListen*）。
///
/// Shared Player Core（Detailed Design v1.2 FINAL）:
/// - 再生は app-shared な [SharedPlaybackTransport] 経由。owner は
///   `PlaybackOwnerKey.transient(sessionId)`。
/// - user-visible TTS usage accounting の対象外（PD-1）。`const NoUsageAccounting()`。
/// - write-capable な repository / DAO / DB usecase を受け取らない（INV-T1）。
///   defaultSpeed は read-only な [PlaybackDefaultsReader] からのみ読む。
///   Library への唯一の書込み seam は [LibraryPromotionService]。
/// - Bookmark / TOC / 表解析 / 速度・声変更 / 巻戻し・早送りのメソッドは
///   型として持たない（PD-2 capability gating）。
class QuickListenViewModel extends StateNotifier<QuickListenState> {
  final SharedPlaybackTransport _transport;
  final PlaybackDefaultsReader _defaultsReader;
  final LibraryPromotionService _promotion;

  StreamSubscription<PositionObservation>? _positionSubscription;

  /// 現在 session で最後に再生開始した速度（promotion handoff 用）。
  double? _sessionSpeed;

  // Observability: このViewModelインスタンスがpositionを最初に受け取ったかどうか。
  // BehaviorSubject経由で前セッション/前画面の値が即座に再送される可能性を
  // 切り分けるためのフラグ（症状1のEvidence）。
  bool _hasReceivedPosition = false;

  QuickListenViewModel({
    required SharedPlaybackTransport transport,
    required PlaybackDefaultsReader defaultsReader,
    required LibraryPromotionService promotion,
  })  : _transport = transport,
        _defaultsReader = defaultsReader,
        _promotion = promotion,
        super(const QuickListenState()) {
    // 症状1の修正（D15）は Transport に集約された: Transport は
    // 「この owner の speak() 呼び出し後に届いた最初の isPlaying==true」から
    // event を受理し、受理時点の activeOwner で刻印する（INV-T2）。
    // controller は自 session の owner で刻印された event だけを state へ反映する。
    _positionSubscription =
        _transport.positionObservations.listen(_onPositionObserved);
  }

  PlaybackOwnerKey _ownerOf(String sessionId) =>
      PlaybackOwnerKey.transient(sessionId);

  void _onPositionObserved(PositionObservation observation) {
    final data = observation.position;
    final isFirstEvent = !_hasReceivedPosition;
    _hasReceivedPosition = true;

    final session = state.session;
    final appliedToState = session != null &&
        observation.acceptedOwner != null &&
        observation.acceptedOwner == _ownerOf(session.id);

    unawaited(DebugLogger.instance.logEvent('tts_position_received', {
      'origin': 'quick_listen',
      'sessionId': session?.id,
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
  }

  /// 新しい共有テキストでセッションを開始する。
  /// 既存セッションがある場合はMVP仕様として単純に置き換える（DB操作なし）。
  ///
  /// 置き換え前のセッションが再生中・一時停止中だった場合、明示的に停止しないと
  /// 画面上は新しいテキストを表示しているのに音声だけ旧テキストのまま再生され
  /// 続けてしまう（TtsAudioHandlerは単一インスタンスのため）。そのため置き換え時は
  /// 置換前セッション自身の owner で TTS を止めてから新しいセッションを設定する
  /// （owner-gated: 別 owner の再生には作用しない）。
  void start(QuickListenSession session) {
    final previousSession = state.session;
    final replacedExisting = previousSession != null;
    if (replacedExisting) {
      unawaited(_transport.stop(_ownerOf(previousSession.id)));
    }
    // 直前のセッションに対するsave()が進行中でも、新セッションのsave()は
    // それに相乗りせず必ず新しい保存呼び出しを行うようにする。
    // （古いFutureの完了結果は_performSave側のセッションIDガードで無視される）
    _pendingSave = null;
    _sessionSpeed = null;
    _hasReceivedPosition = false; // Observability: 新セッションの初回受信を判定し直す
    state = QuickListenState(session: session);
    final text = session.request.text;
    unawaited(DebugLogger.instance.logEvent('quick_listen_session_started', {
      'sessionId': session.id,
      'charCount': text.length,
      'sourceType': session.request.source?.sourceType,
      'replacedExistingSession': replacedExisting,
      'highlightPositionAtStart': state.highlightPosition,
      // No.94 Observability: request.textはmain.dart _handleSharedPayload()で
      // 既にDart側`.trim()`済みの値（QuickListenScreen(initialText: text)経由）。
      // 比較ルール上、このpayloadHash(raw)は「Dart trimmed hash ↔ Quick Listen
      // raw/session hash」というpost-trim境界の比較に使う値であり、
      // native/plugin境界のprimary identity比較にはshare_classified等の
      // payloadHash(=trim前のDart classify結果)を使うこと（詳細は
      // ShareFingerprintのdocコメント参照）。
      'payloadHash': ShareFingerprint.sha256Hex(text),
      'trimmedPayloadHash': ShareFingerprint.sha256Hex(text.trim()),
    }));
  }

  Future<void> play() async {
    final session = state.session;
    if (session == null || session.request.text.trim().isEmpty) return;
    try {
      // 既存 defaultSpeed を再生時に尊重する（取得タイミングは従来どおり play 時）。
      final speed = await _defaultsReader.readDefaultSpeed();
      // ログ記録前にhighlightPositionをスナップショットし、ログ・speak()の
      // 両方で同じ値を使う。await(readDefaultSpeed/logEvent)の間に
      // position更新でstateが変化しても、記録値と実際にspeak()へ渡す値が
      // 食い違わないようにするため。
      final startPosition = state.highlightPosition;
      await _startFrom(session, startPosition, speed);
      if (!mounted) return;
      state = state.copyWith(isPlaying: true);
    } catch (e) {
      await DebugLogger.instance.logEvent('error', {
        'context': 'quick_listen_play',
        'errorType': e.runtimeType.toString(),
      });
      if (!mounted) return;
      state = state.copyWith(errorMessage: '再生に失敗しました: $e');
    }
  }

  Future<void> _startFrom(
      QuickListenSession session, int startPosition, double speed) {
    if (state.session?.id == session.id) _sessionSpeed = speed;
    return _transport.start(
      _ownerOf(session.id),
      session.request
          .withStartPosition(startPosition)
          .withVoice(PlaybackVoiceParams(speed: speed)),
      accounting: const NoUsageAccounting(), // PD-1: Transientは計上しない
      logFields: {
        'origin': 'quick_listen',
        'sessionId': session.id,
        'highlightPositionAtPlayCall': startPosition,
      },
    );
  }

  Future<void> pause() async {
    final session = state.session;
    if (session == null) return;
    final position = _transport.currentPosition;
    final result = await _transport.pause(_ownerOf(session.id));
    if (!mounted) return;
    state = switch (result) {
      CommandApplied() =>
        state.copyWith(isPlaying: false, highlightPosition: position),
      // 別 owner の位置を自 session へ取り込まない。
      CommandIgnoredStaleOwner() => state.copyWith(isPlaying: false),
    };
  }

  /// 先頭から再生（PD-2 / AC-05）。
  Future<void> seekToStart() => seekToPosition(SeekMath.startPosition);

  /// 本文タップ位置から再生（PD-2 / AC-06）。
  ///
  /// 停止中・一時停止中は位置だけを更新し、再生中は
  /// stop(owner) → position=pos → start(pos) を行う。DB へは一切書かない。
  Future<void> seekToPosition(int position) async {
    final session = state.session;
    if (session == null) return;
    final target = SeekMath.clampTap(position, session.request.text.length);
    if (!state.isPlaying) {
      state = state.copyWith(highlightPosition: target);
      return;
    }
    final sessionId = session.id;
    await _transport.stop(_ownerOf(sessionId));
    // stale async effect gate: await 後は session id が一致する場合のみ反映する。
    if (!mounted || state.session?.id != sessionId) return;
    state = state.copyWith(highlightPosition: target, isPlaying: false);
    try {
      final speed = await _defaultsReader.readDefaultSpeed();
      if (!mounted || state.session?.id != sessionId) return;
      await _startFrom(session, target, speed);
      if (!mounted || state.session?.id != sessionId) return;
      state = state.copyWith(isPlaying: true);
    } catch (e) {
      await DebugLogger.instance.logEvent('error', {
        'context': 'quick_listen_seek',
        'errorType': e.runtimeType.toString(),
      });
      if (!mounted || state.session?.id != sessionId) return;
      state = state.copyWith(errorMessage: '再生に失敗しました: $e');
    }
  }

  /// セッションを破棄する（INV-T3）。DBへの変更は一切行わない。
  ///
  /// `expectedOwner = transient(sessionId)` の owner-safe teardown を行い、
  /// owner 一致時は stop + resume fence（+ terminal close では media
  /// notification の完全消去、NEW-Q1=A）を行う。別 owner が active な stale
  /// close ではその owner へ一切触れない。teardown の結果に関わらず、
  /// 対象 session の state はここで破棄する（別 session の state は壊さない）。
  ///
  /// [sessionId] 省略時は現在の session を対象にする。[reason] は
  /// terminal close（×/system back）以外に、share 到着時の handoff
  /// （[TeardownReason.shareTeardown]）で使う。
  Future<void> close({
    String? sessionId,
    TeardownReason reason = TeardownReason.terminalClose,
  }) async {
    final targetId = sessionId ?? state.session?.id;
    if (targetId != null) {
      try {
        await _transport.forceStopForTeardown(
          expectedOwner: _ownerOf(targetId),
          reason: reason,
          notificationDisposition: reason == TeardownReason.terminalClose
              ? NotificationDisposition.clearIfNoLiveOwner
              : NotificationDisposition.handoff,
        );
      } catch (e) {
        unawaited(DebugLogger.instance.logEvent('error', {
          'context': 'quick_listen_close',
          'errorType': e.runtimeType.toString(),
        }));
      }
    }
    if (!mounted) return;
    final current = state.session;
    if (current == null || current.id == targetId) {
      state = const QuickListenState();
    }
  }

  Future<Content?>? _pendingSave;

  /// 通常Contentへ昇格保存する（DBへは初めてここで1回だけ書き込む）。
  ///
  /// 既に保存済みならその結果を即返す。保存処理が進行中の場合は新たに
  /// 保存を呼ばず、進行中のFutureをそのまま返す。
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
    // 保存時点の snapshot を最初の await より前に同期で取る（§10）:
    // Playing 中は Transport の現在位置（この session が owner の場合のみ）、
    // それ以外は highlightPosition。
    final owner = _ownerOf(session.id);
    final position = state.isPlaying && _transport.activeOwner == owner
        ? _transport.currentPosition
        : state.highlightPosition;
    final playedSpeed = _sessionSpeed;
    state = state.copyWith(isSaving: true, errorMessage: null);
    try {
      final speed = playedSpeed ?? await _defaultsReader.readDefaultSpeed();
      final result = await _promotion.promote(PromotionInput(
        request: session.request,
        position: position,
        speed: speed,
      ));
      final content = result.content;
      // 保存中に新しい共有でセッションが置き換わっていた場合、完了時に
      // 古いセッションの状態で現在の画面を上書きしない（DBへの保存自体は
      // 成功しているのでcontentはそのまま返す）。
      // 保存後も session は Transient のまま（Persistent へ reattach しない）。
      if (mounted && state.session?.id == session.id) {
        state = state.copyWith(
          isSaving: false,
          savedContent: content,
          session: state.session!
              .copyWith(saved: true, promotedContentId: content.id),
        );
      }
      return content;
    } catch (e) {
      if (mounted && state.session?.id == session.id) {
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
    // R-7: 共有 Transport は provider の所有物。自分の購読だけを外す。
    _positionSubscription?.cancel();
    super.dispose();
  }
}
