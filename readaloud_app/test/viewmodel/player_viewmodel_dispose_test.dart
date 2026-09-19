import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/bookmark.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/setting.dart';
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
import 'package:readaloud_app/usecase/playback/start_playback_usecase.dart';
import 'package:readaloud_app/usecase/playback/stop_playback_usecase.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';
import 'package:readaloud_app/viewmodel/player_viewmodel.dart';

// T-R7（Slice 0 / R-7）: autoDispose される PlayerViewModel の dispose が、
// app-shared な playback gate の position 購読を cancel しないこと。
void main() {
  test('T-R7: VM dispose後もshared gateのposition購読が生存し、usage計上が継続する', () async {
    final contentRepo = _FakeContentRepository();
    final playbackRepo = _FakePlaybackRepository();
    final settingsRepo = _FakeSettingsRepository();
    final tts = _FakeTtsService();
    final positions = StreamController<dynamic>.broadcast();
    addTearDown(positions.close);

    final countUsage = CountTtsUsageUseCase(
      settingsRepo: settingsRepo,
      checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
    );
    final savePlaybackState = SavePlaybackStateUseCase(
        playbackRepo: playbackRepo, contentRepo: contentRepo);
    final gate = NormalPlayerPlaybackGate(
      startPlayback: StartPlaybackUseCase(
        contentRepo: contentRepo,
        playbackRepo: playbackRepo,
        positionStream: positions.stream,
        ttsService: tts,
        countUsage: countUsage,
      ),
      stopPlayback: StopPlaybackUseCase(
        playbackRepo: playbackRepo,
        ttsService: tts,
        countUsage: countUsage,
        saveState: savePlaybackState,
      ),
      getCurrentPosition: () => 0,
    );

    final session = NormalPlayerSession(contentId: 'c1');
    await gate.start(sessionId: session.id, contentId: 'c1');

    final vm = PlayerViewModel(
      playbackGate: gate,
      isEffectCurrent: (_) => true,
      savePlaybackState: savePlaybackState,
      setAbRepeat: SetAbRepeatUseCase(playbackRepo),
      addBookmark: AddBookmarkUseCase(_FakeBookmarkRepository()),
      deleteBookmark: DeleteBookmarkUseCase(_FakeBookmarkRepository()),
      updateContent: UpdateContentUseCase(contentRepo),
      saveContent: SaveContentUseCase(contentRepo),
      checkTtsLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      positionStream: positions.stream,
      getCurrentPosition: () => 0,
      playbackRepo: playbackRepo,
      settingsRepo: settingsRepo,
      bookmarkRepo: _FakeBookmarkRepository(),
    );

    // autoDispose相当: 画面離脱でVMだけが破棄される（TTSは継続）。
    vm.dispose();

    expect(positions.hasListener, isTrue,
        reason: 'R-7: VM disposeはshared gateの購読をcancelしない');

    positions.add(const TtsPlaybackPosition(
        charPosition: 25, isPlaying: true, ttsStatus: TtsStatus.playing));
    await Future<void>.delayed(Duration.zero);

    await gate.stopForSession(
        sessionId: session.id, contentId: 'c1', position: 25);
    expect(await settingsRepo.get(SettingKeys.ttsUsedChars), '25',
        reason: 'VM dispose後に届いた再生位置もshared購読経由でusageへ届く');
  });

  test('T-R7（shared構成）: VM dispose後もSharedPlaybackTransportの購読が生存する', () async {
    final contentRepo = _FakeContentRepository();
    final playbackRepo = _FakePlaybackRepository();
    final settingsRepo = _FakeSettingsRepository();
    final tts = _FakeTtsService();
    final positions = StreamController<dynamic>.broadcast();
    addTearDown(positions.close);
    final countUsage = CountTtsUsageUseCase(
      settingsRepo: settingsRepo,
      checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
    );
    final savePlaybackState = SavePlaybackStateUseCase(
        playbackRepo: playbackRepo, contentRepo: contentRepo);
    final transport = SharedPlaybackTransport(
      tts: tts,
      positionStream: positions.stream,
      currentPosition: () => 0,
      resumeFence: _NoopFence(),
    );
    addTearDown(transport.dispose);
    final gate = NormalPlayerPlaybackGate.shared(
      transport: transport,
      resolver: PersistentPlaybackResolver(
          contentRepo: contentRepo, playbackRepo: playbackRepo),
      playbackRepo: playbackRepo,
      savePlaybackState: savePlaybackState,
      accounting: PersistentUsageAccounting(countUsage),
    );

    final session = NormalPlayerSession(contentId: 'c1');
    await gate.start(sessionId: session.id, contentId: 'c1');

    final vm = PlayerViewModel(
      playbackGate: gate,
      isEffectCurrent: (_) => true,
      savePlaybackState: savePlaybackState,
      setAbRepeat: SetAbRepeatUseCase(playbackRepo),
      addBookmark: AddBookmarkUseCase(_FakeBookmarkRepository()),
      deleteBookmark: DeleteBookmarkUseCase(_FakeBookmarkRepository()),
      updateContent: UpdateContentUseCase(contentRepo),
      saveContent: SaveContentUseCase(contentRepo),
      checkTtsLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      positionStream: positions.stream,
      getCurrentPosition: () => 0,
      playbackRepo: playbackRepo,
      settingsRepo: settingsRepo,
      bookmarkRepo: _FakeBookmarkRepository(),
    );
    vm.dispose();

    final accepted = <int>[];
    transport.acceptedPositions.listen((e) => accepted.add(e.charPosition));
    positions.add(const TtsPlaybackPosition(
        charPosition: 12, isPlaying: true, ttsStatus: TtsStatus.playing));
    await Future<void>.delayed(Duration.zero);

    expect(accepted, [12], reason: 'R-7: VM disposeでTransport購読が切れない');
    await gate.stopForSession(
        sessionId: session.id, contentId: 'c1', position: 12);
    expect(await settingsRepo.get(SettingKeys.ttsUsedChars), '12');
  });
}

class _NoopFence implements PlaybackResumeFence {
  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async {}
}

class _FakeTtsService implements TtsService {
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

class _FakeContentRepository implements ContentRepository {
  final Map<String, Content> _store = {};

  @override
  Future<Content?> getById(String id) async => _store[id] ??= Content(
      id: id, title: 't', body: 'body text long enough', sourceType: 'text');

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
