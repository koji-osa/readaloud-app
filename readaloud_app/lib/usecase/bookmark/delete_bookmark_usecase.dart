import '../../repository/bookmark_repository.dart';

class DeleteBookmarkUseCase {
  final BookmarkRepository _repository;

  DeleteBookmarkUseCase(this._repository);

  Future<void> execute(String id) async {
    await _repository.delete(id);
  }
}
