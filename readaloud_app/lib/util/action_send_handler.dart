import 'dart:async';

import 'package:flutter/services.dart';

import 'debug_logger.dart';
import 'share_fingerprint.dart';
import 'share_intent_handler.dart' show SharedContentKind, SharedTextPayload;

/// No.94「外部からtext/plainを共有した際、ReadAloudは開くがHomeに留まり
/// Quick Listenへ進まない」間欠障害のroot-cause fix。
///
/// 【root cause: flutter_sharing_intent 2.0.4のACTION_SEND delivery race】
/// 本アプリが使用するflutter_sharing_intent 2.0.4のAndroid実装は、
/// ACTION_SEND到達時にDart側`getMediaStream()`のlistenerがまだ登録されて
/// おらず`eventSinkSharing`がnullだと、payloadを内部の`latestSharing`へ
/// 保存するだけでDartへは何も配信しない。かつ`onListen()`側の
/// 「listener登録後にcached `latestSharing`を再配信する」コードは
/// コメントアウトされている（upstream Issue #46・PR #107で修正済みだが、
/// 本アプリが使用する2.0.4には未反映）。そのため
/// 「ACTION_SEND到着 → (listener未登録) → listener登録」という順序に
/// なると、本文が両側どこにも残らず消失する。
///
/// plugin本体（pubspec.lock固定version、native source）は一切変更せず、
/// [ProcessTextHandler]と全く同じ設計原則を適用する:
/// native→Dartのpushは`actionSendAvailable`という**本文を含まない通知**
/// のみであり、本文をDartへ渡す経路は[drainPendingActionSend]が呼ぶ
/// `pullPendingActionSend`の応答**だけ**。native側はこの呼び出しでのみ
/// 本文(+URL/text判定)を読み取ると同時にクリアする（atomic consume。
/// native側の実装はandroid/.../MainActivity.kt参照）。通知経路
/// ([startListening])とstartup経路([pullInitialActionSend])のどちらから
/// [drainPendingActionSend]が呼ばれても、実際に本文を取得できるのは
/// どちらか一方だけであり、二重配信は構造的に起こらない。
///
/// 【flutter_sharing_intentとの二重配送防止】
/// Android上のtext/plain ACTION_SENDについては、このhandlerを唯一の
/// 配信経路とする。flutter_sharing_intent側のplugin native実装
/// (`handleIntent()`)自体は変更していないため引き続き内部状態
/// (`latestSharing`等)を更新するが、`lib/main.dart`はAndroidにおいて
/// `ShareIntentHandler.startListening()`を呼ばない（そのstream経由での
/// 配信を止める）ことで、同一ACTION_SENDが2経路から二重に
/// `onPayloadReceived`を呼ぶことを防いでいる。非Android platformでは
/// このhandlerのnative実装が存在しないため、[drainPendingActionSend]は
/// 例外を捕捉してfalseを返すだけで無害（[ProcessTextHandler]と同じ
/// 既存の扱い）であり、`ShareIntentHandler`が引き続き唯一の共有経路となる。
class ActionSendHandler {
  static const MethodChannel _methodChannel =
      MethodChannel('com.example.readaloud_app/action_send');

  final void Function(SharedTextPayload payload) onPayloadReceived;

  // ShareIntentHandler/ProcessTextHandlerのflowId体系と衝突しないよう、
  // action_send専用のprefixを使う。
  static int _flowSeq = 0;
  static String _nextFlowId(String source) => '$source-${++_flowSeq}';

  // 複数箇所(native通知/startup pull)から同時に[drainPendingActionSend]が
  // 呼ばれても、実際のnative呼び出し(pullPendingActionSend)は1回に集約する
  // ためのin-flight guard（ProcessTextHandlerと同じ設計）。
  Future<bool>? _drainInFlight;

  // 現在のDartセッションでACTION_SENDが一度でも処理されたか
  // （通知経由・pull経由いずれか）。ProcessTextHandler.hasDeliveredProcessText
  // と同じ形で公開する（テスト・将来のarbitration判定用）。
  bool _hasDeliveredActionSend = false;
  bool get hasDeliveredActionSend => _hasDeliveredActionSend;

  ActionSendHandler({required this.onPayloadReceived});

  /// native→Dartの通知(`actionSendAvailable`、本文は含まない)を受け付ける
  /// handlerを登録する。通知を受け取ったら[drainPendingActionSend]で
  /// 実際にpullする。Dart isolateの生存期間中1回だけ呼べばよい。
  void startListening() {
    unawaited(DebugLogger.instance.logEvent('action_send_listener_started', {
      'epochMs': DateTime.now().millisecondsSinceEpoch,
    }));
    _methodChannel.setMethodCallHandler((call) async {
      if (call.method != 'actionSendAvailable') return null;
      // native側はこの通知を2引数のinvokeMethod(応答を待たないfire-and-forget)
      // で送るため、ここでawaitしてもnativeの処理をブロックしない。
      await drainPendingActionSend(source: 'action_send_notification');
      return null;
    });
  }

  /// アプリ起動直後に1回だけ呼ぶfallback pull。
  ///
  /// [startListening]による通知handlerの登録が、native側でのIntent capture
  /// より後になってしまう真のcold start（FlutterEngineが新規生成される場合）
  /// に備える。通知経由で既に処理済みであれば`false`が返るだけなので、
  /// 呼び出し順に関わらず二重処理にはならない。
  Future<bool> pullInitialActionSend() {
    return drainPendingActionSend(source: 'action_send_pull');
  }

  /// ACTION_SEND本文取得の唯一の消費経路。native側`pullPendingActionSend`を
  /// 呼び、本文取得・分類・ログ・[onPayloadReceived]呼び出しをすべて内部で
  /// 行う。native側のpending slotは単一slot・atomic consumeのため、
  /// 通知経路とstartup経路の両方から同時に呼ばれても、実際に本文を
  /// 得られるのはどちらか一方だけであり、二重に[onPayloadReceived]が
  /// 呼ばれることはない。戻り値はpayloadを実際に処理したかどうか
  /// （テスト用）。
  Future<bool> drainPendingActionSend({required String source}) {
    return _drainInFlight ??= _performDrain(source).whenComplete(() {
      _drainInFlight = null;
    });
  }

  Future<bool> _performDrain(String source) async {
    final flowId = _nextFlowId(source);
    await DebugLogger.instance
        .logEvent('share_received', {'source': source, 'flowId': flowId});
    Map<Object?, Object?>? result;
    try {
      result = await _methodChannel
          .invokeMapMethod<Object?, Object?>('pullPendingActionSend');
    } catch (e) {
      // 非Android platform（native実装なし）やその他のchannel例外では、
      // ここでfalseを返すだけで無害（ProcessTextHandlerと同じ扱い）。
      await DebugLogger.instance.logEvent('share_pipeline_error', {
        'stage': 'action_send_pull',
        'source': source,
        'flowId': flowId,
        'errorType': e.runtimeType.toString(),
      });
      return false;
    }
    final payload = classify(result, flowId: flowId);
    await DebugLogger.instance.logEvent('share_classified', {
      'source': source,
      'kind': payload?.kind.name ?? 'none',
      'flowId': flowId,
      if (payload != null)
        ...ShareFingerprint.metricsOf(payload.value).toLogFields(),
    });
    if (payload == null) return false;
    _hasDeliveredActionSend = true;
    onPayloadReceived(payload);
    return true;
  }

  /// nativeから返るMap({'text': String, 'kind': 'text'|'url'})を
  /// [SharedTextPayload]へ分類する（テスト容易性のためstatic）。
  /// null/missing text/空白のみはnullを返す。kindの最終判定はnative側
  /// (URLUtil.isValidUrl)の結果をそのまま尊重する（Dart側で再判定しない。
  /// 既存flutter_sharing_intentのURL判定semanticsと揃えるため）。
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
