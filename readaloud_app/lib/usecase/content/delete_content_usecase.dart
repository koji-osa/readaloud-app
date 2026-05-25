import '../../repository/content_repository.dart';

class DeleteContentUseCase {
  final ContentRepository _repository;

  DeleteContentUseCase(this._repository);

  Future<void> execute(String id) async {
    final existing = await _repository.getById(id);
    if (existing == null) throw Exception('コンテンツが見つかりません: $id');
    await _repository.delete(id);
  }
}
