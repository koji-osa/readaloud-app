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

  Future<void> execute(String contentId, int currentPosition) async {
    // TTS使用量カウント停止・端数を保存
    await _countUsage.stopCounting(contentId);

    // 再生停止
    await _ttsService.stop();

    // 再生位置を保存
    final existing = await _playbackRepo.getByContentId(contentId) ??
        PlaybackState(contentId: contentId);
    final totalChars = existing.progressPct > 0
        ? (currentPosition / (existing.progressPct / 100)).round()
        : 1;
    final progressPct = (currentPosition / totalChars * 100).clamp(0.0, 100.0);

    await _saveState.execute(
      contentId: contentId,
      position: currentPosition,
      progressPct: progressPct,
    );
  }

  Future<void> pause(String contentId, int currentPosition) async {
    // TTS使用量カウント一時停止・端数を保存
    await _countUsage.stopCounting(contentId);

    // 一時停止
    await _ttsService.pause();

    // 再生位置を保存
    final existing = await _playbackRepo.getByContentId(contentId) ??
        PlaybackState(contentId: contentId);
    final totalChars = existing.progressPct > 0
        ? (currentPosition / (existing.progressPct / 100)).round()
        : 1;
    final progressPct = (currentPosition / totalChars * 100).clamp(0.0, 100.0);

    await _saveState.execute(
      contentId: contentId,
      position: currentPosition,
      progressPct: progressPct,
    );
  }
}
