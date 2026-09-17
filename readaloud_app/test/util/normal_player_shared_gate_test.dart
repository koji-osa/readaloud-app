import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/setting.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/usecase/playback/persistent_playback_resolver.dart';
import 'package:readaloud_app/usecase/playback/playback_usage_accounting.dart';
import 'package:readaloud_app/usecase/playback/save_playback_state_usecase.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/usecase/playback/start_playback_usecase.dart';
import 'package:readaloud_app/usecase/playback/stop_playback_usecase.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';

// Shared Player Core Slice 3: production 構成（NormalPlayerPlaybackGate.shared）
// の Persistent 契約（T-P1）と owner-safe teardown（C1/C3/INV-T10）を検証する。
void main() {
  setUp(() => DebugLogger.testSink = []);
  tearDown(() => DebugLogger.testSink = null);

  group('T-P1: shared構成のPersistent書込みは旧usecase構成と同値', () {
    for (final op in ['pause', 'stop']) {
      test(
          'start → 受理position → $op で playback_states / tts_used_chars / '
          'status / TTS呼出しが一致する', () async {
        final legacy = _Env.legacy();
        final shared = _Env.shared();
        for (final env in [legacy, shared]) {
          env.contentRepo.store['c1'] = Content(
              id: 'c1', title: 't', body: 'x' * 200, sourceType: 'text');
          env.playbackRepo.store['c1'] = PlaybackState(
              contentId: 'c1', position: 10, progressPct: 5.0, speed: 1.5);
          await env.gate.start(sessionId: 'S', contentId: 'c1');
          env.positions.add(const TtsPlaybackPosition(
              charPosition: 50, isPlaying: true, ttsStatus: TtsStatus.playing));
          await Future<void>.delayed(Duration.zero);
          final outcome = op == 'pause'
              ? await env.gate
                  .pause(sessionId: 'S', contentId: 'c1', position: 50)
              : await env.gate.stopForSession(
                  sessionId: 'S', contentId: 'c1', position: 50);
          expect(outcome.ttsStopConfirmed, isTrue);
          expect(outcome.usageFlushSucceeded, isTrue);
          expect(outcome.positionSaveSucceeded, isTrue);
        }
        final l = legacy.playbackRepo.store['c1']!;
        final s = shared.playbackRepo.store['c1']!;
        expect(s.position, l.position);
        expect(s.progressPct, l.progressPct);
        expect(s.speed, l.speed);
        expect(await shared.settingsRepo.get(SettingKeys.ttsUsedChars),
            await legacy.settingsRepo.get(SettingKeys.ttsUsedChars));
        expect(await shared.settingsRepo.get(SettingKeys.ttsUsedChars), '40');
        expect(shared.contentRepo.store['c1']!.status,
            legacy.contentRepo.store['c1']!.status);
        expect(shared.tts.calls, legacy.tts.calls);
      });
    }
  });

  group('shared構成のteardown（tracker.prepareForRemoval）', () {
    test('再生中のAはowner一致でstop + handoff fence + 位置保存され、除去可能になる', () async {
      final env = _Env.shared();
      env.contentRepo.store['c1'] =
          Content(id: 'c1', title: 't', body: 'x' * 100, sourceType: 'text');
      final tracker = NormalPlayerSessionTracker(playbackGate: env.gate);
      final session = NormalPlayerSession(contentId: 'c1');
      tracker.register(
          session: session,
          route: MaterialPageRoute<void>(builder: (_) => const SizedBox()));
      await env.gate.start(sessionId: session.id, contentId: 'c1');
      env.handlerPosition = 30;

      final ticket = await tracker.prepareForRemoval(flowId: 'f1');

      expect(ticket.stopOutcome.ttsStopConfirmed, isTrue);
      expect(env.tts.calls.last, 'stop');
      expect(env.fence.calls, [NotificationDisposition.handoff]);
      expect(env.playbackRepo.store['c1']!.position, 30);
      expect(env.transport.activeOwner, isNull);
    });

    test('一度も再生していないAのteardownはnoActivePlayback: TTS/fenceに触れず除去可能', () async {
      final env = _Env.shared();
      final tracker = NormalPlayerSessionTracker(playbackGate: env.gate);
      tracker.register(
          session: NormalPlayerSession(contentId: 'c1'),
          route: MaterialPageRoute<void>(builder: (_) => const SizedBox()));

      final ticket = await tracker.prepareForRemoval(flowId: 'f1');

      expect(ticket.stopOutcome.applicable, isFalse);
      expect(ticket.stopOutcome.ttsStopConfirmed, isTrue);
      expect(env.tts.calls, isEmpty);
      expect(env.fence.calls, isEmpty);
      expect(env.playbackRepo.store, isEmpty,
          reason: '所有していない位置を自contentへ保存しない');
    });

    test(
        '別owner（旧NP A）がactiveなままNP Bをteardownするとignored: '
        'AのTTSを止めずroute除去もblockされる（§6.3 AC-01例外）', () async {
      final env = _Env.shared();
      env.contentRepo.store['cA'] =
          Content(id: 'cA', title: 't', body: 'aaaa', sourceType: 'text');
      await env.gate.start(sessionId: 'A', contentId: 'cA');

      final tracker = NormalPlayerSessionTracker(playbackGate: env.gate);
      final sessionB = NormalPlayerSession(contentId: 'cB');
      tracker.register(
          session: sessionB,
          route: MaterialPageRoute<void>(builder: (_) => const SizedBox()));
      env.tts.calls.clear();

      final ticket = await tracker.prepareForRemoval(flowId: 'f1');

      expect(ticket.stopOutcome.ttsStopConfirmed, isFalse);
      expect(env.tts.calls, isEmpty);
      expect(env.fence.calls, isEmpty);
      expect(env.transport.activeOwner, PlaybackOwnerKey.normalPlayer('A'));
    });

    test('UI stop（stopForSession）はowner-retiringではないためfenceしない', () async {
      final env = _Env.shared();
      env.contentRepo.store['c1'] =
          Content(id: 'c1', title: 't', body: 'abcd', sourceType: 'text');
      await env.gate.start(sessionId: 'S', contentId: 'c1');
      await env.gate
          .stopForSession(sessionId: 'S', contentId: 'c1', position: 2);
      expect(env.fence.calls, isEmpty);
      expect(env.transport.activeOwner, PlaybackOwnerKey.normalPlayer('S'));
    });

    test('stale UI stop（別ownerがactive）は位置保存もTTS停止も行わない', () async {
      final env = _Env.shared();
      env.contentRepo.store['cA'] =
          Content(id: 'cA', title: 't', body: 'aaaa', sourceType: 'text');
      await env.gate.start(sessionId: 'A', contentId: 'cA');
      env.tts.calls.clear();

      final outcome = await env.gate
          .stopForSession(sessionId: 'B', contentId: 'cB', position: 3);

      expect(outcome.applicable, isFalse);
      expect(env.tts.calls, isEmpty);
      expect(env.playbackRepo.store.containsKey('cB'), isFalse);
    });
  });

  test(
      'start失敗（speak throw）はPlaybackStartFailureとして伝わり、'
      '次のstartはクリーンに成功する（C2 / AC-19）', () async {
    final env = _Env.shared();
    env.contentRepo.store['c1'] =
        Content(id: 'c1', title: 't', body: 'abcd', sourceType: 'text');
    env.tts.failSpeak = true;
    await expectLater(env.gate.start(sessionId: 'S1', contentId: 'c1'),
        throwsA(isA<PlaybackStartFailure>()));
    expect(env.transport.activeOwner, isNull);

    env.tts.failSpeak = false;
    await env.gate.start(sessionId: 'S2', contentId: 'c1');
    expect(env.transport.activeOwner, PlaybackOwnerKey.normalPlayer('S2'));
  });

  test('AC-14: shared構成のusage counterはPersistentUsageAccounting経由の1 instanceのみ',
      () async {
    final env = _Env.shared();
    env.contentRepo.store['c1'] =
        Content(id: 'c1', title: 't', body: 'x' * 100, sourceType: 'text');
    await env.gate.start(sessionId: 'S', contentId: 'c1');
    env.positions.add(const TtsPlaybackPosition(
        charPosition: 7, isPlaying: true, ttsStatus: TtsStatus.playing));
    await env.gate.stopForSession(sessionId: 'S', contentId: 'c1', position: 7);
    expect(await env.settingsRepo.get(SettingKeys.ttsUsedChars), '7');
  });
}

class _Env {
  _Env._({
    required this.contentRepo,
    required this.playbackRepo,
    required this.settingsRepo,
    required this.tts,
    required this.fence,
    required this.positions,
    required this.gate,
    required SharedPlaybackTransport? transport,
  }) : _transport = transport;

  factory _Env.legacy() {
    final base = _Base();
    final gate = NormalPlayerPlaybackGate(
      startPlayback: StartPlaybackUseCase(
        contentRepo: base.contentRepo,
        playbackRepo: base.playbackRepo,
        positionStream: base.positions.stream,
        ttsService: base.tts,
        countUsage: base.counter,
      ),
      stopPlayback: StopPlaybackUseCase(
        playbackRepo: base.playbackRepo,
        ttsService: base.tts,
        countUsage: base.counter,
        saveState: base.save,
      ),
      getCurrentPosition: () => base.position,
    );
    return base.build(gate, null);
  }

  factory _Env.shared() {
    final base = _Base();
    late final _Env env;
    final transport = SharedPlaybackTransport(
      tts: base.tts,
      positionStream: base.positions.stream,
      currentPosition: () => env.handlerPosition,
      resumeFence: base.fence,
    );
    final gate = NormalPlayerPlaybackGate.shared(
      transport: transport,
      resolver: PersistentPlaybackResolver(
          contentRepo: base.contentRepo, playbackRepo: base.playbackRepo),
      playbackRepo: base.playbackRepo,
      savePlaybackState: base.save,
      accounting: PersistentUsageAccounting(base.counter),
    );
    env = base.build(gate, transport);
    return env;
  }

  final _FakeContentRepository contentRepo;
  final _FakePlaybackRepository playbackRepo;
  final _FakeSettingsRepository settingsRepo;
  final _FakeTts tts;
  final _FakeFence fence;
  final StreamController<dynamic> positions;
  final NormalPlayerPlaybackGate gate;
  final SharedPlaybackTransport? _transport;
  int handlerPosition = 0;

  SharedPlaybackTransport get transport => _transport!;
}

class _Base {
  final contentRepo = _FakeContentRepository();
  final playbackRepo = _FakePlaybackRepository();
  final settingsRepo = _FakeSettingsRepository();
  final tts = _FakeTts();
  final fence = _FakeFence();
  final positions = StreamController<dynamic>.broadcast(sync: true);
  int position = 0;
  late final counter = CountTtsUsageUseCase(
    settingsRepo: settingsRepo,
    checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
  );
  late final save = SavePlaybackStateUseCase(
      playbackRepo: playbackRepo, contentRepo: contentRepo);

  _Env build(
          NormalPlayerPlaybackGate gate, SharedPlaybackTransport? transport) =>
      _Env._(
        contentRepo: contentRepo,
        playbackRepo: playbackRepo,
        settingsRepo: settingsRepo,
        tts: tts,
        fence: fence,
        positions: positions,
        gate: gate,
        transport: transport,
      );
}

class _FakeTts implements TtsService {
  final List<String> calls = [];
  bool failSpeak = false;

  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async {
    if (failSpeak) throw StateError('speak failed');
    calls.add('speak:$startPosition:$speed');
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async => [];

  @override
  Future<void> dispose() async {}
}

class _FakeFence implements PlaybackResumeFence {
  final List<NotificationDisposition> calls = [];

  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async =>
      calls.add(notificationDisposition);
}

class _FakeContentRepository implements ContentRepository {
  final Map<String, Content> store = {};

  @override
  Future<Content?> getById(String id) async => store[id];

  @override
  Future<void> update(Content content) async => store[content.id] = content;

  @override
  Future<List<Content>> getAll() async => store.values.toList();

  @override
  Future<List<Content>> getByStatus(String status) async => [];

  @override
  Future<void> save(Content content) async => store[content.id] = content;

  @override
  Future<void> delete(String id) async => store.remove(id);
}

class _FakePlaybackRepository implements PlaybackRepository {
  final Map<String, PlaybackState> store = {};

  @override
  Future<PlaybackState?> getByContentId(String contentId) async =>
      store[contentId];

  @override
  Future<void> save(PlaybackState state) async =>
      store[state.contentId] = state;

  @override
  Future<void> resetAbRepeat(String contentId) async {}

  @override
  Future<void> resetAllAbRepeat() async {}

  @override
  Future<void> delete(String contentId) async => store.remove(contentId);
}

class _FakeSettingsRepository implements SettingsRepository {
  final Map<String, String> _store = {};

  @override
  Future<String?> get(String key) async => _store[key];

  @override
  Future<void> set(String key, String value) async => _store[key] = value;

  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  Future<Map<String, String>> getAll() async => Map.of(_store);
}
