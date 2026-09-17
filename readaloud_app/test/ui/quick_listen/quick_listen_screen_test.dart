import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/quick_listen_session.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/ui/quick_listen/quick_listen_screen.dart';
import 'package:readaloud_app/usecase/content/library_promotion_service.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/usecase/playback/playback_defaults_reader.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/viewmodel/quick_listen_viewmodel.dart';

// Shared Player Core Slice 5: Transient 画面
// T-L1（lifecycle）/ T-L2（terminal close: × / system back）/ PD-2 / PD-3
void main() {
  late _RecordingTts tts;
  late _RecordingFence fence;
  late SharedPlaybackTransport transport;

  setUp(() {
    DebugLogger.testSink = [];
    tts = _RecordingTts();
    fence = _RecordingFence();
    transport = SharedPlaybackTransport(
      tts: tts,
      positionStream: const Stream.empty(),
      currentPosition: () => 0,
      resumeFence: fence,
    );
  });

  tearDown(() {
    DebugLogger.testSink = null;
    transport.dispose();
  });

  Future<void> pumpApp(WidgetTester tester, {PlaybackRequest? request}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          quickListenViewModelProvider.overrideWith((ref) => _TestVm(
                transport: transport,
                defaultsReader: _FakeDefaults(),
                promotion: LibraryPromotionService(
                  saveContent: SaveContentUseCase(_NoopContentRepository()),
                  playbackRepo: _ThrowingPlaybackRepository(),
                  defaultsReader: _FakeDefaults(),
                ),
              )),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => QuickListenScreen(
                        initialText:
                            request == null ? '共有された本文です。続きの文章。' : null,
                        initialRequest: request,
                      ),
                    ),
                  ),
                  child: const Text('HOME_MARKER'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('HOME_MARKER'));
    await tester.pumpAndSettle();
    expect(find.byType(QuickListenScreen), findsOneWidget);
  }

  QuickListenState vmState(WidgetTester tester) {
    final container = ProviderScope.containerOf(
        tester.element(find.byType(QuickListenScreen)));
    return container.read(quickListenViewModelProvider);
  }

  testWidgets(
      'PD-2: 再生/一時停止・先頭から・Libraryに保存・×のみ表示し、'
      '速度/巻戻し/早送り/末尾/停止は表示しない。PD-3: Quick Listenを見出しにしない', (tester) async {
    await pumpApp(tester);

    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.text('Libraryに保存'), findsOneWidget);
    for (final icon in [
      Icons.replay_10,
      Icons.forward_10,
      Icons.skip_next,
      Icons.stop,
      Icons.bookmark_add,
    ]) {
      expect(find.byIcon(icon), findsNothing, reason: '$icon');
    }
    expect(find.text('1.5x'), findsNothing);
    expect(find.text('Quick Listen'), findsNothing);
    expect(find.text('共有された本文です。続きの文章。'), findsWidgets,
        reason: 'Sourceタイトルが無い場合は既存の自動タイトル（本文先頭30文字）');
  });

  testWidgets('PD-3: Sourceタイトルがあれば見出しに表示する', (tester) async {
    await pumpApp(
      tester,
      request: PlaybackRequest(
        target: const TransientTarget(),
        text: '本文',
        title: 'Sourceのタイトル',
        startPosition: 0,
        source: const SourceDescriptor(sourceType: 'share'),
      ),
    );
    expect(find.text('Sourceのタイトル'), findsOneWidget);
  });

  testWidgets('T-L1: lifecycle paused/resumed ではcontroller状態は不変でstopされない',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(vmState(tester).isPlaying, isTrue);
    tts.calls.clear();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(tts.calls, isEmpty);
    expect(vmState(tester).isPlaying, isTrue);
    expect(vmState(tester).session, isNotNull);
  });

  testWidgets(
      'T-L2: ×でowner-safe teardown（stop + fence clearIfNoLiveOwner）→ '
      'state破棄 → route pop', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.byType(QuickListenScreen), findsNothing);
    expect(find.text('HOME_MARKER'), findsOneWidget);
    expect(tts.calls.last, 'stop');
    expect(fence.calls, [NotificationDisposition.clearIfNoLiveOwner]);
    expect(transport.activeOwner, isNull);
  });

  testWidgets('T-L2: system back（PopScope）も同じterminal closeへ集約される（F-D解消）',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(QuickListenScreen), findsNothing);
    expect(tts.calls.last, 'stop');
    expect(fence.calls, [NotificationDisposition.clearIfNoLiveOwner]);
  });

  testWidgets('T-L2: TTS stopが失敗してもrouteは閉じる', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    tts.failStop = true;

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.byType(QuickListenScreen), findsNothing);
  });

  testWidgets('先頭からボタンと本文タップがTransient seekへ配線されている', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    tts.calls.clear();

    await tester.tap(find.byIcon(Icons.skip_previous));
    await tester.pumpAndSettle();
    expect(tts.calls, ['stop', 'speak:0']);
  });
}

/// QuickListenScreen.initState() の同期 start() は widget test 環境でのみ
/// Riverpod の build 中変更検知に掛かるため、既存 navigation test と同じく
/// start の state 反映だけを1 microtask 遅延させる。
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

class _RecordingTts implements TtsService {
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
      calls.add('speak:$startPosition');

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

class _RecordingFence implements PlaybackResumeFence {
  final List<NotificationDisposition> calls = [];

  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async =>
      calls.add(notificationDisposition);
}

class _NoopContentRepository implements ContentRepository {
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

class _ThrowingPlaybackRepository implements PlaybackRepository {
  Never _fail() => throw StateError('Transient再生操作はPlaybackRepositoryへ到達しない');

  @override
  Future<PlaybackState?> getByContentId(String contentId) async => _fail();

  @override
  Future<void> save(PlaybackState state) async => _fail();

  @override
  Future<void> resetAbRepeat(String contentId) async => _fail();

  @override
  Future<void> resetAllAbRepeat() async => _fail();

  @override
  Future<void> delete(String contentId) async => _fail();
}
