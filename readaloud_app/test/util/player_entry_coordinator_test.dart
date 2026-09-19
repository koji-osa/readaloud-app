import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/quick_listen_session.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/ui/quick_listen/quick_listen_screen.dart';
import 'package:readaloud_app/usecase/content/library_promotion_service.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/usecase/playback/persistent_playback_resolver.dart';
import 'package:readaloud_app/usecase/playback/playback_defaults_reader.dart';
import 'package:readaloud_app/usecase/playback/playback_usage_accounting.dart';
import 'package:readaloud_app/usecase/playback/save_playback_state_usecase.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';
import 'package:readaloud_app/util/player_entry_coordinator.dart';
import 'package:readaloud_app/util/quick_listen_route_tracker.dart';
import 'package:readaloud_app/viewmodel/quick_listen_viewmodel.dart';

// Shared Player Core Slice 6: PlayerEntryCoordinator
// T-R1（NP表示中のentry / Transient表示中のentryでroute数1）、
// T-C3e（entry integration: owner-retiring handoff fence）、D8 step4 gate、
// isMounted checkpoint。
void main() {
  setUp(() => DebugLogger.testSink = []);
  tearDown(() => DebugLogger.testSink = null);

  PlaybackRequest transientRequest(String text) =>
      QuickListenSession.fromSharedText(text).request;

  testWidgets('T-R1: NP A表示中のentry → NP Aは除去されTransientが前面、route数はそれぞれ最大1',
      (tester) async {
    final env = await _pumpEnv(tester);
    await env.harness.openNormalPlayer('cA');
    await tester.pumpAndSettle();
    expect(find.text('NP_MARKER:cA'), findsOneWidget);

    await env.harness.openTransient(transientRequest('共有テキスト1'));
    await tester.pumpAndSettle();

    expect(find.text('NP_MARKER:cA', skipOffstage: false), findsNothing);
    expect(find.byType(QuickListenScreen, skipOffstage: false), findsOneWidget);
    expect(env.tracker.currentSession, isNull);
  });

  testWidgets('T-R1: Transient表示中のentry → 旧Transientは除去されroute数1のまま',
      (tester) async {
    final env = await _pumpEnv(tester);
    await env.harness.openTransient(transientRequest('共有テキスト1'));
    await tester.pumpAndSettle();
    await env.harness.openTransient(transientRequest('共有テキスト2'));
    await tester.pumpAndSettle();
    await env.harness.openTransient(transientRequest('共有テキスト3'));
    await tester.pumpAndSettle();

    expect(find.byType(QuickListenScreen, skipOffstage: false), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(QuickListenScreen, skipOffstage: false), findsNothing);
    expect(find.text('HOME_MARKER'), findsOneWidget);
  });

  testWidgets(
      'T-C3e（entry）: 再生中のNP Aをentryでretire → stop + handoff fence完了後に'
      'だけroute除去・push。Aの遅延teardownはTransient B再生を止めない', (tester) async {
    final env = await _pumpEnv(tester);
    await env.harness.openNormalPlayer('cA');
    await tester.pumpAndSettle();
    final sessionA = env.tracker.currentSession!;
    await env.gate.start(sessionId: sessionA.id, contentId: 'cA');
    env.log.clear();

    await env.harness.openTransient(transientRequest('共有テキストB'));
    await tester.pumpAndSettle();
    // NP route の除去は stop + handoff fence の完了後にだけ行われる。
    expect(env.log.take(3), ['tts:stop', 'fence:handoff', 'nav:removed:np']);

    // Transient B を再生開始
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    final ownerB = env.transport.activeOwner;
    expect(ownerB.toString(), startsWith('tr:'));
    env.log.clear();

    // A の遅延 teardown が B start 後に到着する
    final late = await env.gate.teardownForSession(
        sessionId: sessionA.id,
        contentId: 'cA',
        reason: TeardownReason.shareTeardown);
    expect(late.ttsStopConfirmed, isFalse);
    expect(env.log, isEmpty, reason: 'BのTTS・fenceへ触れない');
    expect(env.transport.activeOwner, ownerB);
  });

  testWidgets('D8 step4: NPのTTS stopが確認できない場合はroute除去もpushもしない',
      (tester) async {
    final env = await _pumpEnv(tester);
    await env.harness.openNormalPlayer('cA');
    await tester.pumpAndSettle();
    final sessionA = env.tracker.currentSession!;
    await env.gate.start(sessionId: sessionA.id, contentId: 'cA');
    env.tts.failStop = true;

    await env.harness.openTransient(transientRequest('共有テキスト'));
    await tester.pumpAndSettle();

    expect(find.text('NP_MARKER:cA'), findsOneWidget);
    expect(find.byType(QuickListenScreen, skipOffstage: false), findsNothing);
    expect(env.tracker.isEffectCurrent(sessionA.id), isTrue,
        reason: 'finallyでclaimがabandonされeffect-activeへ戻る');
  });

  testWidgets('isMounted checkpoint: Transient retire直後にunmountedならroute操作しない',
      (tester) async {
    final env = await _pumpEnv(tester);
    await env.harness.openNormalPlayer('cA');
    await tester.pumpAndSettle();

    await env.harness
        .openTransient(transientRequest('共有テキスト'), isMounted: () => false);
    await tester.pumpAndSettle();

    expect(find.text('NP_MARKER:cA'), findsOneWidget);
    expect(find.byType(QuickListenScreen, skipOffstage: false), findsNothing);
    expect(env.tracker.currentSession, isNotNull);
    expect(env.tracker.isEffectCurrent(env.tracker.currentSession!.id), isTrue);
  });
}

class _Env {
  _Env({
    required this.harness,
    required this.tracker,
    required this.gate,
    required this.transport,
    required this.tts,
    required this.log,
  });

  final _HarnessState harness;
  final NormalPlayerSessionTracker tracker;
  final NormalPlayerPlaybackGate gate;
  final SharedPlaybackTransport transport;
  final _LoggingTts tts;
  final List<String> log;
}

Future<_Env> _pumpEnv(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final log = <String>[];
  final tts = _LoggingTts(log);
  final contentRepo = _FakeContentRepository();
  final playbackRepo = _FakePlaybackRepository();
  final settingsRepo = _FakeSettingsRepository();
  final transport = SharedPlaybackTransport(
    tts: tts,
    positionStream: const Stream.empty(),
    currentPosition: () => 0,
    resumeFence: _LoggingFence(log),
  );
  addTearDown(transport.dispose);
  final gate = NormalPlayerPlaybackGate.shared(
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
  final tracker = NormalPlayerSessionTracker(playbackGate: gate);
  final key = GlobalKey<_HarnessState>();

  await tester.pumpWidget(ProviderScope(
    overrides: [
      quickListenViewModelProvider.overrideWith((ref) => _TestVm(
            transport: transport,
            defaultsReader: _FakeDefaults(),
            promotion: LibraryPromotionService(
              saveContent: SaveContentUseCase(contentRepo),
              playbackRepo: playbackRepo,
              defaultsReader: _FakeDefaults(),
            ),
          )),
    ],
    child: MaterialApp(
      home: _Harness(key: key, tracker: tracker, log: log),
    ),
  ));
  await tester.pumpAndSettle();
  return _Env(
    harness: key.currentState!,
    tracker: tracker,
    gate: gate,
    transport: transport,
    tts: tts,
    log: log,
  );
}

class _Harness extends ConsumerStatefulWidget {
  const _Harness({super.key, required this.tracker, required this.log});
  final NormalPlayerSessionTracker tracker;
  final List<String> log;

  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  late final PlayerEntryCoordinator coordinator = PlayerEntryCoordinator(
    normalPlayerTracker: widget.tracker,
    transientRouteTracker: QuickListenRouteTracker(),
    retireActiveTransient: ({required TeardownReason reason}) =>
        ref.read(quickListenViewModelProvider.notifier).close(reason: reason),
  );

  /// home_screen.dart の register-before-push を模す。
  Future<void> openNormalPlayer(String contentId) async {
    final session = NormalPlayerSession(contentId: contentId);
    final route = MaterialPageRoute<void>(
      builder: (_) => Scaffold(body: Text('NP_MARKER:$contentId')),
    );
    final token = widget.tracker.register(session: session, route: route);
    if (token == null) return;
    unawaited(Navigator.of(context).push(route).then((_) {
      widget.tracker.clearIfCurrent(route);
      widget.log.add('nav:removed:np');
    }));
  }

  Future<void> openTransient(PlaybackRequest request,
      {bool Function()? isMounted}) {
    return coordinator.openTransient(
      context: context,
      isMounted: isMounted ?? () => mounted,
      request: request,
      flowId: 'flow-${DateTime.now().microsecondsSinceEpoch}',
      reason: TeardownReason.shareTeardown,
    );
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('HOME_MARKER')));
}

class _TestVm extends QuickListenViewModel {
  _TestVm({
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

class _LoggingTts implements TtsService {
  _LoggingTts(this.log);
  final List<String> log;
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
      log.add('tts:speak');

  @override
  Future<void> pause() async => log.add('tts:pause');

  @override
  Future<void> stop() async {
    log.add('tts:stop');
    if (failStop) throw StateError('stop failed');
  }

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async => [];

  @override
  Future<void> dispose() async {}
}

class _LoggingFence implements PlaybackResumeFence {
  _LoggingFence(this.log);
  final List<String> log;

  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async =>
      log.add('fence:${notificationDisposition.name}');
}

class _FakeContentRepository implements ContentRepository {
  final Map<String, Content> _store = {};

  @override
  Future<Content?> getById(String id) async => _store[id] ??=
      Content(id: id, title: 't', body: 'body of $id', sourceType: 'text');

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
