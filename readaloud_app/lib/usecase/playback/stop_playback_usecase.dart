import '../../model/normal_player_session.dart';
import '../../repository/playback_repository.dart';
import '../../repository/tts/tts_service.dart';
import '../../model/playback_state.dart';
import '../tts/count_tts_usage_usecase.dart';
import 'save_playback_state_usecase.dart';

class StopPlaybackUseCase {
  final PlaybackRepository _playbackRepo;
  final TtsService _ttsService;
  final CountTtsUsageUseCase _countUsage;
  final SavePlaybackStateUseCase _saveState;

  StopPlaybackUseCase({
    required PlaybackRepository playbackRepo,
    required TtsService ttsService,
    required CountTtsUsageUseCase countUsage,
    required SavePlaybackStateUseCase saveState,
  })  : _playbackRepo = playbackRepo,
        _ttsService = ttsService,
        _countUsage = countUsage,
        _saveState = saveState;

  /// TTS-stop を usage-accounting flush / playback-position save から独立させ、
  /// 各 sub-step の成否を個別に記録する（v0.4.1 D8/D12, RA-NPR-P04 B-01 closure）。
  ///
  /// accounting/persistence の例外が TTS-stop の実行そのものをスキップさせては
  /// ならない。3つの sub-step はそれぞれ独立した try/catch で分離され、いずれか
  /// 1つが失敗しても残りの sub-step は必ず試行される。
  Future<PlaybackStopOutcome> execute(
    String contentId,
    int currentPosition, {
    required PlaybackOwnerKey owner,
  }) =>
      _runStopSequence(
        contentId: contentId,
        currentPosition: currentPosition,
        owner: owner,
        stopTts: () => _ttsService.stop(),
      );

  Future<PlaybackStopOutcome> pause(
    String contentId,
    int currentPosition, {
    required PlaybackOwnerKey owner,
  }) =>
      _runStopSequence(
        contentId: contentId,
        currentPosition: currentPosition,
        owner: owner,
        stopTts: () => _ttsService.pause(),
      );

  Future<PlaybackStopOutcome> _runStopSequence({
    required String contentId,
    required int currentPosition,
    required PlaybackOwnerKey owner,
    required Future<void> Function() stopTts,
  }) async {
    // 1) usage accounting flush（他sub-stepから独立に試行する）
    bool usageOk = true;
    String? usageErr;
    try {
      await _countUsage.stopCounting(owner);
    } catch (e) {
      usageOk = false;
      usageErr = e.runtimeType.toString();
    }

    // 2) TTS停止は必ず試行する（accounting失敗の影響を受けない。B-01の核心）。
    bool ttsOk = true;
    String? ttsErr;
    try {
      await stopTts();
    } catch (e) {
      ttsOk = false;
      ttsErr = e.runtimeType.toString();
    }

    // 3) 再生位置保存も独立に試行する。
    bool posOk = true;
    String? posErr;
    try {
      final existing = await _playbackRepo.getByContentId(contentId) ??
          PlaybackState(contentId: contentId);
      final totalChars = existing.progressPct > 0
          ? (currentPosition / (existing.progressPct / 100)).round()
          : 1;
      final progressPct =
          (currentPosition / totalChars * 100).clamp(0.0, 100.0);
      await _saveState.execute(
        contentId: contentId,
        position: currentPosition,
        progressPct: progressPct,
      );
    } catch (e) {
      posOk = false;
      posErr = e.runtimeType.toString();
    }

    return PlaybackStopOutcome(
      ttsStopSucceeded: ttsOk,
      usageFlushSucceeded: usageOk,
      positionSaveSucceeded: posOk,
      ttsStopErrorType: ttsErr,
      usageFlushErrorType: usageErr,
      positionSaveErrorType: posErr,
    );
  }
}
