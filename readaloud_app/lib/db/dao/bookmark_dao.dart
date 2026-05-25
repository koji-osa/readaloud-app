import 'package:sqflite/sqflite.dart';
import '../../model/bookmark.dart';
import '../database_helper.dart';

class BookmarkDao {
  final DatabaseHelper _dbHelper = DatabaseHelper();

  Future<void> insert(Bookmark bookmark) async {
    final db = await _dbHelper.database;
    await db.insert(
      'bookmarks',
      bookmark.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Bookmark>> getByContentId(String contentId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'bookmarks',
      where: 'content_id = ?',
      whereArgs: [contentId],
      orderBy: 'position ASC',
    );
    return maps.map((m) => Bookmark.fromMap(m)).toList();
  }

  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.delete(
      'bookmarks',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
