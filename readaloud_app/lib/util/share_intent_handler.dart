import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'dart:async';
import 'debug_logger.dart';

/// 共有されたテキストの種類。
/// URLの判定はネイティブ側(URLUtil.isValidUrl)で行われ、
/// SharedFile.typeとしてすでに渡ってくる。
enum SharedContentKind { text, url }

class SharedTextPayload {
  final SharedContentKind kind;
  final String value;

  // initial/stream経路をまたいで1本のshare flowを追跡するための相関ID。
  // ShareIntentHandlerが払い出したflowIdをそのまま保持し、
  // _handleSharedPayload()以降のObservabilityログにも伝播させる。
  final String flowId;

  const SharedTextPayload(this.kind, this.value, {this.flowId = ''});
}

class ShareIntentHandler {
  StreamSubscription? _subscription;
  final void Function(SharedTextPayload payload) onPayloadReceived;

  // Observability: initial経路とstream経路は独立して発火しうるため、
  // 同一呼び出しのshare_received/share_classifiedを対応付けられるよう
  // 呼び出しごとに一意なflowIdを払い出す（症状1の競合切り分け用の
  // 最小限の相関情報。本文・URL等は含まない）。
  static int _flowSeq = 0;
  static String _nextFlowId(String source) => '$source-${++_flowSeq}';

  ShareIntentHandler({required this.onPayloadReceived});

  // アプリ起動中の共有を受け取る
  void startListening() {
    _subscription = FlutterSharingIntent.instance
        .getMediaStream()
        .listen((List<SharedFile> files) {
      final flowId = _nextFlowId('stream');
      unawaited(DebugLogger.instance.logEvent(
          'share_received', {'source': 'stream', 'flowId': flowId}));
      final payload = classify(files, flowId: flowId);
      unawaited(DebugLogger.instance.logEvent('share_classified', {
        'source': 'stream',
        'kind': payload?.kind.name ?? 'none',
        'flowId': flowId,
      }));
      if (payload != null) onPayloadReceived(payload);
    });
  }

  // アプリ起動時に共有されたテキストを取得
  Future<SharedTextPayload?> getInitialSharedPayload() async {
    final flowId = _nextFlowId('initial');
    await DebugLogger.instance.logEvent(
        'share_received', {'source': 'initial', 'flowId': flowId});
    final files =
        await FlutterSharingIntent.instance.getInitialSharing();
    // 取得後にリセット（再起動時に同じテキストが表示されないよう）
    FlutterSharingIntent.instance.reset();
    final payload = classify(files, flowId: flowId);
    await DebugLogger.instance.logEvent('share_classified', {
      'source': 'initial',
      'kind': payload?.kind.name ?? 'none',
      'flowId': flowId,
    });
    return payload;
  }

  // text/plainの共有をURL・通常テキストに分類する（テスト容易性のためstatic）。
  // flowIdは相関ID伝播用の付加情報で、分類結果そのものには影響しない。
  static SharedTextPayload? classify(List<SharedFile> files, {String flowId = ''}) {
    for (final file in files) {
      final value = file.value;
      if (value == null || value.trim().isEmpty) continue;
      if (file.type == SharedMediaType.URL) {
        return SharedTextPayload(SharedContentKind.url, value, flowId: flowId);
      }
      if (file.type == SharedMediaType.TEXT) {
        return SharedTextPayload(SharedContentKind.text, value, flowId: flowId);
      }
    }
    return null;
  }

  void dispose() {
    _subscription?.cancel();
  }
}
