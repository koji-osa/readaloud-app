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
import 'package:readaloud_app/ui/add/add_screen.dart';
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

// BUG-P4 (RA-CC-AUTO-WT-01) regression: Home → 「+」→ AddScreen → 読み上げる →
// Player(pushReplacement) → 停止 → Back → Home で、ライブラリの進捗が
// 再生後の値に更新されること。
//
// Home「+」の `await push(AddScreen)` は、AddScreenがPlayerへ
// pushReplacementした時点で完了してしまい、その時点でloadContents()が
// 走るため、Playerから戻った後に一覧が更新されない（stale）。
// Home→カード→Player は _openPlayer が Player route 完了後に reload する
// 正しい契約（AC-P4-02）。
void main() {
  setUp(() {
    DebugLogger.testSink = [];
  });

  tearDown(() {
    DebugLogger.testSink = null;
  });

  testWidgets(
      'AC-P4-01: Home「+」→Add→読み上げる→Player再生・停止→Backで、'
      'Homeの進捗(progressMap/ContentCard)が再生後のDB値に更新される', (tester) async {
    final env = await _pumpHome(tester);
    expect(find.byType(ContentCard), findsNothing, reason: '初期ライブラリは空');

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(AddScreen), findsOneWidget);

    // 1000文字の平文（TextCleanerで変化しない文）。
    final text = List.filled(100, 'これはテスト文です。').join();
    await tester.enterText(find.byType(TextField).first, text);
    await tester.pump();
    await tester.tap(find.text('読み上げる'));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byType(AddScreen), findsNothing,
        reason: 'AddScreenはPlayerへpushReplacementされる');
    final saved = (await env.contentRepo.getAll()).single;
    final newId = saved.id;
    final bodyLen = saved.body.length;
    expect(bodyLen, greaterThan(300));

    // 再生中の位置を決定論的に注入し、Playerの停止ボタンで保存を確定させる。
    env.emitPosition(const TtsPlaybackPosition(
      charPosition: 300,
      isPlaying: true,
      ttsStatus: TtsStatus.playing,
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pumpAndSettle();

    final expectedPct = 300 / bodyLen * 100;
    final dbState = await env.playbackRepo.getByContentId(newId);
    expect(dbState, isNotNull, reason: '停止でPlaybackStateが保存されている');
    expect(dbState!.progressPct, closeTo(expectedPct, 0.001),
        reason: '(a) DB: 停止位置300 / 本文長 * 100');
    expect(dbState.progressPct, greaterThan(0));
    expect(dbState.progressPct, lessThan(100));

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);

    final listState = env.container.read(contentListViewModelProvider);
    expect((await env.contentRepo.getById(newId))!.status, 'in_progress',
        reason: 'DB側のstatusは再生開始で in_progress になっている');
    expect(listState.progressMap[newId], isNotNull,
        reason: '(b) ContentListState.progressMap[newId]がDB値で更新されている（P4: stale）');
    expect(listState.progressMap[newId], closeTo(dbState.progressPct, 0.001),
        reason: '(b) progressMapがDB値と一致する（P4: stale）');
    final card = tester.widget<ContentCard>(find.byType(ContentCard));
    expect(card.progressPct, closeTo(dbState.progressPct, 0.001),
        reason: '(c) ContentCardに渡るprogressPctがDB値と一致する（P4: stale）');
    expect(card.content.status, 'in_progress',
        reason: '一覧側のContent.statusもDBと一致する（P4: stale）');
  });

  testWidgets(
      'AC-P4-03: Home「+」→Add→Add自身のBack→Home。Playerは出ず、'
      'trackerのsessionはnull', (tester) async {
    final env = await _pumpHome(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(AddScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byType(AddScreen, skipOffstage: false), findsNothing);
    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(env.tracker.currentSession, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'AC-P4-02: 既存コンテンツのカード→Player→停止(新位置)→Backで、'
      'Homeの進捗が更新される（_openPlayerのreload契約）', (tester) async {
    final body = List.filled(100, 'これはテスト文です。').join();
    final existing = Content(
        id: 'existing-1',
        title: 'existing',
        body: body,
        sourceType: 'text',
        status: 'in_progress');
    final env = await _pumpHome(
      tester,
      seedContents: [existing],
      seedPlayback: [
        PlaybackState(contentId: 'existing-1', position: 100, progressPct: 10),
      ],
    );
    expect(
        env.container
            .read(contentListViewModelProvider)
            .progressMap['existing-1'],
        closeTo(10, 0.001),
        reason: '初期ロードで保存済み進捗が反映されている');

    await tester.tap(find.byType(ContentCard));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);

    // カード経由はautoPlayしないため、手動で再生を開始してownerを確立する。
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    env.emitPosition(const TtsPlaybackPosition(
      charPosition: 500,
      isPlaying: true,
      ttsStatus: TtsStatus.playing,
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pumpAndSettle();

    final dbState = await env.playbackRepo.getByContentId('existing-1');
    expect(dbState!.progressPct, closeTo(500 / body.length * 100, 0.001));

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    final listState = env.container.read(contentListViewModelProvider);
    expect(listState.progressMap['existing-1'],
        closeTo(dbState.progressPct, 0.001));
    final card = tester.widget<ContentCard>(find.byType(ContentCard));
    expect(card.progressPct, closeTo(dbState.progressPct, 0.001));
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
  });

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
