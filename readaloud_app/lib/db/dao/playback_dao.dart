import 'package:sqflite/sqflite.dart';
import '../../model/playback_state.dart';
import '../database_helper.dart';

class PlaybackDao {
  final DatabaseHelper _dbHelper = DatabaseHelper();

  Future<void> insertOrUpdate(PlaybackState state) async {
    final db = await _dbHelper.database;
    await db.insert(
      'playback_states',
      state.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<PlaybackState?> getByContentId(String contentId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'playback_states',
      where: 'content_id = ?',
      whereArgs: [contentId],
    );
    if (maps.isEmpty) return null;
    return PlaybackState.fromMap(maps.first);
  }

  // 特定コンテンツのA-Bリピートをリセット
  Future<void> resetAbRepeat(String contentId) async {
    final db = await _dbHelper.database;
    await db.update(
      'playback_states',
      {
        'repeat_start': null,
        'repeat_end': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'content_id = ?',
      whereArgs: [contentId],
    );
  }

  // 全コンテンツのA-Bリピートをリセット（アプリ終了時に呼ぶ）
  Future<void> resetAllAbRepeat() async {
    final db = await _dbHelper.database;
    await db.update(
      'playback_states',
      {
        'repeat_start': null,
        'repeat_end': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  Future<void> delete(String contentId) async {
    final db = await _dbHelper.database;
    await db.delete(
      'playback_states',
      where: 'content_id = ?',
      whereArgs: [contentId],
    );
  }
}
