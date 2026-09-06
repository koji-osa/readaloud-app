import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/share_intent_handler.dart';

SharedFile _file({required String? value, required SharedMediaType type}) =>
    SharedFile(value: value, type: type);

void main() {
  group('ShareIntentHandler.classify', () {
    test('SharedMediaType.URLはSharedContentKind.urlとして分類される', () {
      final payload = ShareIntentHandler.classify([
        _file(value: 'https://example.com/article', type: SharedMediaType.URL),
      ]);

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.url);
      expect(payload.value, 'https://example.com/article');
    });

    test('SharedMediaType.TEXTはSharedContentKind.textとして分類される（Quick Listen対象）', () {
      final payload = ShareIntentHandler.classify([
        _file(value: 'ただの共有テキスト', type: SharedMediaType.TEXT),
      ]);

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.text);
      expect(payload.value, 'ただの共有テキスト');
    });

    test('空リストの場合はnullを返す', () {
      expect(ShareIntentHandler.classify([]), isNull);
    });

    test('valueがnullまたは空白のみの場合はnullを返す（不正payloadの安全な処理）', () {
      expect(
        ShareIntentHandler.classify([
          _file(value: null, type: SharedMediaType.TEXT),
        ]),
        isNull,
      );
      expect(
        ShareIntentHandler.classify([
          _file(value: '   ', type: SharedMediaType.TEXT),
        ]),
        isNull,
      );
    });

    test('TEXT/URL以外の種別（画像等）は無視して次の候補を探す', () {
      final payload = ShareIntentHandler.classify([
        _file(value: '/path/to/image.png', type: SharedMediaType.IMAGE),
        _file(value: '共有テキスト', type: SharedMediaType.TEXT),
      ]);

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.text);
    });

    test('http://・https://いずれもネイティブ側がURL型であればurlとして分類される', () {
      final httpsPayload = ShareIntentHandler.classify([
        _file(value: 'https://example.com/article', type: SharedMediaType.URL),
      ]);
      final httpPayload = ShareIntentHandler.classify([
        _file(value: 'http://example.com/article', type: SharedMediaType.URL),
      ]);

      expect(httpsPayload!.kind, SharedContentKind.url);
      expect(httpPayload!.kind, SharedContentKind.url);
    });

    test('URLを含む通常文章はネイティブ側でTEXT判定されるため、Quick Listen対象のtextのまま扱う', () {
      // URLUtil.isValidUrl()は文字列全体が厳密なURLである場合のみtrueになるため、
      // 前後に文章が付くとネイティブ側でTEXT判定される。ここではその前提を
      // Dart側のclassify()が正しく尊重する（勝手にURL扱いへ格上げしない）ことを確認する。
      final payload = ShareIntentHandler.classify([
        _file(
          value: 'これ面白かった見て https://example.com/article',
          type: SharedMediaType.TEXT,
        ),
      ]);

      expect(payload!.kind, SharedContentKind.text);
    });

    test('valueの前後空白はclassify()では保持され、トリムは呼び出し側の責務とする', () {
      final payload = ShareIntentHandler.classify([
        _file(value: '  https://example.com/article  ', type: SharedMediaType.URL),
      ]);

      expect(payload!.value, '  https://example.com/article  ');
    });

    test('flowIdを渡すとSharedTextPayloadにそのまま伝播する（share flowの相関ID）', () {
      final payload = ShareIntentHandler.classify(
        [_file(value: '共有テキスト', type: SharedMediaType.TEXT)],
        flowId: 'stream-1',
      );

      expect(payload!.flowId, 'stream-1');
    });

    test('flowId未指定時は空文字（既存呼び出し・テストとの後方互換）', () {
      final payload = ShareIntentHandler.classify([
        _file(value: '共有テキスト', type: SharedMediaType.TEXT),
      ]);

      expect(payload!.flowId, '');
    });
  });

  group('ShareIntentHandler.diagnoseCandidates (No.94 Observability)', () {
    test('classify()と同じ選択規則で、選択されたcandidateのindex/種別を返す', () {
      final diagnostics = ShareIntentHandler.diagnoseCandidates([
        _file(value: '/path/to/image.png', type: SharedMediaType.IMAGE),
        _file(value: '共有テキスト', type: SharedMediaType.TEXT),
      ]);

      expect(diagnostics.candidateCount, 2);
      expect(diagnostics.selectedIndex, 1);
      expect(diagnostics.selectedKind, 'text');
    });

    test('URL型が選択される場合はselectedKind=url', () {
      final diagnostics = ShareIntentHandler.diagnoseCandidates([
        _file(value: 'https://example.com/article', type: SharedMediaType.URL),
      ]);

      expect(diagnostics.selectedIndex, 0);
      expect(diagnostics.selectedKind, 'url');
    });

    test('該当candidateが無い場合はselectedIndex=-1・selectedKind=none', () {
      final diagnostics = ShareIntentHandler.diagnoseCandidates([
        _file(value: null, type: SharedMediaType.TEXT),
        _file(value: '   ', type: SharedMediaType.TEXT),
      ]);

      expect(diagnostics.candidateCount, 2);
      expect(diagnostics.selectedIndex, -1);
      expect(diagnostics.selectedKind, 'none');
    });

    test('空リストではcandidateCount=0・selectedIndex=-1', () {
      final diagnostics = ShareIntentHandler.diagnoseCandidates([]);

      expect(diagnostics.candidateCount, 0);
      expect(diagnostics.selectedIndex, -1);
      expect(diagnostics.selectedKind, 'none');
    });

    test('toLogFields()は本文を含まずcandidateCount/selectedIndex/selectedKindのみ返す', () {
      const secret = 'SECRET_TEST_PAYLOAD_12345';
      final diagnostics = ShareIntentHandler.diagnoseCandidates([
        _file(value: secret, type: SharedMediaType.TEXT),
      ]);
      final fields = diagnostics.toLogFields();

      expect(fields.keys,
          containsAll(['candidateCount', 'selectedIndex', 'selectedKind']));
      for (final value in fields.values) {
        expect(value.toString(), isNot(contains(secret)));
      }
    });

    // ChatGPT re-review対応: 「複数candidateのうち意図しないcandidateが選択された」
    // 仮説の切り分け用に、非選択candidateも含めた先頭maxLoggedCandidates件の
    // per-candidate metadataを追加した。以下はその回帰テスト。
    group('per-candidate metadata（非選択candidateの可視化）', () {
      test('TEXT/TEXT混在: 両candidateのkind/charCount/hashがindex別に記録される', () {
        final diagnostics = ShareIntentHandler.diagnoseCandidates([
          _file(value: 'TEXT A', type: SharedMediaType.TEXT),
          _file(value: 'TEXT B and more', type: SharedMediaType.TEXT),
        ]);

        expect(diagnostics.candidateCount, 2);
        expect(diagnostics.selectedIndex, 0);
        expect(diagnostics.loggedCandidates, hasLength(2));

        final c0 = diagnostics.loggedCandidates[0];
        final c1 = diagnostics.loggedCandidates[1];
        expect(c0.kind, 'text');
        expect(c0.valuePresent, isTrue);
        expect(c0.charCount, 'TEXT A'.length);
        expect(c1.kind, 'text');
        expect(c1.charCount, 'TEXT B and more'.length);
        // 異なる本文は異なるhashになる（=candidateごとに識別できる）。
        expect(c0.payloadHash, isNot(c1.payloadHash));
      });

      test('IMAGE/TEXT混在: 非選択のIMAGE candidateもkind/valuePresentが記録される', () {
        final diagnostics = ShareIntentHandler.diagnoseCandidates([
          _file(value: '/path/to/image.png', type: SharedMediaType.IMAGE),
          _file(value: '共有テキスト', type: SharedMediaType.TEXT),
        ]);

        expect(diagnostics.selectedIndex, 1);
        final c0 = diagnostics.loggedCandidates[0];
        expect(c0.kind, 'image');
        expect(c0.valuePresent, isTrue);
        expect(c0.charCount, '/path/to/image.png'.length);
      });

      test('valueがnullのcandidateはvaluePresent=falseで、charCount等はnull', () {
        final diagnostics = ShareIntentHandler.diagnoseCandidates([
          _file(value: null, type: SharedMediaType.TEXT),
        ]);

        final c0 = diagnostics.loggedCandidates[0];
        expect(c0.valuePresent, isFalse);
        expect(c0.charCount, isNull);
        expect(c0.payloadHash, isNull);
      });

      test('候補数がmaxLoggedCandidates(3)を超えてもloggedCandidatesは先頭3件のみ、'
          'candidateCountは全件数を維持する', () {
        final diagnostics = ShareIntentHandler.diagnoseCandidates([
          _file(value: 'A', type: SharedMediaType.TEXT),
          _file(value: 'B', type: SharedMediaType.TEXT),
          _file(value: 'C', type: SharedMediaType.TEXT),
          _file(value: 'D', type: SharedMediaType.TEXT),
          _file(value: 'E', type: SharedMediaType.TEXT),
        ]);

        expect(diagnostics.candidateCount, 5);
        expect(diagnostics.loggedCandidates, hasLength(3));
        expect(ShareIntentHandler.maxLoggedCandidates, 3);
      });

      test('toLogFields()にはcandidate0Kind等が含まれ、本文そのものは一切含まれない'
          '（SECRET_CANDIDATE_A/B、両者で異なるhashになること）', () {
        const secretA = 'SECRET_CANDIDATE_A_12345';
        const secretB = 'SECRET_CANDIDATE_B_67890';
        final diagnostics = ShareIntentHandler.diagnoseCandidates([
          _file(value: secretA, type: SharedMediaType.TEXT),
          _file(value: secretB, type: SharedMediaType.TEXT),
        ]);
        final fields = diagnostics.toLogFields();

        expect(fields.keys, containsAll([
          'candidate0Kind',
          'candidate0ValuePresent',
          'candidate0CharCount',
          'candidate0TrimmedCharCount',
          'candidate0PayloadHash',
          'candidate0TrimmedPayloadHash',
          'candidate1Kind',
          'candidate1PayloadHash',
        ]));
        expect(fields['candidate0PayloadHash'], isNot(fields['candidate1PayloadHash']));

        for (final value in fields.values) {
          expect(value.toString(), isNot(contains(secretA)));
          expect(value.toString(), isNot(contains(secretB)));
        }

        // DebugLoggerの本文除去フィルタ（isForbiddenKey）にキー名が
        // 引っかかって黙って落とされないことも合わせて確認する。
        final line = DebugLogger.formatEvent('share_classified', fields);
        for (final key in fields.keys) {
          expect(line, contains('$key='), reason: '$keyがformatEvent()で除去されている');
        }
      });
    });
  });

  group(
      'ShareIntentHandler.getInitialSharedPayload '
      '(diagnostics/logging shape — classify()未実行の単体検証)', () {
    // 注記(ChatGPT re-review対応): このgroupはgetInitialSharedPayload()自体を
    // 呼び出さず、classify()/diagnoseCandidates()とDebugLogger.logEvent()を
    // 同じ引数で手動呼び出しして、initial_share_check_resultイベントの
    // フィールド形状とprivacy性だけを検証する（テスト名を実態に合わせて修正。
    // 実際にgetInitialSharedPayload()を通す実経路テストは次のgroupを参照）。
    setUp(() {
      DebugLogger.testSink = [];
    });

    tearDown(() {
      DebugLogger.testSink = null;
    });

    test(
        'initial_share_check_resultと同形のフィールドを組み立てても本文は含まれない'
        '（フィールド形状のみの単体検証。実経路の順序検証は次のgroup参照）', () async {
      const secret = 'SECRET_TEST_PAYLOAD_12345';

      final diagnostics = ShareIntentHandler.diagnoseCandidates([
        _file(value: secret, type: SharedMediaType.TEXT),
      ]);
      final payload = ShareIntentHandler.classify(
        [_file(value: secret, type: SharedMediaType.TEXT)],
        flowId: 'initial-1',
      );

      await DebugLogger.instance.logEvent('initial_share_check_result', {
        'flowId': 'initial-1',
        'fileCount': 1,
        'resultKind': payload?.kind.name ?? 'none',
        ...diagnostics.toLogFields(),
      });

      expect(DebugLogger.testSink!.single, isNot(contains(secret)));
      expect(DebugLogger.testSink!.single,
          contains('event=initial_share_check_result'));
      expect(DebugLogger.testSink!.single, contains('selectedKind=text'));
    });
  });

  group('ShareIntentHandler.getInitialSharedPayload (実経路: MethodChannelをmock)', () {
    // flutter_sharing_intentのMethodChannelFlutterSharingIntentは
    // MethodChannel('flutter_sharing_intent')のgetInitialSharing/resetを
    // 呼ぶ実装になっている（pub cache配布ソースで確認済み）。本番コード側に
    // 一切手を入れず、テスト側だけでこのMethodChannelの応答をmockすることで、
    // getInitialSharedPayload()を実際に呼び出す経路のテストが可能になる。
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('flutter_sharing_intent');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      DebugLogger.testSink = [];
    });

    tearDown(() {
      DebugLogger.testSink = null;
      messenger.setMockMethodCallHandler(channel, null);
    });

    test(
        'getInitialSharedPayload()を実際に呼び出すと、share_received→'
        'initial_share_check_requested→initial_share_check_result→'
        'share_classifiedの順で記録され、いずれも本文を含まない', () async {
      const secret = 'SECRET_TEST_PAYLOAD_12345';
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getInitialSharing') {
          return jsonEncode([
            {'value': secret, 'type': SharedMediaType.TEXT.index},
          ]);
        }
        if (call.method == 'reset') return null;
        return null;
      });

      final handler = ShareIntentHandler(onPayloadReceived: (_) {});
      final payload = await handler.getInitialSharedPayload();

      expect(payload, isNotNull);
      expect(payload!.value, secret);

      final eventNames = DebugLogger.testSink!
          .map((l) => l.split(' ').first.replaceFirst('event=', ''))
          .toList();
      expect(
        eventNames,
        [
          'share_received',
          'initial_share_check_requested',
          'initial_share_check_result',
          'share_classified',
        ],
      );

      for (final line in DebugLogger.testSink!) {
        expect(line, isNot(contains(secret)));
      }

      handler.dispose();
    });

    test('getInitialSharing()が空を返す場合はpayload=null、resultKind=noneが記録される',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getInitialSharing') return null;
        return null;
      });

      final handler = ShareIntentHandler(onPayloadReceived: (_) {});
      final payload = await handler.getInitialSharedPayload();

      expect(payload, isNull);
      final resultLine = DebugLogger.testSink!
          .firstWhere((l) => l.contains('event=initial_share_check_result'));
      expect(resultLine, contains('resultKind=none'));
      expect(resultLine, contains('fileCount=0'));

      handler.dispose();
    });
  });

  group('ShareIntentHandler.startListening/dispose '
      '(Persistent Share Observability Phase 1: listener lifecycle)', () {
    // No.94(ACTION_SEND間欠配信消失)の切り分け材料として、listenerの
    // 生存期間そのものをobservability対象にした。ここでは、追加した
    // lifecycle logging自体が既存のpayload delivery・dispose挙動を
    // 変えていないことを確認する。
    setUp(() {
      DebugLogger.testSink = [];
    });

    tearDown(() {
      DebugLogger.testSink = null;
    });

    test('startListening()はshare_listener_start_requested→'
        'share_listener_started→share_stream_subscription_createdの順で記録する',
        () {
      final handler = ShareIntentHandler(onPayloadReceived: (_) {});
      handler.startListening();

      final eventNames = DebugLogger.testSink!
          .map((l) => l.split(' ').first.replaceFirst('event=', ''))
          .toList();
      expect(
        eventNames,
        [
          'share_listener_start_requested',
          'share_listener_started',
          'share_stream_subscription_created',
        ],
      );

      handler.dispose();
    });

    test('dispose()はshare_listener_dispose_requestedを記録し、'
        'cancel()完了後にshare_listener_dispose_completedを記録する（既存の'
        'dispose()呼び出し規約(戻り値void・同期呼び出し)は変更しない）', () async {
      final handler = ShareIntentHandler(onPayloadReceived: (_) {});
      handler.startListening();
      DebugLogger.testSink!.clear();

      // 既存呼び出し元(main.dartのdispose())と同じく、戻り値を待たずに
      // 同期的に呼ぶ。
      handler.dispose();
      // cancel()完了(Future)を待つため、1 microtaskだけ進める。
      await Future<void>.delayed(Duration.zero);

      final eventNames = DebugLogger.testSink!
          .map((l) => l.split(' ').first.replaceFirst('event=', ''))
          .toList();
      expect(
        eventNames,
        ['share_listener_dispose_requested', 'share_listener_dispose_completed'],
      );
    });

    test('lifecycle loggingを追加しても、EventChannel経由で届いたpayloadは'
        '従来どおりonPayloadReceivedへ渡される（regressionなし）', () async {
      // flutter_sharing_intentのFlutterSharingIntent.getMediaStream()は
      // EventChannel("flutter_sharing_intent/events-sharing")を使う実装に
      // なっている（pub cache配布ソースで確認済み）。本番コード側に一切
      // 手を入れず、テスト側だけでこのEventChannelをmockすることで、
      // 追加したlifecycle loggingが実際のstream配信経路を壊していないことを
      // 検証できる。
      TestWidgetsFlutterBinding.ensureInitialized();
      const eventChannel =
          EventChannel('flutter_sharing_intent/events-sharing');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      late void Function(Object?) emit;
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(onListen: (arguments, events) {
          emit = events.success;
        }),
      );

      const secret = 'SECRET_STREAM_REGRESSION_CHECK';
      final received = <String>[];
      final handler =
          ShareIntentHandler(onPayloadReceived: (p) => received.add(p.value));
      handler.startListening();
      await Future<void>.delayed(Duration.zero);

      emit(jsonEncode([
        {'value': secret, 'type': SharedMediaType.TEXT.index},
      ]));
      await Future<void>.delayed(Duration.zero);

      expect(received, [secret]);
      // 追加したlifecycle logging自体が本文を漏らしていないことも確認する。
      for (final line in DebugLogger.testSink!) {
        expect(line, isNot(contains(secret)));
      }

      handler.dispose();
      messenger.setMockStreamHandler(eventChannel, null);
    });
  });
}
