import '../../model/content.dart';
import '../../db/dao/content_dao.dart';
import '../content_repository.dart';

// TODO: Firebase同期を追加する
// 同期対象: contents（body含む）
// 同期タイミング: 追加・削除時・アプリ起動時
class ContentRepositoryImpl implements ContentRepository {
  final ContentDao _dao = ContentDao();

  @override
  Future<List<Content>> getAll() => _dao.getAll();

  @override
  Future<List<Content>> getByStatus(String status) =>
      _dao.getByStatus(status);

  @override
  Future<Content?> getById(String id) => _dao.getById(id);

  @override
  Future<void> save(Content content) => _dao.insert(content);

  @override
  Future<void> update(Content content) => _dao.update(content);

  @override
  Future<void> delete(String id) => _dao.delete(id);
}
