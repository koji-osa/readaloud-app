import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

/// FIX-021調査用デバッグロガー
/// 一時停止・再開時のTTS再生位置情報をファイルに記録する
class DebugLogger {
  static DebugLogger? _instance;
  static DebugLogger get instance => _instance ??= DebugLogger._();
  DebugLogger._();

  File? _logFile;
  bool _isInitialized = false;

  // progressHandler前後のログ件数制限
  static const int _preBufferSize = 5;
  static const int _postLogCount = 10;
  final List<String> _preBuffer = []; // 一時停止前の直近5件
  int _postCount = 0;                 // 再開後のログカウント
  bool _isPostLogging = false;        // 再開後のログ記録中フラグ

  /// アプリ起動時に呼ぶ。ログファイルを初期化する。
  Future<void> init({required String appVersion}) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final timestamp =
          '${now.year}${_pad(now.month)}${_pad(now.day)}_${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}';
      final version = appVersion.replaceAll('+', '_');
      final fileName = 'readaloud_fix021_v${version}_$timestamp.log';
      _logFile = File('${dir.path}/$fileName');
      await _logFile!.writeAsString(
        '=== ReadAloud FIX-021 Debug Log ===\n'
        'Version: $appVersion\n'
        'Started: ${now.toIso8601String()}\n'
        '=====================================\n',
      );
      _isInitialized = true;

      // 古いログファイルを5件まで保持・それ以上は削除
      await _cleanOldLogs(dir);
    } catch (e) {
      debugPrint('[DebugLogger] init error: $e');
    }
  }

  /// ログを追記する
  Future<void> log(String message) async {
    if (!_isInitialized || _logFile == null) return;
    try {
      final now = DateTime.now();
      final time =
          '${_pad(now.hour)}:${_pad(now.minute)}:${_pad(now.second)}.${now.millisecond.toString().padLeft(3, '0')}';
      await _logFile!.writeAsString(
        '[$time] $message\n',
        mode: FileMode.append,
      );
    } catch (e) {
      debugPrint('[DebugLogger] log error: $e');
    }
  }

  /// progressHandlerのログを記録（一時停止前後のみ絞り込む）
  void bufferProgress(String message) {
    if (!_isInitialized) return;
    if (_isPostLogging) {
      // 再開後: 最大10件記録
      if (_postCount < _postLogCount) {
        log(message);
        _postCount++;
      } else {
        _isPostLogging = false;
      }
    } else {
      // 通常再生中: 直近5件をバッファに保持
      _preBuffer.add(message);
      if (_preBuffer.length > _preBufferSize) {
        _preBuffer.removeAt(0);
      }
    }
  }

  /// 一時停止時に呼ぶ。バッファをフラッシュしてログに書く。
  Future<void> onPause(int currentPosition, int chunkIndex) async {
    if (!_isInitialized) return;
    await log('--- PAUSE START ---');
    await log('PAUSE: currentPosition=$currentPosition chunkIndex=$chunkIndex');
    // 一時停止前の直近progressHandlerログを書き出す
    for (final msg in _preBuffer) {
      await log('[PRE-PAUSE] $msg');
    }
    _preBuffer.clear();
    await log('--- PAUSE END ---');
  }

  /// 再開時に呼ぶ。再開後10件のprogressHandlerログを記録開始。
  Future<void> onResume(int currentPosition, int chunkIndex, int chunkStart) async {
    if (!_isInitialized) return;
    _postCount = 0;
    _isPostLogging = true;
    await log('--- RESUME START ---');
    await log('RESUME: currentPosition=$currentPosition chunkIndex=$chunkIndex chunkStart=$chunkStart');
  }

  /// Downloadフォルダにコピーする
  Future<String?> copyToDownloads() async {
    if (!_isInitialized || _logFile == null) return null;
    try {
      // Android Download ディレクトリ
      const downloadPath = '/storage/emulated/0/Download';
      final downloadDir = Directory(downloadPath);
      if (!await downloadDir.exists()) return null;
      final dest = File('$downloadPath/${_logFile!.path.split('/').last}');
      await _logFile!.copy(dest.path);
      return dest.path;
    } catch (e) {
      debugPrint('[DebugLogger] copyToDownloads error: $e');
      return null;
    }
  }

  /// 古いログファイルを削除（5件超えたら古い順に削除）
  Future<void> _cleanOldLogs(Directory dir) async {
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('readaloud_fix021_'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      while (files.length > 5) {
        await files.first.delete();
        files.removeAt(0);
      }
    } catch (e) {
      debugPrint('[DebugLogger] cleanOldLogs error: $e');
    }
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}
