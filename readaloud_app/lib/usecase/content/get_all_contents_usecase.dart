import '../../model/content.dart';
import '../../repository/content_repository.dart';

class GetAllContentsUseCase {
  final ContentRepository _repository;

  GetAllContentsUseCase(this._repository);

  Future<List<Content>> execute() => _repository.getAll();

  Future<List<Content>> executeByStatus(String status) =>
      _repository.getByStatus(status);
}
