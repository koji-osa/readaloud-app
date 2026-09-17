import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/playback_request.dart';
import '../providers.dart';
import '../usecase/playback/shared_playback_transport.dart';
import 'debug_logger.dart';
import 'normal_player_session_tracker.dart';
import 'quick_listen_route_tracker.dart';

/// Player entry の単一入口（Slice 6）。
/// Pre-Commit M-1: route tracker（UI 依存）を使うため providers.dart ではなく
/// ここで定義する（providers.dart → UI の依存を作らない）。
final playerEntryCoordinatorProvider = Provider<PlayerEntryCoordinator>((ref) {
  return PlayerEntryCoordinator(
    normalPlayerTracker: ref.read(normalPlayerSessionTrackerProvider),
    transientRouteTracker: ref.read(quickListenRouteTrackerProvider),
    retireActiveTransient: ({required TeardownReason reason}) =>
        ref.read(quickListenViewModelProvider.notifier).close(reason: reason),
  );
});

/// share 経路とアプリ内 Source entry が同一手順・同一 tracker を通る単一入口
/// （Detailed Design v1.2 FINAL §15 Slice 6 / INV-T4）。
///
/// 旧 `main.dart._handleSharedPayload` の D8 二相 teardown を抽出したもの。
/// v1.3 FINAL（PC-1 / INV-T11）で Route Retirement と Playback Retirement を分離:
/// 1. current NP route を最初の await より前に同期 claim
/// 2. Transport の authoritative active playback を retire（stop + handoff fence。
///    Persistent なら retire した target 自身へ位置保存）
/// 3. TTS stop が確認できなければ covering entry を block（claim は finally で解放）
/// 4. Transient session state を identity-safe に cleanup → liveness checkpoint
/// 5. Transient route 除去 → claim 済み NP route 除去 → zero-await で covering push
/// route owner と playback owner の不一致そのものは block 条件にしない。
/// blind global stop へは fallback しない。
class PlayerEntryCoordinator {
  PlayerEntryCoordinator({
    required NormalPlayerSessionTracker normalPlayerTracker,
    required QuickListenRouteTracker transientRouteTracker,
    required Future<void> Function({required TeardownReason reason})
        retireActiveTransient,
  })  : _normalPlayerTracker = normalPlayerTracker,
        _transientRouteTracker = transientRouteTracker,
        _retireActiveTransient = retireActiveTransient;

  final NormalPlayerSessionTracker _normalPlayerTracker;
  final QuickListenRouteTracker _transientRouteTracker;
  final Future<void> Function({required TeardownReason reason})
      _retireActiveTransient;

  QuickListenRouteTracker get transientRouteTracker => _transientRouteTracker;

  /// 現在の Player（NP / Transient）を retire・除去して、[pushCovering] で
  /// 新しい covering route を push する。
  ///
  /// [isMounted] は呼び出し元 `State.mounted` と同じ意味位置（Transient retire
  /// 直後、route 除去前）で評価する。[pushCovering] は同期で push すること。
  Future<void> openCovering({
    required BuildContext context,
    required bool Function() isMounted,
    required String flowId,
    required TeardownReason reason,
    required void Function(BuildContext context) pushCovering,
  }) async {
    final tracker = _normalPlayerTracker;

    // v0.4.1 D8 step 2 / v1.3 §6.3 C: 最初のawaitより前に current route を同期
    // claim し、Transport の authoritative active playback を retire する
    // （never throws。stop完了より前にroute除去しない）。
    unawaited(DebugLogger.instance
        .logEvent('player_stop_requested', {'flowId': flowId}));
    final ticket =
        await tracker.prepareForExternalEntry(flowId: flowId, reason: reason);
    unawaited(DebugLogger.instance
        .logEvent('player_stop_completed', {'flowId': flowId}));

    try {
      // v0.4.1 D8 step 4 / B-01 closure: 実 active playback の TTS-stop が確認
      // できない場合は、route を除去せず covering route も push せずに return
      // する（route の有無に関わらない）。accounting/position-save 失敗だけなら
      // ここには引っかからない（ticket.stopOutcome.ttsStopConfirmed）。
      if (!ticket.stopOutcome.ttsStopConfirmed) {
        unawaited(DebugLogger.instance.logEvent('error', {
          'context': 'handle_shared_payload_tts_stop_unconfirmed',
          'flowId': flowId,
        }));
        return;
      }

      // Transient 再生が裏で継続していると単一の TtsAudioHandler を取り合う
      // ため、新しい entry を処理する前に owner-safe に retire しておく
      // （stop + handoff fence。別 owner がactiveなら何もしない）。
      unawaited(DebugLogger.instance
          .logEvent('quick_listen_close_requested', {'flowId': flowId}));
      await _retireActiveTransient(reason: reason);
      unawaited(DebugLogger.instance
          .logEvent('quick_listen_close_completed', {'flowId': flowId}));

      // 呼び出し元 State.mounted と同じ意味位置の liveness checkpoint。
      // （context.mounted は同じ Element の生存判定で、analyzer に guard を示す）
      if (!isMounted() || !context.mounted) {
        unawaited(DebugLogger.instance.logEvent('error', {
          'context': 'handle_shared_payload_not_mounted',
          'flowId': flowId,
        }));
        return;
      }

      // 直前のQuickListen routeがNavigator stack上に残っていれば、
      // ここで対象routeだけを除去する（payload種別に関わらず必ず呼ぶ）。
      _transientRouteTracker.removeActiveQuickListen(
        context: context,
        flowId: flowId,
      );

      // v0.4.1: Normal Player route除去の権威ある唯一の場所。
      // ここから次のcovering route pushまでの間にawaitを置かない
      // （NRR-08 / zero-await guarantee）。
      tracker.removeActivePlayerNow(ticket, context: context);

      pushCovering(context);
    } catch (e) {
      // No.94 Observability: 例外は握りつぶさず、ログだけ追加してrethrowする。
      unawaited(DebugLogger.instance.logEvent('share_pipeline_error', {
        'stage': 'payload_handler',
        'flowId': flowId,
        'errorType': e.runtimeType.toString(),
      }));
      rethrow;
    } finally {
      // v0.4.1 D8 step 11: 同期・冪等・identity-safe。自flowのclaimだけを外す。
      tracker.abandonRemoval(ticket);
    }
  }

  /// 解決済み Transient [request] を開く（share 経路・将来の Source entry 共通）。
  Future<void> openTransient({
    required BuildContext context,
    required bool Function() isMounted,
    required PlaybackRequest request,
    required String flowId,
    required TeardownReason reason,
  }) =>
      openCovering(
        context: context,
        isMounted: isMounted,
        flowId: flowId,
        reason: reason,
        pushCovering: (ctx) => _transientRouteTracker.openTransient(
          context: ctx,
          request: request,
          flowId: flowId,
        ),
      );
}
