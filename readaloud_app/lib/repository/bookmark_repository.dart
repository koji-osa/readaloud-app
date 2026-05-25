import '../model/bookmark.dart';

abstract class BookmarkRepository {
  Future<List<Bookmark>> getByContentId(String contentId);
  Future<void> save(Bookmark bookmark);
  Future<void> delete(String id);
}
