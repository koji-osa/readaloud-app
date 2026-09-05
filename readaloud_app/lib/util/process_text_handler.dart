import 'dart:async';

import 'package:flutter/services.dart';

import 'debug_logger.dart';
import 'share_fingerprint.dart';
import 'share_intent_handler.dart' show SharedContentKind, SharedTextPayload;

/// Android標準のテキスト選択メニュー(ACTION_PROCESS_TEXT)から選択テキストを
/// 受け取るためのhandler。
///
/// 【重要: Activity cold start ≠ Dart cold start】
/// ReadAloudはaudio_service(0.18.18)のcached FlutterEngineパターン
/// (`AudioServiceActivity.provideFlutterEngine()` →
/// `AudioServicePlugin.getFlutterEngine()`)を使っているため、
/// `MainActivity.onCreate()`が呼ばれても、Dartの`main()`/
/// `AppEntryPoint.initState()`が再実行されるとは限らない
/// （Activityだけが再生成され、Dart isolateとwidget treeの状態は
/// そのまま生き続けるケースがある）。
///
/// 【単一消費経路（ChatGPT re-review v2対応）】
/// 当初はnative→Dartのpush(`deliverProcessText`)が選択テキスト本文
/// そのものを運んでいたが、pushのack応答で native側のpending slotが
/// クリアされる前に、Dart側のstartup pull(`pullPendingProcessText`)が
/// 同じ本文を取得できるrace（同一PROCESS_TEXTの二重delivery）があった。
///
/// そのため設計を変更し、native→Dartのpushは`processTextAvailable`という
/// **本文を含まない通知**のみとした。選択テキスト本文をDartへ渡す経路は
/// [drainPendingProcessText]が呼ぶ`pullPendingProcessText`の応答**だけ**
/// であり、native側はこの呼び出しでのみ本文を読み取ると同時にクリアする
/// （atomic consume。native側の実装はandroid/.../MainActivity.kt参照）。
/// 通知経路(`startListening`)とstartup経路(`pullInitialProcessText`)の
/// どちらから[drainPendingProcessText]が呼ばれても、実際に本文を取得
/// できるのはどちらか一方だけであり、二重配信は構造的に起こらない。
///
/// Dart側でも、[drainPendingProcessText]の呼び出しをin-flight Futureで
/// 共有し、同時に複数箇所から呼ばれても実際のnative呼び出しは1回に
/// 集約する（二重配信防止の本体はnative側のatomic consumeであり、これは
/// 無駄な重複呼び出しを避けるための補助的な最適化）。
///
/// 【arbitration: stale ACTION_SENDへのフォールスルー防止】
/// 現在の起動/セッションでPROCESS_TEXTが処理された（通知経由・pull経由の
/// いずれか）という事実は、[hasDeliveredProcessText]で保持する。
/// 「pending slotに現在textが残っているか」（[drainPendingProcessText]の
/// 戻り値）と「このセッションでPROCESS_TEXTが処理された事実があるか」
/// ([hasDeliveredProcessText])は別物であるため、main.dartの
/// `_checkInitialShareIntent()`は両方を確認したうえで、いずれもfalseの
/// 場合のみ`ShareIntentHandler.getInitialSharedPayload()`
/// （No.94で問題になったflutter_sharing_intent側のstale initial payload
/// を返しうる）へフォールスルーする。
///
/// flutter_sharing_intentプラグインはACTION_PROCESS_TEXTを一切処理しない
/// （プラグイン本体はACTION_SEND/SEND_MULTIPLE/VIEW/WEB_SEARCHのみ対応）ため、
/// plugin改変を避けるためReadAloud独自のMethodChannelでDart側へ橋渡しする。
///
/// 選択テキストは常に[SharedContentKind.text]として扱う（URL形式であっても
/// Web Import/AddScreenへは送らない。ユーザーが「選択したものを聴く」操作を
/// したためで、classify()側でURL判定はしない）。
class ProcessTextHandler {
  static const MethodChannel _methodChannel =
      MethodChannel('com.example.readaloud_app/process_text');

  final void Function(SharedTextPayload payload) onPayloadReceived;

  // ShareIntentHandlerのflowId体系(initial-N/stream-N)と衝突しないよう、
  // process_text専用のprefixを使う。'notification'/'pull'は「cold/warmと
  // いうActivity lifecycleの推測」ではなく、実際にどちらの経路で
  // drainがトリガーされたかを示す（class docの
  // 「Activity cold start ≠ Dart cold start」参照）。
  static int _flowSeq = 0;
  static String _nextFlowId(String source) => '$source-${++_flowSeq}';

  // 複数箇所(native通知/startup pull)から同時に[drainPendingProcessText]が
  // 呼ばれても、実際のnative呼び出し(pullPendingProcessText)は1回に集約する
  // ためのin-flight guard。二重配信防止の本体はnative側のpendingProcessText
  // 単一slot・atomic consumeであり、これはその上での無駄な重複呼び出しを
  // 避けるための最適化。
  Future<bool>? _drainInFlight;

  // 現在のDartセッションでPROCESS_TEXTが一度でも処理されたか
  // （通知経由・pull経由いずれか）。main.dartのarbitration判定に使う
  // （class docの「arbitration」参照）。
  bool _hasDeliveredProcessText = false;
  bool get hasDeliveredProcessText => _hasDeliveredProcessText;

  ProcessTextHandler({required this.onPayloadReceived});

  /// native→Dartの通知(`processTextAvailable`、本文は含まない)を受け付ける
  /// handlerを登録する。通知を受け取ったら[drainPendingProcessText]で
  /// 実際にpullする。Dart isolateの生存期間中1回だけ呼べばよい。
  void startListening() {
    unawaited(DebugLogger.instance.logEvent('process_text_listener_started', {
      'epochMs': DateTime.now().millisecondsSinceEpoch,
    }));
    _methodChannel.setMethodCallHandler((call) async {
      if (call.method != 'processTextAvailable') return null;
      // native側はこの通知を2引数のinvokeMethod(応答を待たないfire-and-forget)
      // で送るため、ここでawaitしても native の処理をブロックしない。
      await drainPendingProcessText(source: 'process_text_notification');
      return null;
    });
  }

  /// アプリ起動直後に1回だけ呼ぶfallback pull。
  ///
  /// [startListening]による通知handlerの登録が、native側でのIntent capture
  /// より後になってしまう真のcold start（FlutterEngineが新規生成される場合）
  /// に備える。通知経由で既に処理済みであれば`false`が返るだけなので、
  /// 呼び出し順に関わらず二重処理にはならない。
  ///
  /// 【重要】戻り値が`false`でも、[hasDeliveredProcessText]が`true`なら
  /// 「現在の起動はPROCESS_TEXTによるものだったが、通知経由で既に処理
  /// 済み」という意味であり、呼び出し元は
  /// `ShareIntentHandler.getInitialSharedPayload()`へフォールスルーしては
  /// ならない（class docの「arbitration」参照）。
  Future<bool> pullInitialProcessText() {
    return drainPendingProcessText(source: 'process_text_pull');
  }

  /// 選択テキスト取得の唯一の消費経路。native側`pullPendingProcessText`を
  /// 呼び、本文取得・分類・ログ・[onPayloadReceived]呼び出しをすべて内部で
  /// 行う。native側のpendingProcessTextは単一slot・atomic consumeのため、
  /// 通知経路とstartup経路の両方から同時に呼ばれても、実際に本文を
  /// 得られるのはどちらか一方だけであり、二重に[onPayloadReceived]が
  /// 呼ばれることはない。戻り値はpayloadを実際に処理したかどうか
  /// （テスト・呼び出し元のarbitration判定用）。
  Future<bool> drainPendingProcessText({required String source}) {
    return _drainInFlight ??= _performDrain(source).whenComplete(() {
      _drainInFlight = null;
    });
  }

  Future<bool> _performDrain(String source) async {
    final flowId = _nextFlowId(source);
    await DebugLogger.instance
        .logEvent('share_received', {'source': source, 'flowId': flowId});
    String? text;
    try {
      text =
          await _methodChannel.invokeMethod<String>('pullPendingProcessText');
    } catch (e) {
      await DebugLogger.instance.logEvent('share_pipeline_error', {
        'stage': 'process_text_pull',
        'source': source,
        'flowId': flowId,
        'errorType': e.runtimeType.toString(),
      });
      return false;
    }
    final payload = classify(text, flowId: flowId);
    await DebugLogger.instance.logEvent('share_classified', {
      'source': source,
      'kind': payload?.kind.name ?? 'none',
      'flowId': flowId,
      if (payload != null)
        ...ShareFingerprint.metricsOf(payload.value).toLogFields(),
    });
    if (payload == null) return false;
    _hasDeliveredProcessText = true;
    onPayloadReceived(payload);
    return true;
  }

  /// ACTION_PROCESS_TEXTの選択テキストを常に[SharedContentKind.text]として
  /// 分類する（テスト容易性のためstatic）。null/空/空白のみはnullを返す。
  /// URL形式であってもurlへ格上げしない（Section 6の設計方針どおり。
  /// ShareIntentHandler.classify()とは異なり、ネイティブ側URL判定結果を
  /// 参照する余地がそもそも無いため常にtext固定でよい）。
  static SharedTextPayload? classify(String? rawText, {String flowId = ''}) {
    if (rawText == null) return null;
    if (rawText.trim().isEmpty) return null;
    return SharedTextPayload(SharedContentKind.text, rawText, flowId: flowId);
  }

  void dispose() {
    _methodChannel.setMethodCallHandler(null);
  }
}
