import '../../model/playback_request.dart';
import '../../model/playback_state.dart';
import '../../repository/content_repository.dart';
import '../../repository/playback_repository.dart';

/// Content 行と既存 PlaybackState を読み、[PlaybackRequest] へ変換する
/// （DB 読込 + 開始時 status 更新）。旧 `StartPlaybackUseCase.execute` の
/// DB 部分（取得 → 既定値 → status in_progress）の逐語移設。
class PersistentPlaybackResolver {
  PersistentPlaybackResolver({
    required ContentRepository contentRepo,
    required PlaybackRepository playbackRepo,
  })  : _contentRepo = contentRepo,
        _playbackRepo = playbackRepo;

  final ContentRepository _contentRepo;
  final PlaybackRepository _playbackRepo;

  Future<PlaybackRequest> resolveForStart(String contentId) async {
    final content = await _contentRepo.getById(contentId);
    if (content == null) throw Exception('コンテンツが見つかりません: $contentId');

    // 再生状態を取得（なければ初期値で作成）
    final state = await _playbackRepo.getByContentId(contentId) ??
        PlaybackState(contentId: contentId);

    // コンテンツのステータスを「読書中」に更新
    await _contentRepo.update(
      content.copyWith(status: 'in_progress'),
    );

    return PlaybackRequest(
      target: PersistentTarget.of(content),
      text: content.body,
      title: content.title,
      startPosition: state.position,
      voice: PlaybackVoiceParams(
        speed: state.speed,
        pitch: state.pitch,
        volume: state.volume,
        voiceId: state.voiceId,
      ),
    );
  }
}
