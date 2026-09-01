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
  });
}
