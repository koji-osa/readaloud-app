import '../../repository/playback_repository.dart';
import '../../model/playback_state.dart';

class SetAbRepeatUseCase {
  final PlaybackRepository _repository;

  SetAbRepeatUseCase(this._repository);

  // A-Bリピートを設定
  Future<void> execute({
    required String contentId,
    required int start,
    required int end,
  }) async {
    assert(start < end, 'A-Bリピートの開始位置は終了位置より前にしてください');

    final existing = await _repository.getByContentId(contentId) ??
        PlaybackState(contentId: contentId);

    final updated = existing.copyWith(
      repeatStart: start,
      repeatEnd: end,
    );
    await _repository.save(updated);
  }

  // A-Bリピートを解除
  Future<void> clear(String contentId) async {
    await _repository.resetAbRepeat(contentId);
  }
}
