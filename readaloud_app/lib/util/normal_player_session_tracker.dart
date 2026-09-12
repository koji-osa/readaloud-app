import 'dart:async';

import 'package:flutter/widgets.dart';

import '../model/normal_player_session.dart';
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

/// Normal Player の playback 遷移（start/pause/stop）を直列化する薄い gate。
///
/// navigation・dialog・AI workflow・Player UI state は一切所有しない（D12）。
/// 同一 session の in-flight stop は [NormalPlayerSessionTracker] 側でも
/// dedupe されるが、この gate 自身も start/stop/pause を単一 chain 上に
/// 直列化することで、A の遅延 stop が B の新しい start と交差する事故を防ぐ。
class NormalPlayerPlaybackGate {
  NormalPlayerPlaybackGate({
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

  Future<void> start({required String sessionId, required String contentId}) {
    return _enqueue(() => _startPlayback.execute(
          contentId,
          owner: PlaybackOwnerKey.normalPlayer(sessionId),
        ));
  }

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

  /// [position] を省略した場合は共有 audioHandler の現在位置を使う。
  /// tracker 主導の teardown 経路（live VM を再 read しない、D16）はこちらを使う。
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

  void dispose() => _startPlayback.dispose();
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
  Future<PlayerRemovalTicket> prepareForRemoval(
      {required String flowId}) async {
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
      final future = _playbackGate.stopForSession(
          sessionId: sessionId, contentId: contentId);
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
