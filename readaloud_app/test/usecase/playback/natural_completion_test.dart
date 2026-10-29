import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_request.dart';
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
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';

// P5: Persistent(Library) の自然終了を 100% / completed として保存する。
const _playing300 = TtsPlaybackPosition(
    charPosition: 300, isPlaying: true, ttsStatus: TtsStatus.playing);
const _completed1000 = TtsPlaybackPosition(
    charPosition: 1000,
    isPlaying: false,
    ttsStatus: TtsStatus.stopped,
    isNaturalCompletion: true);

Future<void> _pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() => DebugLogger.testSink = []);
  tearDown(() => DebugLogger.testSink = null);

  Future<_Env> started({String id = 'c1', String session = 'S'}) async {
    final env = _Env();
    env.contentRepo.store[id] =
        Content(id: id, title: 't', body: 'x' * 1000, sourceType: 'text');
    await env.gate.start(sessionId: session, contentId: id);
    env.positions.add(_playing300);
    await _pump();
    return env;
  }

  test('自然終了でDBがpct 100 / position=本文長 / status completedになる', () async {
    final env = await started();
    env.positions.add(_completed1000);
    await _pump();

    final s = env.playbackRepo.store['c1']!;
    expect(s.progressPct, 100.0);
    expect(s.position, 1000);
    expect(env.contentRepo.store['c1']!.status, 'completed');
  });

  test('usageは1回だけflushされ、activeOwnerはnullになり、TTSには触れない', () async {
    final env = await started();
    env.positions.add(_completed1000);
    await _pump();

    expect(env.transport.activeOwner, isNull);
    expect(await env.settingsRepo.get(SettingKeys.ttsUsedChars), '1000');
    expect(env.tts.calls.where((c) => c == 'stop'), isEmpty,
        reason: '完了op自身はTTSに触れない');
  });

  test('完了後の同session stopForSessionはnotApplicableで100%を下げない', () async {
    final env = await started();
    env.positions.add(_completed1000);
    await _pump();
    final saves = env.playbackRepo.saveCount;

    final outcome = await env.gate
        .stopForSession(sessionId: 'S', contentId: 'c1', position: 100);

    expect(outcome.applicable, isFalse);
    expect(env.playbackRepo.store['c1']!.progressPct, 100.0);
    expect(env.playbackRepo.store['c1']!.position, 1000);
    expect(env.playbackRepo.saveCount, saves);
    expect(await env.settingsRepo.get(SettingKeys.ttsUsedChars), '1000');
  });

  test('stale: 完了op実行前に新session Bがstartすると、Aは100%にならずBも触れない', () async {
    final env = await started();
    env.contentRepo.store['c2'] =
        Content(id: 'c2', title: 't', body: 'y' * 500, sourceType: 'text');
    env.playbackRepo.store['c1'] =
        PlaybackState(contentId: 'c1', position: 300, progressPct: 30.0);

    env.positions.add(_completed1000); // op は microtask で予約されるだけ
    await env.gate.start(sessionId: 'B', contentId: 'c2');
    await _pump();

    expect(env.playbackRepo.store['c1']!.progressPct, 30.0);
    expect(env.contentRepo.store['c1']!.status, isNot('completed'));
    expect(env.playbackRepo.store['c2']?.progressPct ?? 0.0, isNot(100.0));
    expect(env.contentRepo.store['c2']!.status, isNot('completed'));
    expect(env.transport.activeOwner, PlaybackOwnerKey.normalPlayer('B'));
  });

  test('完了eventが重複しても書込みは1回', () async {
    final env = await started();
    final before = env.playbackRepo.saveCount;
    env.positions.add(_completed1000);
    env.positions.add(_completed1000);
    await _pump();

    expect(env.playbackRepo.saveCount, before + 1);
    expect(env.playbackRepo.store['c1']!.progressPct, 100.0);
  });

  test('通常のstop event(isNaturalCompletion=false)では完了書込みなし', () async {
    final env = await started();
    final before = env.playbackRepo.saveCount;
    env.positions.add(const TtsPlaybackPosition(
        charPosition: 1000, isPlaying: false, ttsStatus: TtsStatus.stopped));
    await _pump();

    expect(env.playbackRepo.saveCount, before);
    expect(env.playbackRepo.store.containsKey('c1'), isFalse);
    expect(env.contentRepo.store['c1']!.status, isNot('completed'));
    expect(env.transport.activeOwner, PlaybackOwnerKey.normalPlayer('S'));
  });

  test('Transient ownerの自然終了はDBに書かない', () async {
    final env = _Env();
    env.contentRepo.store['c1'] =
        Content(id: 'c1', title: 't', body: 'x' * 1000, sourceType: 'text');
    await env.transport.start(
      PlaybackOwnerKey.transient('Q'),
      PlaybackRequest(
          target: const TransientTarget(),
          text: 'x' * 1000,
          startPosition: 0),
      accounting: const NoUsageAccounting(),
    );
    env.positions.add(_playing300);
    await _pump();
    env.positions.add(_completed1000);
    await _pump();

    expect(env.playbackRepo.saveCount, 0);
    expect(env.contentRepo.store['c1']!.status, isNot('completed'));
    expect(env.transport.activeOwner, PlaybackOwnerKey.transient('Q'));
  });

  test('本文が空のContentは何も書かず例外も出さない', () async {
    final env = await started();
    env.contentRepo.store['c1'] =
        Content(id: 'c1', title: 't', body: '', sourceType: 'text');
    final before = env.playbackRepo.saveCount;
    env.positions.add(_completed1000);
    await _pump();

    expect(env.playbackRepo.saveCount, before);
    expect(env.transport.activeOwner, isNull);
  });

  test('保存が例外でも未処理例外は漏れず、ownerはclearされる', () async {
    final env = await started();
    env.playbackRepo.failSave = true;
    env.positions.add(_completed1000);
    await _pump();

    expect(env.transport.activeOwner, isNull);
    expect(env.contentRepo.store['c1']!.status, isNot('completed'));
  });
}

class _Env {
  _Env() {
    transport = SharedPlaybackTransport(
      tts: tts,
      positionStream: positions.stream,
      currentPosition: () => handlerPosition,
      resumeFence: _FakeFence(),
    );
    gate = NormalPlayerPlaybackGate.shared(
      transport: transport,
      resolver: PersistentPlaybackResolver(
          contentRepo: contentRepo, playbackRepo: playbackRepo),
      playbackRepo: playbackRepo,
      savePlaybackState: SavePlaybackStateUseCase(
          playbackRepo: playbackRepo, contentRepo: contentRepo),
      accounting: PersistentUsageAccounting(CountTtsUsageUseCase(
        settingsRepo: settingsRepo,
        checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      )),
    );
  }

  final contentRepo = _FakeContentRepository();
  final playbackRepo = _FakePlaybackRepository();
  final settingsRepo = _FakeSettingsRepository();
  final tts = _FakeTts();
  final positions = StreamController<dynamic>.broadcast(sync: true);
  int handlerPosition = 0;
  late final SharedPlaybackTransport transport;
  late final NormalPlayerPlaybackGate gate;
}

class _FakeTts implements TtsService {
  final List<String> calls = [];

  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async =>
      calls.add('speak:$startPosition');

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
  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async {}
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
  int saveCount = 0;
  bool failSave = false;

  @override
  Future<PlaybackState?> getByContentId(String contentId) async =>
      store[contentId];

  @override
  Future<void> save(PlaybackState state) async {
    if (failSave) throw StateError('save failed');
    saveCount++;
    store[state.contentId] = state;
  }

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
