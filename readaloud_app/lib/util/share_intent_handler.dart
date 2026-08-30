import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'dart:async';

/// 共有されたテキストの種類。
/// URLの判定はネイティブ側(URLUtil.isValidUrl)で行われ、
/// SharedFile.typeとしてすでに渡ってくる。
enum SharedContentKind { text, url }

class SharedTextPayload {
  final SharedContentKind kind;
  final String value;

  const SharedTextPayload(this.kind, this.value);
}

class ShareIntentHandler {
  StreamSubscription? _subscription;
  final void Function(SharedTextPayload payload) onPayloadReceived;

  ShareIntentHandler({required this.onPayloadReceived});

  // アプリ起動中の共有を受け取る
  void startListening() {
    _subscription = FlutterSharingIntent.instance
        .getMediaStream()
        .listen((List<SharedFile> files) {
      final payload = classify(files);
      if (payload != null) onPayloadReceived(payload);
    });
  }

  // アプリ起動時に共有されたテキストを取得
  Future<SharedTextPayload?> getInitialSharedPayload() async {
    final files =
        await FlutterSharingIntent.instance.getInitialSharing();
    // 取得後にリセット（再起動時に同じテキストが表示されないよう）
    FlutterSharingIntent.instance.reset();
    return classify(files);
  }

  // text/plainの共有をURL・通常テキストに分類する（テスト容易性のためstatic）
  static SharedTextPayload? classify(List<SharedFile> files) {
    for (final file in files) {
      final value = file.value;
      if (value == null || value.trim().isEmpty) continue;
      if (file.type == SharedMediaType.URL) {
        return SharedTextPayload(SharedContentKind.url, value);
      }
      if (file.type == SharedMediaType.TEXT) {
        return SharedTextPayload(SharedContentKind.text, value);
      }
    }
    return null;
  }

  void dispose() {
    _subscription?.cancel();
  }
}
