import 'package:sqflite/sqflite.dart';
import '../../model/content.dart';
import '../database_helper.dart';

class ContentDao {
  final DatabaseHelper _dbHelper = DatabaseHelper();

  Future<void> insert(Content content) async {
    final db = await _dbHelper.database;
    await db.insert(
      'contents',
      content.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Content>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'contents',
      orderBy: 'created_at DESC',
    );
    return maps.map((m) => Content.fromMap(m)).toList();
  }

  // ステータスでフィルタリング（未読・読書中・完了）
  Future<List<Content>> getByStatus(String status) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'contents',
      where: 'status = ?',
      whereArgs: [status],
      orderBy: 'created_at DESC',
    );
    return maps.map((m) => Content.fromMap(m)).toList();
  }

  Future<Content?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'contents',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return Content.fromMap(maps.first);
  }

  Future<void> update(Content content) async {
    final db = await _dbHelper.database;
    await db.update(
      'contents',
      content.toMap(),
      where: 'id = ?',
      whereArgs: [content.id],
    );
  }

  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.delete(
      'contents',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
