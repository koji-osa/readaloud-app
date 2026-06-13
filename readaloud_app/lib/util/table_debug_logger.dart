import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

/// FIX-050: 表分析デバッグロガー
/// 有効期限: 2026-07-02まで（20日間限定）
class TableDebugLogger {
  static TableDebugLogger? _instance;
  static TableDebugLogger get instance => _instance ??= TableDebugLogger._();
  TableDebugLogger._();

  // 有効期限（2026年7月2日）
  static final _expireDate = DateTime(2026, 7, 2);

  bool get _isActive => DateTime.now().isBefore(_expireDate);

  File? _logFile;
  final StringBuffer _buffer = StringBuffer();

  static const int _maxLogFiles = 15;

  /// 1回の分析開始時に呼ぶ。新しいログファイルを作成する。
  Future<void> startAnalysis({
    required String provider,
    required int textLength,
    required bool shouldClean,
  }) async {
    if (!_isActive) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final timestamp =
          '${now.year}${_pad(now.month)}${_pad(now.day)}_${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}';
      final fileName = 'readaloud_fix050_${timestamp}.log';
      _logFile = File('${dir.path}/$fileName');
      _buffer.clear();
      _append('=== ReadAloud FIX-050 表分析デバッグログ ===');
      _append('開始: ${now.toIso8601String()}');
      _append('有効期限: ${_expireDate.toIso8601String().substring(0, 10)}');
      _append('=====================================');
      _append('[分析開始] API=$provider テキスト文字数=$textLength クリーニング=$shouldClean');
      await _cleanOldLogs(dir);
    } catch (e) {
      debugPrint('[TableDebugLogger] startAnalysis error: $e');
    }
  }

  /// プロンプト送信直前
  void logPrompt(int promptLength) {
    if (!_isActive) return;
    _append('[プロンプト送信] 文字数=$promptLength');
  }

  /// AI返答受信成功
  void logResponse(String content) {
    if (!_isActive) return;
    _append('[AI返答受信] 文字数=${content.length}');
    _append('[AI返答全文]');
    _append(content);
  }

  /// AI呼び出し失敗
  void logApiError(String error) {
    if (!_isActive) return;
    _append('[APIエラー] $error');
  }

  /// JSON解析成功
  void logParsed(int tableCount) {
    if (!_isActive) return;
    if (tableCount == 0) {
      _append('[JSON解析] 表なし');
    } else {
      _append('[JSON解析] 検出表数=$tableCount');
    }
  }

  /// JSON解析失敗
  void logParseError(String rawContent) {
    if (!_isActive) return;
    _append('[JSON解析失敗] 受信内容全文:');
    _append(rawContent);
  }

  /// 各表の処理結果
  void logTableItem({
    required int index,
    required int startPosition,
    required int endPosition,
    required String tableText,
    required String description,
  }) {
    if (!_isActive) return;
    _append('[表$index] 開始位置=$startPosition 終了位置=$endPosition');
    _append('[表$index 全文]');
    _append(tableText);
    _append('[表$index 解説]');
    _append(description);
  }

  /// 分析完了
  Future<void> finishAnalysis({
    required int tableCount,
    required int bookmarkCount,
    required int elapsedMillis,
  }) async {
    if (!_isActive) return;
    _append('[分析完了] 表数=$tableCount ブックマーク数=$bookmarkCount 所要時間=${elapsedMillis}ms');
    await _flush();
  }

  /// バッファをファイルに書き出す
  Future<void> _flush() async {
    if (_logFile == null) return;
    try {
      await _logFile!.writeAsString(_buffer.toString());
    } catch (e) {
      debugPrint('[TableDebugLogger] flush error: $e');
    }
  }

  void _append(String message) {
    final now = DateTime.now();
    final time =
        '${_pad(now.hour)}:${_pad(now.minute)}:${_pad(now.second)}.${now.millisecond.toString().padLeft(3, '0')}';
    _buffer.writeln('[$time] $message');
  }

  /// 全ログファイルをDownloadフォルダにコピーする（FIX-050修正）
  Future<int> copyToDownloads() async {
    try {
      const downloadPath = '/storage/emulated/0/Download';
      final downloadDir = Directory(downloadPath);
      if (!await downloadDir.exists()) return 0;
      final appDir = await getApplicationDocumentsDirectory();
      final files = appDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('readaloud_fix050_'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      int count = 0;
      for (final file in files) {
        try {
          final dest = File('$downloadPath/${file.path.split('/').last}');
          await file.copy(dest.path);
          count++;
        } catch (e) {
          debugPrint('[TableDebugLogger] copy error: $e');
        }
      }
      return count;
    } catch (e) {
      debugPrint('[TableDebugLogger] copyToDownloads error: $e');
      return 0;
    }
  }

  /// 古いログファイルを削除（15件超えたら古い順に削除）
  Future<void> _cleanOldLogs(Directory dir) async {
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('readaloud_fix050_'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      while (files.length > _maxLogFiles) {
        await files.first.delete();
        files.removeAt(0);
      }
    } catch (e) {
      debugPrint('[TableDebugLogger] cleanOldLogs error: $e');
    }
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}
