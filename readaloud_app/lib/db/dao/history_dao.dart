import 'package:sqflite/sqflite.dart';
import '../../model/history.dart';
import '../database_helper.dart';

class HistoryDao {
  final DatabaseHelper _dbHelper = DatabaseHelper();
  static const int maxHistoryCount = 10;

  Future<void> insertOrUpdate(History history) async {
    final db = await _dbHelper.database;

    // 同一コンテンツの履歴があれば削除（重複防止）
    await db.delete(
      'history',
      where: 'content_id = ?',
      whereArgs: [history.contentId],
    );

    // 新しい履歴を追加
    await db.insert('history', history.toMap());

    // 10件を超えたら古いものを削除
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM history'),
    ) ?? 0;

    if (count > maxHistoryCount) {
      await db.rawDelete('''
        DELETE FROM history WHERE id IN (
          SELECT id FROM history
          ORDER BY played_at ASC
          LIMIT ?
        )
      ''', [count - maxHistoryCount]);
    }
  }

  Future<List<History>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'history',
      orderBy: 'played_at DESC',
    );
    return maps.map((m) => History.fromMap(m)).toList();
  }

  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.delete(
      'history',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
