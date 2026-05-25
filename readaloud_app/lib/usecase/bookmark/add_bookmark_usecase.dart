import '../../model/bookmark.dart';
import '../../repository/bookmark_repository.dart';

class AddBookmarkUseCase {
  final BookmarkRepository _repository;

  AddBookmarkUseCase(this._repository);

  Future<Bookmark> execute({
    required String contentId,
    required int position,
    String? label,
  }) async {
    final bookmark = Bookmark(
      contentId: contentId,
      position: position,
      label: label,
    );
    await _repository.save(bookmark);
    return bookmark;
  }
}
