import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/process_text_handler.dart';
import 'package:readaloud_app/util/share_intent_handler.dart' show SharedContentKind;

void main() {
  group('ProcessTextHandler.classify', () {
    test('通常テキストはSharedContentKind.textとして分類される', () {
      final payload = ProcessTextHandler.classify('選択されたテキスト');

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.text);
      expect(payload.value, '選択されたテキスト');
    });

    test('URL形式の選択テキストでもtext扱いのまま（Web Importへ送らない）', () {
      final payload =
          ProcessTextHandler.classify('https://example.com/article');

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.text);
    });

    test('nullはnullを返す', () {
      expect(ProcessTextHandler.classify(null), isNull);
    });

    test('空文字はnullを返す（Quick Listenを開かない）', () {
      expect(ProcessTextHandler.classify(''), isNull);
    });

    test('空白のみはnullを返す（Quick Listenを開かない）', () {
      expect(ProcessTextHandler.classify('   '), isNull);
    });

    test('flowIdを渡すとSharedTextPayloadにそのまま伝播する', () {
      final payload =
          ProcessTextHandler.classify('text', flowId: 'process_text_pull-1');

      expect(payload!.flowId, 'process_text_pull-1');
    });

    test('flowId未指定時は空文字（既存呼び出しとの後方互換）', () {
      final payload = ProcessTextHandler.classify('text');

      expect(payload!.flowId, '');
    });
  });

  group('ProcessTextHandler 単一消費経路 (実経路: MethodChannelをmock)', () {
    // ChatGPT re-review v2対応: 選択テキスト本文をDartへ渡す経路は
    // pullPendingProcessTextの応答だけであり、native→Dartのpush
    // (processTextAvailable)は本文を含まない通知のみになった。
    // ここではその契約全体（drainPendingProcessText経由の単一消費・
    // in-flight共有・通知simulate）を実経路で検証する。
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('com.example.readaloud_app/process_text');
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

    // native→Dartの「processTextAvailable」通知(本文を含まない)を
    // simulateする。MainActivity.notifyProcessTextAvailableIfPending()と
    // 同じ形（引数なし）。
    Future<void> simulateNativeNotification() async {
      final message =
          codec.encodeMethodCall(const MethodCall('processTextAvailable'));
      await messenger.handlePlatformMessage(
          'com.example.readaloud_app/process_text', message, null);
    }

    test('pullInitialProcessText(): 選択テキストが返る場合、share_received→'
        'share_classifiedの順で記録され、本文はログに出ない', () async {
      const secret = 'SECRET_TEST_PAYLOAD_12345';
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pullPendingProcessText') return secret;
        return null;
      });

      final received = <String>[];
      final handler =
          ProcessTextHandler(onPayloadReceived: (p) => received.add(p.value));
      final pulled = await handler.pullInitialProcessText();

      expect(pulled, isTrue);
      expect(received, [secret]);
      expect(handler.hasDeliveredProcessText, isTrue);

      final eventNames = DebugLogger.testSink!
          .map((l) => l.split(' ').first.replaceFirst('event=', ''))
          .toList();
      expect(eventNames, ['share_received', 'share_classified']);

      for (final line in DebugLogger.testSink!) {
        expect(line, isNot(contains(secret)));
      }

      handler.dispose();
    });

    test('pullInitialProcessText(): nullが返る場合はfalse、kind=noneが記録され、'
        'hasDeliveredProcessTextもfalseのまま（Quick Listenを開かない）', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);

      final handler = ProcessTextHandler(onPayloadReceived: (_) {});
      final pulled = await handler.pullInitialProcessText();

      expect(pulled, isFalse);
      expect(handler.hasDeliveredProcessText, isFalse);
      final classifiedLine = DebugLogger.testSink!
          .firstWhere((l) => l.contains('event=share_classified'));
      expect(classifiedLine, contains('kind=none'));
      expect(classifiedLine, contains('source=process_text_pull'));

      handler.dispose();
    });

    test('pullInitialProcessText(): MethodChannel呼び出しが例外を投げた場合は'
        'share_pipeline_errorを記録し、falseを返す（rethrowしない）', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'TEST_ERROR');
      });

      final handler = ProcessTextHandler(onPayloadReceived: (_) {});
      final pulled = await handler.pullInitialProcessText();

      expect(pulled, isFalse);
      final errorLine = DebugLogger.testSink!
          .firstWhere((l) => l.contains('event=share_pipeline_error'));
      expect(errorLine, contains('stage=process_text_pull'));

      handler.dispose();
    });

    // --- Section 5-A: push-notification / startup drain競合 ---
    test('A. 通知経由のdrainとstartup pullがほぼ同時に発生しても、'
        'onPayloadReceivedは合計1回だけ呼ばれる', () async {
      const secret = 'SECRET_RACE_PAYLOAD_A';
      var pullCallCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingProcessText') return null;
        pullCallCount++;
        // native側のpendingProcessText atomic consumeをシミュレートする:
        // 1回目の呼び出しだけ本文を返し、以降は消費済みとしてnullを返す。
        return pullCallCount == 1 ? secret : null;
      });

      final received = <String>[];
      final handler =
          ProcessTextHandler(onPayloadReceived: (p) => received.add(p.value));
      handler.startListening();

      // native通知(processTextAvailable)とDart起動時pullがほぼ同時に
      // 発生するケースをシミュレートする。
      final notificationFuture = simulateNativeNotification();
      final pullFuture = handler.pullInitialProcessText();
      await Future.wait([notificationFuture, pullFuture]);

      expect(received, [secret]);
      expect(handler.hasDeliveredProcessText, isTrue);

      for (final line in DebugLogger.testSink!) {
        expect(line, isNot(contains(secret)));
      }

      handler.dispose();
    });

    test('A. drainPendingProcessText()を直接2回同時に呼んでも、'
        'in-flight Futureが共有されonPayloadReceivedは1回だけ', () async {
      const secret = 'SECRET_RACE_PAYLOAD_DIRECT';
      var pullCallCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingProcessText') return null;
        pullCallCount++;
        return pullCallCount == 1 ? secret : null;
      });

      var callCount = 0;
      final handler = ProcessTextHandler(onPayloadReceived: (_) => callCount++);

      final first = handler.drainPendingProcessText(source: 'process_text_pull');
      final second =
          handler.drainPendingProcessText(source: 'process_text_notification');
      final results = await Future.wait([first, second]);

      expect(callCount, 1);
      expect(results, [true, true]); // 両方とも同じdrainの結果を共有する
      expect(pullCallCount, 1); // native呼び出しは1回だけ集約される

      handler.dispose();
    });

    // --- Section 5-B: PROCESS_TEXT処理済み + stale ACTION_SEND arbitration ---
    test('B. 通知経由で既に処理済みの場合、hasDeliveredProcessTextはtrueのまま、'
        '後続のstartup pullはfalseを返す'
        '（main.dartがstale ACTION_SENDへフォールスルーしないための材料）',
        () async {
      const secret = 'SECRET_HANDLED_VIA_NOTIFICATION';
      var pullCallCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingProcessText') return null;
        pullCallCount++;
        return pullCallCount == 1 ? secret : null;
      });

      final received = <String>[];
      final handler =
          ProcessTextHandler(onPayloadReceived: (p) => received.add(p.value));
      handler.startListening();

      // 通知が先に処理を終える（main.dartのstartup pullより前）。
      await simulateNativeNotification();
      expect(received, [secret]);
      expect(handler.hasDeliveredProcessText, isTrue);

      // その後、main.dart _checkInitialShareIntent()相当のstartup pullが
      // 行われる。pending側は既に消費済みのためfalseが返る。
      final pulledNow = await handler.pullInitialProcessText();

      expect(pulledNow, isFalse);
      // ただしhasDeliveredProcessTextはtrueのまま維持される。main.dartは
      // `pulledNow || hasDeliveredProcessText`でarbitrationするため、
      // このセッションではShareIntentHandlerへフォールスルーしない。
      expect(handler.hasDeliveredProcessText, isTrue);
      expect(received, [secret]); // 二重には処理されていない

      handler.dispose();
    });

    test('B. PROCESS_TEXTが一切無かった場合はhasDeliveredProcessTextがfalseのまま'
        '（通常のACTION_SEND initial payloadへ進んでよい）', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);

      final handler = ProcessTextHandler(onPayloadReceived: (_) {});
      handler.startListening();
      final pulledNow = await handler.pullInitialProcessText();

      expect(pulledNow, isFalse);
      expect(handler.hasDeliveredProcessText, isFalse);

      handler.dispose();
    });

    test('URL形式のテキストが通知経由で届いてもtext扱いのままonPayloadReceivedへ渡される',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pullPendingProcessText') {
          return 'https://example.com/from-notification';
        }
        return null;
      });

      SharedContentKind? receivedKind;
      final handler =
          ProcessTextHandler(onPayloadReceived: (p) => receivedKind = p.kind);
      handler.startListening();

      await simulateNativeNotification();

      expect(receivedKind, SharedContentKind.text);

      handler.dispose();
    });

    test('dispose()後は通知handlerが解除され、通知してもonPayloadReceivedが'
        '呼ばれない', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pullPendingProcessText') return 'after dispose';
        return null;
      });

      var callCount = 0;
      final handler = ProcessTextHandler(onPayloadReceived: (_) => callCount++);
      handler.startListening();
      handler.dispose();

      await simulateNativeNotification();

      expect(callCount, 0);
    });
  });
}
