import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/tts/playback_resume_fence.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/usecase/playback/persistent_playback_resolver.dart';
import 'package:readaloud_app/usecase/playback/playback_usage_accounting.dart';
import 'package:readaloud_app/usecase/playback/save_playback_state_usecase.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';

// P6: Normal Player (Persistent) の再生位置を約30秒ごとに checkpoint 保存する。

Future<void> _pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

TtsPlaybackPosition _playing(int pos) => TtsPlaybackPosition(
    charPosition: pos, isPlaying: true, ttsStatus: TtsStatus.playing);

void main() {
  setUp(() => DebugLogger.testSink = []);
  tearDown(() => DebugLogger.testSink = null);

  Future<_Env> started({String session = 'S', String id = 'c1'}) async {
    final env = _Env();
    env.addContent(id, 1000);
    await env.gate.start(sessionId: session, contentId: id);
    env.emit(300); // window 開始
    await _pump();
    return env;
  }

  test('30秒ごとにcheckpointが保存され、DB位置は最後のcheckpoint位置', () async {
    final env = await started();
    final base = env.playbackRepo.saveCount;
    for (var i = 1; i <= 13; i++) {
      env.clock = env.clock.add(const Duration(seconds: 5));
      env.emit(300 + 25 * i);
      await _pump();
    }
    // t=30 (pos 450) と t=60 (pos 600) で保存。t=65 (pos 625) は未保存。
    expect(env.playbackRepo.saveCount - base, 2);
    final s = env.playbackRepo.store['c1']!;
    expect(s.position, 600);
    expect(s.progressPct, 60.0);
    expect(env.contentRepo.store['c1']!.status, isNot('completed'));
  });

  test('アプリ再起動相当: resolveForStartのstartPositionが最後のcheckpoint', () async {
    final env = await started();
    for (var i = 1; i <= 7; i++) {
      env.clock = env.clock.add(const Duration(seconds: 5));
      env.emit(300 + 25 * i);
      await _pump();
    }
    expect(env.playbackRepo.store['c1']!.position, 450);
    final fresh = PersistentPlaybackResolver(
        contentRepo: env.contentRepo, playbackRepo: env.playbackRepo);
    final req = await fresh.resolveForStart('c1');
    expect(req.startPosition, 450);
  });

  test('30秒未満・位置が進まない・pause中は保存しない', () async {
    final env = await started();
    final base = env.playbackRepo.saveCount;

    env.clock = env.clock.add(const Duration(seconds: 25));
    env.emit(400);
    await _pump();
    expect(env.playbackRepo.saveCount, base, reason: '30秒未満');

    env.clock = env.clock.add(const Duration(seconds: 10)); // t=35
    env.emit(300); // 位置が進んでいない
    await _pump();
    expect(env.playbackRepo.saveCount, base, reason: '位置が進んでいない');

    env.clock = env.clock.add(const Duration(seconds: 5)); // t=40
    env.emit(425);
    await _pump();
    expect(env.playbackRepo.saveCount, base + 1);

    await env.gate.pause(sessionId: 'S', contentId: 'c1', position: 430);
    final afterPause = env.playbackRepo.saveCount;
    env.clock = env.clock.add(const Duration(seconds: 60));
    env.positions.add(const TtsPlaybackPosition(
        charPosition: 430, isPlaying: false, ttsStatus: TtsStatus.paused));
    await _pump();
    expect(env.playbackRepo.saveCount, afterPause, reason: 'pause中は保存しない');
  });

  test('stale: checkpoint予約後に新session Bがstartするとc1もc2も書かない', () async {
    final env = await started();
    env.addContent('c2', 500);
    env.playbackRepo.store['c1'] =
        PlaybackState(contentId: 'c1', position: 300, progressPct: 30.0);

    env.clock = env.clock.add(const Duration(seconds: 30));
    env.emit(450); // checkpoint は microtask で予約されるだけ
    await env.gate.start(sessionId: 'B', contentId: 'c2');
    await _pump();

    expect(env.playbackRepo.store['c1']!.position, 300);
    expect(env.playbackRepo.store['c2'], isNull);
    expect(env.transport.activeOwner, PlaybackOwnerKey.normalPlayer('B'));
  });

  test('interleave: checkpoint予約後のstopForSession(X)が最終値になる', () async {
    final env = await started();
    env.clock = env.clock.add(const Duration(seconds: 30));
    env.emit(450);
    await env.gate
        .stopForSession(sessionId: 'S', contentId: 'c1', position: 333);
    await _pump();

    expect(env.playbackRepo.store['c1']!.position, 333);
  });

  test('interleave(seek相当): stop + 直接保存Yが最終値になる', () async {
    final env = await started();
    env.clock = env.clock.add(const Duration(seconds: 30));
    env.emit(450);
    await env.gate
        .stopForSession(sessionId: 'S', contentId: 'c1', position: 450);
    await env.savePlayback
        .execute(contentId: 'c1', position: 120, progressPct: 12.0);
    await _pump();

    expect(env.playbackRepo.store['c1']!.position, 120);
    expect(env.playbackRepo.store['c1']!.progressPct, 12.0);
  });

  test('自然終了(P5): checkpoint後も最終は100%/completedで後続eventに上書きされない', () async {
    final env = await started();
    env.clock = env.clock.add(const Duration(seconds: 30));
    env.emit(450);
    await _pump();
    expect(env.playbackRepo.store['c1']!.position, 450);

    env.positions.add(const TtsPlaybackPosition(
        charPosition: 1000,
        isPlaying: false,
        ttsStatus: TtsStatus.stopped,
        isNaturalCompletion: true));
    await _pump();
    final saves = env.playbackRepo.saveCount;
    expect(env.playbackRepo.store['c1']!.progressPct, 100.0);
    expect(env.contentRepo.store['c1']!.status, 'completed');

    env.clock = env.clock.add(const Duration(seconds: 60));
    env.emit(900);
    await _pump();
    expect(env.playbackRepo.saveCount, saves);
    expect(env.playbackRepo.store['c1']!.progressPct, 100.0);
    expect(env.contentRepo.store['c1']!.status, 'completed');
  });

  test('Transient ownerの60秒再生はDB書込みゼロ', () async {
    final env = _Env();
    env.addContent('c1', 1000);
    await env.transport.start(
      PlaybackOwnerKey.transient('Q'),
      PlaybackRequest(
          target: const TransientTarget(), text: 'x' * 1000, startPosition: 0),
      accounting: const NoUsageAccounting(),
    );
    env.emit(100);
    await _pump();
    for (var i = 1; i <= 13; i++) {
      env.clock = env.clock.add(const Duration(seconds: 5));
      env.emit(100 + 25 * i);
      await _pump();
    }
    expect(env.playbackRepo.saveCount, 0);
  });

  test('保存が例外でも未処理例外は出ず、in-flightは解除され次で再試行できる', () async {
    final env = await started();
    env.playbackRepo.failSave = true;
    env.clock = env.clock.add(const Duration(seconds: 30));
    env.emit(450);
    await _pump();
    expect(env.playbackRepo.saveCount, 0);

    env.playbackRepo.failSave = false;
    env.clock = env.clock.add(const Duration(seconds: 1));
    env.emit(460);
    await _pump();
    expect(env.playbackRepo.saveCount, 1);
    expect(env.playbackRepo.store['c1']!.position, 460);
  });

  test('gate dispose時にopが保留中でも例外なく、書込みもしない', () async {
    final env = await started();
    env.clock = env.clock.add(const Duration(seconds: 30));
    env.emit(450);
    env.gate.dispose();
    await _pump();
    expect(env.playbackRepo.saveCount, 0);
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
    savePlayback = SavePlaybackStateUseCase(
        playbackRepo: playbackRepo, contentRepo: contentRepo);
    gate = NormalPlayerPlaybackGate.shared(
      transport: transport,
      resolver: PersistentPlaybackResolver(
          contentRepo: contentRepo, playbackRepo: playbackRepo),
      playbackRepo: playbackRepo,
      savePlaybackState: savePlayback,
      accounting: PersistentUsageAccounting(CountTtsUsageUseCase(
        settingsRepo: settingsRepo,
        checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      )),
      checkpointInterval: const Duration(seconds: 30),
      clock: () => clock,
    );
  }

  /// handler の現在位置（snapshot.position の供給源）と event を揃えて流す。
  void emit(int pos) {
    handlerPosition = pos;
    positions.add(_playing(pos));
  }

  void addContent(String id, int len) => contentRepo.store[id] =
      Content(id: id, title: 't', body: 'x' * len, sourceType: 'text');

  DateTime clock = DateTime(2026, 1, 1);
  final contentRepo = _FakeContentRepository();
  final playbackRepo = _FakePlaybackRepository();
  final settingsRepo = _FakeSettingsRepository();
  final tts = _FakeTts();
  final positions = StreamController<dynamic>.broadcast(sync: true);
  int handlerPosition = 0;
  late final SharedPlaybackTransport transport;
  late final SavePlaybackStateUseCase savePlayback;
  late final NormalPlayerPlaybackGate gate;
}

class _FakeTts implements TtsService {
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
  Future<void> stop() async {}

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
