import '../model/playback_state.dart';

abstract class PlaybackRepository {
  Future<PlaybackState?> getByContentId(String contentId);
  Future<void> save(PlaybackState state);
  Future<void> resetAbRepeat(String contentId);
  Future<void> resetAllAbRepeat();
  Future<void> delete(String contentId);
}
