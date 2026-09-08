import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/util/external_input_handler.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/share_intent_handler.dart' show SharedContentKind;

void main() {
  group('ExternalInputHandler.classify', () {
    test('kind=textのMapはSharedContentKind.textとして分類される', () {
      final payload = ExternalInputHandler.classify(
          {'source': 'action_send', 'kind': 'text', 'text': '共有されたテキスト'});

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.text);
      expect(payload.value, '共有されたテキスト');
    });

    test('kind=urlのMapはSharedContentKind.urlとして分類される'
        '（native側URLUtil.isValidUrlの判定結果をそのまま尊重する）', () {
      final payload = ExternalInputHandler.classify(
          {'source': 'action_send', 'kind': 'url', 'text': 'https://example.com/article'});

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.url);
      expect(payload.value, 'https://example.com/article');
    });

    test('source=process_textのkind=textはSharedContentKind.textとして分類される'
        '（URL昇格しない）', () {
      final payload = ExternalInputHandler.classify(
          {'source': 'process_text', 'kind': 'text', 'text': 'https://example.com/selected'});

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.text);
    });

    test('nullはnullを返す', () {
      expect(ExternalInputHandler.classify(null), isNull);
    });

    test('textキーが無いMapはnullを返す', () {
      expect(ExternalInputHandler.classify({'source': 'action_send', 'kind': 'text'}), isNull);
    });

    test('空文字のtextはnullを返す（Quick Listenを開かない）', () {
      expect(
          ExternalInputHandler.classify(
              {'source': 'action_send', 'kind': 'text', 'text': ''}),
          isNull);
    });

    test('空白のみのtextはnullを返す（Quick Listenを開かない）', () {
      expect(
          ExternalInputHandler.classify(
              {'source': 'action_send', 'kind': 'text', 'text': '   '}),
          isNull);
    });

    test('flowIdを渡すとSharedTextPayloadにそのまま伝播する', () {
      final payload = ExternalInputHandler.classify(
          {'source': 'action_send', 'kind': 'text', 'text': 'text'},
          flowId: 'external_input_pull-1');

      expect(payload!.flowId, 'external_input_pull-1');
    });

    test('flowId未指定時は空文字（既存呼び出しとの後方互換）', () {
      final payload = ExternalInputHandler.classify(
          {'source': 'action_send', 'kind': 'text', 'text': 'text'});

      expect(payload!.flowId, '');
    });
  });

  group('ExternalInputHandler 単一消費経路・redrain (実経路: MethodChannelをmock)', () {
    // No.94 Share Event Architecture (Architecture Z): 本文をDartへ渡す
    // 経路はpullPendingExternalInputの応答だけであり、native→Dartのpush
    // (externalInputAvailable)は本文を含まない通知のみ。ここではその契約
    // 全体（drainPendingExternalInput経由の単一消費・in-flight共有・
    // redrain・通知simulate）を実経路で検証する。
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('com.example.readaloud_app/external_input');
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

    // native→Dartの「externalInputAvailable」通知(本文を含まない)を
    // simulateする。MainActivity.notifyExternalInputAvailableIfPending()と
    // 同じ形（引数なし）。
    Future<void> simulateNativeNotification() async {
      final message =
          codec.encodeMethodCall(const MethodCall('externalInputAvailable'));
      await messenger.handlePlatformMessage(
          'com.example.readaloud_app/external_input', message, null);
    }

    // === Core: single-consumer / classification / privacy ===

    test('pullInitialExternalInput(): 本文が返る場合、share_received→'
        'share_classifiedの順で記録され、本文はログに出ない', () async {
      const secret = 'SECRET_TEST_PAYLOAD_EXTERNAL_INPUT';
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pullPendingExternalInput') {
          return {'source': 'action_send', 'kind': 'text', 'text': secret};
        }
        return null;
      });

      final received = <String>[];
      final handler = ExternalInputHandler(
          onPayloadReceived: (p) async => received.add(p.value));
      final pulled = await handler.pullInitialExternalInput();

      expect(pulled, isTrue);
      expect(received, [secret]);

      final eventNames = DebugLogger.testSink!
          .map((l) => l.split(' ').first.replaceFirst('event=', ''))
          .toList();
      expect(eventNames, ['share_received', 'share_classified']);

      for (final line in DebugLogger.testSink!) {
        expect(line, isNot(contains(secret)));
      }

      handler.dispose();
    });

    test('pullInitialExternalInput(): nullが返る場合はfalse、kind=noneが記録される'
        '（Quick Listenを開かない）', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);

      final handler = ExternalInputHandler(onPayloadReceived: (_) async {});
      final pulled = await handler.pullInitialExternalInput();

      expect(pulled, isFalse);
      final classifiedLine = DebugLogger.testSink!
          .firstWhere((l) => l.contains('event=share_classified'));
      expect(classifiedLine, contains('kind=none'));
      expect(classifiedLine, contains('source=external_input_pull'));

      handler.dispose();
    });

    test('pullInitialExternalInput(): MethodChannel呼び出しが例外を投げた場合は'
        'share_pipeline_errorを記録し、falseを返す（rethrowしない。'
        '非Android platformでnative実装が無い場合と同じ扱い）', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'TEST_ERROR');
      });

      final handler = ExternalInputHandler(onPayloadReceived: (_) async {});
      final pulled = await handler.pullInitialExternalInput();

      expect(pulled, isFalse);
      final errorLine = DebugLogger.testSink!
          .firstWhere((l) => l.contains('event=share_pipeline_error'));
      expect(errorLine, contains('stage=external_input_pull'));

      handler.dispose();
    });

    test('通知経由のdrainとstartup pullがほぼ同時に発生しても、'
        'onPayloadReceivedは合計1回だけ呼ばれる', () async {
      const secret = 'SECRET_RACE_PAYLOAD_A';
      var pullCallCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingExternalInput') return null;
        pullCallCount++;
        return pullCallCount == 1
            ? {'source': 'action_send', 'kind': 'text', 'text': secret}
            : null;
      });

      final received = <String>[];
      final handler = ExternalInputHandler(
          onPayloadReceived: (p) async => received.add(p.value));
      handler.startListening();

      final notificationFuture = simulateNativeNotification();
      final pullFuture = handler.pullInitialExternalInput();
      await Future.wait([notificationFuture, pullFuture]);

      expect(received, [secret]);

      for (final line in DebugLogger.testSink!) {
        expect(line, isNot(contains(secret)));
      }

      handler.dispose();
    });

    test('drainPendingExternalInput()を直接2回同時に呼んでも、'
        'in-flight Futureが共有されonPayloadReceivedは1回だけ'
        '（2回目の呼び出しは既存in-flightへjoinし、v3 addendumのredrain'
        '設計によりA完了後に無害な追加pullが1回発生するが、それは'
        'nativeで既に消費済みのためnoneを返しdouble deliveryはしない。'
        'T-23と同じ原理——redrainは「in-flight中に呼び出しが来たか」'
        'だけで判定し、同一eventへの重複呼び出しか新規eventかは'
        '区別しない、という意図された仕様。5709c892旧設計の'
        '「追加native呼び出しゼロ」という保証は、redrain正当性'
        '（T-20）獲得のtrade-offとして意図的に緩和した）', () async {
      const secret = 'SECRET_RACE_PAYLOAD_DIRECT';
      var pullCallCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingExternalInput') return null;
        pullCallCount++;
        return pullCallCount == 1
            ? {'source': 'action_send', 'kind': 'text', 'text': secret}
            : null;
      });

      var callCount = 0;
      final handler =
          ExternalInputHandler(onPayloadReceived: (_) async => callCount++);

      final first =
          handler.drainPendingExternalInput(source: 'external_input_pull');
      final second = handler.drainPendingExternalInput(
          source: 'external_input_notification');
      final results = await Future.wait([first, second]);

      expect(callCount, 1); // onPayloadReceivedはA本文で1回だけ
      expect(results, [true, true]); // anyDelivered=trueをcycle全体で共有
      expect(pullCallCount, 2); // 1回目=A取得、2回目=redrainだがnone

      handler.dispose();
    });

    test('URL形式のtextが通知経由で届くとSharedContentKind.urlへ分類される', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pullPendingExternalInput') {
          return {
            'source': 'action_send',
            'kind': 'url',
            'text': 'https://example.com/from-notification',
          };
        }
        return null;
      });

      SharedContentKind? receivedKind;
      final handler = ExternalInputHandler(
          onPayloadReceived: (p) async => receivedKind = p.kind);
      handler.startListening();

      await simulateNativeNotification();

      expect(receivedKind, SharedContentKind.url);

      handler.dispose();
    });

    test('通常textが通知経由で届くとSharedContentKind.textへ分類される', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pullPendingExternalInput') {
          return {'source': 'process_text', 'kind': 'text', 'text': 'ただのテキスト'};
        }
        return null;
      });

      SharedContentKind? receivedKind;
      final handler = ExternalInputHandler(
          onPayloadReceived: (p) async => receivedKind = p.kind);
      handler.startListening();

      await simulateNativeNotification();

      expect(receivedKind, SharedContentKind.text);

      handler.dispose();
    });

    test('dispose()後は通知handlerが解除され、通知してもonPayloadReceivedが'
        '呼ばれない', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pullPendingExternalInput') {
          return {'source': 'action_send', 'kind': 'text', 'text': 'after dispose'};
        }
        return null;
      });

      var callCount = 0;
      final handler =
          ExternalInputHandler(onPayloadReceived: (_) async => callCount++);
      handler.startListening();
      handler.dispose();

      await simulateNativeNotification();

      expect(callCount, 0);
    });

    // === Legacy contract migration audit ===
    // ChatGPT precommit review v2 Fix 7/8 → RA-N94-P01/P02: 旧
    // process_text_handler_test.dartの「B. 通知経由で既に処理済みの場合、
    // hasDeliveredProcessTextはtrueのまま、後続のstartup pullはfalseを
    // 返す」のうち、main.dart側cross-handler arbitration用途
    // （ProcessText→ActionSendへのfall-through回避）は単一handler統合
    // （Architecture Z）により構造的に不要化した（main.dartはもはや
    // このhandlerの内部stateを一切読まない）。この配信成功flag自体も
    // RA-N94-P01のimpact check（production consumer 0件を確認済み）を
    // 経てRA-N94-P02で削除した。このtestはflagの検証ではなく、「一度配信に成功した同一
    // handler instanceへ、pendingが空の状態で再度pullしても、falseを
    // 返しstuck状態にならない」という、flagとは独立した中核契約
    // （drain cycleの再実行可能性）を検証するものとして存続させる
    // （RA-N94-P01 Scenario B）。
    test('post-delivery後、pendingが無い状態で再度pullしてもfalseを返す'
        '（同一handler instanceでの連続drain cycle、stuck状態にならない'
        'ことの確認）', () async {
      var pullCallCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingExternalInput') return null;
        pullCallCount++;
        return pullCallCount == 1
            ? {'source': 'process_text', 'kind': 'text', 'text': 'A'}
            : null;
      });

      final handler = ExternalInputHandler(onPayloadReceived: (_) async {});

      final first = await handler.pullInitialExternalInput();
      expect(first, isTrue);

      final second = await handler.pullInitialExternalInput();
      expect(second, isFalse);

      handler.dispose();
    });

    // === Redrain traces (T-20〜T-25, v3 addendum) ===

    test('T-20: A callback await中にB captureされても、'
        'A完了後にredrainでBがdeliveryされる（取り残されない）', () async {
      var pullCallCount = 0;
      final aGate = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingExternalInput') return null;
        pullCallCount++;
        if (pullCallCount == 1) {
          return {'source': 'action_send', 'kind': 'text', 'text': 'A'};
        }
        if (pullCallCount == 2) {
          return {'source': 'action_send', 'kind': 'text', 'text': 'B'};
        }
        return null;
      });

      final received = <String>[];
      final handler = ExternalInputHandler(onPayloadReceived: (p) async {
        if (p.value == 'A') await aGate.future;
        received.add(p.value);
      });

      final drainA =
          handler.drainPendingExternalInput(source: 'external_input_notification');
      // Aのpull・classifyまでのmicrotaskを進める（callbackはaGateで停止中）。
      await Future.delayed(Duration.zero);

      // B capture＋notify: Aのcallbackがin-flightのため、in-flight
      // FutureへjoinしredrainRequestedがtrueになる。
      final drainB =
          handler.drainPendingExternalInput(source: 'external_input_notification');

      aGate.complete();
      await drainA;
      await drainB;

      expect(received, ['A', 'B']);
      expect(pullCallCount, 2);

      handler.dispose();
    });

    test('T-21: Multi-redrain coalescing — A中にB→Cが来ても'
        'single-slot latest-winsによりCのみdeliveryされる（queueなし）', () async {
      var pullCallCount = 0;
      final aGate = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingExternalInput') return null;
        pullCallCount++;
        if (pullCallCount == 1) {
          return {'source': 'action_send', 'kind': 'text', 'text': 'A'};
        }
        // 2回目のpull時点で、native single slotは既にB→Cへ上書き済み
        // という想定（Bはpullされる前にCで上書きされ消える＝coalescing）。
        if (pullCallCount == 2) {
          return {'source': 'action_send', 'kind': 'text', 'text': 'C'};
        }
        return null;
      });

      final received = <String>[];
      final handler = ExternalInputHandler(onPayloadReceived: (p) async {
        if (p.value == 'A') await aGate.future;
        received.add(p.value);
      });

      final drainA =
          handler.drainPendingExternalInput(source: 'external_input_notification');
      await Future.delayed(Duration.zero);

      final drainB =
          handler.drainPendingExternalInput(source: 'external_input_notification');
      final drainC =
          handler.drainPendingExternalInput(source: 'external_input_notification');

      aGate.complete();
      await drainA;
      await drainB;
      await drainC;

      expect(received, ['A', 'C']);
      expect(pullCallCount, 2); // redrainは1回だけ発生（B/Cの通知は1回のredrainへcoalesce）

      handler.dispose();
    });

    test('T-22: 完了後の同一content re-shareは、redrain/dedup stateに'
        '関わらず必ず再deliveryされる', () async {
      var pullCallCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingExternalInput') return null;
        pullCallCount++;
        return {'source': 'action_send', 'kind': 'text', 'text': 'A'};
      });

      final received = <String>[];
      final handler = ExternalInputHandler(
          onPayloadReceived: (p) async => received.add(p.value));

      final first = await handler.drainPendingExternalInput(
          source: 'external_input_notification');
      final second = await handler.drainPendingExternalInput(
          source: 'external_input_notification');

      expect(first, isTrue);
      expect(second, isTrue);
      expect(received, ['A', 'A']);
      expect(pullCallCount, 2);

      handler.dispose();
    });

    test('T-23: in-flight中のduplicate notify（native pendingなし）は'
        'redrainでnoneとなりA一回のみdelivery、cycle全体のreturnはtrue'
        '（anyDelivered semantics）', () async {
      var pullCallCount = 0;
      final aGate = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingExternalInput') return null;
        pullCallCount++;
        if (pullCallCount == 1) {
          return {'source': 'action_send', 'kind': 'text', 'text': 'A'};
        }
        return null; // duplicate notify、実際には何もcaptureされていない
      });

      final received = <String>[];
      final handler = ExternalInputHandler(onPayloadReceived: (p) async {
        await aGate.future;
        received.add(p.value);
      });

      final drainA =
          handler.drainPendingExternalInput(source: 'external_input_notification');
      await Future.delayed(Duration.zero);
      final drainDup =
          handler.drainPendingExternalInput(source: 'external_input_notification');

      aGate.complete();
      final resultA = await drainA;
      final resultDup = await drainDup;

      expect(received, ['A']);
      expect(pullCallCount, 2);
      expect(resultA, isTrue);
      expect(resultDup, isTrue);

      handler.dispose();
    });

    test('T-24: async callback serialization — Bのcallback開始は'
        'Aのcallback完了後（AがBの後からUIを上書きしない）', () async {
      var pullCallCount = 0;
      final aGate = Completer<void>();
      final callbackOrder = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingExternalInput') return null;
        pullCallCount++;
        if (pullCallCount == 1) {
          return {'source': 'action_send', 'kind': 'text', 'text': 'A'};
        }
        if (pullCallCount == 2) {
          return {'source': 'action_send', 'kind': 'text', 'text': 'B'};
        }
        return null;
      });

      final handler = ExternalInputHandler(onPayloadReceived: (p) async {
        callbackOrder.add('${p.value}-start');
        if (p.value == 'A') await aGate.future;
        callbackOrder.add('${p.value}-end');
      });

      final drainA =
          handler.drainPendingExternalInput(source: 'external_input_notification');
      await Future.delayed(Duration.zero);
      final drainB =
          handler.drainPendingExternalInput(source: 'external_input_notification');

      // Aのcallbackが完了するまでBのcallbackは開始されていないはず。
      expect(callbackOrder, ['A-start']);

      aGate.complete();
      await drainA;
      await drainB;

      expect(callbackOrder, ['A-start', 'A-end', 'B-start', 'B-end']);

      handler.dispose();
    });

    test('T-25: Exception reset — callback例外後もstateがリセットされ、'
        '次のfresh eventを正常に処理できる', () async {
      var pullCallCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'pullPendingExternalInput') return null;
        pullCallCount++;
        if (pullCallCount == 1) {
          return {'source': 'action_send', 'kind': 'text', 'text': 'A'};
        }
        if (pullCallCount == 2) {
          return {'source': 'action_send', 'kind': 'text', 'text': 'B'};
        }
        return null;
      });

      final received = <String>[];
      final handler = ExternalInputHandler(onPayloadReceived: (p) async {
        if (p.value == 'A') throw StateError('boom');
        received.add(p.value);
      });

      await expectLater(
        handler.drainPendingExternalInput(source: 'external_input_notification'),
        throwsA(isA<StateError>()),
      );

      final delivered = await handler.drainPendingExternalInput(
          source: 'external_input_notification');

      expect(delivered, isTrue);
      expect(received, ['B']);

      handler.dispose();
    });
  });
}
