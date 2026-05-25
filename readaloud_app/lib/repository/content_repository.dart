import '../model/content.dart';

abstract class ContentRepository {
  Future<List<Content>> getAll();
  Future<List<Content>> getByStatus(String status);
  Future<Content?> getById(String id);
  Future<void> save(Content content);
  Future<void> update(Content content);
  Future<void> delete(String id);
}
