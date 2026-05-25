import '../../repository/content_repository.dart';

class UpdateContentUseCase {
  final ContentRepository _repository;

  UpdateContentUseCase(this._repository);

  Future<void> execute({
    required String id,
    String? title,
    String? body,
    String? status,
  }) async {
    final existing = await _repository.getById(id);
    if (existing == null) throw Exception('コンテンツが見つかりません: $id');

    final updated = existing.copyWith(
      title: title,
      body: body,
      status: status,
    );
    await _repository.update(updated);
  }
}
