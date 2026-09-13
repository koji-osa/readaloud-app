import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/usecase/playback/save_playback_state_usecase.dart';
import 'package:readaloud_app/usecase/playback/start_playback_usecase.dart';
import 'package:readaloud_app/usecase/playback/stop_playback_usecase.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';

// Canonical Design v0.4.1 の session 権威モデル（tracker + playback gate）の
// contract test。real Navigator を必要としない fake route/fake usecase のみで
// 決定論的に検証する（RA-NPR-P04-R1 Q6 の想定どおり）。
void main() {
  late _FakeContentRepository contentRepo;
  late _FakePlaybackRepository playbackRepo;
  late _FakeSettingsRepository settingsRepo;
  late _FakeTtsAudioHandler audioHandler;
  late CountTtsUsageUseCase countUsage;
  late NormalPlayerPlaybackGate gate;
  late NormalPlayerSessionTracker tracker;

  NormalPlayerSessionTracker buildTracker() {
    contentRepo = _FakeContentRepository();
    playbackRepo = _FakePlaybackRepository();
    settingsRepo = _FakeSettingsRepository();
    audioHandler = _FakeTtsAudioHandler();
    countUsage = CountTtsUsageUseCase(
      settingsRepo: settingsRepo,
      checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
    );
    final startPlayback = StartPlaybackUseCase(
      contentRepo: contentRepo,
      playbackRepo: playbackRepo,
      positionStream: audioHandler.customState,
      ttsService: audioHandler,
      countUsage: countUsage,
    );
    final stopPlayback = StopPlaybackUseCase(
      playbackRepo: playbackRepo,
      ttsService: audioHandler,
      countUsage: countUsage,
      saveState: SavePlaybackStateUseCase(
          playbackRepo: playbackRepo, contentRepo: contentRepo),
    );
    gate = NormalPlayerPlaybackGate(
      startPlayback: startPlayback,
      stopPlayback: stopPlayback,
      getCurrentPosition: () => audioHandler.currentPosition,
    );
    return NormalPlayerSessionTracker(playbackGate: gate);
  }

  setUp(() {
    tracker = buildTracker();
  });

  group('registration / rollback（D4/NRR-02/NRR-05）', () {
    test('registerで登録した直後はisEffectCurrentがtrueになる', () {
      final session = NormalPlayerSession(contentId: 'c1');
      final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      final token = tracker.register(session: session, route: route);

      expect(token, isNotNull);
      expect(tracker.isEffectCurrent(session.id), isTrue);
      expect(tracker.currentSession?.id, session.id);
    });

    test('register(replacingOrigin:)はeffect-currentでないoriginからの登録を拒否する',
        () async {
      final sessionA = NormalPlayerSession(contentId: 'c1');
      final routeA = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tracker.register(session: sessionA, route: routeA);

      // Aをretiringにする（stopは即座に成功させる）。
      await tracker.prepareForRemoval(flowId: 'f1');
      expect(tracker.isEffectCurrent(sessionA.id), isFalse);

      final sessionB = NormalPlayerSession(contentId: 'c2');
      final routeB = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      final token = tracker.register(
        session: sessionB,
        route: routeB,
        replacingOrigin: PlayerOriginToken(
            sessionId: sessionA.id, contentId: sessionA.contentId),
      );

      expect(token, isNull, reason: 'retiring中のAはBをregisterできない（CB-1 V-B）');
      expect(tracker.currentSession?.id, sessionA.id,
          reason: 'Bは生成されずAが依然current');
    });

    test('abortRegistrationは直前のregistrationへ正確に復元する（nullへblind clearしない）', () {
      final sessionA = NormalPlayerSession(contentId: 'c1');
      final routeA = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tracker.register(session: sessionA, route: routeA);

      final sessionB = NormalPlayerSession(contentId: 'c2');
      final routeB = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      final tokenB = tracker.register(session: sessionB, route: routeB);

      tracker.abortRegistration(tokenB!);

      expect(tracker.currentSession?.id, sessionA.id,
          reason: 'D4: rollbackはnullではなく直前のAへ正確に復元する');
    });

    test('abortRegistrationはidentity-safe: 別のregistrationが既にcurrentならno-op',
        () {
      final sessionA = NormalPlayerSession(contentId: 'c1');
      final routeA = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      final tokenA = tracker.register(session: sessionA, route: routeA);

      final sessionB = NormalPlayerSession(contentId: 'c2');
      final routeB = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tracker.register(session: sessionB, route: routeB);

      // 遅れてAのtokenでabortRegistrationが呼ばれても、既にBが正しくcurrent。
      tracker.abortRegistration(tokenA!);

      expect(tracker.currentSession?.id, sessionB.id,
          reason: '遅延したabortRegistrationがnewer registrationを壊してはならない');
    });
  });

  group('removeActivePlayerNow 3分岐契約（D7/G-01/TL-04）', () {
    test('branch1: registrationが無い場合はno-op', () {
      final ticket = PlayerRemovalTicket.forSession(
        sessionId: 'ghost',
        contentId: 'c1',
        claimId: 'claim-x',
        flowId: 'f1',
        stopOutcome: PlaybackStopOutcome.notApplicable(),
      );
      // context は分岐1では一切参照されないため未使用のfakeで良い。
      expect(
          () =>
              tracker.removeActivePlayerNow(ticket, context: _UnusedContext()),
          returnsNormally);
    });

    test('branch1: session不一致の場合は新しいregistrationを誤除去しない', () async {
      final sessionA = NormalPlayerSession(contentId: 'c1');
      final routeA = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tracker.register(session: sessionA, route: routeA);
      final ticketA = await tracker.prepareForRemoval(flowId: 'f1');

      // Aが除去される前に、Bが新たにcurrentへ差し替わったと仮定する。
      final sessionB = NormalPlayerSession(contentId: 'c2');
      final routeB = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      // B登録はreplacingOriginなしなので常に成功する（Home/Add経路相当）。
      tracker.register(session: sessionB, route: routeB);

      tracker.removeActivePlayerNow(ticketA, context: _UnusedContext());

      expect(tracker.currentSession?.id, sessionB.id,
          reason: '古いticketがnewer registration(B)を誤除去してはならない');
    });

    test('branch2: tracked routeがinactiveな場合はidentity-safeにclearするだけ',
        () async {
      final session = NormalPlayerSession(contentId: 'c1');
      // 一度もpushしていないRouteはisActive==falseのまま（実Navigator不要）。
      final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      expect(route.isActive, isFalse);
      tracker.register(session: session, route: route);
      final ticket = await tracker.prepareForRemoval(flowId: 'f1');

      tracker.removeActivePlayerNow(ticket, context: _UnusedContext());

      expect(tracker.currentSession, isNull);
    });
  });

  group('retirement claim lifecycle（D6/D7, CB-4）', () {
    test('複数flowが同時にclaimしても片方のabandonだけではeffect-activeへ戻らない', () async {
      final session = NormalPlayerSession(contentId: 'c1');
      final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tracker.register(session: session, route: route);

      final ticket1 = await tracker.prepareForRemoval(flowId: 'f1');
      final ticket2 = await tracker.prepareForRemoval(flowId: 'f2');
      expect(tracker.retirementClaimCountForTest, 2);
      expect(ticket2.sessionId, session.id);

      tracker.abandonRemoval(ticket1);

      expect(tracker.isEffectCurrent(session.id), isFalse,
          reason: 'f2のclaimが残っている限りAはretiringのまま（CB-4 #3）');
    });

    test('両方のflowがabandonするとexactly onceでeffect-activeへ戻る', () async {
      final session = NormalPlayerSession(contentId: 'c1');
      final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tracker.register(session: session, route: route);

      final ticket1 = await tracker.prepareForRemoval(flowId: 'f1');
      final ticket2 = await tracker.prepareForRemoval(flowId: 'f2');

      tracker.abandonRemoval(ticket1);
      expect(tracker.isEffectCurrent(session.id), isFalse);
      tracker.abandonRemoval(ticket2);

      expect(tracker.isEffectCurrent(session.id), isTrue,
          reason: '最後のclaimが外れた瞬間にexactly onceでactiveへ戻る（CB-4 #4）');
    });

    test('B登録後のAの遅延abandonはno-op（identity-safe）', () async {
      final sessionA = NormalPlayerSession(contentId: 'c1');
      final routeA = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tracker.register(session: sessionA, route: routeA);
      final ticketA = await tracker.prepareForRemoval(flowId: 'f1');

      final sessionB = NormalPlayerSession(contentId: 'c2');
      final routeB = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tracker.register(session: sessionB, route: routeB);

      tracker.abandonRemoval(ticketA);

      expect(tracker.isEffectCurrent(sessionB.id), isTrue,
          reason: 'Aの遅延abandonはBのclaim集合に影響しない（CB-4 #5）');
    });

    test('除去成功後の遅延abandonはno-op', () async {
      final session = NormalPlayerSession(contentId: 'c1');
      final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tracker.register(session: session, route: route);
      final ticket = await tracker.prepareForRemoval(flowId: 'f1');
      tracker.removeActivePlayerNow(ticket, context: _UnusedContext());
      expect(tracker.currentSession, isNull);

      // registrationが既に消えた後にabandonを呼んでも例外にならない。
      expect(() => tracker.abandonRemoval(ticket), returnsNormally);
      expect(tracker.currentSession, isNull);
    });
  });

  group('DC-01: 同一sessionのin-flight stop dedupe（RA-NPR-P04-R1）', () {
    test('同時prepareForRemovalは同じstop試行を共有し、両方が同じ結果を観測する', () async {
      final completer = Completer<void>();
      audioHandler.stopBehavior = () => completer.future;

      final session = NormalPlayerSession(contentId: 'c1');
      final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tracker.register(session: session, route: route);

      final future1 = tracker.prepareForRemoval(flowId: 'f1');
      final future2 = tracker.prepareForRemoval(flowId: 'f2');

      completer.complete();
      final ticket1 = await future1;
      final ticket2 = await future2;

      expect(audioHandler.stopCallCount, 1,
          reason: '後続ticketはstopをunknownで返さず先行stopへpiggybackする（DC-01）');
      expect(ticket1.stopOutcome.ttsStopSucceeded, isTrue);
      expect(ticket2.stopOutcome.ttsStopSucceeded, isTrue);
    });
  });

  group('B-01 closure: TTS-stop confirmed gating（D8/D12/D16）', () {
    test('TTS-stop失敗時はremoveActivePlayerNowが除去しない（defense-in-depth）', () async {
      audioHandler.stopBehavior = () => throw Exception('tts stop failed');

      final session = NormalPlayerSession(contentId: 'c1');
      final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tracker.register(session: session, route: route);
      final ticket = await tracker.prepareForRemoval(flowId: 'f1');

      expect(ticket.stopOutcome.ttsStopSucceeded, isFalse);
      expect(ticket.stopOutcome.ttsStopConfirmed, isFalse);

      tracker.removeActivePlayerNow(ticket, context: _UnusedContext());

      expect(tracker.currentSession?.id, session.id,
          reason: 'TTS-stopが確認できないPlayerはroute除去されず回復可能なまま残る');
    });

    test(
        'accounting flush失敗だけならTTS-stopは実行され、removalは許可される'
        '（I-01是正: production counterのpathで実際にflush失敗を発生させる）', () async {
      final session = NormalPlayerSession(contentId: 'c1');
      final owner = PlaybackOwnerKey.normalPlayer(session.id);

      // I-01是正: stopForSession()が使うのと同じownerでstartCountingを呼び、
      // _activeOwnerを実際に確立してからupdatePosition()でflush対象のdelta
      // (50)を作る。旧テストはstartCounting()を一度も呼んでいなかったため
      // _activeOwnerがnullのままで、stopCounting(owner)がowner不一致相当で
      // 即returnし、意図した永続書込み失敗が一度も発生していなかった
      // （audioHandler.currentPositionを書くだけでは_currentPositionは進まず、
      // production側の唯一の入力経路はupdatePosition()）。
      countUsage.startCounting(
          owner: owner, totalChars: 1000, startPosition: 0);
      countUsage.updatePosition(50);

      settingsRepo.failNextSet = 1; // _addUsage の永続書込みを1回だけ失敗させる

      final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      tracker.register(session: session, route: route);
      final ticket = await tracker.prepareForRemoval(flowId: 'f1');

      expect(ticket.stopOutcome.usageFlushSucceeded, isFalse,
          reason: 'I-01是正: accountingの永続書込み失敗が実際にproduction counterの'
              'pathを通って発生したことを確認する（空振り防止。旧テストはこの'
              'assertionが無く、baselineの逐次失敗モードへ退行してもpassしていた）');
      expect(audioHandler.stopCallCount, 1,
          reason: 'accounting失敗がTTS停止をskipさせない（B-01）');
      expect(ticket.stopOutcome.ttsStopSucceeded, isTrue);
      expect(ticket.stopOutcome.ttsStopConfirmed, isTrue);

      tracker.removeActivePlayerNow(ticket, context: _UnusedContext());
      expect(tracker.currentSession, isNull,
          reason: 'TTS-stop成功後はremovalが許可される（accounting失敗の有無に'
              '関わらず）');
    });
  });
}

class _UnusedContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('この分岐ではBuildContextは参照されないはず');
}

class _FakeContentRepository implements ContentRepository {
  final Map<String, Content> _store = {};

  Content _ensure(String id) => _store.putIfAbsent(
        id,
        () =>
            Content(id: id, title: 't', body: 'body text', sourceType: 'text'),
      );

  @override
  Future<Content?> getById(String id) async => _ensure(id);

  @override
  Future<void> update(Content content) async => _store[content.id] = content;

  @override
  Future<List<Content>> getAll() async => _store.values.toList();

  @override
  Future<List<Content>> getByStatus(String status) async => [];

  @override
  Future<void> save(Content content) async => _store[content.id] = content;

  @override
  Future<void> delete(String id) async => _store.remove(id);
}

class _FakePlaybackRepository implements PlaybackRepository {
  final Map<String, PlaybackState> _store = {};

  @override
  Future<PlaybackState?> getByContentId(String contentId) async =>
      _store[contentId];

  @override
  Future<void> save(PlaybackState state) async =>
      _store[state.contentId] = state;

  @override
  Future<void> resetAbRepeat(String contentId) async {}

  @override
  Future<void> resetAllAbRepeat() async {}

  @override
  Future<void> delete(String contentId) async => _store.remove(contentId);
}

class _FakeSettingsRepository implements SettingsRepository {
  final Map<String, String> _store = {};
  int failNextSet = 0;

  @override
  Future<String?> get(String key) async => _store[key];

  @override
  Future<void> set(String key, String value) async {
    if (failNextSet > 0) {
      failNextSet--;
      throw Exception('settings write failed (test)');
    }
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  Future<Map<String, String>> getAll() async => Map.of(_store);
}

/// StartPlaybackUseCase が要求する TtsAudioHandler 相当の最小 fake。
/// 本物の TtsAudioHandler は BaseAudioHandler を継承する重量級クラスのため、
/// TtsService インターフェースのみを実装する軽量 fake を使う（QuickListen系
/// テストの既存パターンと同型）。
class _FakeTtsAudioHandler implements TtsService {
  int currentPosition = 0;
  int stopCallCount = 0;
  dynamic Function()? stopBehavior;
  final StreamController<dynamic> _customStateController =
      StreamController<dynamic>.broadcast();

  Stream<dynamic> get customState => _customStateController.stream;

  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {
    stopCallCount++;
    final behavior = stopBehavior;
    if (behavior != null) {
      final result = behavior();
      if (result is Future) await result;
    }
  }

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async => [];

  @override
  Future<void> dispose() async {}
}
