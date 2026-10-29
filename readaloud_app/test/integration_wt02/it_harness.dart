// RA-CC-AUTO-WT-02 / IT: shared integration harness.
//
// Compiles against BOTH base 5986e147 and the integration head (only
// pre-existing public APIs are referenced here). New-API wiring (clock /
// checkpointInterval) is injected by the caller through [GateBuilder].
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
import 'package:readaloud_app/util/normal_player_session_tracker.dart';
import 'package:readaloud_app/viewmodel/add_content_viewmodel.dart';
import 'package:readaloud_app/viewmodel/content_list_viewmodel.dart';
import 'package:readaloud_app/viewmodel/obsidian_import_viewmodel.dart';
import 'package:readaloud_app/viewmodel/player_viewmodel.dart';
import 'package:readaloud_app/viewmodel/settings_viewmodel.dart';

/// 1000 chars of plain Japanese (unchanged by TextCleaner).
final String itBody = List.filled(100, 'これはテスト文です。').join();

/// Lets the caller build the gate (to inject checkpointInterval / clock on the
/// integration head without this file referencing them).
typedef GateBuilder = NormalPlayerPlaybackGate Function(GateDeps deps);

class GateDeps {
  GateDeps({
    required this.transport,
    required this.resolver,
    required this.playbackRepo,
    required this.savePlaybackState,
    required this.accounting,
  });
  final SharedPlaybackTransport transport;
  final PersistentPlaybackResolver resolver;
  final PlaybackRepository playbackRepo;
  final SavePlaybackStateUseCase savePlaybackState;
  final PlaybackUsageAccounting accounting;
}

NormalPlayerPlaybackGate defaultGateBuilder(GateDeps d) =>
    NormalPlayerPlaybackGate.shared(
      transport: d.transport,
      resolver: d.resolver,
      playbackRepo: d.playbackRepo,
      savePlaybackState: d.savePlaybackState,
      accounting: d.accounting,
    );

/// Non-widget core: real transport / gate / tracker over in-memory fakes.
class ItCore {
  ItCore({GateBuilder gateBuilder = defaultGateBuilder}) {
    transport = SharedPlaybackTransport(
      tts: tts,
      positionStream: positions.stream,
      currentPosition: () => handlerPosition,
      resumeFence: _NoopFence(),
    );
    savePlayback = SavePlaybackStateUseCase(
        playbackRepo: playbackRepo, contentRepo: contentRepo);
    resolver = PersistentPlaybackResolver(
        contentRepo: contentRepo, playbackRepo: playbackRepo);
    gate = gateBuilder(GateDeps(
      transport: transport,
      resolver: resolver,
      playbackRepo: playbackRepo,
      savePlaybackState: savePlayback,
      accounting: PersistentUsageAccounting(CountTtsUsageUseCase(
        settingsRepo: settingsRepo,
        checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      )),
    ));
    tracker = NormalPlayerSessionTracker(playbackGate: gate);
  }

  final contentRepo = ItContentRepository();
  final playbackRepo = ItPlaybackRepository();
  final settingsRepo = ItSettingsRepository();
  final tts = ItTtsService();
  final StreamController<dynamic> positions =
      StreamController<dynamic>.broadcast(sync: true);
  int handlerPosition = 0;
  late final SharedPlaybackTransport transport;
  late final SavePlaybackStateUseCase savePlayback;
  late final PersistentPlaybackResolver resolver;
  late final NormalPlayerPlaybackGate gate;
  late final NormalPlayerSessionTracker tracker;

  void addContent(String id, int len,
          {String status = 'unread', String? body}) =>
      contentRepo.store[id] = Content(
          id: id,
          title: 't-$id',
          body: body ?? ('x' * len),
          sourceType: 'text',
          status: status);

  /// Emits a position event and keeps the handler position in sync.
  void emit(TtsPlaybackPosition p) {
    handlerPosition = p.charPosition;
    positions.add(p);
  }

  void emitPlaying(int pos) => emit(TtsPlaybackPosition(
      charPosition: pos, isPlaying: true, ttsStatus: TtsStatus.playing));

  Future<String?> usedChars() => settingsRepo.get('tts_used_chars');

  Future<void> dispose() async {
    gate.dispose();
    transport.dispose();
    await positions.close();
  }
}

/// Settle microtasks / zero-delay futures (non-widget tests).
Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class ItEnv {
  ItEnv(this.core, this.container);
  final ItCore core;
  final ProviderContainer container;

  ItContentRepository get contentRepo => core.contentRepo;
  ItPlaybackRepository get playbackRepo => core.playbackRepo;
  ItTtsService get tts => core.tts;
  NormalPlayerSessionTracker get tracker => core.tracker;
  SharedPlaybackTransport get transport => core.transport;
  ItSettingsRepository get settingsRepo => core.settingsRepo;
  void emit(TtsPlaybackPosition p) => core.emit(p);
  void emitPlaying(int pos) => core.emitPlaying(pos);
}

Future<ItEnv> pumpHome(
  WidgetTester tester, {
  List<Content> seedContents = const [],
  List<PlaybackState> seedPlayback = const [],
  GateBuilder gateBuilder = defaultGateBuilder,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final core = ItCore(gateBuilder: gateBuilder);
  for (final c in seedContents) {
    await core.contentRepo.save(c);
  }
  for (final p in seedPlayback) {
    await core.playbackRepo.save(p);
  }
  core.playbackRepo.saveCalls = 0;
  core.playbackRepo.saves.clear();
  addTearDown(core.positions.close);
  addTearDown(core.transport.dispose);

  final contentRepo = core.contentRepo;
  final playbackRepo = core.playbackRepo;
  final settingsRepo = core.settingsRepo;
  final gate = core.gate;
  final tracker = core.tracker;
  final bookmarkRepo = _FakeBookmarkRepository();
  final obsidianRepo = _FakeObsidianRepository();
  final savePlaybackState = core.savePlayback;

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
              getCurrentPosition: () => core.handlerPosition,
              playbackRepo: playbackRepo,
              settingsRepo: settingsRepo,
              bookmarkRepo: bookmarkRepo,
            )),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();

  return ItEnv(
    core,
    ProviderScope.containerOf(tester.element(find.byType(HomeScreen))),
  );
}

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

/// Counts every call so tests can assert "stop was not invoked".
class ItTtsService implements TtsService {
  int speakCount = 0;
  int pauseCount = 0;
  int stopCount = 0;

  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async =>
      speakCount++;

  @override
  Future<void> pause() async => pauseCount++;

  @override
  Future<void> stop() async => stopCount++;

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

class ItContentRepository implements ContentRepository {
  final Map<String, Content> store = {};

  /// Number of list reads (= Home loadContents reaching the DB layer).
  int getAllCalls = 0;

  @override
  Future<Content?> getById(String id) async => store[id];

  @override
  Future<void> update(Content content) async => store[content.id] = content;

  @override
  Future<List<Content>> getAll() async {
    getAllCalls++;
    return store.values.toList();
  }

  @override
  Future<List<Content>> getByStatus(String status) async =>
      store.values.where((c) => c.status == status).toList();

  @override
  Future<void> save(Content content) async => store[content.id] = content;

  @override
  Future<void> delete(String id) async => store.remove(id);
}

class ItPlaybackRepository implements PlaybackRepository {
  final Map<String, PlaybackState> store = {};

  /// While non-null, [save] blocks on it (fixes race orderings).
  Completer<void>? saveBarrier;
  bool failSave = false;

  /// Attempts (including failed ones).
  int saveCalls = 0;

  /// Successful writes, in order: (contentId, position, pct).
  final List<(String, int, double)> saves = [];

  @override
  Future<PlaybackState?> getByContentId(String contentId) async =>
      store[contentId];

  @override
  Future<void> save(PlaybackState state) async {
    saveCalls++;
    final b = saveBarrier;
    if (b != null) await b.future;
    if (failSave) throw StateError('save failed');
    store[state.contentId] = state;
    saves.add((state.contentId, state.position, state.progressPct));
  }

  @override
  Future<void> resetAbRepeat(String contentId) async {}

  @override
  Future<void> resetAllAbRepeat() async {}

  @override
  Future<void> delete(String contentId) async => store.remove(contentId);
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

class ItSettingsRepository implements SettingsRepository {
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
