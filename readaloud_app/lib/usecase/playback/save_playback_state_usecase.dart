import '../../model/playback_state.dart';
import '../../repository/playback_repository.dart';
import '../../repository/content_repository.dart';

class SavePlaybackStateUseCase {
  final PlaybackRepository _playbackRepo;
  final ContentRepository _contentRepo;

  SavePlaybackStateUseCase({
    required PlaybackRepository playbackRepo,
    required ContentRepository contentRepo,
  })  : _playbackRepo = playbackRepo,
        _contentRepo = contentRepo;

  Future<void> execute({
    required String contentId,
    required int position,
    required double progressPct,
    double? speed,
    String? voiceId,
    double? pitch,
    double? volume,
  }) async {
    final existing = await _playbackRepo.getByContentId(contentId) ??
        PlaybackState(contentId: contentId);

    final updated = existing.copyWith(
      position: position,
      progressPct: progressPct,
      speed: speed,
      voiceId: voiceId,
      pitch: pitch,
      volume: volume,
      lastPlayedAt: DateTime.now().millisecondsSinceEpoch,
    );

    await _playbackRepo.save(updated);

    // 進捗100%なら完了ステータスに更新
    if (progressPct >= 100.0) {
      final content = await _contentRepo.getById(contentId);
      if (content != null) {
        await _contentRepo.update(content.copyWith(status: 'completed'));
      }
    }
  }
}
