import 'dart:async';
import 'dart:io';

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
  });
}
