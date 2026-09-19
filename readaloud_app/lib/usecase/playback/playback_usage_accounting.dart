import 'dart:async';

import '../../model/normal_player_session.dart';
import '../tts/count_tts_usage_usecase.dart';

/// usage flush の構造化結果。
final class UsageFlushResult {
  const UsageFlushResult.succeeded()
      : succeeded = true,
        errorType = null;
  const UsageFlushResult.failed(String this.errorType) : succeeded = false;
  const UsageFlushResult.notApplicable()
      : succeeded = true,
        errorType = null;

  final bool succeeded;
  final String? errorType;
}

/// user-visible TTS usage accounting の境界（Detailed Design v1.2 FINAL §7.2 / PD-1）。
///
/// Transport は session ごとに注入された実装を呼ぶだけで、mode 分岐を持たない。
///
/// [onPlaybackStopped] は `FutureOr` を返す。flush 対象を持たない実装
/// （[NoUsageAccounting]）が同期に完了した場合、Transport は await による
/// microtask 境界を挟まずに TTS stop へ進める（旧 Quick Listen の
/// 「置換時に同期的に TTS stop を要求する」タイミングを維持するため）。
abstract interface class PlaybackUsageAccounting {
  void onPlaybackStarted({
    required PlaybackOwnerKey owner,
    required int totalChars,
    required int startPosition,
  });
  void onPositionAdvanced(int position);
  FutureOr<UsageFlushResult> onPlaybackStopped(PlaybackOwnerKey owner);
  void onPlaybackAborted(PlaybackOwnerKey owner);
}

/// Transient 専用。フィールド・依存なし。user-visible な計量を一切行わない（PD-1）。
final class NoUsageAccounting implements PlaybackUsageAccounting {
  const NoUsageAccounting();

  @override
  void onPlaybackStarted({
    required PlaybackOwnerKey owner,
    required int totalChars,
    required int startPosition,
  }) {}

  @override
  void onPositionAdvanced(int position) {}

  @override
  UsageFlushResult onPlaybackStopped(PlaybackOwnerKey owner) =>
      const UsageFlushResult.notApplicable();

  @override
  void onPlaybackAborted(PlaybackOwnerKey owner) {}
}

/// Persistent 専用。app-shared な唯一の [CountTtsUsageUseCase] を包み、
/// 既存 counter へ同じ順序で委譲する。
final class PersistentUsageAccounting implements PlaybackUsageAccounting {
  PersistentUsageAccounting(this._counter);

  final CountTtsUsageUseCase _counter;

  @override
  void onPlaybackStarted({
    required PlaybackOwnerKey owner,
    required int totalChars,
    required int startPosition,
  }) =>
      _counter.startCounting(
        owner: owner,
        totalChars: totalChars,
        startPosition: startPosition,
      );

  @override
  void onPositionAdvanced(int position) => _counter.updatePosition(position);

  @override
  Future<UsageFlushResult> onPlaybackStopped(PlaybackOwnerKey owner) async {
    try {
      await _counter.stopCounting(owner);
      return const UsageFlushResult.succeeded();
    } catch (e) {
      return UsageFlushResult.failed(e.runtimeType.toString());
    }
  }

  @override
  void onPlaybackAborted(PlaybackOwnerKey owner) {
    // best-effort。例外は飲む（start 失敗 rollback の途中で二次障害にしない）。
    unawaited(_counter.stopCounting(owner).catchError((_) {}));
  }
}
