import 'dart:async';

import 'package:flutter/services.dart';

import 'debug_logger.dart';
import 'share_fingerprint.dart';
import 'share_intent_handler.dart' show SharedContentKind, SharedTextPayload;

/// No.94 Share Event Architecture（Architecture Z）。
///
/// `ACTION_SEND`(text/plain)/`ACTION_PROCESS_TEXT`(text/plain)いずれも、
/// native側`ExternalInputEntryActivity`（plain Activity、
/// FlutterEngineへ非attach）が唯一のcapture元となり、
/// `ExternalInputPendingStore`（single slot、`{source, kind, text}`）
/// へ書き込む。このhandlerは旧`ActionSendHandler`/`ProcessTextHandler`
/// を統合した**唯一**のDart側bridgeであり、`MainActivity`の統合
/// MethodChannel(`pullPendingExternalInput`)を通じて本文を取得する。
///
/// 【単一消費経路（5709c892から継続）】
/// native→Dartのpushは`externalInputAvailable`という**本文を含まない
/// 通知**のみ。本文をDartへ渡す経路は[drainPendingExternalInput]が呼ぶ
/// `pullPendingExternalInput`の応答**だけ**であり、native側はこの
/// 呼び出しでのみ本文を読み取ると同時にclearする（atomic consume）。
///
/// 【Cross-ingress ordering（Architecture Z本体）】
/// `ACTION_SEND`と`ACTION_PROCESS_TEXT`は単一のnative pending store・
/// 単一のMethodChannel・この単一handlerを共有するため、
/// PROCESS_TEXT→ACTION_SEND・ACTION_SEND→PROCESS_TEXTいずれの順序でも、
/// 後着のfresh eventが最終的にDartへ届く（native側の単一main
/// thread・single slotのoverwrite semanticsにより、global total
/// orderが自明に成立する）。
///
/// 【Redrain design（v3 addendum）】
/// callback（[onPayloadReceived]）を`Future<void> Function`として
/// **await**することで、native event order→pull order→
/// `_handleSharedPayload()`のUI/navigation完了順序を同一drain
/// cycle内でserializeする。callback in-flight中に後続eventの通知が
/// 来た場合は[_redrainRequested]をtrueにしてin-flight Futureへ
/// joinし、現在のcallbackが完了した時点で自動的に再pull
/// （redrain）する——これにより、pull済みだがcallback処理未完了の
/// 間に後続eventが来ても取り残されない（v2で未検討だったgap、
/// v3 addendumで解消）。queue・timer・content hashは一切使わない
/// （1 in-flight Future + 1 redrain boolのみで完結する）。
///
/// 【非Android platform】
/// このhandlerのnative実装はAndroidにのみ存在する。非Android
/// platformでは[drainPendingExternalInput]は例外を捕捉してfalseを
/// 返すだけで無害（既存`ActionSendHandler`/`ProcessTextHandler`と
/// 同じ扱い）であり、`ShareIntentHandler`（flutter_sharing_intent
/// 経由）が引き続き唯一の共有経路となる（`lib/main.dart`の
/// `Platform.isAndroid`分岐参照）。
class ExternalInputHandler {
  static const MethodChannel _methodChannel =
      MethodChannel('com.example.readaloud_app/external_input');

  final Future<void> Function(SharedTextPayload payload) onPayloadReceived;

  // 他handlerのflowId体系と衝突しないよう、external_input専用の
  // prefixを使う。
  static int _flowSeq = 0;
  static String _nextFlowId(String source) => '$source-${++_flowSeq}';

  // 複数箇所(native通知/startup pull/redrain)から同時に
  // drainPendingExternalInputが呼ばれても、実際のnative呼び出しは
  // in-flightの間は増えない（既存in-flight Futureへjoinする）ための
  // guard。
  Future<bool>? _drainInFlight;

  // in-flight中に後続の通知/pull要求が来たかどうか。現在のcallback
  // （_performDrain内のonPayloadReceived await）が完了した時点で
  // このflagを見て、trueならもう一度_performDrainを実行する
  // （redrain）。v3 addendum参照。
  bool _redrainRequested = false;

  ExternalInputHandler({required this.onPayloadReceived});

  /// native→Dartの通知(`externalInputAvailable`、本文は含まない)を
  /// 受け付けるhandlerを登録する。通知を受け取ったら
  /// [drainPendingExternalInput]で実際にpullする。Dart isolateの
  /// 生存期間中1回だけ呼べばよい。
  void startListening() {
    unawaited(DebugLogger.instance.logEvent('external_input_listener_started', {
      'epochMs': DateTime.now().millisecondsSinceEpoch,
    }));
    _methodChannel.setMethodCallHandler((call) async {
      if (call.method != 'externalInputAvailable') return null;
      // native側はこの通知を2引数のinvokeMethod(応答を待たないfire-and-forget)
      // で送るため、ここでawaitしてもnativeの処理をブロックしない。
      await drainPendingExternalInput(source: 'external_input_notification');
      return null;
    });
  }

  /// アプリ起動直後に1回だけ呼ぶfallback pull。
  ///
  /// [startListening]による通知handlerの登録が、native側でのIntent
  /// capture・forwardingより後になってしまう真のcold start
  /// （FlutterEngineが新規生成される場合）に備える。通知経由で既に
  /// 処理済みであれば`false`が返るだけなので、呼び出し順に関わらず
  /// 二重処理にはならない。
  Future<bool> pullInitialExternalInput() {
    return drainPendingExternalInput(source: 'external_input_pull');
  }

  /// external input取得の唯一の消費経路。native側
  /// `pullPendingExternalInput`を呼び、本文取得・分類・ログ・
  /// [onPayloadReceived]呼び出し（await）をすべて内部で行う。
  /// 呼び出し中に別の通知/pull要求が来た場合は、現在の処理完了後に
  /// 自動的に再pull（redrain）する。戻り値はこのcycle全体で
  /// 1回以上payloadを実際に処理したかどうか（`anyDelivered`）。
  Future<bool> drainPendingExternalInput({required String source}) {
    if (_drainInFlight != null) {
      _redrainRequested = true;
      return _drainInFlight!;
    }
    return _drainInFlight = _runDrainLoop(source);
  }

  Future<bool> _runDrainLoop(String initialSource) async {
    var source = initialSource;
    var anyDelivered = false;
    try {
      while (true) {
        final delivered = await _performDrain(source);
        anyDelivered = anyDelivered || delivered;
        if (!_redrainRequested) break;
        _redrainRequested = false;
        source = 'external_input_redrain';
      }
    } finally {
      // 例外発生時も含め、必ずclean stateへ戻す（v3 addendum
      // 「Exception-safe state reset」参照）。retry/backoffは追加
      // しない——次のfresh eventが新しいdrain cycleを開始できれば
      // 十分。
      _drainInFlight = null;
      _redrainRequested = false;
    }
    return anyDelivered;
  }

  Future<bool> _performDrain(String source) async {
    final flowId = _nextFlowId(source);
    await DebugLogger.instance
        .logEvent('share_received', {'source': source, 'flowId': flowId});
    Map<Object?, Object?>? result;
    try {
      result = await _methodChannel
          .invokeMapMethod<Object?, Object?>('pullPendingExternalInput');
    } catch (e) {
      // 非Android platform（native実装なし）やその他のchannel例外では、
      // ここでfalseを返すだけで無害（既存handlerと同じ扱い）。
      await DebugLogger.instance.logEvent('share_pipeline_error', {
        'stage': 'external_input_pull',
        'source': source,
        'flowId': flowId,
        'errorType': e.runtimeType.toString(),
      });
      return false;
    }
    final payload = classify(result, flowId: flowId);
    await DebugLogger.instance.logEvent('share_classified', {
      'source': source,
      'nativeSource': result?['source'],
      'kind': payload?.kind.name ?? 'none',
      'flowId': flowId,
      if (payload != null)
        ...ShareFingerprint.metricsOf(payload.value).toLogFields(),
    });
    if (payload == null) return false;
    // native event order → pull order → UI/navigation完了順序を
    // 同一drain cycle内でserializeするため、ここでawaitする
    // （v3 addendum「Async delivery boundary」参照。旧handlerでは
    // awaitしていなかったため、in-flight中に後続eventのnavigationが
    // 並行実行され得るraceがあった）。
    await onPayloadReceived(payload);
    return true;
  }

  /// nativeから返るMap({'source': String, 'kind': String,
  /// 'text': String})を[SharedTextPayload]へ分類する（テスト容易性の
  /// ためstatic）。null/missing text/空白のみはnullを返す。kindの
  /// 最終判定はnative側（ACTION_SENDは`URLUtil.isValidUrl`、
  /// ACTION_PROCESS_TEXTは常に'text'固定）の結果をそのまま尊重する
  /// （Dart側で再判定しない）。
  static SharedTextPayload? classify(
    Map<Object?, Object?>? result, {
    String flowId = '',
  }) {
    if (result == null) return null;
    final text = result['text'] as String?;
    if (text == null || text.trim().isEmpty) return null;
    final kind = result['kind'] == 'url'
        ? SharedContentKind.url
        : SharedContentKind.text;
    return SharedTextPayload(kind, text, flowId: flowId);
  }

  void dispose() {
    _methodChannel.setMethodCallHandler(null);
  }
}
