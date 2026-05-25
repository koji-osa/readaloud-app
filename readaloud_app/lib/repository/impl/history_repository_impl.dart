import '../../model/history.dart';
import '../../db/dao/history_dao.dart';
import '../history_repository.dart';

class HistoryRepositoryImpl implements HistoryRepository {
  final HistoryDao _dao = HistoryDao();

  @override
  Future<List<History>> getAll() => _dao.getAll();

  @override
  Future<void> save(History history) => _dao.insertOrUpdate(history);

  @override
  Future<void> delete(String id) => _dao.delete(id);
}
