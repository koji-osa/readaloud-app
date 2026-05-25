import '../../model/bookmark.dart';
import '../../db/dao/bookmark_dao.dart';
import '../bookmark_repository.dart';

// TODO: Firebase同期を追加する
// 同期対象: bookmarks 全カラム
// 同期タイミング: 追加・削除時・アプリ起動時
class BookmarkRepositoryImpl implements BookmarkRepository {
  final BookmarkDao _dao = BookmarkDao();

  @override
  Future<List<Bookmark>> getByContentId(String contentId) =>
      _dao.getByContentId(contentId);

  @override
  Future<void> save(Bookmark bookmark) => _dao.insert(bookmark);

  @override
  Future<void> delete(String id) => _dao.delete(id);
}
