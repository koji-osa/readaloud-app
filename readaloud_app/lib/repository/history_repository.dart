import '../model/history.dart';

abstract class HistoryRepository {
  Future<List<History>> getAll();
  Future<void> save(History history);
  Future<void> delete(String id);
}
