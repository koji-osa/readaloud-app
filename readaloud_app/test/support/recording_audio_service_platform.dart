// Playback Session Lifecycle Hardening — Detailed Design v1.2 FINAL §15.4.
//
// audio_service の Dart -> platform 境界を記録する fake。channel文字列ではなく
// AudioServicePlatform の公開interfaceに結合するため、host OS（Windows/Linuxの
// NoOpAudioService既定）に影響されない（RT-1 / INV-17）。
//
// テスト専用。production コードから import してはならない。

// ignore: depend_on_referenced_packages
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';

/// [RecordingAudioServicePlatform] が記録した1件の platform message。
/// T5 は「同一列内の順序」ではなく各列の独立assertionに使うため、
/// メソッド名だけの発生順ログ（[methodLog]）を別途保持する。
class RecordingAudioServicePlatform extends AudioServicePlatform {
  final List<SetStateRequest> setStateCalls = [];
  final List<SetMediaItemRequest> setMediaItemCalls = [];
  final List<StopServiceRequest> stopServiceCalls = [];

  /// setState / setMediaItem / stopService を発生順に1本の列としても保持する。
  final List<String> methodLog = [];

  void reset() {
    setStateCalls.clear();
    setMediaItemCalls.clear();
    stopServiceCalls.clear();
    methodLog.clear();
  }

  @override
  Future<void> setState(SetStateRequest request) async {
    setStateCalls.add(request);
    methodLog.add('setState');
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    setMediaItemCalls.add(request);
    methodLog.add('setMediaItem');
  }

  @override
  Future<void> stopService(StopServiceRequest request) async {
    stopServiceCalls.add(request);
    methodLog.add('stopService');
  }

  // init() / 各 _observe* installation が呼ぶ残りは、throwさせず無害な no-op
  // にする（基底は UnimplementedError を投げるため、override が必要）。
  // 想定外のメソッドが呼ばれた場合はここに無い限り基底の UnimplementedError
  // が投げられるので、記録漏れは silent failure ではなく loud failure になる。
  @override
  Future<void> configure(ConfigureRequest request) async {}

  @override
  Future<void> setQueue(SetQueueRequest request) async {}

  @override
  Future<void> setAndroidPlaybackInfo(
      SetAndroidPlaybackInfoRequest request) async {}

  @override
  Future<void> androidForceEnableMediaButtons(
      AndroidForceEnableMediaButtonsRequest request) async {}

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) {}
}
