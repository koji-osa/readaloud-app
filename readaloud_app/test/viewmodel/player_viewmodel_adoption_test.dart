import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/bookmark.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/repository/bookmark_repository.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/usecase/bookmark/add_bookmark_usecase.dart';
import 'package:readaloud_app/usecase/bookmark/delete_bookmark_usecase.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/usecase/content/update_content_usecase.dart';
import 'package:readaloud_app/usecase/playback/persistent_playback_resolver.dart';
import 'package:readaloud_app/usecase/playback/playback_usage_accounting.dart';
import 'package:readaloud_app/usecase/playback/save_playback_state_usecase.dart';
import 'package:readaloud_app/usecase/playback/set_ab_repeat_usecase.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';
import 'package:readaloud_app/viewmodel/player_viewmodel.dart';

// Playback Session Lifecycle Hardening Slice 5 — Detailed Design v1.2 FINAL
// §15.2 T6-T13, T19. PlayerViewModel.setContent()のDA-2 adoption + live
// overlayを、production同様のSharedPlaybackTransport構成（NormalPlayerPlaybackGate
// .shared）で検証する。VMは複数のPlayer route open/closeにまたがって使い捨てに
// なる（autoDispose）ため、各「reopen」は新しいPlayerViewModelインスタンス +
// 新しいsessionIdとしてモデル化する。
void main() {
  setUp(() {
    DebugLogger.testSink = [];
  });
  tearDown(() {
    DebugLogger.testSink = null;
  });

  late _Env env;

  setUp(() {
    env = _Env();
  });

  tearDown(() async {
    env.dispose();
  });

  test('T6: A active -> Back(VM dispose) -> Aをreopen -> isPlaying:true、'
      'highlightPositionはDBではなくlive', () async {
    final vmA = env.newVm();
    const sA = 'S1';
    await vmA.setContent(origin: _origin(sA, 'A'), content: _content('A'));
    await vmA.play(origin: _origin(sA, 'A'));
    env.emit(8);
    vmA.dispose(); // Back相当。TransportのownerはNP:S1のまま生存する。

    final vmB = env.newVm();
    const sB = 'S2';
    await vmB.setContent(origin: _origin(sB, 'A'), content: _content('A'));

    expect(vmB.state.isPlaying, isTrue);
    expect(vmB.state.highlightPosition, 8,
        reason: 'live overlayがDBのstale値より優先される（INV-8）');
    expect(env.transport.activeOwner, PlaybackOwnerKey.normalPlayer(sB),
        reason: 'adoptionでownerがnp:S2へ移る');
  });

  test('T7: reopen後、以後のowner刻印済みeventがgate.liveUpdates経由でUIを更新する',
      () async {
    final vmA = env.newVm();
    await vmA.setContent(origin: _origin('S1', 'A'), content: _content('A'));
    await vmA.play(origin: _origin('S1', 'A'));
    env.emit(3);
    vmA.dispose();

    final vmB = env.newVm();
    await vmB.setContent(origin: _origin('S2', 'A'), content: _content('A'));
    expect(vmB.state.highlightPosition, 3);

    env.emit(9);
    expect(vmB.state.highlightPosition, 9,
        reason: 'adoption後もliveUpdatesが同じpipelineで継続する');
  });

  test('T8/INV-7: A active -> 別contentのBを開く -> adoptActivePersistentはnull、'
      'Bの状態はB自身のDBから、Aのowner/requestは無変化', () async {
    final vmA = env.newVm();
    await vmA.setContent(origin: _origin('S1', 'A'), content: _content('A'));
    await vmA.play(origin: _origin('S1', 'A'));
    env.emit(4);

    final vmB = env.newVm();
    await vmB.setContent(origin: _origin('S2', 'B'), content: _content('B'));

    expect(vmB.state.isPlaying, isFalse);
    expect(vmB.state.highlightPosition, 0);
    expect(env.transport.activeOwner, PlaybackOwnerKey.normalPlayer('S1'),
        reason: 'Aのownerは別targetのadoption試行によって変化しない');
    expect((env.transport.activeRequestForDebug!.target as PersistentTarget)
        .contentId, 'A');

    // liveUpdates(S2)はAの刻印済みeventを一切通さない。
    env.emit(7);
    expect(vmB.state.highlightPosition, 0,
        reason: 'liveUpdates(S_B)はA由来のeventを一切通さない');
  });

  test('T9/INV-11: A active -> Aをreopen -> TtsService.speak呼び出し回数は'
      '不変（二重発話なし）', () async {
    final vmA = env.newVm();
    await vmA.setContent(origin: _origin('S1', 'A'), content: _content('A'));
    await vmA.play(origin: _origin('S1', 'A'));
    final speakCountAfterA = env.tts.speakCount;
    vmA.dispose();

    final vmB = env.newVm();
    await vmB.setContent(origin: _origin('S2', 'A'), content: _content('A'));

    expect(env.tts.speakCount, speakCountAfterA,
        reason: 'adoptionはspeak()を一切呼ばない');
  });

  test(
      'T10/DA-3: A active -> Aをreopen -> external Share相当のretireActiveForExternalEntryは'
      'np:S2(adopted)をretireし、target Aへ保存する', () async {
    final vmA = env.newVm();
    await vmA.setContent(origin: _origin('S1', 'A'), content: _content('A'));
    await vmA.play(origin: _origin('S1', 'A'));
    vmA.dispose();

    final vmB = env.newVm();
    await vmB.setContent(origin: _origin('S2', 'A'), content: _content('A'));
    expect(env.transport.activeOwner, PlaybackOwnerKey.normalPlayer('S2'));

    final retirement = await env.transport.retireActiveForExternalEntry(
        reason: TeardownReason.shareTeardown);

    expect(retirement.hadActivePlayback, isTrue);
    expect(retirement.retiredOwner, PlaybackOwnerKey.normalPlayer('S2'),
        reason: 'retireされるのはadoption後の現owner（np:S2）');
    expect((retirement.retiredTarget as PersistentTarget).contentId, 'A');
    expect(env.transport.activeOwner, isNull);
  });

  test('T11/INV-9: live Aが無い状態でAをreopen -> adoptActivePersistentはnull、'
      'DB positionが使われる', () async {
    await env.playbackRepo.save(PlaybackState(contentId: 'A', position: 55));

    final vm = env.newVm();
    await vm.setContent(origin: _origin('S1', 'A'), content: _content('A'));

    expect(vm.state.isPlaying, isFalse);
    expect(vm.state.highlightPosition, 55,
        reason: 'live sessionが無ければDBのpositionをそのまま使う');
  });

  test('T12: 新UIがbindした後の旧route由来のstale teardownはignoredStaleOwnerで、'
      '現owner/UIは無変化', () async {
    final vmA = env.newVm();
    await vmA.setContent(origin: _origin('S1', 'A'), content: _content('A'));
    await vmA.play(origin: _origin('S1', 'A'));
    vmA.dispose();

    final vmB = env.newVm();
    await vmB.setContent(origin: _origin('S2', 'A'), content: _content('A'));
    env.emit(6);
    expect(vmB.state.highlightPosition, 6);

    final stale = await env.transport.forceStopForTeardown(
      expectedOwner: PlaybackOwnerKey.normalPlayer('S1'),
      reason: TeardownReason.routeRemoval,
      notificationDisposition: NotificationDisposition.handoff,
    );

    expect(stale.application, TeardownApplication.ignoredStaleOwner);
    expect(env.transport.activeOwner, PlaybackOwnerKey.normalPlayer('S2'));
    expect(vmB.state.highlightPosition, 6, reason: '現在のUIは無変化');
  });

  test(
      'T13/RT-3/RT-6: 一時停止中のlive sessionをadopt -> (i)isPlaying=false '
      '(ii)hasLiveStatus=true & paused (iii)persistStopPositionがちょうど1回、'
      'live位置で発生 (iv)UIはlive位置でpaused表示 (v)続くPlayはlive位置から再開する',
      () async {
    await env.playbackRepo.save(PlaybackState(contentId: 'A', position: 999));

    final vmA = env.newVm();
    await vmA.setContent(origin: _origin('S1', 'A'), content: _content('A'));
    await vmA.play(origin: _origin('S1', 'A'));
    env.emit(20);
    await vmA.pause(origin: _origin('S1', 'A'));
    // 実機のTtsAudioHandler.pause()はcustomStateへisPlaying:falseの
    // TtsPlaybackPositionを発行する（device_tts_service.dart）。fake TTSは
    // それを行わないため、ここでTransportの_lastAcceptedPositionを更新する
    // 目的でpause相当のpositionイベントを注入する。
    env.emitPaused(20);
    // pause()自身がpersistStopPosition相当の保存を行うため、adoption起点の
    // 1回だけを数えられるようここでカウンタをリセットする。
    final saveCountBeforeReopen = env.playbackRepo.saveCount;
    vmA.dispose();

    final vmB = env.newVm();
    await vmB.setContent(origin: _origin('S2', 'A'), content: _content('A'));

    expect(vmB.state.isPlaying, isFalse, reason: '(i)');
    expect(vmB.state.ttsStatus, TtsStatus.paused, reason: '(ii)');
    expect(vmB.state.highlightPosition, 20, reason: '(iv) live位置(20)で表示');
    expect(env.playbackRepo.saveCount - saveCountBeforeReopen, 1,
        reason: '(iii) INV-15の one-shot write がちょうど1回だけ発生する');
    expect((await env.playbackRepo.getByContentId('A'))!.position, 20,
        reason: '(iii) 保存されたpositionはlive位置(20)');

    await vmB.play(origin: _origin('S2', 'A'));
    expect(env.tts.lastStartPosition, 20,
        reason: '(v) 続くPlayはDBの古い999ではなくlive位置(20)から再開する');
  });

  test('T19/RT-7/INV-18: liveがない通常のPlayも同じowner-stamped pipelineを使う。'
      'play()前はliveUpdatesが何も出さず、gate.start後はaccepted eventがUIへ届く',
      () async {
    final vm = env.newVm();
    await vm.setContent(origin: _origin('S1', 'A'), content: _content('A'));

    // play()前: liveがそもそも無いのでstate mutationは起きない。
    env.emit(3);
    expect(vm.state.highlightPosition, 0);

    await vm.play(origin: _origin('S1', 'A'));
    env.emit(5);
    expect(vm.state.highlightPosition, 5,
        reason: '通常のfresh PlayもliveUpdates経由の同じpipelineでUIへ届く');
  });
}

PlayerOriginToken _origin(String sessionId, String contentId) =>
    PlayerOriginToken(sessionId: sessionId, contentId: contentId);

Content _content(String id) =>
    Content(id: id, title: 'title-$id', body: 'body of $id long enough for progress calc', sourceType: 'text');

class _Env {
  _Env() {
    transport = SharedPlaybackTransport(
      tts: tts,
      positionStream: positions.stream,
      currentPosition: () => handlerPosition,
      resumeFence: _NoopFence(),
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

  final _FakeContentRepository contentRepo = _FakeContentRepository();
  final _FakePlaybackRepository playbackRepo = _FakePlaybackRepository();
  final _FakeBookmarkRepository bookmarkRepo = _FakeBookmarkRepository();
  final _FakeSettingsRepository settingsRepo = _FakeSettingsRepository();
  final _FakeTtsService tts = _FakeTtsService();
  final StreamController<dynamic> positions =
      StreamController<dynamic>.broadcast(sync: true);
  int handlerPosition = 0;

  late final SharedPlaybackTransport transport;
  late final NormalPlayerPlaybackGate gate;

  void emit(int position) {
    handlerPosition = position;
    positions.add(TtsPlaybackPosition(
      charPosition: position,
      isPlaying: true,
      ttsStatus: TtsStatus.playing,
    ));
  }

  void emitPaused(int position) {
    handlerPosition = position;
    positions.add(TtsPlaybackPosition(
      charPosition: position,
      isPlaying: false,
      ttsStatus: TtsStatus.paused,
    ));
  }

  PlayerViewModel newVm() {
    final settingsRepoLocal = settingsRepo;
    final vm = PlayerViewModel(
      playbackGate: gate,
      isEffectCurrent: (_) => true,
      savePlaybackState: SavePlaybackStateUseCase(
          playbackRepo: playbackRepo, contentRepo: contentRepo),
      setAbRepeat: SetAbRepeatUseCase(playbackRepo),
      addBookmark: AddBookmarkUseCase(bookmarkRepo),
      deleteBookmark: DeleteBookmarkUseCase(bookmarkRepo),
      updateContent: UpdateContentUseCase(contentRepo),
      saveContent: SaveContentUseCase(contentRepo),
      checkTtsLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepoLocal),
      getCurrentPosition: () => handlerPosition,
      playbackRepo: playbackRepo,
      settingsRepo: settingsRepoLocal,
      bookmarkRepo: bookmarkRepo,
    );
    _vms.add(vm);
    return vm;
  }

  final List<PlayerViewModel> _vms = [];

  void dispose() {
    for (final vm in _vms) {
      if (vm.mounted) vm.dispose();
    }
    transport.dispose();
    positions.close();
  }
}

class _NoopFence implements PlaybackResumeFence {
  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async {}
}

class _FakeTtsService implements TtsService {
  int speakCount = 0;
  int? lastStartPosition;

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
    lastStartPosition = startPosition;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async => [];

  @override
  Future<void> dispose() async {}
}

class _FakeContentRepository implements ContentRepository {
  final Map<String, Content> _store = {};

  @override
  Future<Content?> getById(String id) async => _store[id] ??= _content(id);

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
  int saveCount = 0;

  @override
  Future<PlaybackState?> getByContentId(String contentId) async =>
      _store[contentId];

  @override
  Future<void> save(PlaybackState state) async {
    saveCount++;
    _store[state.contentId] = state;
  }

  @override
  Future<void> resetAbRepeat(String contentId) async {}

  @override
  Future<void> resetAllAbRepeat() async {}

  @override
  Future<void> delete(String contentId) async => _store.remove(contentId);
}

class _FakeBookmarkRepository implements BookmarkRepository {
  @override
  Future<List<Bookmark>> getByContentId(String contentId) async => [];

  @override
  Future<void> save(Bookmark bookmark) async {}

  @override
  Future<void> delete(String id) async {}
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
