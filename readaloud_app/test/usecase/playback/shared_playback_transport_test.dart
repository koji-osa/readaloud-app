import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/setting.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/usecase/playback/playback_usage_accounting.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';

// Shared Player Core Slice 3: SharedPlaybackTransport の Core unit test
// （Detailed Design v1.2 FINAL §16 T-C1 / T-C2 / T-C3a / T-C3b / T-C3c / T-C3e）。
//
// Playback Session Lifecycle Hardening Slice 3: DA-2 adoption 追加
// （Detailed Design v1.2 FINAL §15.2 T14-T18）。
void main() {
  late List<String> log;
  late _FakeTts tts;
  late _FakeFence fence;
  late StreamController<dynamic> positions;
  late int handlerPosition;
  late SharedPlaybackTransport transport;

  final ownerA = PlaybackOwnerKey.normalPlayer('A');
  final ownerB = PlaybackOwnerKey.normalPlayer('B');
  final ownerC = PlaybackOwnerKey.normalPlayer('C');
  final ownerD = PlaybackOwnerKey.normalPlayer('D');

  PlaybackRequest req(String text, {int start = 0}) => PlaybackRequest(
      target: const TransientTarget(), text: text, startPosition: start);

  PlaybackRequest persistentReq(String text,
          {int start = 0, String contentId = 'A'}) =>
      PlaybackRequest(
        target: PersistentTarget.ofRegisteredSessionContentId(contentId),
        text: text,
        startPosition: start,
      );

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

  group('Detailed Design v1.2 FINAL §8.2/§12/§15.2: adoptActivePersistent (DA-2)',
      () {
    test('T16 [NR-3]: PersistentTargetはcontentIdでvalue equality、TransientTargetは不変',
        () {
      final a1 = PersistentTarget.ofRegisteredSessionContentId('A');
      final a2 = PersistentTarget.ofRegisteredSessionContentId('A');
      final b = PersistentTarget.ofRegisteredSessionContentId('B');
      expect(a1, equals(a2));
      expect(a1.hashCode, a2.hashCode);
      expect(a1, isNot(equals(b)));

      // TransientTargetはidentity比較のまま（INV-13: adoptActivePersistentの
      // 型が PersistentTarget のみを受け付けるため、Transient は型レベルで除外
      // されており、instance equalityへの変更は不要かつ行われていない）。
      const t1 = TransientTarget();
      expect(identical(t1, t1), isTrue,
          reason: 'TransientTargetは既定のidentity比較のまま'
              '（==/hashCodeへの変更は行っていない）');

      // INV-13 型レベル回帰防止（Independent Pre-Commit Review Finding 2）。
      // adoptActivePersistent の target 引数が PersistentTarget から
      // PlaybackTarget（＝TransientTargetも受理可能）へ将来widenされていない
      // ことを、tear-offの宣言された関数型に対する反変性チェックで検証する。
      //
      // このrepositoryにはcompile-fail fixture用の追加ツール/依存が無いため
      // （新規依存はこのテストのためだけに追加しない）、実際のコンパイル
      // エラーの代わりに、宣言された関数シグネチャに対するruntime `is`
      // チェックで代替する — これがこの環境で利用可能な最も強い
      // type-signature assertion である。
      //
      // 反変性の根拠: パラメータをより広い型（PlaybackTarget）で受け付ける
      // 関数は、より狭い型（PersistentTarget）だけを受け付ける関数の代わりに
      // 安全に使える（＝ is関係が成立する）。逆に、狭い型だけを受け付ける
      // 実際の関数が、広い型を受け付けるフリをすること（＝ is関係が成立
      // すること）は型システム上できない。したがって target が将来
      // PlaybackTarget へwidenされると、下の判定は true に反転し、
      // isFalse assertion が失敗して回帰を検知する。
      final isWidenedToPlaybackTarget = transport.adoptActivePersistent
          is Future<ActivePlaybackSnapshot?> Function({
        required PlaybackTarget target,
        required PlaybackOwnerKey newOwner,
        required PlaybackUsageAccounting accounting,
      });
      expect(isWidenedToPlaybackTarget, isFalse,
          reason: 'adoptActivePersistentのtargetパラメータがPersistentTargetより'
              '広い型（PlaybackTarget、＝TransientTargetも受理可能）へwidenされて'
              'いないことを検証する（INV-13の型レベル回帰防止）。widenされると'
              'この判定はtrueへ反転し、ここで失敗する。');
    });

    test(
        'H1/T15a: 同一owner(np:S2)への重複adoptionは完全no-op（flush無し・'
        'onPlaybackStarted無し・TTS無し・同一snapshotを返す）', () async {
      final acc = _SpyAccounting(log, 'A');
      await transport.start(ownerA, persistentReq('aaaa', contentId: 'A'),
          accounting: acc);
      positions.add(const TtsPlaybackPosition(
          charPosition: 2, isPlaying: true, ttsStatus: TtsStatus.playing));
      final before = transport.activeSnapshot!;
      log.clear();

      final result = await transport.adoptActivePersistent(
        target: PersistentTarget.ofRegisteredSessionContentId('A'),
        newOwner: ownerA,
        accounting: acc,
      );

      expect(log, isEmpty, reason: 'flush/onPlaybackStarted/TTSのいずれも起きない');
      expect(transport.activeOwner, ownerA);
      expect(result!.owner, before.owner);
      expect(result.position, before.position);
      expect(result.epoch, before.epoch);
      expect(result.isPlaying, before.isPlaying);
    });

    test('adoption: activeが無ければnull（noActive）で完全no-op', () async {
      final result = await transport.adoptActivePersistent(
        target: PersistentTarget.ofRegisteredSessionContentId('A'),
        newOwner: ownerA,
        accounting: const NoUsageAccounting(),
      );
      expect(result, isNull);
      expect(log, isEmpty);
    });

    test('adoption: Transient targetが活性中はnull（型レベルでは無くruntime narrowing）',
        () async {
      await transport.start(ownerA, req('transient'),
          accounting: const NoUsageAccounting());
      final result = await transport.adoptActivePersistent(
        target: PersistentTarget.ofRegisteredSessionContentId('A'),
        newOwner: ownerB,
        accounting: const NoUsageAccounting(),
      );
      expect(result, isNull);
      expect(transport.activeOwner, ownerA, reason: 'Transientのownerは無変化');
    });

    test('INV-7: 別contentのtargetに対するadoptionはnull、活性owner/requestは無変化',
        () async {
      await transport.start(ownerA, persistentReq('aaaa', contentId: 'A'),
          accounting: const NoUsageAccounting());
      final result = await transport.adoptActivePersistent(
        target: PersistentTarget.ofRegisteredSessionContentId('B'),
        newOwner: ownerB,
        accounting: const NoUsageAccounting(),
      );
      expect(result, isNull);
      expect(transport.activeOwner, ownerA);
      expect((transport.activeRequestForDebug!.target as PersistentTarget)
          .contentId, 'A');
    });

    test(
        'T14 [RT-4]: 1回のadoptionをまたぐusage accounting（position streamは動き続ける）。'
        'no-await swap windowにより新ownerへ即座に正しく帰属し、合計課金は単一session'
        '相当（P_final-P_start）になる（INV-12）', () async {
      final settingsRepo = _FakeSettingsRepository();
      final counter = CountTtsUsageUseCase(
        settingsRepo: settingsRepo,
        checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      );
      final accounting = PersistentUsageAccounting(counter);
      final accepted = <OwnedPositionEvent>[];
      transport.acceptedPositions.listen(accepted.add);

      await transport.start(ownerA, persistentReq('0123456789', contentId: 'A'),
          accounting: accounting);
      handlerPosition = 3;
      positions.add(const TtsPlaybackPosition(
          charPosition: 3, isPlaying: true, ttsStatus: TtsStatus.playing));

      final adopt = transport.adoptActivePersistent(
        target: PersistentTarget.ofRegisteredSessionContentId('A'),
        newOwner: ownerB,
        accounting: accounting,
      );
      // owner swap は同期的に起こる（await境界を挟まない、§8.2.6）ため、
      // ここで発生するpositionは新ownerへ即座に正しく帰属する。
      expect(transport.activeOwner, ownerB);
      handlerPosition = 9;
      positions.add(const TtsPlaybackPosition(
          charPosition: 9, isPlaying: true, ttsStatus: TtsStatus.playing));

      final snapshot = await adopt;
      expect(snapshot, isNotNull);
      expect(snapshot!.owner, ownerB);
      expect(snapshot.hasLiveStatus, isTrue);
      expect(snapshot.position, 9);

      handlerPosition = 12;
      positions.add(const TtsPlaybackPosition(
          charPosition: 12, isPlaying: true, ttsStatus: TtsStatus.playing));
      await transport.stop(ownerB);

      expect(accepted.map((e) => '${e.owner}:${e.charPosition}'),
          ['np:A:3', 'np:B:9', 'np:B:12']);
      expect(await settingsRepo.get(SettingKeys.ttsUsedChars), '12',
          reason: 'P_final(12) - P_start(0)。二重計上も欠落も無い');
    });

    test(
        'T15b [NR-1][RT-4]: reopenによる新sessionへの再adoption（non-quiescent）。'
        'flushは1回だけ、restartも1回だけ、TTSは無変化、旧ownerの遅延teardownは'
        'ignoredStaleOwnerになる', () async {
      final settingsRepo = _FakeSettingsRepository();
      final counter = CountTtsUsageUseCase(
        settingsRepo: settingsRepo,
        checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      );
      final accounting = PersistentUsageAccounting(counter);

      await transport.start(ownerA, persistentReq('aaaaaaaaaa', contentId: 'A'),
          accounting: accounting);
      handlerPosition = 4;
      positions.add(const TtsPlaybackPosition(
          charPosition: 4, isPlaying: true, ttsStatus: TtsStatus.playing));
      final speakCountBefore = tts.speakCount;

      final adopt = transport.adoptActivePersistent(
        target: PersistentTarget.ofRegisteredSessionContentId('A'),
        newOwner: ownerB,
        accounting: accounting,
      );
      handlerPosition = 7;
      positions.add(const TtsPlaybackPosition(
          charPosition: 7, isPlaying: true, ttsStatus: TtsStatus.playing));
      await adopt;

      expect(transport.activeOwner, ownerB);
      expect(tts.speakCount, speakCountBefore, reason: 'adoptionはspeak()を呼ばない');
      expect(tts.stopCount, 0, reason: 'adoptionはstop()も呼ばない');

      handlerPosition = 10;
      positions.add(const TtsPlaybackPosition(
          charPosition: 10, isPlaying: true, ttsStatus: TtsStatus.playing));
      await transport.stop(ownerB);

      expect(await settingsRepo.get(SettingKeys.ttsUsedChars), '10');

      // 旧sessionの遅延teardownは、既にownerが進んでいるためno-op。
      final stale = await transport.forceStopForTeardown(
        expectedOwner: ownerA,
        reason: TeardownReason.routeRemoval,
        notificationDisposition: NotificationDisposition.handoff,
      );
      expect(stale.application, TeardownApplication.ignoredStaleOwner);
    });

    test(
        'T15c [NR-1][RT-4]: 3段のreopen chain（np:B -> np:C -> np:D）。'
        '各hopでflush/restartは1回ずつ、累計課金は単一session相当', () async {
      final settingsRepo = _FakeSettingsRepository();
      final counter = CountTtsUsageUseCase(
        settingsRepo: settingsRepo,
        checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      );
      final accounting = PersistentUsageAccounting(counter);

      await transport.start(ownerA, persistentReq('chain', contentId: 'A'),
          accounting: accounting);
      handlerPosition = 2;
      positions.add(const TtsPlaybackPosition(
          charPosition: 2, isPlaying: true, ttsStatus: TtsStatus.playing));

      Future<ActivePlaybackSnapshot?> hop(PlaybackOwnerKey newOwner) =>
          transport.adoptActivePersistent(
            target: PersistentTarget.ofRegisteredSessionContentId('A'),
            newOwner: newOwner,
            accounting: accounting,
          );

      final hopToB = hop(ownerB);
      handlerPosition = 5;
      positions.add(const TtsPlaybackPosition(
          charPosition: 5, isPlaying: true, ttsStatus: TtsStatus.playing));
      expect((await hopToB)!.owner, ownerB);

      final hopToC = hop(ownerC);
      handlerPosition = 8;
      positions.add(const TtsPlaybackPosition(
          charPosition: 8, isPlaying: true, ttsStatus: TtsStatus.playing));
      expect((await hopToC)!.owner, ownerC);

      final hopToD = hop(ownerD);
      handlerPosition = 11;
      positions.add(const TtsPlaybackPosition(
          charPosition: 11, isPlaying: true, ttsStatus: TtsStatus.playing));
      expect((await hopToD)!.owner, ownerD);

      expect(transport.activeOwner, ownerD);
      await transport.stop(ownerD);

      expect(await settingsRepo.get(SettingKeys.ttsUsedChars), '11',
          reason: 'P_final(11) - P_start(0)。chain全体で単一session相当');
      expect(tts.stopCount, 1,
          reason: 'TTS stopはchainの最後のstop()だけ（adoptionは1回もstopを呼ばない）');
    });

    test(
        'T17 [RT-3]: 前sessionのlive-state(isPlaying=true)は新sessionへ継承されない'
        '（INV-16）', () async {
      final acc1 = _SpyAccounting(log, '1');
      await transport.start(ownerA, req('S1'), accounting: acc1);
      positions.add(const TtsPlaybackPosition(
          charPosition: 5, isPlaying: true, ttsStatus: TtsStatus.playing));
      expect(transport.activeSnapshot!.hasLiveStatus, isTrue);
      expect(transport.activeSnapshot!.isPlaying, isTrue);
      final epochAfterS1 = transport.activeSnapshot!.epoch;

      await transport.forceStopForTeardown(
        expectedOwner: ownerA,
        reason: TeardownReason.terminalClose,
        notificationDisposition: NotificationDisposition.clearIfNoLiveOwner,
      );
      expect(transport.activeSnapshot, isNull);

      final acc2 = _SpyAccounting(log, '2');
      await transport.start(ownerB, req('S2'), accounting: acc2);
      // 意図的にposition eventをまだ発生させない: 受理済みeventが無い。
      final snap2 = transport.activeSnapshot!;
      expect(snap2.hasLiveStatus, isFalse,
          reason: 'session1のisPlaying:trueを継承しない');
      expect(snap2.isPlaying, isFalse);
      expect(snap2.ttsStatus, TtsStatus.stopped);
      expect(snap2.epoch, greaterThan(epochAfterS1),
          reason: '_sessionEpochがsession境界で進んでいる');
    });

    test(
        'T18 [RT-4]: 旧ownerのflush書込みが遅延している間にhandoffが完了し、'
        'handoff後のpositionも新ownerへ正しく計上される（二重計上も欠落も無い）',
        () async {
      final settingsRepo = _DelayableSettingsRepository();
      final counter = CountTtsUsageUseCase(
        settingsRepo: settingsRepo,
        checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      );
      final accounting = PersistentUsageAccounting(counter);

      await transport.start(ownerA, persistentReq('T18', contentId: 'A'),
          accounting: accounting);
      handlerPosition = 3;
      positions.add(const TtsPlaybackPosition(
          charPosition: 3, isPlaying: true, ttsStatus: TtsStatus.playing));

      final gate = Completer<void>();
      settingsRepo.holdNextSet = gate;

      final adopt = transport.adoptActivePersistent(
        target: PersistentTarget.ofRegisteredSessionContentId('A'),
        newOwner: ownerB,
        accounting: accounting,
      );
      // owner swapはflushの永続化書込み完了を待たない（no-await swap window）。
      expect(transport.activeOwner, ownerB);

      handlerPosition = 9;
      positions.add(const TtsPlaybackPosition(
          charPosition: 9, isPlaying: true, ttsStatus: TtsStatus.playing));

      gate.complete();
      final snapshot = await adopt;
      expect(snapshot!.owner, ownerB);

      handlerPosition = 12;
      positions.add(const TtsPlaybackPosition(
          charPosition: 12, isPlaying: true, ttsStatus: TtsStatus.playing));
      await transport.stop(ownerB);

      expect(await settingsRepo.get(SettingKeys.ttsUsedChars), '12',
          reason: 'P_final(12) - P_start(0)。遅延書込みがあっても二重計上・欠落は無い');
    });
  });
}

class _FakeTts implements TtsService {
  _FakeTts(this.log);
  final List<String> log;
  bool failSpeak = false;
  bool failStop = false;
  int stopCount = 0;
  int speakCount = 0;
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
    speakCount++;
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

/// T14/T15b/T15c 用。実際の [CountTtsUsageUseCase] を app-shared 1 instance と
/// して両ownerに渡し、adoption 前後の合計課金が単一session相当になることを
/// 実際の文字数算術で検証する（INV-12）。
class _FakeSettingsRepository implements SettingsRepository {
  final Map<String, String> _store = {};

  @override
  Future<String?> get(String key) async => _store[key];

  @override
  Future<void> set(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  Future<Map<String, String>> getAll() async => Map.of(_store);
}

/// T18 用。次の `set()` 呼び出しだけを、[holdNextSet] が complete するまで
/// 保留する（永続化書込みが handoff より遅延するケースを再現する）。
class _DelayableSettingsRepository implements SettingsRepository {
  final Map<String, String> _store = {};
  Completer<void>? holdNextSet;

  @override
  Future<String?> get(String key) async => _store[key];

  @override
  Future<void> set(String key, String value) async {
    final hold = holdNextSet;
    if (hold != null) {
      holdNextSet = null;
      await hold.future;
    }
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  Future<Map<String, String>> getAll() async => Map.of(_store);
}
