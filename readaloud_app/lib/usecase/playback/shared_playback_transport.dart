import 'dart:async';

import 'package:meta/meta.dart';

import '../../model/normal_player_session.dart';
import '../../model/playback_request.dart';
import '../../model/tts_playback_position.dart';
import '../../repository/tts/playback_resume_fence.dart';
import '../../repository/tts/tts_service.dart';
import '../../util/debug_logger.dart';
import 'playback_usage_accounting.dart';

export '../../repository/tts/playback_resume_fence.dart'
    show NotificationDisposition, PlaybackResumeFence;

/// owner を恒久 retire する teardown の理由（Detailed Design v1.2 FINAL §6.3）。
enum TeardownReason { shareTeardown, routeRemoval, terminalClose }

sealed class OwnedCommandResult {
  const OwnedCommandResult();
}

/// owner が active で、実際に TTS へ作用した。
final class CommandApplied extends OwnedCommandResult {
  const CommandApplied({
    required this.ttsSucceeded,
    required this.usageFlushSucceeded,
    required this.positionAtStop,
    this.ttsErrorType,
    this.usageFlushErrorType,
  });

  final bool ttsSucceeded;
  final bool usageFlushSucceeded;
  final int positionAtStop;
  final String? ttsErrorType;
  final String? usageFlushErrorType;
}

/// owner が active でないため何もしなかった（TTS・accounting・state に触れていない）。
final class CommandIgnoredStaleOwner extends OwnedCommandResult {
  const CommandIgnoredStaleOwner({
    required this.requestedOwner,
    required this.activeOwner,
  });

  final PlaybackOwnerKey requestedOwner;
  final PlaybackOwnerKey? activeOwner;
}

enum TeardownApplication { applied, noActivePlayback, ignoredStaleOwner }

final class ForceStopOutcome {
  const ForceStopOutcome({
    required this.application,
    required this.ttsStopSucceeded,
    required this.usageFlushSucceeded,
    required this.positionAtStop,
    required this.resumeStateDiscarded,
    this.ttsStopErrorType,
    this.usageFlushErrorType,
  });

  final TeardownApplication application;
  final bool ttsStopSucceeded;
  final bool usageFlushSucceeded;
  final bool resumeStateDiscarded;
  final int positionAtStop;
  final String? ttsStopErrorType;
  final String? usageFlushErrorType;

  /// applied で stop 成功、または noActivePlayback なら true。
  /// ignoredStaleOwner は別 owner 保護のため false。
  bool get ttsStopConfirmed =>
      application == TeardownApplication.noActivePlayback ||
      (application == TeardownApplication.applied && ttsStopSucceeded);
}

/// external-entry authoritative retirement の結果（v1.3 §6.2）。
final class ActivePlaybackRetirement {
  const ActivePlaybackRetirement({
    required this.hadActivePlayback,
    this.retiredOwner,
    this.retiredTarget,
    required this.stopOutcome,
  });

  final bool hadActivePlayback;
  final PlaybackOwnerKey? retiredOwner;

  /// retire した再生の target。Persistent なら上位 seam がこの target 自身へ
  /// 位置を保存する（別 route の content へは書かない）。
  final PlaybackTarget? retiredTarget;
  final ForceStopOutcome stopOutcome;
}

final class PlaybackStartFailure implements Exception {
  const PlaybackStartFailure({
    required this.owner,
    required this.errorType,
    this.cause,
  });

  final PlaybackOwnerKey owner;
  final String errorType;
  final Object? cause;

  /// UI の既存エラー文言（`'再生に失敗しました: $e'`）を変えないよう、原因の
  /// 表現をそのまま返す。
  @override
  String toString() => cause?.toString() ?? 'PlaybackStartFailure($errorType)';
}

/// D15 受理後の position event。受理時点の activeOwner で刻印される。
final class OwnedPositionEvent {
  const OwnedPositionEvent({
    required this.owner,
    required this.charPosition,
    required this.isPlaying,
    required this.ttsStatus,
  });

  final PlaybackOwnerKey owner;
  final int charPosition;
  final bool isPlaying;
  final TtsStatus ttsStatus;
}

/// Transport が受け取ったすべての position event の観測（Observability 用）。
/// [acceptedOwner] は D15 受理済みで owner 刻印された場合のみ非 null。
final class PositionObservation {
  const PositionObservation({
    required this.position,
    required this.acceptedOwner,
  });

  final TtsPlaybackPosition position;
  final PlaybackOwnerKey? acceptedOwner;
}

/// [SharedPlaybackTransport.exclusive] の区間内でだけ使える操作。
/// 区間内から Transport の public start/pause/stop を呼ぶと自己待ちになるため、
/// 必ずこちらを使う。
abstract interface class TransportOps {
  Future<void> startUnlocked(
    PlaybackOwnerKey owner,
    PlaybackRequest request, {
    required PlaybackUsageAccounting accounting,
    Map<String, Object?> logFields,
  });
  Future<OwnedCommandResult> pauseUnlocked(PlaybackOwnerKey owner);
  Future<OwnedCommandResult> stopUnlocked(PlaybackOwnerKey owner);
  Future<ForceStopOutcome> forceStopForTeardownUnlocked({
    required PlaybackOwnerKey expectedOwner,
    required TeardownReason reason,
    required NotificationDisposition notificationDisposition,
  });
  Future<ActivePlaybackRetirement> retireActiveForExternalEntryUnlocked({
    required TeardownReason reason,
  });
  int get currentPosition;
  PlaybackOwnerKey? get activeOwner;
}

/// Normal Player / Transient 共通の再生 Transport（Detailed Design v1.2 FINAL §6）。
///
/// app-shared（非 autoDispose）。repository / DAO / DB に一切依存しない。
/// owner・受理状態・usage accounting の単一の所有権状態機械を持つ。
class SharedPlaybackTransport implements TransportOps {
  SharedPlaybackTransport({
    required TtsService tts,
    required Stream<dynamic> positionStream,
    required int Function() currentPosition,
    required PlaybackResumeFence resumeFence,
  })  : _tts = tts,
        _currentPosition = currentPosition,
        _resumeFence = resumeFence {
    // position 購読は生成時に1回だけ張り、start 毎に再購読しない（R-7）。
    _positionSubscription = positionStream.listen(_onPosition);
  }

  final TtsService _tts;
  final int Function() _currentPosition;
  final PlaybackResumeFence _resumeFence;
  late final StreamSubscription<dynamic> _positionSubscription;

  final StreamController<OwnedPositionEvent> _accepted =
      StreamController<OwnedPositionEvent>.broadcast(sync: true);
  final StreamController<PositionObservation> _observations =
      StreamController<PositionObservation>.broadcast(sync: true);

  PlaybackOwnerKey? _activeOwner;

  /// activeOwner の canonical な再生要求。owner と同時に設定・clear する
  /// （外部公開しない。external-entry retirement で retired target を返すため）。
  PlaybackRequest? _activeRequest;
  PlaybackUsageAccounting? _activeAccounting;

  // D15 position-stream gating（旧 StartPlaybackUseCase / Quick Listen と同型）。
  bool _hasCalledSpeak = false;
  bool _accept = false;

  // ---- exclusive chain -------------------------------------------------
  // 何も実行中・待機中でなければ body を同期的に開始し、そうでなければ
  // 投入順に直列実行する。chain 自身は常に正常完了させ、1回の失敗で以後の
  // 直列化が壊れないようにする。
  Future<void> _tail = Future<void>.value();
  bool _running = false;
  int _queued = 0;

  bool _disposed = false;

  @override
  PlaybackOwnerKey? get activeOwner => _activeOwner;

  @override
  int get currentPosition => _currentPosition();

  /// debug / test 専用。production caller は owner 発見に使わない
  /// （external entry は [retireActiveForExternalEntry] を使う）。
  @visibleForTesting
  PlaybackRequest? get activeRequestForDebug => _activeRequest;

  /// D15 受理後・owner 刻印済みの position event。
  Stream<OwnedPositionEvent> get acceptedPositions => _accepted.stream;

  /// 受理前を含むすべての position event（Observability 用）。
  Stream<PositionObservation> get positionObservations => _observations.stream;

  /// NP / Transient 共通の直列化区間。
  Future<T> exclusive<T>(Future<T> Function(TransportOps ops) body) {
    if (!_running && _queued == 0) {
      final done = _runNow(body);
      _tail = done.then((_) {}, onError: (_) {});
      return done;
    }
    _queued++;
    final result = _tail.then((_) {
      _queued--;
      return _runNow(body);
    });
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<T> _runNow<T>(Future<T> Function(TransportOps ops) body) {
    _running = true;
    final Future<T> future;
    try {
      future = body(this);
    } catch (e, st) {
      _running = false;
      return Future<T>.error(e, st);
    }
    return future.whenComplete(() => _running = false);
  }

  Future<void> start(
    PlaybackOwnerKey owner,
    PlaybackRequest request, {
    required PlaybackUsageAccounting accounting,
    Map<String, Object?> logFields = const {},
  }) =>
      exclusive((ops) => ops.startUnlocked(owner, request,
          accounting: accounting, logFields: logFields));

  Future<OwnedCommandResult> pause(PlaybackOwnerKey owner) =>
      exclusive((ops) => ops.pauseUnlocked(owner));

  Future<OwnedCommandResult> stop(PlaybackOwnerKey owner) =>
      exclusive((ops) => ops.stopUnlocked(owner));

  /// owner を恒久 retire する teardown 専用（coordinator / tracker / terminal
  /// close のみが呼ぶ）。[expectedOwner] 以外が active なら完全 no-op。
  Future<ForceStopOutcome> forceStopForTeardown({
    required PlaybackOwnerKey expectedOwner,
    required TeardownReason reason,
    required NotificationDisposition notificationDisposition,
  }) =>
      exclusive((ops) => ops.forceStopForTeardownUnlocked(
            expectedOwner: expectedOwner,
            reason: reason,
            notificationDisposition: notificationDisposition,
          ));

  /// external / share entry 専用（v1.3 §6.3 B / INV-T11）。caller-supplied owner
  /// ではなく、Transport 自身が exclusive chain 内で authoritative な
  /// activeOwner / activeRequest を capture して retire（stop + handoff fence）
  /// する。blind stop ではない。active が無ければ成功 no-op。
  Future<ActivePlaybackRetirement> retireActiveForExternalEntry({
    required TeardownReason reason,
  }) =>
      exclusive(
          (ops) => ops.retireActiveForExternalEntryUnlocked(reason: reason));

  // ---- TransportOps ----------------------------------------------------

  @override
  Future<void> startUnlocked(
    PlaybackOwnerKey owner,
    PlaybackRequest request, {
    required PlaybackUsageAccounting accounting,
    Map<String, Object?> logFields = const {},
  }) async {
    _activeOwner = owner;
    _activeRequest = request;
    _activeAccounting = accounting;
    _hasCalledSpeak = false;
    _accept = false;
    try {
      accounting.onPlaybackStarted(
        owner: owner,
        totalChars: request.text.length,
        startPosition: request.startPosition,
      );
      // Observability: play()相当の直前状態を記録（本文は含めない）
      await DebugLogger.instance.logEvent('tts_play_requested', {
        ...logFields,
        'startPositionPassedToSpeak': request.startPosition,
      });
      // 読み上げ開始直前にゲートを開ける（D15）。
      _hasCalledSpeak = true;
      await _tts.speak(
        text: request.text,
        startPosition: request.startPosition,
        speed: request.voice.speed,
        pitch: request.voice.pitch,
        volume: request.voice.volume,
        voiceId: request.voice.voiceId,
      );
    } catch (e) {
      // C2: start 失敗 rollback。次 session がクリーンに開始できる状態へ戻す。
      accounting.onPlaybackAborted(owner);
      if (_activeOwner == owner) {
        _activeOwner = null;
        _activeRequest = null;
        _activeAccounting = null;
      }
      _hasCalledSpeak = false;
      _accept = false;
      unawaited(DebugLogger.instance.logEvent('playback_start_failed', {
        'owner': owner.toString(),
        'errorType': e.runtimeType.toString(),
      }));
      throw PlaybackStartFailure(
        owner: owner,
        errorType: e.runtimeType.toString(),
        cause: e,
      );
    }
  }

  @override
  Future<OwnedCommandResult> pauseUnlocked(PlaybackOwnerKey owner) =>
      _ownedStop(owner, () => _tts.pause());

  @override
  Future<OwnedCommandResult> stopUnlocked(PlaybackOwnerKey owner) =>
      _ownedStop(owner, () => _tts.stop());

  Future<OwnedCommandResult> _ownedStop(
    PlaybackOwnerKey owner,
    Future<void> Function() ttsCommand,
  ) async {
    final active = _activeOwner;
    if (active != owner) {
      // C1: stale owner。TTS・accounting・state に一切触れない。
      return CommandIgnoredStaleOwner(
          requestedOwner: owner, activeOwner: active);
    }
    final positionAtStop = _currentPosition();

    // 1) usage accounting flush（他 sub-step から独立。B-01 順序を維持）
    final flush = _flushUsage(owner);
    final usage = flush is Future<UsageFlushResult> ? await flush : flush;

    // 2) TTS は必ず試行する
    bool ttsOk = true;
    String? ttsErr;
    try {
      await ttsCommand();
    } catch (e) {
      ttsOk = false;
      ttsErr = e.runtimeType.toString();
    }

    return CommandApplied(
      ttsSucceeded: ttsOk,
      usageFlushSucceeded: usage.succeeded,
      positionAtStop: positionAtStop,
      ttsErrorType: ttsErr,
      usageFlushErrorType: usage.errorType,
    );
  }

  @override
  Future<ForceStopOutcome> forceStopForTeardownUnlocked({
    required PlaybackOwnerKey expectedOwner,
    required TeardownReason reason,
    required NotificationDisposition notificationDisposition,
  }) async {
    final active = _activeOwner;
    if (active == null) {
      _logTeardown(expectedOwner, reason, TeardownApplication.noActivePlayback);
      return ForceStopOutcome(
        application: TeardownApplication.noActivePlayback,
        ttsStopSucceeded: true,
        usageFlushSucceeded: true,
        positionAtStop: _currentPosition(),
        resumeStateDiscarded: false,
      );
    }
    if (active != expectedOwner) {
      // INV-T10: stale teardown。TTS・accounting・resume fence・notification
      // に一切触れない。blind global stop へ fallback しない。
      _logTeardown(
          expectedOwner, reason, TeardownApplication.ignoredStaleOwner);
      return ForceStopOutcome(
        application: TeardownApplication.ignoredStaleOwner,
        ttsStopSucceeded: false,
        usageFlushSucceeded: true,
        positionAtStop: _currentPosition(),
        resumeStateDiscarded: false,
        ttsStopErrorType: 'ignoredStaleOwner',
      );
    }

    final outcome =
        await _retireOwnerUnlocked(expectedOwner, notificationDisposition);
    _logTeardown(expectedOwner, reason, TeardownApplication.applied);
    return outcome;
  }

  @override
  Future<ActivePlaybackRetirement> retireActiveForExternalEntryUnlocked({
    required TeardownReason reason,
  }) async {
    // v1.3 §6.3 B: caller は owner を指定しない。同一 critical section で
    // Transport 自身の authoritative activeOwner / activeRequest を capture する。
    final owner = _activeOwner;
    final request = _activeRequest;
    if (owner == null) {
      _logExternalRetirement(null, reason);
      return ActivePlaybackRetirement(
        hadActivePlayback: false,
        stopOutcome: ForceStopOutcome(
          application: TeardownApplication.noActivePlayback,
          ttsStopSucceeded: true,
          usageFlushSucceeded: true,
          positionAtStop: _currentPosition(),
          resumeStateDiscarded: false,
        ),
      );
    }
    final outcome =
        await _retireOwnerUnlocked(owner, NotificationDisposition.handoff);
    _logExternalRetirement(owner, reason);
    return ActivePlaybackRetirement(
      hadActivePlayback: true,
      retiredOwner: owner,
      retiredTarget: request?.target,
      stopOutcome: outcome,
    );
  }

  /// [owner]（= 現在の activeOwner）を恒久 retire する共通手順:
  /// accounting flush → TTS stop → resume fence → owner/request/accounting/D15 clear。
  Future<ForceStopOutcome> _retireOwnerUnlocked(
    PlaybackOwnerKey owner,
    NotificationDisposition notificationDisposition,
  ) async {
    final positionAtStop = _currentPosition();

    // 1) owner 自身の accounting flush
    final flush = _flushUsage(owner);
    final usage = flush is Future<UsageFlushResult> ? await flush : flush;

    // 2) TTS stop
    bool ttsOk = true;
    String? ttsErr;
    try {
      await _tts.stop();
    } catch (e) {
      ttsOk = false;
      ttsErr = e.runtimeType.toString();
    }

    // 3) owner を恒久 retire するため必ず resume fence（C3）
    bool discarded = true;
    try {
      await _resumeFence.discardResumeState(
          notificationDisposition: notificationDisposition);
    } catch (e) {
      discarded = false;
      unawaited(DebugLogger.instance.logEvent('error', {
        'context': 'playback_resume_fence',
        'errorType': e.runtimeType.toString(),
      }));
    }

    // 4) activeOwner / activeRequest / activeAccounting / D15 state clear
    if (_activeOwner == owner) {
      _clearActive();
    }

    return ForceStopOutcome(
      application: TeardownApplication.applied,
      ttsStopSucceeded: ttsOk,
      usageFlushSucceeded: usage.succeeded,
      positionAtStop: positionAtStop,
      resumeStateDiscarded: discarded,
      ttsStopErrorType: ttsErr,
      usageFlushErrorType: usage.errorType,
    );
  }

  void _clearActive() {
    _activeOwner = null;
    _activeRequest = null;
    _activeAccounting = null;
    _hasCalledSpeak = false;
    _accept = false;
  }

  void _logExternalRetirement(PlaybackOwnerKey? owner, TeardownReason reason) {
    unawaited(
        DebugLogger.instance.logEvent('playback_external_entry_retirement', {
      'retiredOwner': owner?.toString(),
      'reason': reason.name,
      'hadActivePlayback': owner != null,
    }));
  }

  /// accounting が同期に完了した場合は同期値を返し、呼び出し側が await による
  /// microtask 境界を挟まずに TTS command へ進めるようにする。
  FutureOr<UsageFlushResult> _flushUsage(PlaybackOwnerKey owner) {
    final accounting = _activeAccounting;
    if (accounting == null) return const UsageFlushResult.notApplicable();
    final FutureOr<UsageFlushResult> result;
    try {
      result = accounting.onPlaybackStopped(owner);
    } catch (e) {
      return UsageFlushResult.failed(e.runtimeType.toString());
    }
    if (result is Future<UsageFlushResult>) {
      return result.catchError(
          (Object e) => UsageFlushResult.failed(e.runtimeType.toString()));
    }
    return result;
  }

  void _logTeardown(PlaybackOwnerKey expectedOwner, TeardownReason reason,
      TeardownApplication application) {
    unawaited(DebugLogger.instance.logEvent('playback_teardown', {
      'expectedOwner': expectedOwner.toString(),
      'reason': reason.name,
      'application': application.name,
    }));
  }

  // ---- position stream -------------------------------------------------

  void _onPosition(dynamic data) {
    if (data is! TtsPlaybackPosition) return;
    final owner = _activeOwner;
    if (owner != null && !_accept && _hasCalledSpeak && data.isPlaying) {
      _accept = true;
    }
    final accepted = owner != null && _accept;
    if (!_observations.isClosed) {
      _observations.add(PositionObservation(
        position: data,
        acceptedOwner: accepted ? owner : null,
      ));
    }
    if (!accepted) return;
    _activeAccounting?.onPositionAdvanced(data.charPosition);
    if (!_accepted.isClosed) {
      _accepted.add(OwnedPositionEvent(
        owner: owner,
        charPosition: data.charPosition,
        isPlaying: data.isPlaying,
        ttsStatus: data.ttsStatus,
      ));
    }
  }

  /// provider の ref.onDispose からのみ呼ぶ（VM からは呼ばない。R-7）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_positionSubscription.cancel());
    unawaited(_accepted.close());
    unawaited(_observations.close());
  }
}
