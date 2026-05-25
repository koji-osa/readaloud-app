import '../../model/playback_state.dart';
import '../../db/dao/playback_dao.dart';
import '../playback_repository.dart';

// TODO: Firebase同期を追加する
// 同期対象: position / speed / pitch / volume / voice_id
// 同期除外: repeat_start / repeat_end（一時設定のため）
// 同期タイミング: 再生終了時・バックグラウンド移行時
class PlaybackRepositoryImpl implements PlaybackRepository {
  final PlaybackDao _dao = PlaybackDao();

  @override
  Future<PlaybackState?> getByContentId(String contentId) =>
      _dao.getByContentId(contentId);

  @override
  Future<void> save(PlaybackState state) => _dao.insertOrUpdate(state);

  @override
  Future<void> resetAbRepeat(String contentId) =>
      _dao.resetAbRepeat(contentId);

  @override
  Future<void> resetAllAbRepeat() => _dao.resetAllAbRepeat();

  @override
  Future<void> delete(String contentId) => _dao.delete(contentId);
}
