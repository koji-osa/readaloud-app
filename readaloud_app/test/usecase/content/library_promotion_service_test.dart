import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/bookmark.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/quick_listen_session.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/repository/bookmark_repository.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/usecase/bookmark/add_bookmark_usecase.dart';
import 'package:readaloud_app/usecase/bookmark/delete_bookmark_usecase.dart';
import 'package:readaloud_app/usecase/content/library_promotion_service.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/usecase/content/update_content_usecase.dart';
import 'package:readaloud_app/usecase/playback/persistent_playback_resolver.dart';
import 'package:readaloud_app/usecase/playback/playback_defaults_reader.dart';
import 'package:readaloud_app/usecase/playback/playback_usage_accounting.dart';
import 'package:readaloud_app/usecase/playback/save_playback_state_usecase.dart';
import 'package:readaloud_app/usecase/playback/set_ab_repeat_usecase.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';
import 'package:readaloud_app/viewmodel/player_viewmodel.dart';
import 'package:readaloud_app/viewmodel/quick_listen_viewmodel.dart';

// Shared Player Core Slice 7a / 7b: LibraryPromotionService
// T-M1（snapshot / provenance / single-flight / session置換中の非反映）
// T-M2（position + speed handoff）
void main() {
  late _FakeContentRepository contentRepo;
  late _FakePlaybackRepository playbackRepo;
  late _FakeDefaults defaults;
  late LibraryPromotionService service;

  setUp(() {
    DebugLogger.testSink = [];
    contentRepo = _FakeContentRepository();
    playbackRepo = _FakePlaybackRepository();
    defaults = _FakeDefaults(1.0);
    service = LibraryPromotionService(
      saveContent: SaveContentUseCase(contentRepo),
      playbackRepo: playbackRepo,
      defaultsReader: defaults,
    );
  });

  tearDown(() => DebugLogger.testSink = null);

  PlaybackRequest request(String text,
          {String? title, SourceDescriptor? source}) =>
      PlaybackRequest(
        target: const TransientTarget(),
        text: text,
        title: title,
        startPosition: 0,
        source: source ?? const SourceDescriptor(sourceType: 'share'),
      );

  group('T-M1: snapshot / provenance', () {
    test('body snapshotとSourceDescriptorのprovenanceを新規Content行へ保存する', () async {
      final result = await service.promote(PromotionInput(
        request: request('本文スナップショット',
            title: 'Sourceタイトル',
            source: const SourceDescriptor(
              sourceType: 'obsidian',
              sourceFilename: 'note.md',
              externalType: 'obsidian',
              vaultName: 'Vault',
              relativePath: 'dir/note.md',
            )),
        position: 0,
        speed: 1.0,
      ));

      final saved = contentRepo.saved.single;
      expect(result.content.id, saved.id);
      expect(saved.body, '本文スナップショット');
      expect(saved.title, 'Sourceタイトル');
      expect(saved.sourceType, 'obsidian');
      expect(saved.sourceFilename, 'note.md');
      expect(saved.externalType, 'obsidian');
      expect(saved.vaultName, 'Vault');
      expect(saved.relativePath, 'dir/note.md');
    });

    test('PD-3: Sourceタイトルが無ければSaveContentUseCaseの既存自動タイトル', () async {
      await service.promote(PromotionInput(
          request: request('共有された本文です'), position: 0, speed: 1.0));
      expect(contentRepo.saved.single.title, '共有された本文です');
      expect(contentRepo.saved.single.sourceType, 'share');
    });

    test('TransientTarget以外（既存Content）はpromotion入力として受け付けない', () async {
      final existing =
          Content(id: 'c-existing', title: 't', body: 'b', sourceType: 'text');
      await expectLater(
        service.promote(PromotionInput(
          request: PlaybackRequest(
              target: PersistentTarget.of(existing),
              text: 'b',
              startPosition: 0),
          position: 0,
          speed: 1.0,
        )),
        throwsArgumentError,
      );
      expect(contentRepo.saved, isEmpty);
    });
  });

  group('T-M2: position / speed handoff（7b）', () {
    test('position>0なら新行へposition・progress・speedを書く', () async {
      defaults.speed = 1.5;
      final result = await service.promote(PromotionInput(
          request: request('0123456789'), position: 4, speed: 1.5));

      expect(result.handoffApplied, isTrue);
      final state = playbackRepo.store[result.content.id]!;
      expect(state.position, 4);
      expect(state.progressPct, 40.0);
      expect(state.speed, 1.5);
    });

    test('position==0かつspeed==defaultSpeedなら行を作らない（既存の初回default速度初期化に任せる）',
        () async {
      defaults.speed = 1.75;
      final result = await service.promote(PromotionInput(
          request: request('0123456789'), position: 0, speed: 1.75));
      expect(result.handoffApplied, isFalse);
      expect(playbackRepo.store, isEmpty);
    });

    test('handoff失敗でもContent保存は巻き戻さない', () async {
      playbackRepo.failSave = true;
      final result = await service.promote(PromotionInput(
          request: request('0123456789'), position: 5, speed: 1.0));
      expect(result.handoffApplied, isFalse);
      expect(result.handoffErrorType, isNotNull);
      expect(contentRepo.saved, hasLength(1));
    });

    test('positionは本文長へclampされる', () async {
      final result = await service.promote(
          PromotionInput(request: request('abc'), position: 99, speed: 1.0));
      expect(playbackRepo.store[result.content.id]!.position, 3);
    });

    test('handoff後、Normal PlayerのsetContentが保存時位置・速度を反映する', () async {
      defaults.speed = 1.0;
      final result = await service.promote(PromotionInput(
          request: request('0123456789ABCDEFGHIJ'), position: 12, speed: 2.0));
      final content = result.content;

      final vm = _playerViewModel(contentRepo, playbackRepo);
      addTearDown(vm.dispose);
      final origin =
          PlayerOriginToken(sessionId: 'np-1', contentId: content.id);
      await vm.setContent(origin: origin, content: content);

      expect(vm.state.highlightPosition, 12);
      expect(vm.state.playbackState!.speed, 2.0);
      expect(vm.state.playbackState!.position, 12);
    });
  });

  group('QuickListenViewModel.save() via promotion', () {
    late StreamController<dynamic> positions;
    late SharedPlaybackTransport transport;
    late QuickListenViewModel vm;
    late int handlerPosition;

    setUp(() {
      positions = StreamController<dynamic>.broadcast(sync: true);
      handlerPosition = 0;
      transport = SharedPlaybackTransport(
        tts: _NoopTts(),
        positionStream: positions.stream,
        currentPosition: () => handlerPosition,
        resumeFence: _NoopFence(),
      );
      vm = QuickListenViewModel(
        transport: transport,
        defaultsReader: defaults,
        promotion: service,
      );
    });

    tearDown(() async {
      if (vm.mounted) vm.dispose();
      transport.dispose();
      await positions.close();
    });

    test(
        '再生中の保存は保存時点のTransport位置を渡し、promotedContentIdを付与、'
        'sessionはTransientのまま（以後の位置はLibraryへ書かない）', () async {
      defaults.speed = 1.25;
      vm.start(QuickListenSession.fromSharedText('0123456789ABCDEFGHIJ'));
      await vm.play();
      positions.add(const TtsPlaybackPosition(
          charPosition: 7, isPlaying: true, ttsStatus: TtsStatus.playing));
      handlerPosition = 7;

      final content = await vm.save();

      expect(vm.state.session!.promotedContentId, content!.id);
      expect(vm.state.session!.saved, isTrue);
      expect(playbackRepo.store[content.id]!.position, 7);
      expect(playbackRepo.store[content.id]!.speed, 1.25);
      expect(transport.activeOwner,
          PlaybackOwnerKey.transient(vm.state.session!.id),
          reason: '保存後もTransientのまま（Persistentへreattachしない）');

      positions.add(const TtsPlaybackPosition(
          charPosition: 15, isPlaying: true, ttsStatus: TtsStatus.playing));
      handlerPosition = 15;
      await vm.pause();
      await vm.close();
      expect(playbackRepo.store[content.id]!.position, 7,
          reason: '保存後に聴き進めた位置はLibraryへ反映しない');
      expect(playbackRepo.saveCount, 1);
    });

    test('single-flight: 同時保存でもContentは1件', () async {
      vm.start(QuickListenSession.fromSharedText('本文'));
      final results = await Future.wait([vm.save(), vm.save()]);
      expect(contentRepo.saved, hasLength(1));
      expect(results[1], same(results[0]));
    });

    test('保存中にsessionが置き換わっても結果を新sessionへ反映しない', () async {
      vm.start(QuickListenSession.fromSharedText('A'));
      final pending = vm.save();
      vm.start(QuickListenSession.fromSharedText('B'));
      final content = await pending;
      expect(content, isNotNull);
      expect(vm.state.hasSaved, isFalse);
      expect(vm.state.session!.promotedContentId, isNull);
    });
  });
}

PlayerViewModel _playerViewModel(
    ContentRepository contentRepo, PlaybackRepository playbackRepo) {
  final settingsRepo = _FakeSettingsRepository();
  final bookmarkRepo = _FakeBookmarkRepository();
  final save = SavePlaybackStateUseCase(
      playbackRepo: playbackRepo, contentRepo: contentRepo);
  return PlayerViewModel(
    // setContent は playback gate を使わない。
    playbackGate: NormalPlayerPlaybackGate.shared(
      transport: SharedPlaybackTransport(
        tts: _NoopTts(),
        positionStream: const Stream.empty(),
        currentPosition: () => 0,
        resumeFence: _NoopFence(),
      ),
      resolver: PersistentPlaybackResolver(
          contentRepo: contentRepo, playbackRepo: playbackRepo),
      playbackRepo: playbackRepo,
      savePlaybackState: save,
      accounting: const NoUsageAccounting(),
    ),
    isEffectCurrent: (_) => true,
    savePlaybackState: save,
    setAbRepeat: SetAbRepeatUseCase(playbackRepo),
    addBookmark: AddBookmarkUseCase(bookmarkRepo),
    deleteBookmark: DeleteBookmarkUseCase(bookmarkRepo),
    updateContent: UpdateContentUseCase(contentRepo),
    saveContent: SaveContentUseCase(contentRepo),
    checkTtsLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
    getCurrentPosition: () => 0,
    playbackRepo: playbackRepo,
    settingsRepo: settingsRepo,
    bookmarkRepo: bookmarkRepo,
  );
}

class _FakeDefaults implements PlaybackDefaultsReader {
  _FakeDefaults(this.speed);
  double speed;

  @override
  Future<double> readDefaultSpeed() async => speed;
}

class _NoopTts implements TtsService {
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

class _NoopFence implements PlaybackResumeFence {
  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async {}
}

class _FakeContentRepository implements ContentRepository {
  final List<Content> saved = [];

  @override
  Future<void> save(Content content) async => saved.add(content);

  @override
  Future<List<Content>> getAll() async => saved;

  @override
  Future<List<Content>> getByStatus(String status) async => [];

  @override
  Future<Content?> getById(String id) async =>
      saved.where((c) => c.id == id).firstOrNull;

  @override
  Future<void> update(Content content) async {}

  @override
  Future<void> delete(String id) async {}
}

class _FakePlaybackRepository implements PlaybackRepository {
  final Map<String, PlaybackState> store = {};
  bool failSave = false;
  int saveCount = 0;

  @override
  Future<PlaybackState?> getByContentId(String contentId) async =>
      store[contentId];

  @override
  Future<void> save(PlaybackState state) async {
    if (failSave) throw StateError('save failed (test)');
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
