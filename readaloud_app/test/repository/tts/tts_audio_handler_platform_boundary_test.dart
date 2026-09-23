// Playback Session Lifecycle Hardening — Detailed Design v1.2 FINAL §15.4.
//
// DA-1 platform-boundary test seam. T0 / T1 / T1b / T2 / T5 (§15.1, §15.1.1).
//
// このファイルは AudioService.init() を isolate 中に厳密に1回だけ呼ぶ
// （§15.4.3）。init() は `assert(_cacheManager == null)` から始まり reset API
// が無いため、2回目の呼び出しは assert 有効下（flutter test）で throw する。
// したがってこのファイルの全テストは同一の TtsAudioHandler インスタンスを共有し、
// per-test isolation は明示的な reset（§15.4.4）で行う。
//
// RecordingAudioServicePlatform は audio_service.dart:16 の
// `AudioServicePlatform _platform` — Dart→platform 境界のすべてがここを通る —
// を記録する。channel文字列ではなく公開interfaceに結合するため、Windows/Linux
// host の既定 NoOpAudioService に左右されない（RT-1）。

import 'package:audio_service/audio_service.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/main.dart' show kAudioServiceConfig;
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/repository/tts/device_tts_service.dart';
import 'package:readaloud_app/usecase/playback/playback_usage_accounting.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/util/debug_logger.dart';

import '../../support/fake_cache_manager.dart';
import '../../support/recording_audio_service_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingAudioServicePlatform recorder;
  late TtsAudioHandler handler;
  late List<String> spoken;
  late int ttsStopCalls;

  setUpAll(() async {
    // §15.4.2: インストール順が唯一のハード制約。AudioService.init() より前に
    // install する。
    recorder = RecordingAudioServicePlatform();
    AudioServicePlatform.instance = recorder;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'),
        (call) async {
      if (call.method == 'speak') spoken.add(call.arguments as String);
      if (call.method == 'stop') ttsStopCalls++;
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
    // spoken/ttsStopCallsはこの下のhandler.stop()自体が発火させるchannel呼び出し
    // からmockハンドラが読むため、それより前に初期化しておく必要がある。
    DebugLogger.testSink = [];
    spoken = [];
    ttsStopCalls = 0;
    // §15.4.4: double reset。reset自身が生んだ記録を後続assertionへ漏らさない。
    recorder.reset();
    await handler.stop();
    // stop()が発火させたplaybackStateイベントは_observePlaybackStateの
    // 独立したawait forループを通じて非同期にplatformへ届く。await handler.stop()
    // の完了はそれの完了を保証しないため、先に少し待ってから2回目のresetを
    // 行わないと、届くのが遅れて次のテストの録画先頭を汚染しうる。
    await Future<void>.delayed(const Duration(milliseconds: 10));
    recorder.reset();
    spoken.clear();
    ttsStopCalls = 0;
  });

  SharedPlaybackTransport buildTransport() => SharedPlaybackTransport(
        tts: handler,
        positionStream: handler.customState,
        currentPosition: () => handler.currentPosition,
        resumeFence: handler,
      );

  test(
      'T0 [RT-1][INV-17]: seam non-vacuity — known-good speak()はrecorderに'
      'playing:trueのsetStateを1件以上残す', () async {
    await handler.speak(text: 'T0 TEXT。', startPosition: 0);

    final playingCalls =
        recorder.setStateCalls.where((c) => c.state.playing).toList();
    expect(playingCalls, isNotEmpty,
        reason: 'seamが記録を止めていれば、この時点で空になり全体が偽陰性の緑にならず'
            'ここで失敗する（RT-1のvacuous passクラスを閉じる）');
  });

  test('T1b: production config regression guard（main.dartのkAudioServiceConfig）',
      () {
    expect(kAudioServiceConfig.androidStopForegroundOnPause, isTrue,
        reason: 'A1: exitPlayingState()を有効化する唯一のlever');
  });

  test(
      'T1 [INV-4][INV-14]: terminal close（他ownerなし） — setState列に'
      '非idle->idleの遷移がちょうど1回だけ現れ、その後setMediaItemは1件も無く、'
      'spokenは空のまま', () async {
    await handler.speak(text: 'T1 TEXT。', startPosition: 0);
    spoken.clear();

    await handler.stop();
    await handler.discardResumeState(
        notificationDisposition: NotificationDisposition.clearIfNoLiveOwner);

    expect(recorder.setStateCalls, isNotEmpty, reason: 'T0の非空性前提（INV-17）');

    final merged = _mergedCalls(recorder);
    var idleEdges = 0;
    var idleEdgeIndex = -1;
    AudioProcessingStateMessage? prevState;
    for (var i = 0; i < merged.length; i++) {
      final call = merged[i];
      if (call.kind != _CallKind.setState) continue;
      final cur = call.processingState!;
      if (prevState != null &&
          prevState != AudioProcessingStateMessage.idle &&
          cur == AudioProcessingStateMessage.idle) {
        idleEdges++;
        idleEdgeIndex = i;
      }
      prevState = cur;
    }
    expect(idleEdges, 1, reason: '非idle -> idle の遷移はちょうど1回（terminal teardown）');

    final hasMediaItemAfterIdle = merged
        .skip(idleEdgeIndex + 1)
        .any((c) => c.kind == _CallKind.setMediaItem);
    expect(hasMediaItemAfterIdle, isFalse,
        reason: 'INV-14: idle edge後にsetMediaItemは1件も無い'
            '（A2でmediaItem.add(null)を削除済み）');

    expect(spoken, isEmpty, reason: 'terminal teardownは新しいspeak()を発生させない');
  });

  test(
      'T2 [FC-2]: stale A close while B active — 差分real-platform test。'
      '既知良好actionでrecorderの生存を証明してからreset、staleなteardownは'
      'setState/setMediaItem/stopServiceを1件も増やさず、FlutterTts.stopも'
      '呼ばれない', () async {
    final transport = buildTransport();
    addTearDown(transport.dispose);

    final ownerA = PlaybackOwnerKey.normalPlayer('A');
    final ownerB = PlaybackOwnerKey.normalPlayer('B');

    await transport.start(
      ownerA,
      PlaybackRequest(
          target: const TransientTarget(), text: 'A TEXT。', startPosition: 0),
      accounting: const NoUsageAccounting(),
    );
    await transport.start(
      ownerB,
      PlaybackRequest(
          target: const TransientTarget(), text: 'B TEXT。', startPosition: 0),
      accounting: const NoUsageAccounting(),
    );

    // known-good action: recorderが生きていることを同一テスト内で証明する
    // （非空性の差分前提。後続の「ゼロメッセージ」assertionを非自明にする — §15.4.5）。
    expect(recorder.setStateCalls, isNotEmpty);
    expect(recorder.setMediaItemCalls, isNotEmpty);
    recorder.reset();
    spoken.clear();
    ttsStopCalls = 0;

    final outcome = await transport.forceStopForTeardown(
      expectedOwner: ownerA,
      reason: TeardownReason.terminalClose,
      notificationDisposition: NotificationDisposition.clearIfNoLiveOwner,
    );

    expect(outcome.application, TeardownApplication.ignoredStaleOwner);
    expect(recorder.setStateCalls, isEmpty);
    expect(recorder.setMediaItemCalls, isEmpty);
    expect(recorder.stopServiceCalls, isEmpty);
    expect(ttsStopCalls, 0, reason: 'stale close は FlutterTts.stop を呼ばない');
  });

  test(
      'T5 [RT-5]: 新ownerのstartが旧owner(handoff)のteardown完了と重なっても、'
      'setState列内でterminal idle edgeの後にのみ新ownerのplaying:trueが現れ、'
      'それ以降に新ownerを打ち消すidle edgeは現れない。setMediaItemの有無は'
      'setStateとの相対indexでは比較しない（cross-stream orderingに依存しない）',
      () async {
    final transport = buildTransport();
    addTearDown(transport.dispose);

    final ownerA = PlaybackOwnerKey.normalPlayer('A');
    final ownerB = PlaybackOwnerKey.normalPlayer('B');

    // A の最初の speak() が「ready/playing:true」を録画に残す（後続のidle edge
    // 検出のためのanchorとして必要 — ここでrecorder.reset()はしない）。
    await transport.start(
      ownerA,
      PlaybackRequest(
          target: const TransientTarget(), text: 'OLD。', startPosition: 0),
      accounting: const NoUsageAccounting(),
    );

    final teardown = transport.forceStopForTeardown(
      expectedOwner: ownerA,
      reason: TeardownReason.shareTeardown,
      notificationDisposition: NotificationDisposition.handoff,
    );
    final startB = transport.start(
      ownerB,
      PlaybackRequest(
          target: const TransientTarget(), text: 'NEW。', startPosition: 0),
      accounting: const NoUsageAccounting(),
    );
    await Future.wait([teardown, startB]);

    expect(recorder.setStateCalls, isNotEmpty);
    final states = recorder.setStateCalls.map((c) => c.state).toList();

    var idleIndex = -1;
    AudioProcessingStateMessage? prev;
    for (var i = 0; i < states.length; i++) {
      final cur = states[i].processingState;
      if (prev != null &&
          prev != AudioProcessingStateMessage.idle &&
          cur == AudioProcessingStateMessage.idle) {
        idleIndex = i;
      }
      prev = cur;
    }
    expect(idleIndex, isNot(-1), reason: '(a)-1: terminal idle edgeが現れる');

    final newOwnerPlayingIndex =
        states.indexWhere((s) => s.playing == true, idleIndex + 1);
    expect(newOwnerPlayingIndex, greaterThan(idleIndex),
        reason: '(a)-2: 新ownerのplaying:trueはidle edgeより後に現れる');

    // states[0] は A 自身の speak() による「ready/playing:true」で、これは
    // anchor として意図的に残している（idle edge検出に必要）。(a)-3が実際に
    // 見ているのは「それに加えて」新ownerのplaying:trueがidle edgeより前に
    // 漏れていないことなので、anchor自身は比較対象から除く。
    final betweenStartAndIdle = states.sublist(1, idleIndex);
    expect(betweenStartAndIdle.any((s) => s.playing == true), isFalse,
        reason: '(a)-3: 新ownerのstartがidle edgeより前に漏れていない');

    final afterNewOwnerPlaying = states.sublist(newOwnerPlayingIndex + 1);
    expect(
      afterNewOwnerPlaying
          .any((s) => s.processingState == AudioProcessingStateMessage.idle),
      isFalse,
      reason: '(a)-4: 新ownerのplaying:true後にidle edgeで打ち消されない',
    );

    // (b): terminal(handoff)側はmediaItemを一切出さない（A2/INV-14）。
    // 新ownerのspeak()が出すsetMediaItemはpresenceのみ確認し、setStateとの
    // 相対indexは比較しない（RT-5: cross-stream orderingは保証されない）。
    expect(recorder.setMediaItemCalls, isNotEmpty,
        reason: '新ownerのspeak()がMediaItemを送る（存在のみ確認）');
  });
}

enum _CallKind { setState, setMediaItem, stopService }

class _LoggedCall {
  const _LoggedCall.state(this.processingState) : kind = _CallKind.setState;
  const _LoggedCall.mediaItem()
      : kind = _CallKind.setMediaItem,
        processingState = null;
  const _LoggedCall.stopService()
      : kind = _CallKind.stopService,
        processingState = null;

  final _CallKind kind;
  final AudioProcessingStateMessage? processingState;
}

/// [recorder.methodLog] とtyped call listを突き合わせ、setState/setMediaItem/
/// stopServiceが実際に発生した順のリストを再構築する。T1/T5はこれを使って
/// 「同一列内の順序」と「別列の有無」を、互いを混同せずに検証する（§12.1 / RT-5）。
List<_LoggedCall> _mergedCalls(RecordingAudioServicePlatform recorder) {
  var stateIdx = 0;
  final merged = <_LoggedCall>[];
  for (final name in recorder.methodLog) {
    switch (name) {
      case 'setState':
        merged.add(_LoggedCall.state(
            recorder.setStateCalls[stateIdx++].state.processingState));
      case 'setMediaItem':
        merged.add(const _LoggedCall.mediaItem());
      case 'stopService':
        merged.add(const _LoggedCall.stopService());
    }
  }
  return merged;
}
