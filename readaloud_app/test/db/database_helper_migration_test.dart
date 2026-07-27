import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:readaloud_app/db/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// v1時点のcontentsテーブル定義（externalType/vaultName/relativePath追加前）。
// マイグレーション対象の初期状態を再現するために使用する。
const _v1CreateContentsTable = '''
  CREATE TABLE contents (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    source_type TEXT NOT NULL,
    source_url TEXT,
    source_filename TEXT,
    char_count INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'unread',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    synced_at INTEGER
  )
''';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v1スキーマから起動すると、v2へのマイグレーションでカラムが追加され既存データが保持される', () async {
    final dbDir = await databaseFactory.getDatabasesPath();
    final path = join(dbDir, 'readaloud_migration_test.db');
    final dbFile = File(path);
    if (await dbFile.exists()) {
      await dbFile.delete();
    }

    // v1スキーマのDBを事前に用意し、既存データが1件入っている状態を再現する
    final v1Db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute(_v1CreateContentsTable);
        },
      ),
    );
    await v1Db.insert('contents', {
      'id': 'content-1',
      'title': 'タイトル',
      'body': '本文',
      'source_type': 'obsidian',
      'char_count': 2,
      'status': 'unread',
      'created_at': 0,
      'updated_at': 0,
    });
    await v1Db.close();

    // DatabaseHelperと同じopenDatabase呼び出しを再現し、実際の_onUpgradeを経由させる
    final upgradedDb = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: DatabaseHelper.onCreateForTest,
        onUpgrade: DatabaseHelper.onUpgradeForTest,
      ),
    );

    final columns = await upgradedDb.rawQuery('PRAGMA table_info(contents)');
    final columnNames = columns.map((c) => c['name'] as String).toSet();
    expect(columnNames, containsAll(['external_type', 'vault_name', 'relative_path']));

    final rows = await upgradedDb.query('contents', where: 'id = ?', whereArgs: ['content-1']);
    expect(rows, hasLength(1));
    expect(rows.first['title'], 'タイトル');
    expect(rows.first['external_type'], isNull);
    expect(rows.first['vault_name'], isNull);
    expect(rows.first['relative_path'], isNull);

    await upgradedDb.close();
    await dbFile.delete();
  });
}
