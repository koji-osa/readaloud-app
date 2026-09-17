import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/bookmark.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/quick_listen_session.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/providers.dart';
import 'package:readaloud_app/repository/bookmark_repository.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/ui/home/widgets/tts_usage_banner.dart'
    show settingsViewModelProvider;
import 'package:readaloud_app/ui/player/player_screen.dart';
import 'package:readaloud_app/ui/quick_listen/quick_listen_screen.dart';
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
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';
import 'package:readaloud_app/util/player_entry_coordinator.dart';
import 'package:readaloud_app/viewmodel/player_viewmodel.dart';
import 'package:readaloud_app/viewmodel/quick_listen_viewmodel.dart';
import 'package:readaloud_app/viewmodel/settings_viewmodel.dart';

// Pre-Commit Correction PC-2（Detailed Design v1.3 FINAL §15 / §16 T-C3f/g/h）:
// production 構成（SharedPlaybackTransport + NormalPlayerPlaybackGate.shared +
// PersistentUsageAccounting + 実 PlayerScreen/PlayerViewModel + 実
// playerEntryCoordinatorProvider）で external/share entry の
// route owner / playback owner 分離を検証する。legacy usecase backend は使わない。
void main() {
  setUp(() => DebugLogger.testSink = []);
  tearDown(() => DebugLogger.testSink = null);

  Future<void> playCurrentPlayer(
      WidgetTester tester, _Env env, int position) async {
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    env.handlerPosition = position;
    env.positions.add(TtsPlaybackPosition(
        charPosition: position, isPlaying: true, ttsStatus: TtsStatus.playing));
    await tester.pump();
  }

  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Case 1 / T-C3f: NP A再生 → system back（A route無し・A playback継続）→ text share: '
      'Aが停止・fence・A位置保存され、Quick Listenが開く', (tester) async {
    final env = await _pumpEnv(tester);
    await env.harness.openFromHome(_content('cA'));
    await tester.pumpAndSettle();
    await playCurrentPlayer(tester, env, 37);
    await systemBack(tester);

    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(env.tracker.currentSession, isNull);
    expect(env.transport.activeOwner.toString(), startsWith('np:'),
        reason: 'system back後もAのplayback ownerは残る（合法state）');
    env.tts.calls.clear();

    await env.harness.shareText('共有テキスト');
    await tester.pumpAndSettle();

    expect(env.tts.calls, contains('stop'), reason: 'A stops');
    expect(env.fence.calls, [NotificationDisposition.handoff]);
    expect(env.playbackRepo.store['cA']!.position, 37, reason: 'A位置はAへ保存');
    expect(find.byType(QuickListenScreen), findsOneWidget);
  });

  testWidgets(
      'Case 2 / T-C3g / T-C3h: A再生 → system back → B open未再生 → text share: '
      'Bを同期claim、Aを停止・fence・A位置をAへ保存（Bへは書かない）、B route除去、QL表示', (tester) async {
    final env = await _pumpEnv(tester);
    await env.harness.openFromHome(_content('cA'));
    await tester.pumpAndSettle();
    await playCurrentPlayer(tester, env, 37);
    await systemBack(tester);

    await env.harness.openFromHome(_content('cB'));
    await tester.pumpAndSettle();
    final sessionB = env.tracker.currentSession!;
    expect(sessionB.contentId, 'cB');
    final bPositionBefore = env.playbackRepo.store['cB']?.position;
    env.tts.calls.clear();

    final share = env.harness.shareText('共有テキスト');
    expect(env.tracker.isEffectCurrent(sessionB.id), isFalse,
        reason: 'Bは最初のawaitより前に同期claimされる');
    await share;
    await tester.pumpAndSettle();

    expect(env.tts.calls, contains('stop'));
    expect(env.fence.calls, [NotificationDisposition.handoff]);
    expect(env.playbackRepo.store['cA']!.position, 37);
    expect(env.playbackRepo.store['cB']?.position, bPositionBefore,
        reason: 'AのpositionをBのcontentへ保存しない（AC-22）');
    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(env.tracker.currentSession, isNull);
    expect(find.byType(QuickListenScreen), findsOneWidget);
    expect(env.transport.activeOwner, isNull);
  });

  testWidgets(
      'Case 3: Case 2と同じ状態からURL share → AddScreen相当が開きdead-endにならない（AC-21）',
      (tester) async {
    final env = await _pumpEnv(tester);
    await env.harness.openFromHome(_content('cA'));
    await tester.pumpAndSettle();
    await playCurrentPlayer(tester, env, 12);
    await systemBack(tester);
    await env.harness.openFromHome(_content('cB'));
    await tester.pumpAndSettle();

    await env.harness.shareUrl('https://example.com/a');
    await tester.pumpAndSettle();

    expect(find.text('ADD_SCREEN_MARKER'), findsOneWidget);
    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(env.playbackRepo.store['cA']!.position, 12);
    expect(env.transport.activeOwner, isNull);
  });

  testWidgets('Case 4: B自身がactive → share: B停止・fence・B位置保存・B route除去・share継続',
      (tester) async {
    final env = await _pumpEnv(tester);
    await env.harness.openFromHome(_content('cB'));
    await tester.pumpAndSettle();
    await playCurrentPlayer(tester, env, 21);
    env.tts.calls.clear();

    await env.harness.shareText('共有テキスト');
    await tester.pumpAndSettle();

    expect(env.tts.calls, contains('stop'));
    expect(env.fence.calls, [NotificationDisposition.handoff]);
    expect(env.playbackRepo.store['cB']!.position, 21);
    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.byType(QuickListenScreen), findsOneWidget);
  });

  testWidgets(
      'Case 5: active playback無し + B未再生 → share: stop不要、B route除去、share継続',
      (tester) async {
    final env = await _pumpEnv(tester);
    await env.harness.openFromHome(_content('cB'));
    await tester.pumpAndSettle();
    expect(env.transport.activeOwner, isNull);

    await env.harness.shareText('共有テキスト');
    await tester.pumpAndSettle();

    expect(env.tts.calls, isNot(contains('stop')));
    expect(env.fence.calls, isEmpty);
    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.byType(QuickListenScreen), findsOneWidget);
  });

  testWidgets(
      'D8 step4維持: active playbackのTTS stopが確認できない場合はcovering entryをblockし、'
      'claimはfinallyで解放される', (tester) async {
    final env = await _pumpEnv(tester);
    await env.harness.openFromHome(_content('cB'));
    await tester.pumpAndSettle();
    await playCurrentPlayer(tester, env, 5);
    final sessionB = env.tracker.currentSession!;
    env.tts.failStop = true;

    await env.harness.shareText('共有テキスト');
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byType(QuickListenScreen, skipOffstage: false), findsNothing);
    expect(env.tracker.isEffectCurrent(sessionB.id), isTrue);
  });
}

Content _content(String id) =>
    Content(id: id, title: 'title-$id', body: 'x' * 400, sourceType: 'text');

class _Env {
  _Env({
    required this.harness,
    required this.tracker,
    required this.transport,
    required this.tts,
    required this.fence,
    required this.positions,
    required this.playbackRepo,
  });

  final _HarnessState harness;
  final NormalPlayerSessionTracker tracker;
  final SharedPlaybackTransport transport;
  final _FakeTts tts;
  final _FakeFence fence;
  final StreamController<dynamic> positions;
  final _FakePlaybackRepository playbackRepo;
  int handlerPosition = 0;
}

Future<_Env> _pumpEnv(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final contentRepo = _FakeContentRepository();
  final playbackRepo = _FakePlaybackRepository();
  final bookmarkRepo = _FakeBookmarkRepository();
  final settingsRepo = _FakeSettingsRepository();
  final tts = _FakeTts();
  final fence = _FakeFence();
  final positions = StreamController<dynamic>.broadcast();
  addTearDown(positions.close);

  late _Env env;
  // --- providers.dart と同一の production composition ---
  final transport = SharedPlaybackTransport(
    tts: tts,
    positionStream: positions.stream,
    currentPosition: () => env.handlerPosition,
    resumeFence: fence,
  );
  addTearDown(transport.dispose);
  final savePlaybackState = SavePlaybackStateUseCase(
      playbackRepo: playbackRepo, contentRepo: contentRepo);
  final gate = NormalPlayerPlaybackGate.shared(
    transport: transport,
    resolver: PersistentPlaybackResolver(
        contentRepo: contentRepo, playbackRepo: playbackRepo),
    playbackRepo: playbackRepo,
    savePlaybackState: savePlaybackState,
    accounting: PersistentUsageAccounting(CountTtsUsageUseCase(
      settingsRepo: settingsRepo,
      checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
    )),
  );
  final tracker = NormalPlayerSessionTracker(playbackGate: gate);
  final defaults = _FakeDefaults();
  final key = GlobalKey<_HarnessState>();

  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPlaybackTransportProvider.overrideWithValue(transport),
      normalPlayerPlaybackGateProvider.overrideWithValue(gate),
      normalPlayerSessionTrackerProvider.overrideWithValue(tracker),
      settingsViewModelProvider.overrideWith((ref) => SettingsViewModel(
            settingsRepo: settingsRepo,
            checkTtsLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
          )),
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
            positionStream: positions.stream,
            getCurrentPosition: () => env.handlerPosition,
            playbackRepo: playbackRepo,
            settingsRepo: settingsRepo,
            bookmarkRepo: bookmarkRepo,
          )),
      quickListenViewModelProvider.overrideWith((ref) => _TestQuickListenVm(
            transport: transport,
            defaultsReader: defaults,
            promotion: LibraryPromotionService(
              saveContent: SaveContentUseCase(contentRepo),
              playbackRepo: playbackRepo,
              defaultsReader: defaults,
            ),
          )),
    ],
    child: MaterialApp(home: _Harness(key: key)),
  ));
  await tester.pumpAndSettle();

  env = _Env(
    harness: key.currentState!,
    tracker: tracker,
    transport: transport,
    tts: tts,
    fence: fence,
    positions: positions,
    playbackRepo: playbackRepo,
  );
  return env;
}

class _Harness extends ConsumerStatefulWidget {
  const _Harness({super.key});

  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  int _flowSeq = 0;

  /// home_screen.dart の register-before-push を模す。
  Future<void> openFromHome(Content content) async {
    final session = NormalPlayerSession(contentId: content.id);
    final route = MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(content: content, sessionId: session.id),
    );
    final tracker = ref.read(normalPlayerSessionTrackerProvider);
    final token = tracker.register(session: session, route: route);
    if (token == null) return;
    unawaited(Navigator.of(context).push(route).then((_) {
      tracker.clearIfCurrent(route);
    }));
  }

  /// main.dart._handleSharedPayload() の text 分岐と同じ呼び出し。
  Future<void> shareText(String text) {
    return ref.read(playerEntryCoordinatorProvider).openTransient(
          context: context,
          isMounted: () => mounted,
          request: QuickListenSession.fromSharedText(text).request,
          flowId: 'flow-${++_flowSeq}',
          reason: TeardownReason.shareTeardown,
        );
  }

  /// main.dart._handleSharedPayload() の URL 分岐と同じ呼び出し
  /// （AddScreen の代わりに marker 画面を push）。
  Future<void> shareUrl(String url) {
    return ref.read(playerEntryCoordinatorProvider).openCovering(
          context: context,
          isMounted: () => mounted,
          flowId: 'flow-${++_flowSeq}',
          reason: TeardownReason.shareTeardown,
          pushCovering: (ctx) => Navigator.of(ctx).push(MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: Center(child: Text('ADD_SCREEN_MARKER'))),
          )),
        );
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('HOME_MARKER')));
}

class _TestQuickListenVm extends QuickListenViewModel {
  _TestQuickListenVm({
    required super.transport,
    required super.defaultsReader,
    required super.promotion,
  });

  @override
  void start(QuickListenSession session) {
    scheduleMicrotask(() => super.start(session));
  }
}

class _FakeDefaults implements PlaybackDefaultsReader {
  @override
  Future<double> readDefaultSpeed() async => 1.0;
}

class _FakeTts implements TtsService {
  final List<String> calls = [];
  bool failStop = false;

  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async =>
      calls.add('speak');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (failStop) throw StateError('stop failed');
  }

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
