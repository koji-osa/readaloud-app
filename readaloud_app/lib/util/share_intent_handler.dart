import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'dart:async';

class ShareIntentHandler {
  StreamSubscription? _subscription;
  final void Function(String text) onTextReceived;

  ShareIntentHandler({required this.onTextReceived});

  // アプリ起動中の共有を受け取る
  void startListening() {
    _subscription = FlutterSharingIntent.instance
        .getMediaStream()
        .listen((List<SharedFile> files) {
      for (final file in files) {
        if (file.type == SharedMediaType.TEXT && file.value != null) {
          onTextReceived(file.value!);
          break;
        }
      }
    });
  }

  // アプリ起動時に共有されたテキストを取得
  Future<String?> getInitialSharedText() async {
    final files =
        await FlutterSharingIntent.instance.getInitialSharing();
    for (final file in files) {
      if (file.type == SharedMediaType.TEXT && file.value != null) {
        return file.value;
      }
    }
    return null;
  }

  void dispose() {
    _subscription?.cancel();
  }
}
