import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/usecase/playback/playback_usage_accounting.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/util/debug_logger.dart';

// Shared Player Core Slice 3: SharedPlaybackTransport の Core unit test
// （Detailed Design v1.2 FINAL §16 T-C1 / T-C2 / T-C3a / T-C3b / T-C3c / T-C3e）。
void main() {
  late List<String> log;
  late _FakeTts tts;
  late _FakeFence fence;
  late StreamController<dynamic> positions;
  late int handlerPosition;
  late SharedPlaybackTransport transport;

  final ownerA = PlaybackOwnerKey.normalPlayer('A');
  final ownerB = PlaybackOwnerKey.normalPlayer('B');

  PlaybackRequest req(String text, {int start = 0}) => PlaybackRequest(
      target: const TransientTarget(), text: text, startPosition: start);

  setUp(() {
    DebugLogger.testSink = [];
    log = [];
    tts = _FakeTts(log);
    fence = _FakeFence(log);
    positions = StreamController<dynamic>.broadcast(sync: true);
    handlerPosition = 0;
    transport = SharedPlaybackTransport(
      tts: tts,
      positionStream: positions.stream,
      currentPosition: () => handlerPosition,
      resumeFence: fence,
    );
  });

  tearDown(() async {
    DebugLogger.testSink = null;
    transport.dispose();
    await positions.close();
  });

  test('T-C1: exclusive区間は投入順に直列実行され、失敗しても以後のchainは壊れない', () async {
    final order = <String>[];
    final gate1 = Completer<void>();
    final f1 = transport.exclusive((_) async {
      order.add('1-begin');
      await gate1.future;
      order.add('1-end');
    });
    final f2 = transport.exclusive((_) async {
      order.add('2');
      throw StateError('boom');
    });
    final f3 = transport.exclusive((_) async => order.add('3'));

    await Future<void>.delayed(Duration.zero);
    expect(order, ['1-begin'], reason: '先行区間の完了前に後続区間は開始しない');
    gate1.complete();
    await f1;
    await expectLater(f2, throwsStateError);
    await f3;
    expect(order, ['1-begin', '1-end', '2', '3']);
  });

  test(
      'T-C2: speak前の再送isPlaying:trueは受理せず、speak後の最初のisPlaying:true'
      'から受理し、受理時点のactiveOwnerで刻印する', () async {
    final accepted = <OwnedPositionEvent>[];
    final observed = <PositionObservation>[];
    transport.acceptedPositions.listen(accepted.add);
    transport.positionObservations.listen(observed.add);
    final accounting = _SpyAccounting(log, 'acc');

    // speak() の最中（D15 gate を開けた直後）に届く前 session の再送を再現する。
    tts.onSpeak = () {
      positions.add(const TtsPlaybackPosition(
          charPosition: 5, isPlaying: false, ttsStatus: TtsStatus.stopped));
    };
    // start 前の stale event は owner 不在のため受理されない。
    positions.add(const TtsPlaybackPosition(
        charPosition: 601, isPlaying: true, ttsStatus: TtsStatus.playing));

    await transport.start(ownerA, req('0123456789'), accounting: accounting);
    positions.add(const TtsPlaybackPosition(
        charPosition: 3, isPlaying: true, ttsStatus: TtsStatus.playing));
    positions.add(const TtsPlaybackPosition(
        charPosition: 4, isPlaying: false, ttsStatus: TtsStatus.paused));

    expect(accepted.map((e) => e.charPosition), [3, 4]);
    expect(accepted.every((e) => e.owner == ownerA), isTrue);
    expect(observed.map((o) => o.acceptedOwner), [null, null, ownerA, ownerA]);
    expect(accounting.advanced, [3, 4]);
  });

  test('T-C2: 別ownerのstartで受理状態はresetされ、以後のeventは新ownerで刻印される', () async {
    final accepted = <OwnedPositionEvent>[];
    transport.acceptedPositions.listen(accepted.add);
    await transport.start(ownerA, req('aaaa'),
        accounting: const NoUsageAccounting());
    positions.add(const TtsPlaybackPosition(
        charPosition: 1, isPlaying: true, ttsStatus: TtsStatus.playing));

    tts.onSpeak = null;
    final startB = transport.start(ownerB, req('bbbb'),
        accounting: const NoUsageAccounting());
    await startB;
    positions.add(const TtsPlaybackPosition(
        charPosition: 2, isPlaying: true, ttsStatus: TtsStatus.playing));

    expect(accepted.map((e) => '${e.owner}:${e.charPosition}'),
        ['np:A:1', 'np:B:2']);
  });

  test(
      'T-C3a: A start → B start → 遅延したA stop/pause はCommandIgnoredStaleOwner。'
      'BのTTS・accounting・stateは無変化', () async {
    final accA = _SpyAccounting(log, 'A');
    final accB = _SpyAccounting(log, 'B');
    await transport.start(ownerA, req('aaaa'), accounting: accA);
    await transport.start(ownerB, req('bbbb'), accounting: accB);
    log.clear();

    final stop = await transport.stop(ownerA);
    final pause = await transport.pause(ownerA);

    expect(stop, isA<CommandIgnoredStaleOwner>());
    expect((stop as CommandIgnoredStaleOwner).activeOwner, ownerB);
    expect(pause, isA<CommandIgnoredStaleOwner>());
    expect(log, isEmpty, reason: 'TTS/accounting/fenceへ一切触れない');
    expect(transport.activeOwner, ownerB);

    final applied = await transport.stop(ownerB);
    expect(applied, isA<CommandApplied>());
    expect(log, ['B:stopped', 'tts:stop']);
  });

  test('B-01: owner一致のstopではusage flush失敗でもTTS stopは実行され、結果は個別に返る', () async {
    final acc = _SpyAccounting(log, 'A')..failFlush = true;
    await transport.start(ownerA, req('aaaa'), accounting: acc);
    handlerPosition = 3;

    final result = await transport.stop(ownerA) as CommandApplied;

    expect(result.usageFlushSucceeded, isFalse);
    expect(result.ttsSucceeded, isTrue);
    expect(result.positionAtStop, 3);
    expect(tts.stopCount, 1);
    expect(transport.activeOwner, ownerA,
        reason: '通常stopはownerを恒久retireしない（teardownのみがclearする）');
  });

  group('T-C3b: owner-safe teardown', () {
    test(
        'activeOwner=BのときexpectedOwner=Aのteardownはignoredで、'
        'BのTTS・accounting・resume state・notificationは無変化', () async {
      final accB = _SpyAccounting(log, 'B');
      await transport.start(ownerB, req('bbbb'), accounting: accB);
      log.clear();

      final outcome = await transport.forceStopForTeardown(
        expectedOwner: ownerA,
        reason: TeardownReason.terminalClose,
        notificationDisposition: NotificationDisposition.clearIfNoLiveOwner,
      );

      expect(outcome.application, TeardownApplication.ignoredStaleOwner);
      expect(outcome.ttsStopConfirmed, isFalse);
      expect(outcome.resumeStateDiscarded, isFalse);
      expect(log, isEmpty);
      expect(transport.activeOwner, ownerB);
    });

    test('activeOwner=nullならnoActivePlaybackでTTS/fenceに触れない', () async {
      final outcome = await transport.forceStopForTeardown(
        expectedOwner: ownerA,
        reason: TeardownReason.shareTeardown,
        notificationDisposition: NotificationDisposition.handoff,
      );
      expect(outcome.application, TeardownApplication.noActivePlayback);
      expect(outcome.ttsStopConfirmed, isTrue);
      expect(log, isEmpty);
    });

    test('owner一致ならflush → TTS stop → fence → owner clear の順でexclusive内に完了する',
        () async {
      final acc = _SpyAccounting(log, 'A');
      await transport.start(ownerA, req('aaaa'), accounting: acc);
      log.clear();

      final outcome = await transport.forceStopForTeardown(
        expectedOwner: ownerA,
        reason: TeardownReason.terminalClose,
        notificationDisposition: NotificationDisposition.clearIfNoLiveOwner,
      );

      expect(outcome.application, TeardownApplication.applied);
      expect(outcome.resumeStateDiscarded, isTrue);
      expect(log, ['A:stopped', 'tts:stop', 'fence:clearIfNoLiveOwner']);
      expect(transport.activeOwner, isNull);
    });

    test('TTS stop失敗でもfenceは実行され、ttsStopConfirmedはfalseになる', () async {
      await transport.start(ownerA, req('aaaa'),
          accounting: const NoUsageAccounting());
      tts.failStop = true;
      final outcome = await transport.forceStopForTeardown(
        expectedOwner: ownerA,
        reason: TeardownReason.shareTeardown,
        notificationDisposition: NotificationDisposition.handoff,
      );
      expect(outcome.application, TeardownApplication.applied);
      expect(outcome.ttsStopSucceeded, isFalse);
      expect(outcome.ttsStopConfirmed, isFalse);
      expect(fence.calls, [NotificationDisposition.handoff]);
    });
  });

  test(
      'T-C3c: A speak失敗 → PlaybackStartFailure、abort済みでactiveOwnerはnull → '
      'B startは成功し、Aの残渣がBへ影響しない', () async {
    final accA = _SpyAccounting(log, 'A');
    final accB = _SpyAccounting(log, 'B');
    final accepted = <OwnedPositionEvent>[];
    transport.acceptedPositions.listen(accepted.add);

    tts.failSpeak = true;
    await expectLater(
      transport.start(ownerA, req('aaaa'), accounting: accA),
      throwsA(isA<PlaybackStartFailure>()
          .having((f) => f.owner, 'owner', ownerA)
          .having((f) => f.toString(), 'toString', contains('speak failed'))),
    );
    expect(accA.aborted, [ownerA]);
    expect(transport.activeOwner, isNull);

    // 失敗後に届いた isPlaying:true は受理されない（受理状態が残っていない）。
    positions.add(const TtsPlaybackPosition(
        charPosition: 9, isPlaying: true, ttsStatus: TtsStatus.playing));
    expect(accepted, isEmpty);

    tts.failSpeak = false;
    await transport.start(ownerB, req('bbbb'), accounting: accB);
    positions.add(const TtsPlaybackPosition(
        charPosition: 2, isPlaying: true, ttsStatus: TtsStatus.playing));

    expect(transport.activeOwner, ownerB);
    expect(accepted.single.owner, ownerB);
    expect(accA.advanced, isEmpty);
    expect(accB.advanced, [2]);
  });

  test(
      'T-C3e（Core）: AをshareTeardownでretire → stop+handoff fence完了後にだけB start。'
      'Aの遅延teardownがB start後に到着してもBを止めない', () async {
    await transport.start(ownerA, req('OLD'),
        accounting: const NoUsageAccounting());
    log.clear();

    // teardown と B start を連続投入しても、B の speak は fence 完了後になる。
    final teardown = transport.forceStopForTeardown(
      expectedOwner: ownerA,
      reason: TeardownReason.shareTeardown,
      notificationDisposition: NotificationDisposition.handoff,
    );
    final startB = transport.start(ownerB, req('NEW'),
        accounting: const NoUsageAccounting());
    await Future.wait([teardown, startB]);
    expect(log, ['tts:stop', 'fence:handoff', 'tts:speak:NEW']);

    log.clear();
    final late = await transport.forceStopForTeardown(
      expectedOwner: ownerA,
      reason: TeardownReason.shareTeardown,
      notificationDisposition: NotificationDisposition.handoff,
    );
    expect(late.application, TeardownApplication.ignoredStaleOwner);
    expect(log, isEmpty, reason: '遅延teardownはBのTTS/fenceへ触れない');
    expect(transport.activeOwner, ownerB);
  });

  test('NoUsageAccountingのstopはmicrotask境界を挟まずTTS stopを要求する', () async {
    await transport.start(ownerA, req('abc'),
        accounting: const NoUsageAccounting());
    final future = transport.stop(ownerA);
    expect(tts.stopCount, 1, reason: '同期的にTTS stopが要求される');
    await future;
  });

  group('T-C3f（Core）: retireActiveForExternalEntry（v1.3 §6.3 B）', () {
    test('active無しなら hadActivePlayback=false の成功no-op（TTS/fenceに触れない）',
        () async {
      final r = await transport.retireActiveForExternalEntry(
          reason: TeardownReason.shareTeardown);
      expect(r.hadActivePlayback, isFalse);
      expect(r.retiredOwner, isNull);
      expect(r.stopOutcome.ttsStopConfirmed, isTrue);
      expect(log, isEmpty);
    });

    test(
        'callerはownerを指定せず、Transportがactive owner/request.targetをcaptureして '
        'flush → stop → handoff fence → owner/request clear', () async {
      final acc = _SpyAccounting(log, 'A');
      final request = req('aaaa');
      await transport.start(ownerA, request, accounting: acc);
      expect(transport.activeRequestForDebug, same(request));
      handlerPosition = 3;
      log.clear();

      final r = await transport.retireActiveForExternalEntry(
          reason: TeardownReason.shareTeardown);

      expect(r.hadActivePlayback, isTrue);
      expect(r.retiredOwner, ownerA);
      expect(r.retiredTarget, same(request.target));
      expect(r.stopOutcome.application, TeardownApplication.applied);
      expect(r.stopOutcome.positionAtStop, 3);
      expect(log, ['A:stopped', 'tts:stop', 'fence:handoff']);
      expect(transport.activeOwner, isNull);
      expect(transport.activeRequestForDebug, isNull);
    });

    test('external retirementは後続start/遅延session teardownと直列化され、新ownerを止めない',
        () async {
      await transport.start(ownerA, req('OLD'),
          accounting: const NoUsageAccounting());
      log.clear();
      final retire = transport.retireActiveForExternalEntry(
          reason: TeardownReason.shareTeardown);
      final startB = transport.start(ownerB, req('NEW'),
          accounting: const NoUsageAccounting());
      await Future.wait([retire, startB]);
      expect(log, ['tts:stop', 'fence:handoff', 'tts:speak:NEW']);

      log.clear();
      final late = await transport.forceStopForTeardown(
        expectedOwner: ownerA,
        reason: TeardownReason.shareTeardown,
        notificationDisposition: NotificationDisposition.handoff,
      );
      expect(late.application, TeardownApplication.ignoredStaleOwner);
      expect(log, isEmpty);
      expect(transport.activeOwner, ownerB);
    });

    test('activeRequestはstart失敗rollbackとterminal closeでもownerと同時にclearされる',
        () async {
      tts.failSpeak = true;
      await expectLater(
          transport.start(ownerA, req('a'),
              accounting: const NoUsageAccounting()),
          throwsA(isA<PlaybackStartFailure>()));
      expect(transport.activeRequestForDebug, isNull);

      tts.failSpeak = false;
      await transport.start(ownerB, req('b'),
          accounting: const NoUsageAccounting());
      await transport.forceStopForTeardown(
        expectedOwner: ownerB,
        reason: TeardownReason.terminalClose,
        notificationDisposition: NotificationDisposition.clearIfNoLiveOwner,
      );
      expect(transport.activeOwner, isNull);
      expect(transport.activeRequestForDebug, isNull);
    });
  });
}

class _FakeTts implements TtsService {
  _FakeTts(this.log);
  final List<String> log;
  bool failSpeak = false;
  bool failStop = false;
  int stopCount = 0;
  void Function()? onSpeak;

  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async {
    onSpeak?.call();
    if (failSpeak) throw StateError('speak failed');
    log.add('tts:speak:$text');
  }

  @override
  Future<void> pause() async => log.add('tts:pause');

  @override
  Future<void> stop() async {
    stopCount++;
    log.add('tts:stop');
    if (failStop) throw StateError('stop failed');
  }

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async => [];

  @override
  Future<void> dispose() async {}
}

class _FakeFence implements PlaybackResumeFence {
  _FakeFence(this.log);
  final List<String> log;
  final List<NotificationDisposition> calls = [];

  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async {
    calls.add(notificationDisposition);
    log.add('fence:${notificationDisposition.name}');
  }
}

class _SpyAccounting implements PlaybackUsageAccounting {
  _SpyAccounting(this.log, this.name);
  final List<String> log;
  final String name;
  bool failFlush = false;
  final List<int> advanced = [];
  final List<PlaybackOwnerKey> aborted = [];

  @override
  void onPlaybackStarted({
    required PlaybackOwnerKey owner,
    required int totalChars,
    required int startPosition,
  }) {}

  @override
  void onPositionAdvanced(int position) => advanced.add(position);

  @override
  Future<UsageFlushResult> onPlaybackStopped(PlaybackOwnerKey owner) async {
    log.add('$name:stopped');
    if (failFlush) return const UsageFlushResult.failed('StateError');
    return const UsageFlushResult.succeeded();
  }

  @override
  void onPlaybackAborted(PlaybackOwnerKey owner) => aborted.add(owner);
}
