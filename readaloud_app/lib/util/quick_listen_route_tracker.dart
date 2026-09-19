import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/playback_request.dart';
import '../model/quick_listen_session.dart';
import '../ui/quick_listen/quick_listen_screen.dart';
import 'debug_logger.dart';

/// Transient route の追跡（Slice 6: main.dart の State field から app-shared
/// provider へ移し、share 経路とアプリ内 Source entry が同じ instance を見る）。
/// Pre-Commit M-1: UI に依存するため providers.dart ではなくここで定義する。
final quickListenRouteTrackerProvider =
    Provider<QuickListenRouteTracker>((ref) => QuickListenRouteTracker());

/// 新しいtext shareが届くたびに直前のQuickListen routeを追跡し、
/// Navigator stack上に残ったままにしない役割を持つ。
///
/// 従来はshare handlerがQuickListenViewModelをcloseするだけで、
/// 既存のQuickListenScreen route自体はpop/remove/replaceされなかった。
/// そのため新しいQuickListenScreenをpushしても直前のrouteがstackに残り続け、
/// 後発routeをcloseした際に、状態がリセットされた直前routeが空画面として
/// 再露出する不具合があった（quickListenViewModelProviderが.familyではない
/// シングルトンのため、複数routeが同一stateを共有してしまうことが根因）。
///
/// このクラスは、追跡している直前のQuickListen routeだけを`removeRoute()`で
/// 除去する。Home/Player/Settings/AddScreenなど無関係なrouteには一切触れない。
///
/// 除去自体は新しいtext shareに限らない。URL共有でAddScreenへ分岐する場合も
/// 「旧QuickListen routeが残ったまま」という同じ根因が起こりうるため、
/// 呼び出し元（main.dartの_handleSharedPayload）はpayload種別を判定する前に
/// 必ず[removeActiveQuickListen]を呼ぶ。
class QuickListenRouteTracker {
  Route<void>? _activeRoute;

  @visibleForTesting
  bool get hasActiveRouteForTest =>
      _activeRoute != null && _activeRoute!.isActive;

  /// 追跡中のQuickListen routeが残っていれば、そのrouteだけをremoveRoute()で
  /// 除去する。追跡中routeが無い、またはすでにpopされている場合は何もしない。
  ///
  /// 呼び出し元は、この呼び出しより前に
  /// `quickListenViewModelProvider.notifier.close()`をawait済みであること
  /// （TTS/使用量停止をroute操作より先に完了させ、autoDispose providerの
  /// 最後のwatcherがroute除去で先に消えることによる競合を避けるため）。
  void removeActiveQuickListen({
    required BuildContext context,
    required String flowId,
  }) {
    final previous = _activeRoute;
    if (previous == null || !previous.isActive) return;

    unawaited(DebugLogger.instance.logEvent('navigation_remove_requested', {
      'target': 'quick_listen_stale_route',
      'flowId': flowId,
    }));
    Navigator.of(context).removeRoute(previous);
    unawaited(DebugLogger.instance.logEvent('navigation_remove_completed', {
      'target': 'quick_listen_stale_route',
      'flowId': flowId,
    }));
    // removeRoute()はpush()が返したFutureを完了させるが、その.then()での
    // クリアは次のmicrotaskまで遅延する。ここで即座にクリアしておくことで、
    // 同じ呼び出し内で直後にopenQuickListen()が新しいrouteを積んでも、
    // 旧routeの遅延した.then()コールバックが新routeの追跡を誤って
    // nullに戻す競合を避ける。
    if (identical(_activeRoute, previous)) {
      _activeRoute = null;
    }
  }

  /// [text]を表示する新しいQuickListenScreenをpushする。
  ///
  /// 呼び出し元は、この呼び出しより前に[removeActiveQuickListen]で
  /// 旧routeの除去を済ませていること。
  ///
  /// Shared Player Core Slice 6: [openTransient] へ委譲する薄い互換 adapter。
  /// 共有 text は `QuickListenSession.fromSharedText` で TextCleaner を1回だけ
  /// 適用して request にする（INV-18）。
  @Deprecated('Use openTransient(request:) via PlayerEntryCoordinator')
  void openQuickListen({
    required BuildContext context,
    required String text,
    required String flowId,
  }) {
    openTransient(
      context: context,
      request: QuickListenSession.fromSharedText(text).request,
      flowId: flowId,
    );
  }

  /// 解決済みの Transient [request] を表示する新しい QuickListenScreen を push する。
  ///
  /// 呼び出し元は、この呼び出しより前に[removeActiveQuickListen]で
  /// 旧routeの除去を済ませていること（`PlayerEntryCoordinator` が保証する）。
  void openTransient({
    required BuildContext context,
    required PlaybackRequest request,
    required String flowId,
  }) {
    final navigator = Navigator.of(context);
    unawaited(DebugLogger.instance.logEvent('navigation_push_requested', {
      'target': 'quick_listen',
      'stackSource': 'share_handler',
      'flowId': flowId,
    }));
    final route = MaterialPageRoute<void>(
      builder: (_) => QuickListenScreen(initialRequest: request),
    );
    _activeRoute = route;
    unawaited(navigator.push(route).then((_) {
      if (identical(_activeRoute, route)) {
        _activeRoute = null;
      }
    }));

    // No.94 Observability: push直後ではなく最初のframe描画後に1回だけ、
    // このrouteが実際にNavigator stack上でcurrent/activeかどうかを記録する。
    // trueの場合だけでなくfalseの場合も必ず記録することで、cold-startで
    // route再露出が発生した場合の切り分け材料にする。既存のpush/pop
    // ロジック自体には一切影響しない（読み取り専用の観測のみ）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(DebugLogger.instance.logEvent('quick_listen_route_visibility', {
        'flowId': flowId,
        'isCurrent': route.isCurrent,
        'isActive': route.isActive,
      }));
    });
  }
}
