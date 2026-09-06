import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// FIX-021調査用デバッグロガー
/// 一時停止・再開時のTTS再生位置情報をファイルに記録する
class DebugLogger {
  static DebugLogger? _instance;
  static DebugLogger get instance => _instance ??= DebugLogger._();
  DebugLogger._();

  File? _logFile;
  bool _isInitialized = false;

  // 実ファイルへの書き込みを直列化するためのキュー。unawaited(logEvent(...))が
  // 複数並行して呼ばれても、書き込みが呼び出し順と異なる順序で完了したり
  // 相互に破壊したりしないようにする。
  Future<void> _writeQueue = Future<void>.value();

  // logEvent呼び出し順を示す単調増加シーケンス番号。
  // ファイルI/O自体は非同期のため完了順が呼び出し順と一致する保証がなくても、
  // このseqを見れば実際のイベント発生順を再構成できる。
  int _seqCounter = 0;
  int _nextSeq() => ++_seqCounter;

  // progressHandler前後のログ件数制限
  static const int _preBufferSize = 5;
  static const int _postLogCount = 10;
  final List<String> _preBuffer = []; // 一時停止前の直近5件
  int _postCount = 0;                 // 再開後のログカウント
  bool _isPostLogging = false;        // 再開後のログ記録中フラグ

  /// アプリ起動時に呼ぶ。ログファイルを初期化する。
  /// [overrideDirectory]はunit testからpath_providerを介さずログ出力先を
  /// 指定するためのフック（本番経路では常にnull）。
  Future<void> init({
    required String appVersion,
    Directory? overrideDirectory,
  }) async {
    try {
      final dir = overrideDirectory ?? await getApplicationDocumentsDirectory();
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

  /// ログを追記する。
  /// 実ファイルへの書き込みは[_writeQueue]で直列化されるため、複数箇所から
  /// ほぼ同時に呼ばれても書き込み順が呼び出し順と食い違ったり、書き込み同士が
  /// 衝突したりしない。
  Future<void> log(String message) {
    if (!_isInitialized || _logFile == null) return Future.value();
    final result = _writeQueue.then((_) => _writeLine(message));
    _writeQueue = result.catchError((_) {});
    return result;
  }

  Future<void> _writeLine(String message) async {
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

  // Persistent Share Observability Phase 1: native側(MainActivity.kt +
  // NativeShareObservability.kt)のpersistent share logを取得するための
  // 診断専用MethodChannel。ACTION_SEND/PROCESS_TEXT deliveryには使用しない。
  static const MethodChannel _nativeShareObservabilityChannel =
      MethodChannel('com.example.readaloud_app/native_share_observability');

  /// [fetchNativeShareObservabilitySnapshot]の既定timeout。
  ///
  /// native側が何らかの理由で`MethodChannel.Result`を一切呼ばない場合
  /// （ChatGPT precommit review v2 Fix 1）、awaitしているFutureが永遠に
  /// 完了せず、既存の「ログ出力」操作自体がhangしてしまう。診断用途として
  /// 妥当な固定値としてこのtimeoutを設ける。
  @visibleForTesting
  static const Duration nativeShareObservabilityTimeout = Duration(seconds: 3);

  /// nativeのpersistent share observability snapshotを取得する。
  ///
  /// 取得失敗時（MissingPluginException、その他のPlatformException、
  /// [timeout]超過等）はnullを返す。[copyToDownloads]はこれを使って
  /// graceful degradationする（native取得に失敗してもDartログ単体の
  /// exportは従来どおり成功させる）。テスト容易性のためpublicにしている
  /// （native側からの文字列をそのまま返すだけで、本文相当のデータを
  /// ここで新たに生成することはない）。[timeout]はテストでのみ短縮値を
  /// 注入する想定（production呼び出しは既定値を使う）。
  @visibleForTesting
  Future<String?> fetchNativeShareObservabilitySnapshot({
    Duration timeout = nativeShareObservabilityTimeout,
  }) async {
    try {
      return await _nativeShareObservabilityChannel
          .invokeMethod<String>('getNativeShareLogSnapshot')
          .timeout(timeout);
    } catch (e) {
      debugPrint(
          '[DebugLogger] native share observability snapshot fetch error: $e');
      return null;
    }
  }

  /// Dart診断ログとnative persistent share observabilityログを1つの
  /// exportファイル用の内容へ結合する（純粋関数・I/Oなし、テスト容易）。
  /// [nativeSnapshot]がnullまたは空の場合は[dartLogContent]をそのまま返す。
  /// 本メソッド自体は値の中身を検査・変更しないため、privacy除外の責務は
  /// 引き続き[formatEvent]/[isForbiddenKey]（Dart側）およびnative側の
  /// fields構築（呼び出し元）にある。
  @visibleForTesting
  static String composeExportContent({
    required String dartLogContent,
    String? nativeSnapshot,
  }) {
    if (nativeSnapshot == null || nativeSnapshot.isEmpty) {
      return dartLogContent;
    }
    return '$dartLogContent\n'
        '=== Native Persistent Share Observability ===\n'
        '$nativeSnapshot';
  }

  /// Downloadフォルダにコピーする。
  ///
  /// Persistent Share Observability Phase 1: 可能であればnative側の
  /// persistent share observabilityログも取得し、Dart診断ログと1つの
  /// ファイルへ結合してexportする（ユーザーは既存の「ログ出力」操作を
  /// 1回行うだけで両方を取得できる）。native側取得に失敗しても、Dart
  /// 診断ログ単体のexportは従来どおり成功させる（graceful degradation。
  /// MissingPluginException等でも既存exportを失敗させない）。
  /// 元の[_logFile]自体は書き換えない（結合はexportコピー時のみ）。
  Future<String?> copyToDownloads() async {
    if (!_isInitialized || _logFile == null) return null;
    try {
      // 直前のunawaited(logEvent(...))による書き込みがまだ_writeQueueに
      // 積まれている状態でコピーすると、直近のイベントがexportから欠落する
      // ため、コピー開始前に現在キューされている書き込みの完了を待つ。
      await _writeQueue;
      // Android Download ディレクトリ
      const downloadPath = '/storage/emulated/0/Download';
      final downloadDir = Directory(downloadPath);
      if (!await downloadDir.exists()) return null;
      final dest = File('$downloadPath/${_logFile!.path.split('/').last}');

      final dartLogContent = await _logFile!.readAsString();
      final nativeSnapshot = await fetchNativeShareObservabilitySnapshot();
      final combined = composeExportContent(
        dartLogContent: dartLogContent,
        nativeSnapshot: nativeSnapshot,
      );
      await dest.writeAsString(combined);
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

  // ===== Observability-assisted Device Validation =====
  // 構造化イベントログ。body/word/url/clipboard/titleに相当するキーは
  // 値に関わらず無条件で除外する（Privacy方針：本文・URL・clipboard・titleを
  // 一切記録しない）。位置・件数・種別ラベル等の数値/カテゴリ値のみを許可する。
  // 単語単位（camelCase/snake_case分割後）で完全一致させる禁止語。
  static const List<String> _forbiddenWords = [
    'body',
    'text',
    'word',
    'url',
    'clipboard',
    'title',
  ];

  // camelCase/snake_caseの単語境界でキー名を分割するための区切り位置。
  static final RegExp _wordBoundaryPattern =
      RegExp(r'(?<=[a-z0-9])(?=[A-Z])|_');

  static bool isForbiddenKey(String key) {
    // 単純な部分文字列一致だと、'context'が禁止語'text'を偶然含んでしまい
    // 無関係なフィールドまで誤って除外されていた。camelCase/snake_caseの
    // 単語単位に分割し、単語として完全一致する場合のみ禁止する。
    final words =
        key.split(_wordBoundaryPattern).map((w) => w.toLowerCase());
    return words.any(_forbiddenWords.contains);
  }

  /// イベント名とフィールドから1行分のログ文字列を組み立てる（純粋関数・I/Oなし）。
  /// 本文相当のキーは[isForbiddenKey]により無条件で除外されるため、
  /// ファイルI/Oを介さずユニットテストで安全性を検証できる。
  static String formatEvent(String name, Map<String, Object?> fields) {
    final buffer = StringBuffer('event=$name');
    for (final entry in fields.entries) {
      if (isForbiddenKey(entry.key)) continue;
      buffer.write(' ${entry.key}=${entry.value}');
    }
    return buffer.toString();
  }

  /// テスト用フック。非nullの間はファイルI/Oを行わず、フォーマット済みの
  /// イベント文字列をこのリストへ追記する（unit testでinit()なしに検証するため）。
  static List<String>? testSink;

  /// テスト用フック。非nullの間はlogEvent()内でこのFutureをawaitしてから
  /// 記録する。呼び出し元がログ書き込み待ち中にstateを変更した場合の
  /// レース条件（食い違い）を再現するために使う。
  static Future<void> Function()? testAwaitHook;

  /// 構造化イベントログ。[formatEvent]で本文相当のキーが除外された上で、
  /// 既存の[log]（タイムスタンプ付きファイル追記）へ書き込む。
  /// 呼び出しごとに単調増加する`seq`を末尾に付与する。unawaited(logEvent(...))が
  /// 並行して呼ばれ、ファイルへの書き込み完了順が呼び出し順と一致しない場合でも、
  /// このseqを見れば実機ログから実際のイベント発生順を再構成できる。
  Future<void> logEvent(String name, [Map<String, Object?> fields = const {}]) async {
    final seq = _nextSeq();
    final line = '${formatEvent(name, fields)} seq=$seq';
    final hook = testAwaitHook;
    if (hook != null) await hook();
    final sink = testSink;
    if (sink != null) {
      sink.add(line);
      return;
    }
    await log(line);
  }
}
