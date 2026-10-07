import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/ui/quick_listen/quick_listen_screen.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/usecase/content/library_promotion_service.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/usecase/playback/playback_defaults_reader.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/quick_listen_route_tracker.dart';
import 'package:readaloud_app/viewmodel/quick_listen_viewmodel.dart';

// このテストは実機で観測されたQuick Listen route accumulation
// （QuickListen Aをcloseしないまま新しいtext share Bが届き、Bをcloseすると
// 空になったAが再露出する）をそのまま再現する回帰テスト。
//
// main.dartの_AppEntryPointState._handleSharedPayload()は
// ShareIntentHandler(flutter_sharing_intentプラグイン直結、テストからは
// 差し替え不能)経由でしか駆動できないため、実際に修正対象となった
// QuickListenRouteTracker（main.dartが使っているものと同一のクラス）を
// このテスト用のharness Widgetから直接駆動する。新しい共有は実機では
// 「その時前面にあるどの画面の上にも」届きうるため、ボタンtapではなく
// GlobalKey経由でshare()を直接呼び出す（前面のQuickListenScreenに隠れた
// ボタンをtapできない、という問題を避けるため）。
//
// 注記（RA-QL-LIFECYCLE-FIX-01）: 以前はここで「flutter_riverpod 2.6.1は
// widget test環境でのみ『Tried to modify a provider while the widget tree
// was building』を検知する（実機では発生しない）」として、start()の
// 実際のstate反映を1 microtask遅延させるテスト専用のQuickListenViewModel
// サブクラスで回避していた。実機Device Acceptanceでこの前提が誤りだと
// 判明した（実機でも発生するpre-existing defectだった）ため、本番側を修正
// （sessionのstart()を`QuickListenRouteTracker.openTransient()`がpushより
// 前・widget treeの外で行うよう変更）し、ここでは本物の
// `QuickListenViewModel`をそのまま使う（サブクラスは廃止）。
void main() {
  setUp(() {
    DebugLogger.testSink = [];
  });

  tearDown(() {
    DebugLogger.testSink = null;
  });

  testWidgets(
    'QuickListen Aをcloseしないまま新しいshare Bが届いてBをcloseしても、'
    'Aの空画面は再出現せずHomeへ戻る',
    (tester) async {
      final harnessKey = GlobalKey<_QuickListenNavHarnessState>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            quickListenViewModelProvider
                .overrideWith((ref) => _buildTestViewModel()),
          ],
          child: MaterialApp(home: _QuickListenNavHarness(key: harnessKey)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('HOME_MARKER'), findsOneWidget);
      expect(
        find.byType(QuickListenScreen, skipOffstage: false),
        findsNothing,
      );

      // text share A → QuickListen A表示
      await harnessKey.currentState!.share('共有された本文A');
      await tester.pumpAndSettle();
      expect(
        find.byType(QuickListenScreen, skipOffstage: false),
        findsOneWidget,
      );

      // Aをcloseしないまま、別アプリからtext share Bが届く
      await harnessKey.currentState!.share('共有された本文B');
      await tester.pumpAndSettle();
      // 修正前はAが残ったままBが積まれて2件になり、ここで失敗する。
      // 修正後はAが除去されBのみが残るため1件。
      expect(
        find.byType(QuickListenScreen, skipOffstage: false),
        findsOneWidget,
      );

      // Bを×でclose
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      // 「Bを閉じるとAの空画面が再出現しない」ことを直接検証する。
      expect(
        find.byType(QuickListenScreen, skipOffstage: false),
        findsNothing,
      );
      expect(find.text('HOME_MARKER'), findsOneWidget);
    },
  );

  testWidgets(
    'QuickListen A→share B→share Cと連続しても、offstage込みでQuickListen '
    'routeは常に最大1件のまま',
    (tester) async {
      final harnessKey = GlobalKey<_QuickListenNavHarnessState>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            quickListenViewModelProvider
                .overrideWith((ref) => _buildTestViewModel()),
          ],
          child: MaterialApp(home: _QuickListenNavHarness(key: harnessKey)),
        ),
      );
      await tester.pumpAndSettle();

      for (final text in ['共有された本文A', '共有された本文B', '共有された本文C']) {
        await harnessKey.currentState!.share(text);
        await tester.pumpAndSettle();
        expect(
          find.byType(QuickListenScreen, skipOffstage: false),
          findsOneWidget,
          reason: '"$text"共有後もQuickListen routeは1件のままであるべき',
        );
      }
    },
  );

  testWidgets(
    'QuickListen Aを閉じずにURL共有相当が来てAddScreen相当routeへ分岐しても、'
    'それをcloseした後にQuickListenScreenが再出現しない',
    (tester) async {
      final harnessKey = GlobalKey<_QuickListenNavHarnessState>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            quickListenViewModelProvider
                .overrideWith((ref) => _buildTestViewModel()),
          ],
          child: MaterialApp(home: _QuickListenNavHarness(key: harnessKey)),
        ),
      );
      await tester.pumpAndSettle();

      // QuickListen A
      await harnessKey.currentState!.share('共有された本文A');
      await tester.pumpAndSettle();
      expect(
        find.byType(QuickListenScreen, skipOffstage: false),
        findsOneWidget,
      );

      // Aを閉じないまま、別アプリからURL共有相当が届く
      // （main.dart _handleSharedPayload()のURL分岐: close() →
      // 追跡中QuickListen routeの除去 → AddScreen push、を再現）。
      await harnessKey.currentState!.shareUrlEquivalent();
      await tester.pumpAndSettle();

      // 旧QuickListen route(A)は、URL分岐でも同じroute accumulation根因の
      // ため残ってはならない（修正前はここでまだ1件見つかり失敗する）。
      expect(
        find.byType(QuickListenScreen, skipOffstage: false),
        findsNothing,
      );
      expect(find.text('ADD_SCREEN_MARKER'), findsOneWidget);

      // AddScreen相当をclose
      await tester.tap(find.text('ADD_SCREEN_MARKER'));
      await tester.pumpAndSettle();

      // QuickListenScreenが再出現せず、Homeへ戻ることを確認する。
      expect(
        find.byType(QuickListenScreen, skipOffstage: false),
        findsNothing,
      );
      expect(find.text('HOME_MARKER'), findsOneWidget);
    },
  );

  testWidgets(
      'No.94 Observability: QuickListen push後、最初のframe後にquick_listen_route_'
      'visibilityがisCurrent=true/isActive=trueで1回記録される', (tester) async {
    final harnessKey = GlobalKey<_QuickListenNavHarnessState>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          quickListenViewModelProvider.overrideWith((ref) => _buildTestViewModel()),
        ],
        child: MaterialApp(home: _QuickListenNavHarness(key: harnessKey)),
      ),
    );
    await tester.pumpAndSettle();

    await harnessKey.currentState!.share('共有された本文A');
    await tester.pumpAndSettle();

    final visibilityLines = DebugLogger.testSink!
        .where((l) => l.contains('event=quick_listen_route_visibility'))
        .toList();

    expect(visibilityLines, hasLength(1));
    expect(visibilityLines.single, contains('isCurrent=true'));
    expect(visibilityLines.single, contains('isActive=true'));
  });
}

QuickListenViewModel _buildTestViewModel() {
  final settingsRepo = _FakeSettingsRepository();
  return QuickListenViewModel(
    transport: SharedPlaybackTransport(
      tts: _FakeTtsService(),
      positionStream: const Stream.empty(),
      currentPosition: () => 0,
      resumeFence: _NoopResumeFence(),
    ),
    defaultsReader: SettingsPlaybackDefaultsReader(settingsRepo),
    promotion: _promotion(_FakeContentRepository(), settingsRepo),
  );
}

class _NoopResumeFence implements PlaybackResumeFence {
  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async {}
}

class _QuickListenNavHarness extends ConsumerStatefulWidget {
  const _QuickListenNavHarness({super.key});

  @override
  ConsumerState<_QuickListenNavHarness> createState() =>
      _QuickListenNavHarnessState();
}

class _QuickListenNavHarnessState
    extends ConsumerState<_QuickListenNavHarness> {
  final QuickListenRouteTracker tracker = QuickListenRouteTracker();
  int _flowSeq = 0;

  // main.dart _handleSharedPayload()の非URL分岐（close→
  // removeActiveQuickListen→openQuickListen）と同じ手順をそのまま踏む。
  Future<void> share(String text) async {
    await ref.read(quickListenViewModelProvider.notifier).close();
    if (!mounted) return;
    tracker.removeActiveQuickListen(
      context: context,
      flowId: 'test-flow-${++_flowSeq}',
    );
    tracker.openQuickListen(
      context: context,
      text: text,
      flowId: 'test-flow-$_flowSeq',
    );
  }

  // main.dart _handleSharedPayload()のURL分岐（close→
  // removeActiveQuickListen→AddScreen push）と同じ手順をそのまま踏む。
  // 実AddScreenの詳細機能は不要なため、marker付きの最小Widgetで代替する。
  Future<void> shareUrlEquivalent() async {
    await ref.read(quickListenViewModelProvider.notifier).close();
    if (!mounted) return;
    tracker.removeActiveQuickListen(
      context: context,
      flowId: 'test-flow-${++_flowSeq}',
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const _FakeAddScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('HOME_MARKER')));
  }
}

/// main.dartのAddScreen pushを模した最小の代替Widget。
/// 実AddScreenの機能はテスト対象外のため、marker Textとcloseボタンのみ持つ。
class _FakeAddScreen extends StatelessWidget {
  const _FakeAddScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('ADD_SCREEN_MARKER'),
        ),
      ),
    );
  }
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

class _FakeContentRepository implements ContentRepository {
  @override
  Future<void> save(Content content) async {}

  @override
  Future<List<Content>> getAll() async => [];

  @override
  Future<List<Content>> getByStatus(String status) async => [];

  @override
  Future<Content?> getById(String id) async => null;

  @override
  Future<void> update(Content content) async {}

  @override
  Future<void> delete(String id) async {}
}

/// Shared Player Core Slice 7a: 保存は LibraryPromotionService 経由（構築変更のみ）。
LibraryPromotionService _promotion(
        ContentRepository contentRepo, SettingsRepository settingsRepo) =>
    LibraryPromotionService(
      saveContent: SaveContentUseCase(contentRepo),
      playbackRepo: _InMemoryPlaybackRepository(),
      defaultsReader: SettingsPlaybackDefaultsReader(settingsRepo),
    );

class _InMemoryPlaybackRepository implements PlaybackRepository {
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
