import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/bookmark.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/setting.dart';
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
import 'package:readaloud_app/usecase/bookmark/add_bookmark_usecase.dart';
import 'package:readaloud_app/usecase/bookmark/delete_bookmark_usecase.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/usecase/content/update_content_usecase.dart';
import 'package:readaloud_app/usecase/playback/save_playback_state_usecase.dart';
import 'package:readaloud_app/usecase/playback/set_ab_repeat_usecase.dart';
import 'package:readaloud_app/usecase/playback/start_playback_usecase.dart';
import 'package:readaloud_app/usecase/playback/stop_playback_usecase.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';
import 'package:readaloud_app/viewmodel/player_viewmodel.dart';
import 'package:readaloud_app/viewmodel/settings_viewmodel.dart';

// Canonical Design v0.4.1 の Normal Player 単一route契約に対する widget-level
// navigation test。既存 quick_listen_navigation_test.dart の harness pattern
// （main.dartが実際に駆動する処理を、テスト用harnessから直接同じAPIで駆動する）
// を踏襲する。DB/audio_service等の重量な具象実装は使わず、fakeで完結させる。
void main() {
  setUp(() {
    DebugLogger.testSink = [];
  });

  tearDown(() {
    DebugLogger.testSink = null;
  });

  testWidgets('Home → Player → AppBar Back → Home（従来挙動維持・tracker clear）',
      (tester) async {
    final env = await _pumpHarness(tester);

    unawaited(env.harnessState.openFromHome(_content('c1')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(env.tracker.currentSession, isNotNull);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.text('HOME_MARKER'), findsOneWidget);
    expect(env.tracker.currentSession, isNull,
        reason: 'route completionでtrackerが同期clearされる');
  });

  testWidgets(
      'Player A表示中にshareが届くと、Aは除去されcovering routeが前面になる。'
      'covering routeを閉じてもAは再露出しない', (tester) async {
    final env = await _pumpHarness(tester);

    unawaited(env.harnessState.openFromHome(_content('c1')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);

    await env.harnessState.share('flow-1');
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing,
        reason: 'stale Player Aはstackに残らない（NR-01）');
    expect(find.text('COVERING_MARKER'), findsOneWidget);
    expect(env.ttsService.stopCallCount, 1);

    await tester.tap(find.text('COVERING_MARKER'));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.text('HOME_MARKER'), findsOneWidget);
  });

  testWidgets(
      'rapid share: share#1に続けてshare#2が届いても、Normal Player routeは常に'
      '最大1件で、最終的にshare#2のcovering routeだけが残る', (tester) async {
    final env = await _pumpHarness(tester);

    unawaited(env.harnessState.openFromHome(_content('c1')));
    await tester.pumpAndSettle();

    // 連続shareを待ち合わせずに発火する。
    final f1 = env.harnessState.share('flow-1');
    final f2 = env.harnessState.share('flow-2');
    await Future.wait([f1, f2]);
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.text('COVERING_MARKER', skipOffstage: false), findsOneWidget,
        reason: 'covering routeは常に最大1件のまま（latest-event semantics）');
    expect(env.tracker.currentSession, isNull);
  });

  testWidgets(
      'TTS-stop失敗時はPlayer routeが除去されずcovering routeもpushされない'
      '（B-01 / D8 step4）。Playerは回復可能なまま残る', (tester) async {
    final env = await _pumpHarness(tester);
    env.ttsService.stopBehavior = () => throw Exception('tts stop failed');

    unawaited(env.harnessState.openFromHome(_content('c1')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);

    await env.harnessState.share('flow-1');
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen, skipOffstage: false), findsOneWidget,
        reason: 'TTS-stopが確認できないPlayerは除去されず回復可能なまま残る（D16）');
    expect(find.text('COVERING_MARKER', skipOffstage: false), findsNothing,
        reason: 'covering routeもpushされない');
    expect(env.tracker.isEffectCurrent(env.tracker.currentSession!.id), isTrue,
        reason: 'finallyでclaimがabandonされ、effect-activeへ戻っている');
  });

  testWidgets(
      'register(replacingOrigin:)はeffect-currentでないoriginからのB生成を拒否する'
      '（CB-1 V-B、REQ-034置換相当）', (tester) async {
    final env = await _pumpHarness(tester);

    unawaited(env.harnessState.openFromHome(_content('c1')));
    await tester.pumpAndSettle();
    final sessionA = env.tracker.currentSession!;
    final originA = PlayerOriginToken(
        sessionId: sessionA.id, contentId: sessionA.contentId);

    // Aをretiringにする（shareのprepareForRemoval相当を直接呼ぶ）。
    final ticket = await env.tracker.prepareForRemoval(flowId: 'flow-x');
    expect(env.tracker.isEffectCurrent(sessionA.id), isFalse);

    final sessionB = NormalPlayerSession(contentId: 'c2');
    final routeB = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    final token = env.tracker
        .register(session: sessionB, route: routeB, replacingOrigin: originA);

    expect(token, isNull, reason: 'retiring中のAはBを生成できない');
    expect(env.tracker.currentSession?.id, sessionA.id);

    // 後始末（abandon）してもAの状態に影響しないことを確認。
    env.tracker.abandonRemoval(ticket);
    expect(env.tracker.isEffectCurrent(sessionA.id), isTrue);
  });

  testWidgets(
      'D15: Bがattach/start境界を越えたが自身の再生をまだ受理していない間に、'
      'A由来のstale positionが届いても、UI state（highlightPosition）にも'
      'usage counterのflushにも混入しない（I-02是正）', (tester) async {
    final env = await _pumpHarness(tester);

    // 1) Session A: 実際にplay()し、isPlaying:trueイベントを一度受理させる。
    //    これによりStartPlaybackUseCase側の共有subscriptionが
    //    「acceptしている状態」に入る（=Aが実際に再生position contextを
    //    持つ状態。単にsessionを作っただけではsubscriptionが一度も
    //    accept状態にならず、後段のstale注入が何にも当たらない空振り
    //    テストになってしまうため、これを避ける）。
    unawaited(env.harnessState.openFromHome(_content('c1')));
    await tester.pumpAndSettle();
    final sessionA = env.tracker.currentSession!;

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    env.positionController.add(const TtsPlaybackPosition(
      charPosition: 30,
      isPlaying: true,
      ttsStatus: TtsStatus.playing,
    ));
    await tester.pump();

    // AをAppBar Backで離脱させる。vm.stop()経由でAの使用量(30)は正しく
    // flushされるが、StartPlaybackUseCase._positionSubscriptionはexecute()
    // 呼び出し時にしか再購読されないため、この時点ではまだAのsubscriptionが
    // acceptしたままdangling状態で残る（次にNormal Playerがplay()するまで）。
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(env.tracker.currentSession, isNull);
    expect(await env.settingsRepo.get(SettingKeys.ttsUsedChars), '30',
        reason: 'Aの正当なflushが先に行われていることの前提確認');

    // 2) Session B: 新しいNormal Player sessionとしてattachするが、
    //    まだplay()を呼んでいない（=受理前）。
    unawaited(env.harnessState.openFromHome(_content('c2')));
    await tester.pumpAndSettle();
    final sessionB = env.tracker.currentSession!;
    expect(sessionB.id, isNot(sessionA.id));
    expect(env.harnessState.currentPlayerState().highlightPosition, 0,
        reason: 'B-initialのhighlightPositionは0');

    // 3) B受理前に、A由来のstale position（charPosition=601,
    //    isPlaying:true）をpositionControllerへ注入する。Aのdangling
    //    subscriptionはacceptしたままなので、production内部では
    //    CountTtsUsageUseCase._currentPositionが一時的に601へ書き換わり
    //    うる状態である。
    env.positionController.add(const TtsPlaybackPosition(
      charPosition: 601,
      isPlaying: true,
      ttsStatus: TtsStatus.playing,
    ));
    await tester.pump();

    // (a) UI destination: Bの新しいVMインスタンス自身のgateは
    //     まだ開いていない（B自身のplay()を一度も呼んでいない）ため、
    //     staleイベントはstateへ反映されない。
    expect(env.harnessState.currentPlayerState().highlightPosition, 0,
        reason: 'D15: B受理前のstale positionはUI stateへ反映されない');

    // (b) Usage destination: Bが実際に自分のplay()を呼び、自分自身の
    //     正当なposition(12)を1件受理した後にflushしても、直前に注入した
    //     stale 601がBのusageへ混入していないことを、後続flushの実測値で
    //     証明する（sleep/timerではなく、production counterの
    //     決定論的な観測点=永続化されたttsUsedCharsを使う）。
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    env.positionController.add(const TtsPlaybackPosition(
      charPosition: 12,
      isPlaying: true,
      ttsStatus: TtsStatus.playing,
    ));
    await tester.pump();
    expect(env.harnessState.currentPlayerState().highlightPosition, 12,
        reason: '受理後はB自身の正当なpositionが通常どおり反映される'
            '（gateが常時rejectしているわけではないことの確認）');

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(await env.settingsRepo.get(SettingKeys.ttsUsedChars), '42',
        reason: 'D15是正: Bのflush後合計はA(30)+B自身の正当なdelta(12)の'
            'ちょうど42のみ。注入したstale 601はBのstartCounting()による'
            '_currentPositionのreset（D13/D15の設計上の防御）で無効化されて'
            'おり、Bのusageへ一切混入していないことを、後続flushの実測値'
            'そのもので証明する');
  });
}

class _TestEnv {
  _TestEnv({
    required this.harnessState,
    required this.tracker,
    required this.gate,
    required this.ttsService,
    required this.positionController,
    required this.settingsRepo,
  });

  final _NormalPlayerNavHarnessState harnessState;
  final NormalPlayerSessionTracker tracker;
  final NormalPlayerPlaybackGate gate;
  final _FakeTtsService ttsService;
  final StreamController<dynamic> positionController;
  final _FakeSettingsRepository settingsRepo;
}

Future<_TestEnv> _pumpHarness(WidgetTester tester) async {
  // PlayerScreenは実機の縦長画面を前提としたUIのため、デフォルトの
  // テストサーフェス(800x600)ではRenderFlexがoverflowする。プロダクション
  // コードではなくテストのビューポートだけを広げて対処する。
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final contentRepo = _FakeContentRepository();
  final playbackRepo = _FakePlaybackRepository();
  final bookmarkRepo = _FakeBookmarkRepository();
  final settingsRepo = _FakeSettingsRepository();
  final ttsService = _FakeTtsService();
  final positionController = StreamController<dynamic>.broadcast();
  addTearDown(positionController.close);

  final countUsage = CountTtsUsageUseCase(
    settingsRepo: settingsRepo,
    checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
  );
  final startPlayback = StartPlaybackUseCase(
    contentRepo: contentRepo,
    playbackRepo: playbackRepo,
    positionStream: positionController.stream,
    ttsService: ttsService,
    countUsage: countUsage,
  );
  final savePlaybackState = SavePlaybackStateUseCase(
      playbackRepo: playbackRepo, contentRepo: contentRepo);
  final stopPlayback = StopPlaybackUseCase(
    playbackRepo: playbackRepo,
    ttsService: ttsService,
    countUsage: countUsage,
    saveState: savePlaybackState,
  );
  final gate = NormalPlayerPlaybackGate(
    startPlayback: startPlayback,
    stopPlayback: stopPlayback,
    getCurrentPosition: () => 0,
  );
  final tracker = NormalPlayerSessionTracker(playbackGate: gate);

  final harnessKey = GlobalKey<_NormalPlayerNavHarnessState>();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        normalPlayerSessionTrackerProvider.overrideWithValue(tracker),
        settingsViewModelProvider.overrideWith(
          (ref) => SettingsViewModel(
            settingsRepo: settingsRepo,
            checkTtsLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
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
              positionStream: positionController.stream,
              getCurrentPosition: () => 0,
              playbackRepo: playbackRepo,
              settingsRepo: settingsRepo,
              bookmarkRepo: bookmarkRepo,
            )),
      ],
      child: MaterialApp(home: _NormalPlayerNavHarness(key: harnessKey)),
    ),
  );
  await tester.pumpAndSettle();

  return _TestEnv(
    harnessState: harnessKey.currentState!,
    tracker: tracker,
    gate: gate,
    ttsService: ttsService,
    positionController: positionController,
    settingsRepo: settingsRepo,
  );
}

Content _content(String id) => Content(
    id: id, title: 'title-$id', body: 'body of $id', sourceType: 'text');

/// main.dart の share handler（D8 二相 teardown）を harness から直接駆動する。
/// home_screen.dart の `_openPlayer`（register-before-push）も同様に模す。
class _NormalPlayerNavHarness extends ConsumerStatefulWidget {
  const _NormalPlayerNavHarness({super.key});

  @override
  ConsumerState<_NormalPlayerNavHarness> createState() =>
      _NormalPlayerNavHarnessState();
}

class _NormalPlayerNavHarnessState
    extends ConsumerState<_NormalPlayerNavHarness> {
  // quick_listen_route_tracker.dart の removeActiveQuickListen→openQuickListen
  // と同じ「push前に前回のcovering routeを除去する」パターンをこのharness用に
  // 最小限で再現する（本物のQuickListenRouteTrackerは既存テストで別途検証済み。
  // ここではNormalPlayerSessionTracker側のlatest-event semanticsだけを見る）。
  Route<void>? _activeCoveringRoute;

  /// I-02是正: 現在の（最後にmountされた）PlayerScreenが watch している
  /// PlayerViewModelのstateを、production同様のRiverpod containerから直接
  /// 読み取る（production内部を露出させるための変更ではなく、既存の公開
  /// providerを既存の`ref`経由で読むだけ）。
  PlayerState currentPlayerState() => ref.read(playerViewModelProvider);

  Future<void> openFromHome(Content content) async {
    final session = NormalPlayerSession(contentId: content.id);
    final route = MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(content: content, sessionId: session.id),
    );
    final tracker = ref.read(normalPlayerSessionTrackerProvider);
    final token = tracker.register(session: session, route: route);
    if (token == null) return;
    try {
      await Navigator.of(context).push(route);
      tracker.clearIfCurrent(route);
    } catch (e) {
      tracker.abortRegistration(token);
      rethrow;
    }
  }

  /// main.dart._handleSharedPayload() の D8 二相 teardown と同じ手順を踏む。
  Future<void> share(String flowId) async {
    final tracker = ref.read(normalPlayerSessionTrackerProvider);
    final ticket = await tracker.prepareForRemoval(flowId: flowId);
    try {
      if (ticket.representsCurrentPlayer &&
          !ticket.stopOutcome.ttsStopConfirmed) {
        return;
      }
      if (!mounted) return;
      tracker.removeActivePlayerNow(ticket, context: context);

      final previousCovering = _activeCoveringRoute;
      if (previousCovering != null && previousCovering.isActive) {
        Navigator.of(context).removeRoute(previousCovering);
        if (identical(_activeCoveringRoute, previousCovering)) {
          _activeCoveringRoute = null;
        }
      }
      final coveringRoute = MaterialPageRoute<void>(
        builder: (_) => _CoveringScreen(flowId: flowId),
      );
      _activeCoveringRoute = coveringRoute;
      unawaited(Navigator.of(context).push(coveringRoute).then((_) {
        if (identical(_activeCoveringRoute, coveringRoute)) {
          _activeCoveringRoute = null;
        }
      }));
    } finally {
      tracker.abandonRemoval(ticket);
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('HOME_MARKER')));
  }
}

class _CoveringScreen extends StatelessWidget {
  const _CoveringScreen({required this.flowId});
  final String flowId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('COVERING_MARKER'),
        ),
      ),
    );
  }
}

class _FakeTtsService implements TtsService {
  int stopCallCount = 0;
  dynamic Function()? stopBehavior;

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
  Future<void> stop() async {
    stopCallCount++;
    final behavior = stopBehavior;
    if (behavior != null) {
      final result = behavior();
      if (result is Future) await result;
    }
  }

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async => [];

  @override
  Future<void> dispose() async {}
}

class _FakeContentRepository implements ContentRepository {
  final Map<String, Content> _store = {};

  @override
  Future<Content?> getById(String id) async => _store[id] ??=
      Content(id: id, title: 't', body: 'body', sourceType: 'text');

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
