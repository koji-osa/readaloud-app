import 'package:sqflite/sqflite.dart';
import '../../model/setting.dart';
import '../database_helper.dart';

class SettingsDao {
  final DatabaseHelper _dbHelper = DatabaseHelper();

  Future<void> set(String key, String value) async {
    final db = await _dbHelper.database;
    await db.insert(
      'settings',
      Setting(key: key, value: value).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> get(String key) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (maps.isEmpty) return null;
    return maps.first['value'] as String?;
  }

  Future<void> delete(String key) async {
    final db = await _dbHelper.database;
    await db.delete(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
    );
  }

  Future<Map<String, String>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query('settings');
    return {
      for (final m in maps)
        m['key'] as String: m['value'] as String,
    };
  }
}
