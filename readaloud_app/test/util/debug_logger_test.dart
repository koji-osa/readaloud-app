import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/util/debug_logger.dart';

void main() {
  group('DebugLogger.formatEvent (Privacy: 本文非記録)', () {
    test('数値・カテゴリ値のフィールドはそのまま出力される', () {
      final line = DebugLogger.formatEvent('tts_position_received', {
        'charPosition': 120,
        'isFirstEvent': true,
        'ttsStatus': 'playing',
      });

      expect(line, 'event=tts_position_received charPosition=120 isFirstEvent=true ttsStatus=playing');
    });

    test('bodyキーは値に関わらず除外される', () {
      final line = DebugLogger.formatEvent('quick_listen_session_started', {
        'body': '共有された本文がここに入っていたら漏洩',
        'charCount': 42,
      });

      expect(line, isNot(contains('共有された本文')));
      expect(line, isNot(contains('body=')));
      expect(line, contains('charCount=42'));
    });

    test('textキーを含むフィールド名（sharedText等）は除外される', () {
      final line = DebugLogger.formatEvent('share_classified', {
        'sharedText': 'これは読み上げ本文の断片',
        'kind': 'text',
      });

      expect(line, isNot(contains('これは読み上げ本文の断片')));
      expect(line, isNot(contains('sharedText=')));
      expect(line, contains('kind=text'));
    });

    test('wordキー（TTS progressHandlerの発話断片）は除外される', () {
      final line = DebugLogger.formatEvent('tts_progress', {
        'word': 'こんにちは',
        'chunkIndex': 0,
      });

      expect(line, isNot(contains('こんにちは')));
      expect(line, isNot(contains('word=')));
      expect(line, contains('chunkIndex=0'));
    });

    test('urlキーは除外される', () {
      final line = DebugLogger.formatEvent('share_classified', {
        'url': 'https://example.com/secret-path',
        'kind': 'url',
      });

      expect(line, isNot(contains('example.com')));
      expect(line, isNot(contains('url=')));
    });

    test('clipboardを含むキーは除外される', () {
      final line = DebugLogger.formatEvent('copy_action', {
        'clipboardText': '本文コピー内容',
      });

      expect(line, isNot(contains('本文コピー内容')));
      expect(line, isNot(contains('clipboardText=')));
    });

    test('titleキーは除外される', () {
      final line = DebugLogger.formatEvent('quick_listen_session_started', {
        'title': '共有元のタイトル',
        'sessionId': 'abc-123',
      });

      expect(line, isNot(contains('共有元のタイトル')));
      expect(line, isNot(contains('title=')));
      expect(line, contains('sessionId=abc-123'));
    });

    test('大文字小文字を問わずキー名で判定される（Body, WORD等）', () {
      final line = DebugLogger.formatEvent('event', {
        'Body': 'X',
        'WORD': 'Y',
        'contentId': 'safe-id',
      });

      expect(line, isNot(contains('Body=')));
      expect(line, isNot(contains('WORD=')));
      expect(line, contains('contentId=safe-id'));
    });

    test('フィールドなしの場合はevent名のみ出力される', () {
      final line = DebugLogger.formatEvent('player_stop_requested', {});
      expect(line, 'event=player_stop_requested');
    });

    test('contextキーは"text"を部分文字列として含むが除外されない（regression）', () {
      final line = DebugLogger.formatEvent('error', {
        'context': 'quick_listen_play',
        'errorType': 'StateError',
      });

      expect(line, 'event=error context=quick_listen_play errorType=StateError');
    });

    test('contentIdキーは"text"等を含まないため除外されない', () {
      final line = DebugLogger.formatEvent('tts_play_requested', {
        'contentId': 'abc-123',
      });

      expect(line, contains('contentId=abc-123'));
    });

    test('sharedTextキー（camelCase複合語）は除外される', () {
      final line = DebugLogger.formatEvent('share_classified', {
        'sharedText': '漏洩してはいけない本文',
        'kind': 'text',
      });

      expect(line, isNot(contains('sharedText=')));
      expect(line, contains('kind=text'));
    });

    test('clipboardTextキー（camelCase複合語）は除外される', () {
      final line = DebugLogger.formatEvent('copy_action', {
        'clipboardText': '本文コピー内容',
      });

      expect(line, isNot(contains('clipboardText=')));
    });

    // No.94 Observability: payloadHash/trimmedPayloadHash等のfingerprint系
    // フィールド名が、'text'を単語として含むキー('textHash'等)と衝突して
    // 誤って除外されないことを保証する回帰テスト。
    test('payloadHash/trimmedPayloadHashは除外されず出力される', () {
      final line = DebugLogger.formatEvent('quick_listen_session_started', {
        'sessionId': 's1',
        'charCount': 10,
        'trimmedCharCount': 8,
        'payloadHash': 'abc123',
        'trimmedPayloadHash': 'def456',
      });

      expect(line, contains('payloadHash=abc123'));
      expect(line, contains('trimmedPayloadHash=def456'));
      expect(line, contains('charCount=10'));
      expect(line, contains('trimmedCharCount=8'));
    });

    test('（参考: 命名の理由）textHash/trimmedTextHashは"text"を単語として含むため'
        '除外される。No.94実装がpayloadHash名を採用しているのはこのため', () {
      final line = DebugLogger.formatEvent('quick_listen_session_started', {
        'textHash': 'abc123',
        'trimmedTextHash': 'def456',
        'sessionId': 's1',
      });

      expect(line, isNot(contains('textHash=')));
      expect(line, contains('sessionId=s1'));
    });

    test('候補診断系フィールド(candidateCount/selectedIndex/selectedKind)は除外されない',
        () {
      final line = DebugLogger.formatEvent('share_classified', {
        'candidateCount': 2,
        'selectedIndex': 1,
        'selectedKind': 'text',
      });

      expect(line,
          'event=share_classified candidateCount=2 selectedIndex=1 selectedKind=text');
    });
  });

  group('DebugLogger.logEvent (testSink経由)', () {
    setUp(() {
      DebugLogger.testSink = [];
    });

    tearDown(() {
      DebugLogger.testSink = null;
    });

    test('init()なしでもtestSinkにフォーマット済みイベントが記録される', () async {
      await DebugLogger.instance.logEvent('quick_listen_session_started', {
        'sessionId': 's1',
        'charCount': 10,
      });

      expect(DebugLogger.testSink, hasLength(1));
      expect(DebugLogger.testSink!.single, contains('event=quick_listen_session_started'));
      expect(DebugLogger.testSink!.single, contains('sessionId=s1'));
    });

    test('logEvent経由でも本文相当のキーはtestSinkに残らない', () async {
      await DebugLogger.instance.logEvent('quick_listen_session_started', {
        'sessionId': 's1',
        'body': '漏洩してはいけない本文',
      });

      expect(DebugLogger.testSink!.single, isNot(contains('漏洩してはいけない本文')));
    });

    test('logEventは末尾に単調増加するseqを付与する（testSink経由）', () async {
      await DebugLogger.instance.logEvent('a');
      await DebugLogger.instance.logEvent('b');
      await DebugLogger.instance.logEvent('c');

      final seqs = DebugLogger.testSink!
          .map((l) => int.parse(RegExp(r'seq=(\d+)$').firstMatch(l)!.group(1)!))
          .toList();

      expect(seqs[1], greaterThan(seqs[0]));
      expect(seqs[2], greaterThan(seqs[1]));
      // event=部分の解析（例: quick_listen_viewmodel_testの順序検証）に
      // 影響しないよう、seqはevent名より後ろに付与される。
      expect(DebugLogger.testSink![0], startsWith('event=a'));
    });
  });

  group('DebugLogger.logEvent (production path: 実ファイルI/O)', () {
    late Directory tempDir;

    setUp(() async {
      DebugLogger.testSink = null;
      tempDir = await Directory.systemTemp.createTemp('debug_logger_test_');
      await DebugLogger.instance.init(
        appVersion: 'test',
        overrideDirectory: tempDir,
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test(
        'unawaited(logEvent)を大量に並行発火しても、実ファイル上の行順はseq(=呼び出し順)と一致する',
        () async {
      const total = 40;
      for (var i = 0; i < total; i++) {
        // 本番のquick_listen_viewmodel等と同じくunawaitedで発火する。
        unawaited(
          DebugLogger.instance.logEvent('ordering_probe', {'i': i}),
        );
      }
      // 直列化キューにより、最後に積んだ書き込みが完了した時点で
      // それより前に積まれた全ての書き込みも完了している。
      await DebugLogger.instance.logEvent('ordering_probe_done');

      final files = tempDir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      final lines = await files.single.readAsLines();
      final probeLines = lines
          .where((l) =>
              l.contains('event=ordering_probe ') ||
              l.contains('event=ordering_probe_done'))
          .toList();

      // 書き込みの欠落・破壊（衝突による行の消失や混線）がないこと。
      expect(probeLines, hasLength(total + 1));

      final seqPattern = RegExp(r'seq=(\d+)$');
      final seqs = probeLines
          .map((l) => int.parse(seqPattern.firstMatch(l)!.group(1)!))
          .toList();
      for (var i = 1; i < seqs.length; i++) {
        expect(
          seqs[i],
          greaterThan(seqs[i - 1]),
          reason: '実ファイル中の行順はseqの昇順（=呼び出し順）と一致するべき',
        );
      }

      final iPattern = RegExp(r' i=(\d+) ');
      final orderedIs = probeLines
          .where((l) => l.contains('event=ordering_probe '))
          .map((l) => int.parse(iPattern.firstMatch(l)!.group(1)!))
          .toList();
      expect(orderedIs, List.generate(total, (i) => i));
    });

    test(
        'copyToDownloads()は直前のunawaited(logEvent(...))の書き込み完了を待ってから'
        'コピー先を確認する（実機のDownloadディレクトリが存在しないテスト環境でも、'
        '元のログファイルには書き込みが反映されている）', () async {
      unawaited(DebugLogger.instance.logEvent('late_event_1'));
      unawaited(DebugLogger.instance.logEvent('late_event_2'));

      // 実行環境によって/storage/emulated/0/Downloadの有無は変わりうるため
      // 戻り値そのものは検証しないが、copyToDownloads()が返る時点で
      // _writeQueueへ積まれた書き込みは完了しているべき。
      await DebugLogger.instance.copyToDownloads();

      final logFile = tempDir
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.contains('readaloud_fix021_'));
      final content = await logFile.readAsString();
      expect(content, contains('event=late_event_1'));
      expect(content, contains('event=late_event_2'));
    });
  });

  group('DebugLogger.composeExportContent (Persistent Share Observability Phase 1)',
      () {
    test('nativeSnapshotがnullの場合はDartログ単体を返す（native取得失敗時のgraceful degradation）',
        () {
      final result = DebugLogger.composeExportContent(
        dartLogContent: 'dart log content',
        nativeSnapshot: null,
      );

      expect(result, 'dart log content');
    });

    test('nativeSnapshotが空文字の場合もDartログ単体を返す', () {
      final result = DebugLogger.composeExportContent(
        dartLogContent: 'dart log content',
        nativeSnapshot: '',
      );

      expect(result, 'dart log content');
    });

    test('nativeSnapshotがある場合はDartログの後にnative snapshotを結合する', () {
      final result = DebugLogger.composeExportContent(
        dartLogContent: 'DART_LOG_CONTENT',
        nativeSnapshot: 'NATIVE_SNAPSHOT_CONTENT',
      );

      expect(result, contains('DART_LOG_CONTENT'));
      expect(result, contains('NATIVE_SNAPSHOT_CONTENT'));
      expect(result, contains('Native Persistent Share Observability'));
      expect(
        result.indexOf('DART_LOG_CONTENT'),
        lessThan(result.indexOf('NATIVE_SNAPSHOT_CONTENT')),
        reason: 'Dartログが先、native snapshotが後の順で結合されるべき',
      );
    });

    test('本文相当のprobe文字列をcompose自体が新たに生成・混入させないこと'
        '（privacy除外の責務はformatEvent/isForbiddenKey側にあり、composeは'
        '結合のみを行う純粋関数であることの回帰テスト）', () {
      const probe = 'PERSISTENT_OBS_SECRET_9f3a2';
      final result = DebugLogger.composeExportContent(
        dartLogContent: 'no secret in dart log',
        nativeSnapshot: 'no secret in native snapshot',
      );

      expect(result, isNot(contains(probe)));
    });
  });

  group(
      'DebugLogger.fetchNativeShareObservabilitySnapshot '
      '(Persistent Share Observability Phase 1、実経路: MethodChannelをmock)',
      () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel =
        MethodChannel('com.example.readaloud_app/native_share_observability');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('native側が正常応答した場合はその文字列をそのまま返す', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getNativeShareLogSnapshot') {
          return 'event=activity_lifecycle stage=on_create_enter seq=1';
        }
        return null;
      });

      final result =
          await DebugLogger.instance.fetchNativeShareObservabilitySnapshot();

      expect(result, 'event=activity_lifecycle stage=on_create_enter seq=1');
    });

    test('PlatformException時はnullを返す（graceful degradation。既存exportを'
        '失敗させないため）', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'UNAVAILABLE');
      });

      final result =
          await DebugLogger.instance.fetchNativeShareObservabilitySnapshot();

      expect(result, isNull);
    });

    test('handler未登録(MissingPluginException相当)でもnullを返す', () async {
      // handlerを何も登録しない状態でinvokeMethod()を呼ぶと
      // MissingPluginExceptionが投げられる。
      final result =
          await DebugLogger.instance.fetchNativeShareObservabilitySnapshot();

      expect(result, isNull);
    });

    test('nativeが応答を返さない場合、timeout後にnullを返す（既存「ログ出力」が'
        'hangしないため。ChatGPT precommit review v2 Fix 1）', () async {
      // 意図的に完了しないFutureを返すhandler（native側がresult.success/error
      // を一切呼ばないケースを模擬する）。
      final blocker = Completer<String?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        return blocker.future;
      });

      // このtest自体が実装のバグで無期限waitしないよう、外側にも安全弁の
      // timeoutを付ける（production timeoutが機能していれば5秒以内に完了する）。
      final result = await DebugLogger.instance
          .fetchNativeShareObservabilitySnapshot(
            timeout: const Duration(milliseconds: 50),
          )
          .timeout(const Duration(seconds: 5));

      expect(result, isNull);
    });
  });
}
