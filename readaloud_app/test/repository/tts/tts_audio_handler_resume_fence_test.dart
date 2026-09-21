import 'dart:async';

import 'package:audio_service/audio_service.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_service_platform_interface/method_channel_audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/repository/tts/device_tts_service.dart';
import 'package:readaloud_app/repository/tts/playback_resume_fence.dart';
import 'package:readaloud_app/util/debug_logger.dart';

// Shared Player Core C3（Detailed Design v1.2 FINAL §6.5）:
// T-C3d（unit部分）/ T-C3e（handler部分）。
// 実 TtsAudioHandler を platform channel mock 上で動かし、fence 後に
// notification Play / audio interruption resume（= handler.play()/pause()）が
// retire 済み text を再生しないことを確認する。
// 実機上の media notification 完全消去（NEW-Q1=A）は Device Acceptance Gate で確認する。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Windows/Linux の test host では audio_service が NoOp 実装になり、
    // `androidForceEnableMediaButtons` の platform-channel await が発生しない。
    // Android と同じ MethodChannel 実装へ切り替え、await を決定的に再現する。
    AudioServicePlatform.instance = MethodChannelAudioService();
  });

  late List<String> spoken;

  /// 次の1回だけ `androidForceEnableMediaButtons` の platform-channel 応答を
  /// このCompleterが完了するまで保留する（PC-3 race の決定的再現用）。
  Completer<void>? holdNextMediaButtons;

  setUp(() {
    DebugLogger.testSink = [];
    spoken = [];
    holdNextMediaButtons = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'),
        (call) async {
      if (call.method == 'speak') spoken.add(call.arguments as String);
      return 1;
    });
    for (final name in [
      'com.ryanheise.audio_service.client.methods',
      'com.ryanheise.audio_session',
      'com.ryanheise.android_audio_manager',
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.ryanheise.audio_service.handler.methods'),
        (call) async {
      final hold = holdNextMediaButtons;
      if (call.method == 'androidForceEnableMediaButtons' && hold != null) {
        holdNextMediaButtons = null;
        await hold.future;
      }
      return null;
    });
  });

  group('PC-3 / T-C3i: resume generation（platform await を跨ぐ race）', () {
    test(
        'Race A: 一時停止中の旧ownerの通知Playがawait中 → teardown(stop)完了 → '
        'awaitが完了 → fence、の順でも旧Play continuationは旧textを再開/speakしない', () async {
      final handler = TtsAudioHandler();
      await handler.speak(text: 'OLD TEXT。', startPosition: 0);
      await handler.pause();
      spoken.clear();

      final hold = holdNextMediaButtons = Completer<void>();
      final oldPlay = handler.play(); // 通知Play: platform await で保留
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Transport teardown: TTS stop → （旧Play await 復帰）→ resume fence
      await handler.stop();
      hold.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await handler.discardResumeState(
          notificationDisposition: NotificationDisposition.handoff);
      await oldPlay;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(spoken, isEmpty, reason: 'retire済みtextは復活しない（AC-23）');
      expect(handler.playbackState.value.playing, isFalse);
    });

    test(
        'Race A\': 通知Playのawait中にstop + fenceが完了しても、復帰後の旧Playは'
        'resume/speakせず通知controlsも再表示しない', () async {
      final handler = TtsAudioHandler();
      await handler.speak(text: 'OLD TEXT。', startPosition: 0);
      await handler.pause();
      spoken.clear();

      final hold = holdNextMediaButtons = Completer<void>();
      final oldPlay = handler.play();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await handler.stop();
      await handler.discardResumeState(
          notificationDisposition: NotificationDisposition.clearIfNoLiveOwner);
      hold.complete();
      await oldPlay;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(spoken, isEmpty);
      expect(handler.playbackState.value.controls, isEmpty);
      // NOTE (Playback Session Lifecycle Hardening A2 / INV-14): この
      // assertionはDart側のBehaviorSubject値を見ており、実際の platform
      // message 境界を見ていない — DA-1をshipさせた同じfalse-greenの形。
      // A2でmediaItem.add(null)を削除したため、Dart側の値はもう変化しない
      // （意図的。null replacementはINV-14に違反する）。platform-boundary側の
      // 等価な検証はT1（tts_audio_handler_platform_boundary_test.dart）が行う。
    });

    test(
        'Race B: 旧ownerの通知Playがawait中 → 新ownerのspeak()開始 → awaitが完了、'
        'でも旧Play continuationはresume/speakしない（新ownerの再生だけが1回）', () async {
      final handler = TtsAudioHandler();
      await handler.speak(text: 'OLD TEXT。', startPosition: 0);
      await handler.pause();
      spoken.clear();

      final hold = holdNextMediaButtons = Completer<void>();
      final oldPlay = handler.play();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final newSpeak = handler.speak(text: 'NEW TEXT。', startPosition: 0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      hold.complete();
      await oldPlay;
      await newSpeak;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(spoken, ['NEW TEXT。'],
          reason: '旧Play continuationによる再開/二重speakが無い');
    });
  });

  tearDown(() {
    DebugLogger.testSink = null;
  });

  test('対照: fenceしないstop後のplay()（通知Play相当）は旧textを再生してしまう（F-H）', () async {
    final handler = TtsAudioHandler();
    await handler.speak(text: 'OLD TEXT。', startPosition: 0);
    await handler.stop();
    spoken.clear();

    await handler.play();

    expect(spoken, ['OLD TEXT。'], reason: '既存のrevival経路が実在することの確認');
  });

  test(
      'T-C3d unit: terminal close（stop + fence clearIfNoLiveOwner）後は'
      'play()/interruption pause→resumeで旧textを再生せず、media notification情報を消す',
      () async {
    final handler = TtsAudioHandler();
    await handler.speak(text: 'OLD TEXT。', startPosition: 0);
    expect(handler.mediaItem.value, isNotNull);

    await handler.stop();
    await handler.discardResumeState(
        notificationDisposition: NotificationDisposition.clearIfNoLiveOwner);
    spoken.clear();

    await handler.play(); // 通知の再生ボタン相当
    await handler.pause(); // interruption begin 相当
    await handler.play(); // interruption end(pause) 相当

    expect(spoken, isEmpty, reason: 'retire済みtextは復活しない（INV-T7 / AC-17）');
    expect(handler.playbackState.value.playing, isFalse);
    expect(
        handler.playbackState.value.processingState, AudioProcessingState.idle);
    expect(handler.playbackState.value.controls, isEmpty,
        reason: 'fence後のpause()で通知controlsを再表示しない');
  });

  test(
      'T-C3e handler: handoff fence後〜次owner speak前の通知Play/interruption resumeで'
      '旧textが復活せず、次ownerのspeakは通常どおり再生・再開できる', () async {
    final handler = TtsAudioHandler();
    await handler.speak(text: 'OLD TEXT。', startPosition: 0);
    await handler.stop();
    await handler.discardResumeState(
        notificationDisposition: NotificationDisposition.handoff);
    spoken.clear();

    await handler.play();
    expect(spoken, isEmpty);
    expect(handler.playbackState.value.controls, isEmpty);

    await handler.speak(text: 'NEW TEXT。', startPosition: 0);
    expect(spoken, ['NEW TEXT。']);

    // 次ownerの通常の pause → resume（fenceは解除されている）
    await handler.pause();
    spoken.clear();
    await handler.play();
    expect(spoken, ['NEW TEXT。']);
  });

  test('一時停止中（_isPaused）の旧ownerもfence後はplay()で再開しない', () async {
    final handler = TtsAudioHandler();
    await handler.speak(text: 'PAUSED TEXT。', startPosition: 0);
    await handler.pause();
    await handler.stop();
    await handler.discardResumeState(
        notificationDisposition: NotificationDisposition.handoff);
    spoken.clear();

    await handler.play();
    expect(spoken, isEmpty);
  });
}
