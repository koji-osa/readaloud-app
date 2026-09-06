import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'dart:async';
import 'debug_logger.dart';
import 'share_fingerprint.dart';

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

/// [ShareIntentHandler.diagnoseCandidates]の結果。
/// classify()の実際の選択には一切影響しない、Observability専用の
/// 読み取り専用サマリ（本文は含まない）。
class ShareCandidateDiagnostics {
  final int candidateCount;

  // classify()と同じ規則で選ばれたcandidateのindex。該当なしは-1。
  final int selectedIndex;

  // 'text' | 'url' | 'none'（classify()の選択結果に対応。既存互換のため
  // enumの生の名前ではなくこの3値のまま維持する）
  final String selectedKind;

  // No.94 ChatGPT re-review対応: 「複数candidateのうち意図しないcandidateが
  // 選択された」仮説を切り分けられるよう、非選択candidateも含め先頭
  // [ShareIntentHandler.maxLoggedCandidates]件のprivacy-safe metadataを保持する。
  // candidateCount自体は全candidate数を表すため、ログ肥大化を避けても
  // 「何件あったか」は必ず分かる。
  final List<ShareCandidateSummary> loggedCandidates;

  const ShareCandidateDiagnostics({
    required this.candidateCount,
    required this.selectedIndex,
    required this.selectedKind,
    this.loggedCandidates = const [],
  });

  Map<String, Object?> toLogFields() {
    final fields = <String, Object?>{
      'candidateCount': candidateCount,
      'selectedIndex': selectedIndex,
      'selectedKind': selectedKind,
    };
    for (var i = 0; i < loggedCandidates.length; i++) {
      fields.addAll(loggedCandidates[i].toLogFields(i));
    }
    return fields;
  }
}

/// 1件のcandidateについてのprivacy-safe metadata。
/// [SharedFile.value]そのものは一切保持・返却しない。
class ShareCandidateSummary {
  // SharedMediaTypeの小文字名（'text'|'url'|'image'|'video'|'file'|
  // 'web_search'|'other'）。selectedKindとは異なり、classify()が
  // 選択対象としないtype（画像等）もそのまま可視化する。
  final String kind;

  // SharedFile.valueがnullでないか（空文字・空白のみでもtrueになりうる点で
  // classify()の「非空判定」より緩い。「pluginがそもそも値を返したか」を
  // 区別するための診断用フラグ）。
  final bool valuePresent;

  final int? charCount;
  final int? trimmedCharCount;
  final String? payloadHash;
  final String? trimmedPayloadHash;

  const ShareCandidateSummary({
    required this.kind,
    required this.valuePresent,
    this.charCount,
    this.trimmedCharCount,
    this.payloadHash,
    this.trimmedPayloadHash,
  });

  Map<String, Object?> toLogFields(int index) {
    final fields = <String, Object?>{
      'candidate${index}Kind': kind,
      'candidate${index}ValuePresent': valuePresent,
    };
    if (valuePresent) {
      fields['candidate${index}CharCount'] = charCount;
      fields['candidate${index}TrimmedCharCount'] = trimmedCharCount;
      fields['candidate${index}PayloadHash'] = payloadHash;
      fields['candidate${index}TrimmedPayloadHash'] = trimmedPayloadHash;
    }
    return fields;
  }
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

  // No.94 Observability: 同一プロセス内でShareIntentHandlerが複数回
  // 初期化されていないか切り分けるためのインスタンス識別子。本文は含まない。
  final int _listenerInstanceId = identityHashCode(Object());

  ShareIntentHandler({required this.onPayloadReceived});

  // アプリ起動中の共有を受け取る
  void startListening() {
    // Persistent Share Observability Phase 1: No.94(ACTION_SEND間欠配信消失)の
    // 切り分け材料として、listenerの生存期間そのものをobservability対象にする。
    // 既存のpayload delivery自体（getMediaStream()/.listen()呼び出し、
    // classify()の選択ロジック）は一切変更しない。
    unawaited(DebugLogger.instance.logEvent('share_listener_start_requested', {
      'listenerInstanceId': _listenerInstanceId,
    }));
    unawaited(DebugLogger.instance.logEvent('share_listener_started', {
      'listenerInstanceId': _listenerInstanceId,
      'epochMs': DateTime.now().millisecondsSinceEpoch,
    }));
    _subscription = FlutterSharingIntent.instance.getMediaStream().listen(
      (List<SharedFile> files) {
        final flowId = _nextFlowId('stream');
        unawaited(DebugLogger.instance.logEvent(
            'share_received', {'source': 'stream', 'flowId': flowId}));
        SharedTextPayload? payload;
        try {
          final diagnostics = diagnoseCandidates(files);
          payload = classify(files, flowId: flowId);
          unawaited(DebugLogger.instance.logEvent('share_classified', {
            'source': 'stream',
            'kind': payload?.kind.name ?? 'none',
            'flowId': flowId,
            ...diagnostics.toLogFields(),
            if (payload != null)
              ...ShareFingerprint.metricsOf(payload.value).toLogFields(),
          }));
        } catch (e) {
          unawaited(DebugLogger.instance.logEvent('share_pipeline_error', {
            'stage': 'classify',
            'source': 'stream',
            'flowId': flowId,
            'errorType': e.runtimeType.toString(),
          }));
          rethrow;
        }
        if (payload != null) onPayloadReceived(payload);
      },
      // No.94のための観測のみ。既存のエラー伝播semantics(onErrorを追加せず
      // 例外はそのまま伝播させる)は変更しない。getMediaStream()のbroadcast
      // streamが通常閉じることはないが、万一done通知が来た場合に備えて
      // listenerの生存状況を記録する。
      onDone: () {
        unawaited(DebugLogger.instance.logEvent('share_stream_done', {
          'listenerInstanceId': _listenerInstanceId,
        }));
      },
    );
    unawaited(
        DebugLogger.instance.logEvent('share_stream_subscription_created', {
      'listenerInstanceId': _listenerInstanceId,
      'subscriptionInstanceId': identityHashCode(_subscription),
    }));
  }

  // アプリ起動時に共有されたテキストを取得
  Future<SharedTextPayload?> getInitialSharedPayload() async {
    final flowId = _nextFlowId('initial');
    await DebugLogger.instance.logEvent(
        'share_received', {'source': 'initial', 'flowId': flowId});
    // getInitialSharing()呼び出し直前。既存のshare_received(source=initial)は
    // これより前に記録されているためpayload取得成功のEvidenceにならない点を、
    // このイベントと後続のinitial_share_check_resultで補う。
    await DebugLogger.instance
        .logEvent('initial_share_check_requested', {'flowId': flowId});
    List<SharedFile> files;
    try {
      files = await FlutterSharingIntent.instance.getInitialSharing();
    } catch (e) {
      await DebugLogger.instance.logEvent('share_pipeline_error', {
        'stage': 'initial_get',
        'source': 'initial',
        'flowId': flowId,
        'errorType': e.runtimeType.toString(),
      });
      rethrow;
    }
    // 取得後にリセット（再起動時に同じテキストが表示されないよう）
    FlutterSharingIntent.instance.reset();
    final diagnostics = diagnoseCandidates(files);
    final payload = classify(files, flowId: flowId);
    // getInitialSharing()完了後（=plugin側acquisition境界）のスナップショット。
    await DebugLogger.instance.logEvent('initial_share_check_result', {
      'flowId': flowId,
      'fileCount': files.length,
      'resultKind': payload?.kind.name ?? 'none',
      ...diagnostics.toLogFields(),
      if (payload != null)
        ...ShareFingerprint.metricsOf(payload.value).toLogFields(),
    });
    await DebugLogger.instance.logEvent('share_classified', {
      'source': 'initial',
      'kind': payload?.kind.name ?? 'none',
      'flowId': flowId,
      ...diagnostics.toLogFields(),
      if (payload != null)
        ...ShareFingerprint.metricsOf(payload.value).toLogFields(),
    });
    return payload;
  }

  // 大量candidateによるログ肥大化を避けるための上限（native側ClipDataの
  // MAX_LOGGED_CLIP_ITEMSと同じ考え方）。candidateCount自体はこの上限に
  // 関わらず常に全件数を報告する。
  static const int maxLoggedCandidates = 3;

  // classify()と全く同じ選択規則（最初の非空・URL/TEXT型candidate）を
  // なぞり、本文を含まない診断情報（候補数・選択されたindex/種別、および
  // 非選択candidateも含む先頭maxLoggedCandidates件のmetadata）だけを返す
  // Observability専用ヘルパー。読み取り専用で、実際の選択ロジック
  // (classify())には一切影響しない。
  static ShareCandidateDiagnostics diagnoseCandidates(List<SharedFile> files) {
    var selectedIndex = -1;
    var selectedKind = 'none';
    for (var i = 0; i < files.length; i++) {
      final value = files[i].value;
      if (value == null || value.trim().isEmpty) continue;
      final type = files[i].type;
      if (type == SharedMediaType.URL || type == SharedMediaType.TEXT) {
        selectedIndex = i;
        selectedKind = type == SharedMediaType.URL ? 'url' : 'text';
        break;
      }
    }

    final loggedCount =
        files.length < maxLoggedCandidates ? files.length : maxLoggedCandidates;
    final loggedCandidates = <ShareCandidateSummary>[
      for (var i = 0; i < loggedCount; i++) _summarizeCandidate(files[i]),
    ];

    return ShareCandidateDiagnostics(
      candidateCount: files.length,
      selectedIndex: selectedIndex,
      selectedKind: selectedKind,
      loggedCandidates: loggedCandidates,
    );
  }

  // 1件のSharedFileから、本文を含まないprivacy-safe metadataだけを作る。
  static ShareCandidateSummary _summarizeCandidate(SharedFile file) {
    final value = file.value;
    final kind = file.type.name.toLowerCase();
    if (value == null) {
      return ShareCandidateSummary(kind: kind, valuePresent: false);
    }
    final metrics = ShareFingerprint.metricsOf(value);
    return ShareCandidateSummary(
      kind: kind,
      valuePresent: true,
      charCount: metrics.charCount,
      trimmedCharCount: metrics.trimmedCharCount,
      payloadHash: metrics.payloadHash,
      trimmedPayloadHash: metrics.trimmedPayloadHash,
    );
  }

  // text/plainの共有をURL・通常テキストに分類する（テスト容易性のためstatic）。
  // flowIdは相関ID伝播用の付加情報で、分類結果そのものには影響しない。
  // No.94での変更なし：選択ロジック自体は従来と完全に同一（Observability追加のみ）。
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
    unawaited(DebugLogger.instance.logEvent('share_listener_dispose_requested', {
      'listenerInstanceId': _listenerInstanceId,
    }));
    final subscription = _subscription;
    if (subscription == null) return;
    // dispose()の戻り値型(void)・呼び出し元の同期呼び出しは変更しない。
    // cancel()完了のログはfire-and-forgetで追加するのみ。
    unawaited(subscription.cancel().then((_) {
      unawaited(
          DebugLogger.instance.logEvent('share_listener_dispose_completed', {
        'listenerInstanceId': _listenerInstanceId,
      }));
    }));
  }
}
