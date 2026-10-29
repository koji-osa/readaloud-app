// W2-R-08: 実 TtsAudioHandler の自然終了 callback（flutter_tts の
// `speak.onComplete`）を mocked channel 経由で駆動し、P5 の終端位置計算・
// pause/stop 中の抑止・fence 後の play() 非再生を検証する。
//
// AudioService.init() は isolate 中 1 回のみ（platform-boundary test と同じ制約）。
// 全テストで同一 handler を共有し、setUp で stop() により reset する。

import 'dart:async';

import 'package:audio_service/audio_service.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/main.dart' show kAudioServiceConfig;
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/repository/tts/device_tts_service.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/util/debug_logger.dart';

import '../../support/fake_cache_manager.dart';
import '../../support/recording_audio_service_platform.dart';

/// 1 文 1,200 文字 + 「。」。3 文で 2,000 文字上限により 3 chunk に分割される。
final String _sentence = '${'あ' * 1200}。';
final String _text = _sentence * 3; // 3,603 文字

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingAudioServicePlatform recorder;
  late TtsAudioHandler handler;
  late List<String> spoken;
  late StreamSubscription<dynamic> sub;
  late List<TtsPlaybackPosition> events;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// platform -> Dart の `speak.onComplete` callback を発火する。
  Future<void> fireCompletion() async {
    await messenger.handlePlatformMessage(
      'flutter_tts',
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('speak.onComplete', true)),
      (_) {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  Future<void> settleEvents() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  setUpAll(() async {
    recorder = RecordingAudioServicePlatform();
    AudioServicePlatform.instance = recorder;

    messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'),
        (call) async {
      if (call.method == 'speak') spoken.add(call.arguments as String);
      return 1;
    });
    for (final name in [
      'com.ryanheise.audio_session',
      'com.ryanheise.android_audio_manager',
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (_) async => null);
    }

    handler = await AudioService.init(
      builder: () => TtsAudioHandler(),
      config: kAudioServiceConfig,
      cacheManager: FakeCacheManager(),
    );
  });

  setUp(() async {
    DebugLogger.testSink = [];
    spoken = [];
    await handler.stop();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    spoken.clear();
    events = [];
    sub = handler.customState.listen((e) {
      if (e is TtsPlaybackPosition) events.add(e);
    });
    await settleEvents();
    events.clear(); // BehaviorSubject の replay を捨てる
  });

  tearDown(() async {
    await sub.cancel();
    DebugLogger.testSink = null;
  });

  test(
      '(i) 複数chunk・startPosition>0: 最後のchunk完了で isNaturalCompletion=true、'
      'charPosition == currentPosition == 本文長', () async {
    const start = 50;
    await handler.speak(text: _text, startPosition: start);
    expect(spoken.length, 1, reason: 'chunk 0 が speak される');

    await fireCompletion(); // chunk 0 -> chunk 1
    await fireCompletion(); // chunk 1 -> chunk 2
    expect(spoken.length, 3, reason: '3 chunk 全て speak 済み');
    expect(events.where((e) => e.isNaturalCompletion), isEmpty,
        reason: '最終chunk完了前に自然終了は通知されない');

    await fireCompletion(); // chunk 2 完了 = 全文終了
    final done = events.where((e) => e.isNaturalCompletion).toList();
    expect(done, hasLength(1));
    expect(done.single.charPosition, _text.length);
    expect(done.single.isPlaying, isFalse);
    expect(done.single.ttsStatus, TtsStatus.stopped);
    expect(handler.currentPosition, _text.length);
    expect(spoken.length, 3, reason: '自然終了後に追加のspeakはない');
  });

  test('(ii-a) pause後のcompletion callbackでは isNaturalCompletion が発火しない',
      () async {
    await handler.speak(text: _text, startPosition: 0);
    await fireCompletion();
    await fireCompletion(); // 最終chunkを再生中
    await handler.pause();
    events.clear();

    await fireCompletion();

    expect(events.where((e) => e.isNaturalCompletion), isEmpty);
    expect(spoken.length, 3);
  });

  test('(ii-b) stop後のcompletion callbackでは isNaturalCompletion が発火しない',
      () async {
    await handler.speak(text: _text, startPosition: 0);
    await fireCompletion();
    await fireCompletion();
    await handler.stop();
    events.clear();

    await fireCompletion();

    expect(events.where((e) => e.isNaturalCompletion), isEmpty);
    expect(spoken.length, 3);
  });

  test(
      '(iii) 自然終了 + discardResumeState(clearIfNoLiveOwner) の後の play() は '
      'platform speak を呼ばない', () async {
    await handler.speak(text: _text, startPosition: 0);
    await fireCompletion();
    await fireCompletion();
    await fireCompletion();
    expect(events.where((e) => e.isNaturalCompletion), hasLength(1));
    final spokenBefore = spoken.length;

    await handler.discardResumeState(
        notificationDisposition: NotificationDisposition.clearIfNoLiveOwner);
    await handler.play();
    await settleEvents();

    expect(spoken.length, spokenBefore,
        reason: 'fence後のplay()は全文を再生し直さない');
  });

  test('(iii-control) fenceが無ければ自然終了後のplay()は全文を再生し直す(oracleの非空性)',
      () async {
    await handler.speak(text: _text, startPosition: 0);
    await fireCompletion();
    await fireCompletion();
    await fireCompletion();
    final spokenBefore = spoken.length;

    await handler.play();
    await settleEvents();

    expect(spoken.length, greaterThan(spokenBefore),
        reason: 'fence無しではplay()が再speakする（W2-R-02の症状）');
  });
}
