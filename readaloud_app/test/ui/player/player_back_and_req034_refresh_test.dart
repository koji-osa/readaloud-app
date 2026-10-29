import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/bookmark.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/providers.dart';
import 'package:readaloud_app/repository/bookmark_repository.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/obsidian_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/tts/device_tts_service.dart'
    show TtsAudioHandler;
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/repository/vault_data_source.dart';
import 'package:readaloud_app/ui/add/add_screen.dart'
    show addContentViewModelProvider, obsidianImportViewModelProvider;
import 'package:readaloud_app/ui/home/home_screen.dart';
import 'package:readaloud_app/ui/home/widgets/content_card.dart';
import 'package:readaloud_app/ui/home/widgets/tts_usage_banner.dart'
    show settingsViewModelProvider;
import 'package:readaloud_app/ui/player/player_screen.dart';
import 'package:readaloud_app/usecase/bookmark/add_bookmark_usecase.dart';
import 'package:readaloud_app/usecase/bookmark/delete_bookmark_usecase.dart';
import 'package:readaloud_app/usecase/content/delete_content_usecase.dart';
import 'package:readaloud_app/usecase/content/extract_pdf_content_usecase.dart';
import 'package:readaloud_app/usecase/content/fetch_url_content_usecase.dart';
import 'package:readaloud_app/usecase/content/get_all_contents_usecase.dart';
import 'package:readaloud_app/usecase/content/import_content_usecase.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/usecase/content/update_content_usecase.dart';
import 'package:readaloud_app/usecase/obsidian/obsidian_importer.dart';
import 'package:readaloud_app/usecase/playback/persistent_playback_resolver.dart';
import 'package:readaloud_app/usecase/playback/playback_usage_accounting.dart';
import 'package:readaloud_app/usecase/playback/save_playback_state_usecase.dart';
import 'package:readaloud_app/usecase/playback/set_ab_repeat_usecase.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';
import 'package:readaloud_app/viewmodel/add_content_viewmodel.dart';
import 'package:readaloud_app/viewmodel/content_list_viewmodel.dart';
import 'package:readaloud_app/viewmodel/obsidian_import_viewmodel.dart';
import 'package:readaloud_app/viewmodel/player_viewmodel.dart';
import 'package:readaloud_app/viewmodel/settings_viewmodel.dart';


// RA-CC-AUTO-WT-02 / A: P10 (AppBar back must await vm.stop before pop) と
// R-01 (REQ-034 pushReplacement 後の一覧reload) のテスト。
//
// R-01: REQ-034 経路は TableAnalysisService（ネットワーク/FlutterSecureStorage）を
// PlayerScreen内で直接生成するため、ウィジェットテストから決定論的に駆動できない。
// R-01 は P4(add_screen)と同契約のコード修正のみ（Red未実証）。
void main() {
  setUp(() {
    DebugLogger.testSink = [];
  });

  tearDown(() {
    DebugLogger.testSink = null;
  });

  final body = List.filled(100, 'これはテスト文です。').join();
  final existing = Content(
      id: 'existing-1',
      title: 'existing',
      body: body,
      sourceType: 'text',
      status: 'in_progress');

  Future<_TestEnv> openPlayerPlaying(WidgetTester tester) async {
    final env = await _pumpHome(
      tester,
      seedContents: [existing],
      seedPlayback: [
        PlaybackState(contentId: 'existing-1', position: 100, progressPct: 10),
      ],
    );
    await tester.tap(find.byType(ContentCard));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    env.emitPosition(const TtsPlaybackPosition(
      charPosition: 500,
      isPlaying: true,
      ttsStatus: TtsStatus.playing,
    ));
    await tester.pump();
    return env;
  }

  testWidgets(
      'P10: AppBar back は stop の保存完了まで pop せず、'
      '完了後のHome reloadが保存後のDB値(500)を読む', (tester) async {
    final env = await openPlayerPlaying(tester);

    // stopの保存をバリアでブロックする。
    final barrier = Completer<void>();
    env.playbackRepo.saveBarrier = barrier;

    await tester.tap(find.byIcon(Icons.arrow_back));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(PlayerScreen, skipOffstage: false), findsOneWidget,
        reason: '保存完了前はPlayerルートがまだ残っている（stopをawaitしてからpop）');

    barrier.complete();
    env.playbackRepo.saveBarrier = null;
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);

    final dbState = await env.playbackRepo.getByContentId('existing-1');
    final expectedPct = 500 / body.length * 100;
    expect(dbState!.progressPct, closeTo(expectedPct, 0.001),
        reason: 'DBはstop位置500に更新されている');
    final listState = env.container.read(contentListViewModelProvider);
    expect(listState.progressMap['existing-1'], closeTo(expectedPct, 0.001),
        reason: 'progressMapが保存後のDB値（stale 10%ではない）');
    final card = tester.widget<ContentCard>(find.byType(ContentCard));
    expect(card.progressPct, closeTo(expectedPct, 0.001),
        reason: 'ContentCardのprogressPctが保存後のDB値');
  });

  testWidgets('P10-GUARD: back の二重タップは stop 1回・pop 1回で例外なくHomeへ戻る',
      (tester) async {
    final env = await openPlayerPlaying(tester);

    final barrier = Completer<void>();
    env.playbackRepo.saveBarrier = barrier;
    final savesBefore = env.playbackRepo.saveCalls;

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byIcon(Icons.arrow_back), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 50));

    barrier.complete();
    env.playbackRepo.saveBarrier = null;
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget,
        reason: '二重popでHome自体が消えない');
    expect(env.playbackRepo.saveCalls - savesBefore, 1,
        reason: 'stop保存は1回だけ（2回目のタップは無視）');
  });

  testWidgets(
      'W2-R-01: AppBar back待機中にSystem Backでrouteが先に閉じても、'
      '完了後にHomeがpopされない', (tester) async {
    final env = await openPlayerPlaying(tester);
    final barrier = Completer<void>();
    env.playbackRepo.saveBarrier = barrier;

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.binding.handlePopRoute(); // System Back
    await tester.pump(const Duration(milliseconds: 100));

    barrier.complete();
    env.playbackRepo.saveBarrier = null;
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget,
        reason: 'Playerのみが閉じ、Homeは残る');
  });

  testWidgets('W2-R-05: 離脱待機中は入力を吸収する（再生操作・2回目のbackが無効）',
      (tester) async {
    final env = await openPlayerPlaying(tester);
    final barrier = Completer<void>();
    env.playbackRepo.saveBarrier = barrier;
    final savesBefore = env.playbackRepo.saveCalls;

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump(const Duration(milliseconds: 50));

    final absorbing = find.descendant(
        of: find.byType(PlayerScreen),
        matching:
            find.byWidgetPredicate((w) => w is AbsorbPointer && w.absorbing));
    expect(absorbing, findsWidgets, reason: '待機中はAbsorbPointerがabsorbing');

    final speaksBefore = env.tts.speakCalls;
    final pausesBefore = env.tts.pauseCalls;
    final playControl = find.byIcon(Icons.play_arrow).evaluate().isNotEmpty
        ? find.byIcon(Icons.play_arrow)
        : find.byIcon(Icons.pause);
    expect(playControl, findsOneWidget);
    await tester.tap(playControl, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byIcon(Icons.arrow_back), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 50));

    expect(env.tts.speakCalls, speaksBefore, reason: '再生タップは吸収され新規startなし');
    expect(env.tts.pauseCalls, pausesBefore, reason: '再生/一時停止タップは吸収');
    expect(env.playbackRepo.saveCalls - savesBefore, 1,
        reason: '2回目のbackタップも吸収され、stop保存は1回のまま');

    barrier.complete();
    env.playbackRepo.saveBarrier = null;
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(env.tts.speakCalls, speaksBefore, reason: '離脱後に再生が始まらない');
    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}

class _TestEnv {
  _TestEnv({
    required this.container,
    required this.tracker,
    required this.contentRepo,
    required this.playbackRepo,
    required this.positionController,
    required this.handlerPosition,
    required this.tts,
  });

  final _FakeTtsService tts;

  final ProviderContainer container;
  final NormalPlayerSessionTracker tracker;
  final _FakeContentRepository contentRepo;
  final _FakePlaybackRepository playbackRepo;
  final StreamController<dynamic> positionController;
  final _PositionBox handlerPosition;

  /// positionControllerへのイベント追加とhandlerPositionの更新を一度に行う。
  void emitPosition(TtsPlaybackPosition position) {
    handlerPosition.value = position.charPosition;
    positionController.add(position);
  }
}

class _PositionBox {
  int value = 0;
}

Future<_TestEnv> _pumpHome(
  WidgetTester tester, {
  List<Content> seedContents = const [],
  List<PlaybackState> seedPlayback = const [],
}) async {
  // PlayerScreenは縦長画面前提のためビューポートだけ広げる（本番コードは不変）。
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final contentRepo = _FakeContentRepository();
  for (final c in seedContents) {
    await contentRepo.save(c);
  }
  final playbackRepo = _FakePlaybackRepository();
  for (final p in seedPlayback) {
    await playbackRepo.save(p);
  }
  final bookmarkRepo = _FakeBookmarkRepository();
  final settingsRepo = _FakeSettingsRepository();
  final ttsService = _FakeTtsService();
  final positionController = StreamController<dynamic>.broadcast();
  addTearDown(positionController.close);

  final handlerPosition = _PositionBox();
  final countUsage = CountTtsUsageUseCase(
    settingsRepo: settingsRepo,
    checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
  );
  final savePlaybackState = SavePlaybackStateUseCase(
      playbackRepo: playbackRepo, contentRepo: contentRepo);
  final transport = SharedPlaybackTransport(
    tts: ttsService,
    positionStream: positionController.stream,
    currentPosition: () => handlerPosition.value,
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
  final tracker = NormalPlayerSessionTracker(playbackGate: gate);
  final obsidianRepo = _FakeObsidianRepository();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        audioHandlerProvider.overrideWithValue(_FakeAudioHandler()),
        normalPlayerSessionTrackerProvider.overrideWithValue(tracker),
        settingsViewModelProvider.overrideWith(
          (ref) => SettingsViewModel(
            settingsRepo: settingsRepo,
            checkTtsLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
          ),
        ),
        contentListViewModelProvider.overrideWith(
          (ref) => ContentListViewModel(
            getAllContents: GetAllContentsUseCase(contentRepo),
            deleteContent: DeleteContentUseCase(contentRepo),
            updateContent: UpdateContentUseCase(contentRepo),
            playbackRepo: playbackRepo,
          ),
        ),
        addContentViewModelProvider.overrideWith(
          (ref) => AddContentViewModel(
            saveContent: SaveContentUseCase(contentRepo),
            fetchUrl: FetchUrlContentUseCase(),
            extractPdf: ExtractPdfContentUseCase(),
          ),
        ),
        obsidianImportViewModelProvider.overrideWith(
          (ref) => ObsidianImportViewModel(
            repository: obsidianRepo,
            importer: ObsidianImporter(obsidianRepo),
            importContent:
                ImportContentUseCase(SaveContentUseCase(contentRepo)),
          ),
        ),
        playerViewModelProvider.overrideWith((ref) => PlayerViewModel(
              playbackGate: gate,
              isEffectCurrent: tracker.isEffectCurrent,
              savePlaybackState: savePlaybackState,
              setAbRepeat: SetAbRepeatUseCase(playbackRepo),
              addBookmark: AddBookmarkUseCase(bookmarkRepo),
              deleteBookmark: DeleteBookmarkUseCase(bookmarkRepo),
              updateContent: UpdateContentUseCase(contentRepo),
              saveContent: SaveContentUseCase(contentRepo),
              checkTtsLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
              getCurrentPosition: () => handlerPosition.value,
              playbackRepo: playbackRepo,
              settingsRepo: settingsRepo,
              bookmarkRepo: bookmarkRepo,
            )),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();

  return _TestEnv(
    container:
        ProviderScope.containerOf(tester.element(find.byType(HomeScreen))),
    tracker: tracker,
    contentRepo: contentRepo,
    playbackRepo: playbackRepo,
    positionController: positionController,
    handlerPosition: handlerPosition,
    tts: ttsService,
  );
}

/// PlayerScreenが`audioHandlerProvider`をreadするため、音声プラグインに
/// 触れないfakeで差し替える（声一覧は空）。
class _FakeAudioHandler implements TtsAudioHandler {
  @override
  Future<List<VoiceInfo>> getAvailableVoices() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopFence implements PlaybackResumeFence {
  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async {}
}

class _FakeTtsService implements TtsService {
  int speakCalls = 0;
  int pauseCalls = 0;

  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async {
    speakCalls++;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async => [];

  @override
  Future<void> dispose() async {}
}

class _FakeObsidianRepository implements ObsidianRepository {
  @override
  Future<String?> pickVaultDirectory() async => null;

  @override
  Future<String?> getVaultUri() async => null;

  @override
  Future<String?> getVaultName() async => null;

  @override
  Future<List<VaultEntry>> listNotes() async => [];

  @override
  Future<String> readNoteContent(String uri) async => '';

  @override
  Future<void> writeNote(String path, String content) async {}
}

class _FakeContentRepository implements ContentRepository {
  final Map<String, Content> _store = {};

  @override
  Future<Content?> getById(String id) async => _store[id];

  @override
  Future<void> update(Content content) async => _store[content.id] = content;

  @override
  Future<List<Content>> getAll() async => _store.values.toList();

  @override
  Future<List<Content>> getByStatus(String status) async =>
      _store.values.where((c) => c.status == status).toList();

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

  Completer<void>? saveBarrier;
  int saveCalls = 0;

  @override
  Future<void> save(PlaybackState state) async {
    saveCalls++;
    final b = saveBarrier;
    if (b != null) await b.future;
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
  final List<Bookmark> _store = [];

  @override
  Future<List<Bookmark>> getByContentId(String contentId) async =>
      _store.where((b) => b.contentId == contentId).toList();

  @override
  Future<void> save(Bookmark bookmark) async => _store.add(bookmark);

  @override
  Future<void> delete(String id) async => _store.removeWhere((b) => b.id == id);
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
