import 'dart:async';

import 'package:flutter/widgets.dart';

import '../model/normal_player_session.dart';
import '../model/playback_request.dart';
import '../repository/playback_repository.dart';
import '../usecase/playback/persistent_playback_resolver.dart';
import '../usecase/playback/playback_persistence_policy.dart';
import '../usecase/playback/playback_usage_accounting.dart';
import '../usecase/playback/save_playback_state_usecase.dart';
import '../usecase/playback/shared_playback_transport.dart';
import '../usecase/playback/start_playback_usecase.dart';
import '../usecase/playback/stop_playback_usecase.dart';
import 'debug_logger.dart';

/// `register()` が返す rollback 用 token。
///
/// 直前の registration を保持するため、abort 時に null へ clear するのではなく
/// 直前の registration へ正確に復元できる（D4 / NRR-05）。
class PlayerRegistrationToken {
  const PlayerRegistrationToken._({
    required this.session,
    required this.route,
    required _Registration? previous,
  }) : _previous = previous;

  final NormalPlayerSession session;
  final Route<dynamic> route;
  final _Registration? _previous;
}

/// tracker が保持する現在の registration。
///
/// content・PlayerViewModel・TTS state は一切保持しない（D3）。保持するのは
/// navigation identity（session/route）と retirement claims・owned overlay
/// route の集合のみ。
class _Registration {
  _Registration({required this.session, required this.route});

  final NormalPlayerSession session;
  final Route<dynamic> route;
  final Set<Route<dynamic>> ownedOverlays = <Route<dynamic>>{};
  final List<Route<dynamic>> _overlayOrder = <Route<dynamic>>[];

  /// 各 removal flow が保持する claim id の集合。
  /// `isRetiring` は独立した bool ではなく、この集合から導出する（D6）。
  final Set<String> retirementClaims = <String>{};

  bool get isRetiring => retirementClaims.isNotEmpty;

  void addOverlay(Route<dynamic> overlay) {
    if (ownedOverlays.add(overlay)) {
      _overlayOrder.add(overlay);
    }
  }

  void removeOverlay(Route<dynamic> overlay) {
    ownedOverlays.remove(overlay);
    _overlayOrder.remove(overlay);
  }

  /// 上から順（後から登録された順）に除去するための順序。
  List<Route<dynamic>> get overlaysTopFirst => _overlayOrder.reversed.toList();
}

/// Normal Player の playback 遷移（start/pause/stop/teardown）を直列化する薄い gate。
///
/// navigation・dialog・AI workflow・Player UI state は一切所有しない（D12）。
/// 同一 session の in-flight stop は [NormalPlayerSessionTracker] 側でも
/// dedupe されるが、この gate 自身も start/stop/pause を単一 chain 上に
/// 直列化することで、A の遅延 stop が B の新しい start と交差する事故を防ぐ。
///
/// Shared Player Core Slice 3: public API は不変。production は
/// [NormalPlayerPlaybackGate.shared] で [SharedPlaybackTransport] +
/// [PersistentPlaybackResolver] + [PersistentPersistencePolicy] +
/// [PersistentUsageAccounting] へ委譲する。旧 usecase を受け取る既定
/// constructor は、既存テスト harness のために Slice 3c（別 cleanup PR）まで
/// 残す。
class NormalPlayerPlaybackGate {
  NormalPlayerPlaybackGate({
    required StartPlaybackUseCase startPlayback,
    required StopPlaybackUseCase stopPlayback,
    required int Function() getCurrentPosition,
  }) : _backend = _UseCasePlaybackBackend(
          startPlayback: startPlayback,
          stopPlayback: stopPlayback,
          getCurrentPosition: getCurrentPosition,
        );

  NormalPlayerPlaybackGate.shared({
    required SharedPlaybackTransport transport,
    required PersistentPlaybackResolver resolver,
    required PlaybackRepository playbackRepo,
    required SavePlaybackStateUseCase savePlaybackState,
    required PlaybackUsageAccounting accounting,
  }) : _backend = _SharedTransportPlaybackBackend(
          transport: transport,
          resolver: resolver,
          playbackRepo: playbackRepo,
          savePlaybackState: savePlaybackState,
          accounting: accounting,
        );

  final _NormalPlayerPlaybackBackend _backend;

  Future<void> start({required String sessionId, required String contentId}) =>
      _backend.start(sessionId: sessionId, contentId: contentId);

  Future<PlaybackStopOutcome> pause({
    required String sessionId,
    required String contentId,
    required int position,
  }) =>
      _backend.pause(
          sessionId: sessionId, contentId: contentId, position: position);

  /// UI 起点の停止（seek / 速度変更 / AppBar back 等）。
  /// [position] を省略した場合は共有 audioHandler の現在位置を使う。
  Future<PlaybackStopOutcome> stopForSession({
    required String sessionId,
    required String contentId,
    int? position,
  }) =>
      _backend.stopForSession(
          sessionId: sessionId, contentId: contentId, position: position);

  /// tracker 主導の owner-retiring teardown 経路（live VM を再 read しない、D16）。
  /// shared 構成では `expectedOwner = np(sessionId)` で owner-gated な
  /// force-stop + resume fence を行い、別 owner が active なら何もしない。
  Future<PlaybackStopOutcome> teardownForSession({
    required String sessionId,
    required String contentId,
    required TeardownReason reason,
  }) =>
      _backend.teardownForSession(
          sessionId: sessionId, contentId: contentId, reason: reason);

  /// external / share entry 用の Playback Retirement Authority（v1.3 §6.3 B/C）。
  ///
  /// route 上の session ではなく、Transport が保持する authoritative な
  /// active playback を retire（stop + handoff fence）する。retire した target
  /// が Persistent なら、その target 自身の content へ停止位置を保存する
  /// （current route の別 content へは書かない）。never throws。
  Future<PlaybackStopOutcome> retireActiveForExternalEntry({
    required TeardownReason reason,
  }) =>
      _backend.retireActiveForExternalEntry(reason: reason);

  /// provider の ref.onDispose からのみ呼ぶ（R-7）。
  void dispose() => _backend.dispose();
}

abstract interface class _NormalPlayerPlaybackBackend {
  Future<void> start({required String sessionId, required String contentId});
  Future<PlaybackStopOutcome> pause({
    required String sessionId,
    required String contentId,
    required int position,
  });
  Future<PlaybackStopOutcome> stopForSession({
    required String sessionId,
    required String contentId,
    int? position,
  });
  Future<PlaybackStopOutcome> teardownForSession({
    required String sessionId,
    required String contentId,
    required TeardownReason reason,
  });
  Future<PlaybackStopOutcome> retireActiveForExternalEntry({
    required TeardownReason reason,
  });
  void dispose();
}

/// 旧 usecase 構成（Slice 3c で削除予定）。挙動は v1.2.22 と同一。
class _UseCasePlaybackBackend implements _NormalPlayerPlaybackBackend {
  _UseCasePlaybackBackend({
    required StartPlaybackUseCase startPlayback,
    required StopPlaybackUseCase stopPlayback,
    required int Function() getCurrentPosition,
  })  : _startPlayback = startPlayback,
        _stopPlayback = stopPlayback,
        _getCurrentPosition = getCurrentPosition;

  final StartPlaybackUseCase _startPlayback;
  final StopPlaybackUseCase _stopPlayback;
  // TtsAudioHandler（具象クラス）ではなく現在位置を返す関数を受け取る。
  // QuickListenViewModel の getCurrentPosition 注入と同じ方式（テスト容易性）。
  final int Function() _getCurrentPosition;

  Future<void> _chain = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final result = _chain.then((_) => op());
    // chain 自身は常に正常完了させ、1回の失敗で以後の直列化が壊れないようにする。
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<void> start({required String sessionId, required String contentId}) {
    return _enqueue(() => _startPlayback.execute(
          contentId,
          owner: PlaybackOwnerKey.normalPlayer(sessionId),
        ));
  }

  @override
  Future<PlaybackStopOutcome> pause({
    required String sessionId,
    required String contentId,
    required int position,
  }) {
    return _enqueue(() => _stopPlayback.pause(
          contentId,
          position,
          owner: PlaybackOwnerKey.normalPlayer(sessionId),
        ));
  }

  @override
  Future<PlaybackStopOutcome> stopForSession({
    required String sessionId,
    required String contentId,
    int? position,
  }) {
    return _enqueue(() => _stopPlayback.execute(
          contentId,
          position ?? _getCurrentPosition(),
          owner: PlaybackOwnerKey.normalPlayer(sessionId),
        ));
  }

  @override
  Future<PlaybackStopOutcome> teardownForSession({
    required String sessionId,
    required String contentId,
    required TeardownReason reason,
  }) =>
      stopForSession(sessionId: sessionId, contentId: contentId);

  /// 旧 usecase 構成は authoritative な playback owner を持たないため、
  /// external-entry retirement を提供しない（production は shared 構成のみ）。
  @override
  Future<PlaybackStopOutcome> retireActiveForExternalEntry({
    required TeardownReason reason,
  }) =>
      throw UnsupportedError(
          'external-entry retirement requires NormalPlayerPlaybackGate.shared');

  @override
  void dispose() => _startPlayback.dispose();
}

/// Shared Playback Transport 構成（production）。
class _SharedTransportPlaybackBackend implements _NormalPlayerPlaybackBackend {
  _SharedTransportPlaybackBackend({
    required SharedPlaybackTransport transport,
    required PersistentPlaybackResolver resolver,
    required PlaybackRepository playbackRepo,
    required SavePlaybackStateUseCase savePlaybackState,
    required PlaybackUsageAccounting accounting,
  })  : _transport = transport,
        _resolver = resolver,
        _playbackRepo = playbackRepo,
        _savePlaybackState = savePlaybackState,
        _accounting = accounting;

  final SharedPlaybackTransport _transport;
  final PersistentPlaybackResolver _resolver;
  final PlaybackRepository _playbackRepo;
  final SavePlaybackStateUseCase _savePlaybackState;
  final PlaybackUsageAccounting _accounting;

  PersistentPersistencePolicy _policyFor(String contentId) =>
      PersistentPersistencePolicy(
        target: PersistentTarget.ofRegisteredSessionContentId(contentId),
        playbackRepo: _playbackRepo,
        savePlaybackState: _savePlaybackState,
      );

  @override
  Future<void> start({required String sessionId, required String contentId}) {
    // 解決（DB 読込・status 更新）も NP/Transient 共通 chain 上で行う。
    return _transport.exclusive((ops) async {
      final request = await _resolver.resolveForStart(contentId);
      await ops.startUnlocked(
        PlaybackOwnerKey.normalPlayer(sessionId),
        request,
        accounting: _accounting,
        logFields: {'origin': 'player', 'contentId': contentId},
      );
    });
  }

  @override
  Future<PlaybackStopOutcome> pause({
    required String sessionId,
    required String contentId,
    required int position,
  }) =>
      _transport.exclusive((ops) async => _toStopOutcome(
            await ops.pauseUnlocked(PlaybackOwnerKey.normalPlayer(sessionId)),
            contentId: contentId,
            position: position,
          ));

  @override
  Future<PlaybackStopOutcome> stopForSession({
    required String sessionId,
    required String contentId,
    int? position,
  }) =>
      _transport.exclusive((ops) async => _toStopOutcome(
            await ops.stopUnlocked(PlaybackOwnerKey.normalPlayer(sessionId)),
            contentId: contentId,
            position: position,
          ));

  Future<PlaybackStopOutcome> _toStopOutcome(
    OwnedCommandResult result, {
    required String contentId,
    required int? position,
  }) async {
    switch (result) {
      case CommandIgnoredStaleOwner():
        // この session は TTS を所有していない。TTS・accounting・state・DB の
        // いずれにも触れない（別 owner の位置を自 content へ保存しない）。
        return PlaybackStopOutcome.notApplicable();
      case CommandApplied():
        final saved = await _policyFor(contentId)
            .persistStopPosition(position: position ?? result.positionAtStop);
        return PlaybackStopOutcome(
          ttsStopSucceeded: result.ttsSucceeded,
          usageFlushSucceeded: result.usageFlushSucceeded,
          positionSaveSucceeded: saved.succeeded,
          ttsStopErrorType: result.ttsErrorType,
          usageFlushErrorType: result.usageFlushErrorType,
          positionSaveErrorType: saved.errorType,
        );
    }
  }

  @override
  Future<PlaybackStopOutcome> teardownForSession({
    required String sessionId,
    required String contentId,
    required TeardownReason reason,
  }) =>
      _transport.exclusive((ops) async {
        final outcome = await ops.forceStopForTeardownUnlocked(
          expectedOwner: PlaybackOwnerKey.normalPlayer(sessionId),
          reason: reason,
          notificationDisposition: NotificationDisposition.handoff,
        );
        switch (outcome.application) {
          case TeardownApplication.noActivePlayback:
            return PlaybackStopOutcome.notApplicable();
          case TeardownApplication.ignoredStaleOwner:
            // D8/D16: ttsStopConfirmed == false となり route 除去は進まない。
            return PlaybackStopOutcome(
              ttsStopSucceeded: false,
              usageFlushSucceeded: true,
              positionSaveSucceeded: true,
              ttsStopErrorType: outcome.ttsStopErrorType,
            );
          case TeardownApplication.applied:
            final saved = await _policyFor(contentId)
                .persistStopPosition(position: outcome.positionAtStop);
            return PlaybackStopOutcome(
              ttsStopSucceeded: outcome.ttsStopSucceeded,
              usageFlushSucceeded: outcome.usageFlushSucceeded,
              positionSaveSucceeded: saved.succeeded,
              ttsStopErrorType: outcome.ttsStopErrorType,
              usageFlushErrorType: outcome.usageFlushErrorType,
              positionSaveErrorType: saved.errorType,
            );
        }
      });

  @override
  Future<PlaybackStopOutcome> retireActiveForExternalEntry({
    required TeardownReason reason,
  }) =>
      _transport.exclusive((ops) async {
        final retirement =
            await ops.retireActiveForExternalEntryUnlocked(reason: reason);
        if (!retirement.hadActivePlayback) {
          return PlaybackStopOutcome.notApplicable();
        }
        final stop = retirement.stopOutcome;
        // Persistent なら retire した target 自身へ保存（AC-22）。Transient は非該当。
        final PositionSaveResult saved = switch (retirement.retiredTarget) {
          PersistentTarget target => await PersistentPersistencePolicy(
              target: target,
              playbackRepo: _playbackRepo,
              savePlaybackState: _savePlaybackState,
            ).persistStopPosition(position: stop.positionAtStop),
          TransientTarget() || null => const PositionSaveResult.notApplicable(),
        };
        return PlaybackStopOutcome(
          ttsStopSucceeded: stop.ttsStopSucceeded,
          usageFlushSucceeded: stop.usageFlushSucceeded,
          positionSaveSucceeded: saved.succeeded,
          ttsStopErrorType: stop.ttsStopErrorType,
          usageFlushErrorType: stop.usageFlushErrorType,
          positionSaveErrorType: saved.errorType,
        );
      });

  // Transport は app-shared provider の所有物。gate からは破棄しない。
  @override
  void dispose() {}
}

/// Normal Player の session 権威モデル（Canonical Design v0.4.1）。
///
/// 保持するのは current registration 1件のみ。effect eligibility
/// （新しい副作用を開始してよいか）と navigation registration（除去対象の
/// 特定）は別の概念として扱う（D6）。
class NormalPlayerSessionTracker {
  NormalPlayerSessionTracker({required NormalPlayerPlaybackGate playbackGate})
      : _playbackGate = playbackGate;

  final NormalPlayerPlaybackGate _playbackGate;

  _Registration? _current;
  int _claimSeq = 0;

  /// 同一 session の stop が同時に複数 flow から要求された場合、後続 flow は
  /// 「unknown/unconfirmed」を返さず、先行 stop と同じ Future を共有して
  /// 同じ構造化結果を観測する（RA-NPR-P04-R1 DC-01）。
  final Map<String, Future<PlaybackStopOutcome>> _inFlightStops = {};

  NormalPlayerSession? get currentSession => _current?.session;

  @visibleForTesting
  bool get hasActiveRegistrationForTest => _current != null;

  @visibleForTesting
  int get retirementClaimCountForTest => _current?.retirementClaims.length ?? 0;

  /// 唯一の identity 述語。registration が一致し、かつ retiring でないときのみ true。
  bool isEffectCurrent(String sessionId) {
    final reg = _current;
    return reg != null && reg.session.id == sessionId && !reg.isRetiring;
  }

  /// 3経路すべてで push/pushReplacement より前に呼ぶ。
  ///
  /// [replacingOrigin] が非 null の場合、その origin が effect-current でなければ
  /// 登録を拒否して null を返す（retiring 中の Player が新しい Player を
  /// register できないようにする。REQ-034 経路が使う）。
  PlayerRegistrationToken? register({
    required NormalPlayerSession session,
    required Route<dynamic> route,
    PlayerOriginToken? replacingOrigin,
  }) {
    if (replacingOrigin != null &&
        !isEffectCurrent(replacingOrigin.sessionId)) {
      unawaited(DebugLogger.instance
          .logEvent('navigation_player_registration_refused', {
        'attemptedSessionId': session.id,
        'replacingSessionId': replacingOrigin.sessionId,
        'reason': 'origin_not_effect_current',
      }));
      return null;
    }
    final previous = _current;
    _current = _Registration(session: session, route: route);
    unawaited(
        DebugLogger.instance.logEvent('navigation_player_session_registered', {
      'sessionId': session.id,
      'contentId': session.contentId,
    }));
    return PlayerRegistrationToken._(
        session: session, route: route, previous: previous);
  }

  /// Navigator 操作が同期的に失敗した場合に呼ぶ。identity-safe: この token が
  /// 作った registration がまだ current の場合のみ、直前の registration へ
  /// 正確に復元する（null へ blind clear しない）。
  void abortRegistration(PlayerRegistrationToken token) {
    final cur = _current;
    if (cur == null ||
        !identical(cur.route, token.route) ||
        cur.session.id != token.session.id) {
      return; // 既に別の registration が current。安全に no-op。
    }
    _current = token._previous;
    unawaited(DebugLogger.instance
        .logEvent('navigation_player_registration_rolled_back', {
      'sessionId': token.session.id,
      'restoredPreviousSessionId': token._previous?.session.id,
    }));
  }

  /// push/pushReplacement の returned Future completion で呼ぶ。
  /// identity-safe: 完了した route が今も tracked route である場合のみ clear。
  void clearIfCurrent(Route<dynamic> route) {
    final cur = _current;
    if (cur == null || !identical(cur.route, route)) return;
    final sessionId = cur.session.id;
    _current = null;
    unawaited(
        DebugLogger.instance.logEvent('navigation_player_session_cleared', {
      'sessionId': sessionId,
      'cause': 'route_completed',
    }));
  }

  void registerOwnedOverlay(String sessionId, Route<dynamic> overlay) {
    final cur = _current;
    if (cur != null && cur.session.id == sessionId) cur.addOverlay(overlay);
  }

  void unregisterOwnedOverlay(String sessionId, Route<dynamic> overlay) {
    final cur = _current;
    if (cur != null && cur.session.id == sessionId) cur.removeOverlay(overlay);
  }

  /// 【第1相 / async / Navigator に触れない】
  /// 最初の await より前に、同期的に current registration を capture して
  /// unique claim を追加する（Player を即座に effect-ineligible にする）。
  /// 停止は playback gate 経由で行う。**never throws**。
  ///
  /// Shared Player Core: 停止は owner-retiring teardown（[reason]）として
  /// `expectedOwner = np(sessionId)` で行い、stop 後に resume state を fence する。
  Future<PlayerRemovalTicket> prepareForRemoval({
    required String flowId,
    TeardownReason reason = TeardownReason.shareTeardown,
  }) async {
    final reg = _current;
    if (reg == null) {
      return PlayerRemovalTicket.empty(flowId: flowId);
    }
    final sessionId = reg.session.id;
    final contentId = reg.session.contentId;
    final claimId = 'claim-$sessionId-${++_claimSeq}';
    final wasActive = !reg.isRetiring;
    reg.retirementClaims.add(claimId); // ★ 同期。この行以降 A は effect-ineligible。

    unawaited(DebugLogger.instance.logEvent(
      wasActive
          ? 'navigation_player_session_retiring'
          : 'navigation_player_retirement_claim_added',
      {
        'sessionId': sessionId,
        'contentId': contentId,
        'flowId': flowId,
        'claimCount': reg.retirementClaims.length,
      },
    ));

    final shared = _inFlightStops.containsKey(sessionId);
    unawaited(
        DebugLogger.instance.logEvent('navigation_player_stop_requested', {
      'sessionId': sessionId,
      'flowId': flowId,
      'shared': shared,
    }));

    final stopFuture = _inFlightStops.putIfAbsent(sessionId, () {
      final future = _playbackGate.teardownForSession(
          sessionId: sessionId, contentId: contentId, reason: reason);
      future.whenComplete(() {
        if (identical(_inFlightStops[sessionId], future)) {
          _inFlightStops.remove(sessionId);
        }
      });
      return future;
    });

    PlaybackStopOutcome outcome;
    try {
      outcome = await stopFuture;
    } catch (e) {
      // gate.stopForSession() は never-throw 契約だが、防御的に最悪の場合を扱う。
      outcome = PlaybackStopOutcome(
        ttsStopSucceeded: false,
        usageFlushSucceeded: false,
        positionSaveSucceeded: false,
        ttsStopErrorType: e.runtimeType.toString(),
      );
    }

    unawaited(
        DebugLogger.instance.logEvent('navigation_player_stop_completed', {
      'sessionId': sessionId,
      'flowId': flowId,
      'ttsStopSucceeded': outcome.ttsStopSucceeded,
      'usageFlushSucceeded': outcome.usageFlushSucceeded,
      'positionSaveSucceeded': outcome.positionSaveSucceeded,
    }));
    if (!outcome.ttsStopConfirmed) {
      unawaited(DebugLogger.instance.logEvent('player_stop_failed', {
        'sessionId': sessionId,
        'flowId': flowId,
        'errorType': outcome.ttsStopErrorType,
      }));
    }

    return PlayerRemovalTicket.forSession(
      sessionId: sessionId,
      contentId: contentId,
      claimId: claimId,
      flowId: flowId,
      stopOutcome: outcome,
    );
  }

  /// 【external / share entry 第1相 / async / Navigator に触れない】
  /// v1.3 FINAL §6.3 C / INV-T11: Route Retirement と Playback Retirement を分離する。
  ///
  /// 1. 最初の await より前に current route registration（あれば）を同期 claim し、
  ///    effect-ineligible にする（route owner は playback owner と一致しなくてよい）。
  /// 2. playback gate 経由で Transport の authoritative active playback を retire
  ///    （stop + handoff fence、Persistent なら retire した target 自身へ位置保存）。
  ///
  /// 返す ticket の stopOutcome は **実 active playback** の停止結果であり、route
  /// owner と playback owner の不一致そのものは block 条件にならない。
  /// route が無い場合も stopOutcome を持つ（claim は無い）。**never throws**。
  Future<PlayerRemovalTicket> prepareForExternalEntry({
    required String flowId,
    required TeardownReason reason,
  }) async {
    final reg = _current;
    final sessionId = reg?.session.id;
    final contentId = reg?.session.contentId;
    String? claimId;
    if (reg != null) {
      claimId = 'claim-$sessionId-${++_claimSeq}';
      final wasActive = !reg.isRetiring;
      reg.retirementClaims
          .add(claimId); // ★ 同期。この行以降 route は effect-ineligible。
      unawaited(DebugLogger.instance.logEvent(
        wasActive
            ? 'navigation_player_session_retiring'
            : 'navigation_player_retirement_claim_added',
        {
          'sessionId': sessionId,
          'contentId': contentId,
          'flowId': flowId,
          'claimCount': reg.retirementClaims.length,
        },
      ));
    }

    unawaited(DebugLogger.instance
        .logEvent('navigation_active_playback_retire_requested', {
      'routeSessionId': sessionId,
      'flowId': flowId,
    }));

    PlaybackStopOutcome outcome;
    try {
      outcome =
          await _playbackGate.retireActiveForExternalEntry(reason: reason);
    } catch (e) {
      // gate は never-throw 契約だが、防御的に最悪の場合を扱う（blind stop へは
      // fallback しない）。
      outcome = PlaybackStopOutcome(
        ttsStopSucceeded: false,
        usageFlushSucceeded: false,
        positionSaveSucceeded: false,
        ttsStopErrorType: e.runtimeType.toString(),
      );
    }

    unawaited(DebugLogger.instance
        .logEvent('navigation_active_playback_retire_completed', {
      'routeSessionId': sessionId,
      'flowId': flowId,
      'applicable': outcome.applicable,
      'ttsStopSucceeded': outcome.ttsStopSucceeded,
      'usageFlushSucceeded': outcome.usageFlushSucceeded,
      'positionSaveSucceeded': outcome.positionSaveSucceeded,
    }));
    if (!outcome.ttsStopConfirmed) {
      unawaited(DebugLogger.instance.logEvent('player_stop_failed', {
        'sessionId': sessionId,
        'flowId': flowId,
        'errorType': outcome.ttsStopErrorType,
      }));
    }

    if (reg == null) {
      return PlayerRemovalTicket.empty(flowId: flowId, stopOutcome: outcome);
    }
    return PlayerRemovalTicket.forSession(
      sessionId: sessionId!,
      contentId: contentId!,
      claimId: claimId!,
      flowId: flowId,
      stopOutcome: outcome,
    );
  }

  /// 同期・冪等・identity-safe。自分の claim だけを外す。他の claim が
  /// 残っている限り effect-active へは戻さない。registration が既に消えて
  /// いる、または別 session のものになっている場合は no-op。
  void abandonRemoval(PlayerRemovalTicket ticket) {
    final claimId = ticket.claimId;
    final sessionId = ticket.sessionId;
    if (claimId == null || sessionId == null) return;
    final reg = _current;
    if (reg == null || reg.session.id != sessionId) {
      return; // identity-safe no-op
    }
    final removed = reg.retirementClaims.remove(claimId);
    if (!removed) return; // 既に消費済み（二重 abandon）
    if (reg.retirementClaims.isEmpty) {
      unawaited(DebugLogger.instance
          .logEvent('navigation_player_retirement_abandoned', {
        'sessionId': sessionId,
        'flowId': ticket.flowId,
        'restoredToActive': true,
      }));
    } else {
      unawaited(DebugLogger.instance
          .logEvent('navigation_player_retirement_claim_released', {
        'sessionId': sessionId,
        'flowId': ticket.flowId,
        'remainingClaims': reg.retirementClaims.length,
      }));
    }
  }

  /// 【完全同期 / Navigator のみ】D7 の3分岐契約。
  /// branch 1: registration なし、または session 不一致 → no-op
  /// branch 2: tracked route が inactive → identity-safe clear のみ
  /// branch 3: active → owned overlay を上から除去 → tracked route を除去 → 同期 clear
  void removeActivePlayerNow(PlayerRemovalTicket ticket,
      {required BuildContext context}) {
    final reg = _current;
    final sessionId = ticket.sessionId;
    if (sessionId == null || reg == null || reg.session.id != sessionId) {
      unawaited(
          DebugLogger.instance.logEvent('navigation_player_remove_requested', {
        'sessionId': sessionId,
        'flowId': ticket.flowId,
        'branch': 'none',
      }));
      return; // branch 1
    }
    if (!ticket.stopOutcome.ttsStopConfirmed) {
      // D16 の defense-in-depth: TTS-stop が確認できていない ticket では、
      // 呼び出し側が D8 step 4 の gate を実装し忘れていても除去しない。
      unawaited(
          DebugLogger.instance.logEvent('navigation_player_remove_requested', {
        'sessionId': sessionId,
        'flowId': ticket.flowId,
        'branch': 'blocked_stop_unconfirmed',
      }));
      return;
    }
    if (!reg.route.isActive) {
      _current = null;
      unawaited(
          DebugLogger.instance.logEvent('navigation_player_remove_requested', {
        'sessionId': sessionId,
        'flowId': ticket.flowId,
        'branch': 'inactive',
      }));
      unawaited(
          DebugLogger.instance.logEvent('navigation_player_remove_completed', {
        'sessionId': sessionId,
        'flowId': ticket.flowId,
      }));
      return; // branch 2
    }
    // branch 3
    unawaited(
        DebugLogger.instance.logEvent('navigation_player_remove_requested', {
      'sessionId': sessionId,
      'flowId': ticket.flowId,
      'branch': 'active',
      'overlayCount': reg.ownedOverlays.length,
    }));
    final navigator = Navigator.of(context);
    for (final overlay in reg.overlaysTopFirst) {
      if (overlay.isActive) navigator.removeRoute(overlay);
    }
    navigator.removeRoute(reg.route);
    _current = null; // 同期 clear
    unawaited(
        DebugLogger.instance.logEvent('navigation_player_remove_completed', {
      'sessionId': sessionId,
      'flowId': ticket.flowId,
    }));
  }
}
