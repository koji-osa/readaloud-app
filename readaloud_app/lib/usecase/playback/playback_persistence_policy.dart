import '../../model/playback_request.dart';
import '../../repository/playback_repository.dart';
import 'save_playback_state_usecase.dart';

/// Persistent でだけ意味を持つ再生副作用（Detailed Design v1.2 FINAL §7.3）。
///
/// 主たる安全性は「Transient 側の依存グラフに write-capable repository が
/// 存在しないこと」であり、no-op の [TransientPersistencePolicy] はその補助。
abstract interface class PlaybackPersistencePolicy {
  Future<PositionSaveResult> persistStopPosition({required int position});
  Future<void> persistPosition({
    required int position,
    required double progressPct,
  });
  Future<void> persistVoiceParams({
    required int position,
    required double progressPct,
    double? speed,
    String? voiceId,
    double? pitch,
    double? volume,
  });
}

final class PositionSaveResult {
  const PositionSaveResult({required this.succeeded, this.errorType});
  const PositionSaveResult.notApplicable()
      : succeeded = true,
        errorType = null;

  final bool succeeded;
  final String? errorType;
}

/// Transient 用。フィールド・依存・引数を持たない。
final class TransientPersistencePolicy implements PlaybackPersistencePolicy {
  const TransientPersistencePolicy();

  @override
  Future<PositionSaveResult> persistStopPosition(
          {required int position}) async =>
      const PositionSaveResult.notApplicable();

  @override
  Future<void> persistPosition({
    required int position,
    required double progressPct,
  }) async {}

  @override
  Future<void> persistVoiceParams({
    required int position,
    required double progressPct,
    double? speed,
    String? voiceId,
    double? pitch,
    double? volume,
  }) async {}
}

/// Normal Player（Library Content）用。
final class PersistentPersistencePolicy implements PlaybackPersistencePolicy {
  PersistentPersistencePolicy({
    required PersistentTarget target,
    // 停止位置の保存は SavePlaybackStateUseCase.executeStop へ移ったため未使用。
    // 生成箇所（stop_playback_usecase / tracker / テスト）を変えないよう、
    // constructor のシグネチャは維持している。
    required PlaybackRepository playbackRepo,
    required SavePlaybackStateUseCase savePlaybackState,
  })  : _target = target,
        _saveState = savePlaybackState;

  final PersistentTarget _target;
  final SavePlaybackStateUseCase _saveState;

  /// 旧 `StopPlaybackUseCase._runStopSequence` step 3（位置保存）。
  /// 進捗率は停止位置と現在の本文長から [SavePlaybackStateUseCase.executeStop] が
  /// 計算する（旧実装の「保存済み進捗率からの総文字数の逆算」は廃止）。
  /// 例外は投げず、結果を [PositionSaveResult] で返す（B-01 の独立性を維持）。
  @override
  Future<PositionSaveResult> persistStopPosition(
      {required int position}) async {
    try {
      await _saveState.executeStop(
        contentId: _target.contentId,
        position: position,
      );
      return const PositionSaveResult(succeeded: true);
    } catch (e) {
      return PositionSaveResult(
          succeeded: false, errorType: e.runtimeType.toString());
    }
  }

  @override
  Future<void> persistPosition({
    required int position,
    required double progressPct,
  }) =>
      _saveState.execute(
        contentId: _target.contentId,
        position: position,
        progressPct: progressPct,
      );

  @override
  Future<void> persistVoiceParams({
    required int position,
    required double progressPct,
    double? speed,
    String? voiceId,
    double? pitch,
    double? volume,
  }) =>
      _saveState.execute(
        contentId: _target.contentId,
        position: position,
        progressPct: progressPct,
        speed: speed,
        voiceId: voiceId,
        pitch: pitch,
        volume: volume,
      );
}
