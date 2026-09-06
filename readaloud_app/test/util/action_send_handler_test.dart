import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/util/action_send_handler.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/share_intent_handler.dart' show SharedContentKind;

void main() {
  group('ActionSendHandler.classify', () {
    test('kind=textのMapはSharedContentKind.textとして分類される', () {
      final payload = ActionSendHandler.classify({'text': '共有されたテキスト', 'kind': 'text'});

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.text);
      expect(payload.value, '共有されたテキスト');
    });

    test('kind=urlのMapはSharedContentKind.urlとして分類される'
        '（native側URLUtil.isValidUrlの判定結果をそのまま尊重する）', () {
      final payload = ActionSendHandler.classify(
          {'text': 'https://example.com/article', 'kind': 'url'});

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.url);
      expect(payload.value, 'https://example.com/article');
    });

    test('nullはnullを返す', () {
      expect(ActionSendHandler.classify(null), isNull);
    });

    test('textキーが無いMapはnullを返す', () {
      expect(ActionSendHandler.classify({'kind': 'text'}), isNull);
    });

    test('空文字のtextはnullを返す（Quick Listenを開かない）', () {
      expect(ActionSendHandler.classify({'text': '', 'kind': 'text'}), isNull);
    });

    test('空白のみのtextはnullを返す（Quick Listenを開かない）', () {
      expect(ActionSendHandler.classify({'text': '   ', 'kind': 'text'}),
          isNull);
    });

    test('flowIdを渡すとSharedTextPayloadにそのまま伝播する', () {
      final payload = ActionSendHandler.classify(
          {'text': 'text', 'kind': 'text'},
          flowId: 'action_send_pull-1');

      expect(payload!.flowId, 'action_send_pull-1');
    });

    test('flowId未指定時は空文字（既存呼び出しとの後方互換）', () {
      final payload = ActionSendHandler.classify({'text': 'text', 'kind': 'text'});

      expect(payload!.flowId, '');
    });
  });

  group('ActionSendHandler 単一消費経路 (実経路: MethodChannelをmock)', () {
    // No.94 ACTION_SEND delivery race fix: 本文をDartへ渡す経路は
    // pullPendingActionSendの応答だけであり、native→Dartのpush
    // (actionSendAvailable)は本文を含まない通知のみ。ここではその契約全体
    // （drainPendingActionSend経由の単一消費・in-flight共有・通知simulate）を
    // 実経路で検証する（ProcessTextHandlerと同じ検証パターン）。
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('com.example.readaloud_app/action_send');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      DebugLogger.testSink = [];
    });

    tearDown(() {
      DebugLogger.testSink = null;
      messenger.setMockMethodCallHandler(channel, null);
    });

    // native→Dartの「actionSendAvailable」通知(本文を含まない)をsimulateする。
    // MainActivity.notifyActionSendAvailableIfPending()と同じ形（引数なし）。
    Future<void> simulateNativeNotification() async {
      final message =
          codec.encodeMethodCall(const MethodCall('actionSendAvailable'));
      await messenger.handlePlatformMessage(
          'com.example.readaloud_app/action_send', message, null);
    }

    test('pullInitialActionSend(): 本文が返る場合、share_received→'
        'share_classifiedの順で記録され、本文はログに出ない', () async {
      const secret = 'SECRET_TEST_PAYLOAD_ACTION_SEND';
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pullPendingActionSend') {
          return {'text': secret, 'kind': 'text'};
        }
        return null;
      });

      final received = <String>[];
      final handler =
          ActionSendHandler(onPayloadReceived: (p) => received.add(p.value));
      final pulled = await handler.pullInitialActionSend();

      expect(pulled, isTrue);
      expect(received, [secret]);
      expect(handler.hasDeliveredActionSend, isTrue);

      final eventNames = DebugLogger.testSink!
          .map((l) => l.split(' ').first.replaceFirst('event=', ''))
          .toList();
      expect(eventNames, ['share_received', 'share_classified']);

      for (final line in DebugLogger.testSink!) {
        expect(line, isNot(contains(secret)));
      }

      handler.dispose();
    });

    test('pullInitialActionSend(): nullが返る場合はfalse、kind=noneが記録され、'
        'hasDeliveredActionSendもfalseのまま（Quick Listenを開かない）', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);

      final handler = ActionSendHandler(onPayloadReceived: (_) {});
      final pulled = await handler.pullInitialActionSend();

      expect(pulled, isFalse);
      expect(handler.hasDeliveredActionSend, isFalse);
      final classifiedLine = DebugLogger.testSink!
          .firstWhere((l) => l.contains('event=share_classified'));
      expect(classifiedLine, contains('kind=none'));
      expect(classifiedLine, contains('source=action_send_pull'));

      handler.dispose();
    });

    test('pullInitialActionSend(): MethodChannel呼び出しが例外を投げた場合は'
        'share_pipeline_errorを記録し、falseを返す（rethrowしない。'
        '非Android platformでnative実装が無い場合と同じ扱い）', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'TEST_ERROR');
      });

      final handler = ActionSendHandler(onPayloadReceived: (_) {});
      final pulled = await handler.pullInitialActionSend();

      expect(pulled, isFalse);
      final errorLine = DebugLogger.testSink!
          .firstWhere((l) => l.contains('event=share_pipeline_error'));
      expect(errorLine, contains('stage=action_send_pull'));

      handler.dispose();
    });

    // --- 通知経由のdrainとstartup pullの競合 ---
    test('通知経由のdrainとstartup pullがほぼ同時に発生しても、'
        'onPayloadReceivedは合計1回だけ呼ばれる', () async {
      const secret = 'SECRET_RACE_PAYLOAD_ACTION_SEND_A';
      var pullCallCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingActionSend') return null;
        pullCallCount++;
        // native側のpending slot atomic consumeをシミュレートする:
        // 1回目の呼び出しだけ本文を返し、以降は消費済みとしてnullを返す。
        return pullCallCount == 1 ? {'text': secret, 'kind': 'text'} : null;
      });

      final received = <String>[];
      final handler =
          ActionSendHandler(onPayloadReceived: (p) => received.add(p.value));
      handler.startListening();

      // native通知(actionSendAvailable)とDart起動時pullがほぼ同時に
      // 発生するケースをシミュレートする。
      final notificationFuture = simulateNativeNotification();
      final pullFuture = handler.pullInitialActionSend();
      await Future.wait([notificationFuture, pullFuture]);

      expect(received, [secret]);
      expect(handler.hasDeliveredActionSend, isTrue);

      for (final line in DebugLogger.testSink!) {
        expect(line, isNot(contains(secret)));
      }

      handler.dispose();
    });

    test('drainPendingActionSend()を直接2回同時に呼んでも、'
        'in-flight Futureが共有されonPayloadReceivedは1回だけ', () async {
      const secret = 'SECRET_RACE_PAYLOAD_ACTION_SEND_DIRECT';
      var pullCallCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingActionSend') return null;
        pullCallCount++;
        return pullCallCount == 1 ? {'text': secret, 'kind': 'text'} : null;
      });

      var callCount = 0;
      final handler = ActionSendHandler(onPayloadReceived: (_) => callCount++);

      final first = handler.drainPendingActionSend(source: 'action_send_pull');
      final second =
          handler.drainPendingActionSend(source: 'action_send_notification');
      final results = await Future.wait([first, second]);

      expect(callCount, 1);
      expect(results, [true, true]); // 両方とも同じdrainの結果を共有する
      expect(pullCallCount, 1); // native呼び出しは1回だけ集約される

      handler.dispose();
    });

    test('URL形式のtextが通知経由で届くとSharedContentKind.urlへ分類される'
        '（native側URLUtil.isValidUrlの判定結果をそのまま尊重する）', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pullPendingActionSend') {
          return {'text': 'https://example.com/from-notification', 'kind': 'url'};
        }
        return null;
      });

      SharedContentKind? receivedKind;
      final handler =
          ActionSendHandler(onPayloadReceived: (p) => receivedKind = p.kind);
      handler.startListening();

      await simulateNativeNotification();

      expect(receivedKind, SharedContentKind.url);

      handler.dispose();
    });

    test('通常textが通知経由で届くとSharedContentKind.textへ分類される', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pullPendingActionSend') {
          return {'text': 'ただのテキスト', 'kind': 'text'};
        }
        return null;
      });

      SharedContentKind? receivedKind;
      final handler =
          ActionSendHandler(onPayloadReceived: (p) => receivedKind = p.kind);
      handler.startListening();

      await simulateNativeNotification();

      expect(receivedKind, SharedContentKind.text);

      handler.dispose();
    });

    test('dispose()後は通知handlerが解除され、通知してもonPayloadReceivedが'
        '呼ばれない', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pullPendingActionSend') {
          return {'text': 'after dispose', 'kind': 'text'};
        }
        return null;
      });

      var callCount = 0;
      final handler = ActionSendHandler(onPayloadReceived: (_) => callCount++);
      handler.startListening();
      handler.dispose();

      await simulateNativeNotification();

      expect(callCount, 0);
    });
  });
}
