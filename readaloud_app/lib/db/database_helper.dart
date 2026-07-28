import 'package:meta/meta.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'readaloud.db');
    return openDatabase(
      path,
      version: 2,
      onConfigure: (db) async {
        // 外部キー制約を有効化（カスケード削除に必要）
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  // マイグレーションテストから実際のonCreate/onUpgradeを直接検証するための公開エイリアス
  @visibleForTesting
  static const onCreateForTest = _onCreate;
  @visibleForTesting
  static const onUpgradeForTest = _onUpgrade;

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
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
        synced_at INTEGER,
        external_type TEXT,
        vault_name TEXT,
        relative_path TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE playback_states (
        content_id TEXT PRIMARY KEY,
        position INTEGER NOT NULL DEFAULT 0,
        progress_pct REAL NOT NULL DEFAULT 0.0,
        speed REAL NOT NULL DEFAULT 1.0,
        voice_id TEXT,
        pitch REAL NOT NULL DEFAULT 1.0,
        volume REAL NOT NULL DEFAULT 1.0,
        repeat_start INTEGER,
        repeat_end INTEGER,
        last_played_at INTEGER,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (content_id) REFERENCES contents (id)
          ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE bookmarks (
        id TEXT PRIMARY KEY,
        content_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        label TEXT,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (content_id) REFERENCES contents (id)
          ON DELETE CASCADE
      )
    ''');

    // historyはカスケード削除しない（削除済みコンテンツの履歴を残す）
    // UI層で content_id の存在チェックを行い「削除済みコンテンツ」と表示する
    await db.execute('''
      CREATE TABLE history (
        id TEXT PRIMARY KEY,
        content_id TEXT NOT NULL,
        played_at INTEGER NOT NULL,
        progress_pct REAL NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Obsidianノートへのワンタップ遷移機能のためのカラム追加
      await db.execute('ALTER TABLE contents ADD COLUMN external_type TEXT');
      await db.execute('ALTER TABLE contents ADD COLUMN vault_name TEXT');
      await db.execute('ALTER TABLE contents ADD COLUMN relative_path TEXT');
    }
  }
}
