// RA-CC-AUTO-WT-02 / IT: UI-flow integration tests (IT-01, IT-02, IT-08,
// IT-10 double back tap, IT-11).
//
// This file (and it_harness.dart) intentionally uses ONLY APIs that exist on
// base 5986e147, so it can be copied to the base worktree to obtain
// Red/counterexample evidence (IT-02 is expected to fail on base).
//
// Real: HomeScreen / AddScreen / PlayerScreen / PlayerViewModel /
// SharedPlaybackTransport / NormalPlayerPlaybackGate.shared /
// NormalPlayerSessionTracker / SavePlaybackStateUseCase / ContentListViewModel.
// Fakes: TTS service, audio handler, repositories, settings.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/ui/add/add_screen.dart';
import 'package:readaloud_app/ui/home/home_screen.dart';
import 'package:readaloud_app/ui/home/widgets/content_card.dart';
import 'package:readaloud_app/ui/player/player_screen.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';

import 'it_harness.dart';

int _commits() => (DebugLogger.testSink ?? const <String>[])
    .where((l) => l.contains('content_list_load_commit'))
    .length;

Content _existing(String id, {String status = 'in_progress'}) => Content(
    id: id,
    title: 'title-$id',
    body: itBody,
    sourceType: 'text',
    status: status);

Finder _card(String id) =>
    find.byWidgetPredicate((w) => w is ContentCard && w.content.id == id);

void main() {
  setUp(() => DebugLogger.testSink = []);
  tearDown(() => DebugLogger.testSink = null);

  testWidgets(
      'IT-01 (P4 regression): Add(1000字)->autoPlay->pos300->Stop->AppBar back: '
      'DB / progressMap / ContentCard / status すべて30%・in_progress',
      (tester) async {
    final env = await pumpHome(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(AddScreen), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, itBody);
    await tester.pump();
    await tester.tap(find.text('読み上げる'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);

    final saved = (await env.contentRepo.getAll()).single;
    final id = saved.id;
    expect(saved.body.length, 1000);

    env.emit(const TtsPlaybackPosition(
        charPosition: 300, isPlaying: true, ttsStatus: TtsStatus.playing));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    final db = await env.playbackRepo.getByContentId(id);
    expect(db, isNotNull);
    expect(db!.progressPct, closeTo(30.0, 0.001), reason: 'DB layer');
    final list = env.container.read(contentListViewModelProvider);
    expect(list.progressMap[id], closeTo(30.0, 0.001), reason: 'progressMap');
    final card = tester.widget<ContentCard>(find.byType(ContentCard));
    expect(card.progressPct, closeTo(30.0, 0.001), reason: 'ContentCard');
    expect(card.content.status, 'in_progress', reason: 'list status');
    expect((await env.contentRepo.getById(id))!.status, 'in_progress',
        reason: 'DB status');
  });

  testWidgets(
      'IT-02 (P10): Home既存->play->pos500->AppBar backのみ(stop保存をbarrierで保留): '
      '保留中はPlayerがcurrent routeのまま・reload無し。解放後にpop、list pct=DB=50',
      (tester) async {
    final env = await pumpHome(tester, seedContents: [
      _existing('e1')
    ], seedPlayback: [
      PlaybackState(contentId: 'e1', position: 100, progressPct: 10),
    ]);
    expect(env.container.read(contentListViewModelProvider).progressMap['e1'],
        closeTo(10, 0.001));

    await tester.tap(find.byType(ContentCard));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    env.emit(const TtsPlaybackPosition(
        charPosition: 500, isPlaying: true, ttsStatus: TtsStatus.playing));
    await tester.pump();

    // stopの保存(persistStopPosition)をバリアで保留する。
    final barrier = Completer<void>();
    env.playbackRepo.saveBarrier = barrier;
    final commitsBefore = _commits();
    final readsBefore = env.contentRepo.getAllCalls;

    await tester
        .tap(find.byIcon(Icons.arrow_back)); // AppBar back のみ(Stopは押さない)
    for (var i = 0; i < 10; i++) {
      await tester
          .pump(const Duration(milliseconds: 100)); // 1s: pop animation 十分超過
    }

    // (a) 保留中: Playerは存在するだけでなく current route であること。
    expect(find.byType(PlayerScreen, skipOffstage: false), findsOneWidget,
        reason: 'barrier保留中にPlayerルートが消えている(popが保存完了より先)');
    final ctx = tester.element(find.byType(PlayerScreen, skipOffstage: false));
    expect(ModalRoute.of(ctx)!.isCurrent, isTrue,
        reason: 'barrier保留中にPlayerがcurrent routeでない');
    // (b) 保留中: Home reload(content_list_load_commit / repo.getAll)が走っていない。
    expect(_commits(), commitsBefore,
        reason: 'barrier保留中にcontent_list_load_commitが発生');
    expect(env.contentRepo.getAllCalls, readsBefore,
        reason: 'barrier保留中にlist readが発生(stale読み)');

    barrier.complete();
    env.playbackRepo.saveBarrier = null;
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(_commits(), greaterThan(commitsBefore), reason: '解放後にreloadされる');
    final db = await env.playbackRepo.getByContentId('e1');
    expect(db!.progressPct, closeTo(50.0, 0.001), reason: 'DB=500/1000');
    final list = env.container.read(contentListViewModelProvider);
    expect(list.progressMap['e1'], closeTo(50.0, 0.001), reason: 'list=DB');
    expect(tester.widget<ContentCard>(find.byType(ContentCard)).progressPct,
        closeTo(50.0, 0.001));
  });

  testWidgets(
      'IT-08 (System Back): 再生中にAndroid system back(handlePopRoute): '
      'stop呼ばれず・Transport ownerは継続・routeはpop・list reloadがDBを読む',
      (tester) async {
    final env = await pumpHome(tester, seedContents: [
      _existing('e1')
    ], seedPlayback: [
      PlaybackState(contentId: 'e1', position: 100, progressPct: 10),
    ]);
    await tester.tap(find.byType(ContentCard));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    env.emit(const TtsPlaybackPosition(
        charPosition: 500, isPlaying: true, ttsStatus: TtsStatus.playing));
    await tester.pump();

    final ownerBefore = env.transport.activeOwner;
    expect(ownerBefore, isNotNull);
    final sessionId = env.tracker.currentSession!.id;
    final stopsBefore = env.tts.stopCount;
    final savesBefore = env.playbackRepo.saveCalls;
    final commitsBefore = _commits();
    final readsBefore = env.contentRepo.getAllCalls;

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(handled, isTrue, reason: 'system backがNavigatorで処理された');
    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing,
        reason: 'route popped');
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(env.tts.stopCount, stopsBefore, reason: 'TTS stopは呼ばれない');
    expect(env.transport.activeOwner, ownerBefore,
        reason: 'Transport ownerは維持(背景再生継続)');
    expect(env.playbackRepo.saveCalls, savesBefore, reason: 'stop保存は走らない');
    expect(_commits(), greaterThan(commitsBefore),
        reason: 'list reload commit');
    expect(env.contentRepo.getAllCalls, greaterThan(readsBefore),
        reason: 'reloadがDB(repo)を読む');
    expect(tester.takeException(), isNull);

    // 後始末(oracle判定後): 背景継続中のusage periodic timerを止めて
    // 'Timer is still pending' のharness違反を避ける。
    await env.core.gate
        .stopForSession(sessionId: sessionId, contentId: 'e1', position: 500);
    await tester.pump();
  });

  testWidgets(
      'IT-10 (double back tap): barrier保留中にAppBar backを2連打: '
      'stop保存1回・pop1回・Homeは残る・例外なし', (tester) async {
    final env = await pumpHome(tester, seedContents: [
      _existing('e1')
    ], seedPlayback: [
      PlaybackState(contentId: 'e1', position: 100, progressPct: 10),
    ]);
    await tester.tap(find.byType(ContentCard));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    env.emit(const TtsPlaybackPosition(
        charPosition: 500, isPlaying: true, ttsStatus: TtsStatus.playing));
    await tester.pump();

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
    expect(find.byType(HomeScreen), findsOneWidget, reason: '二重popでHomeが消えない');
    expect(env.playbackRepo.saveCalls - savesBefore, 1, reason: 'stop保存は1回だけ');
  });

  testWidgets(
      'IT-11 (P2/P3 baseline): completed/in_progressの既存表示が不変。'
      'completedを開いて戻っても降格・書込みなし', (tester) async {
    final env = await pumpHome(tester, seedContents: [
      _existing('done', status: 'completed'),
      _existing('prog'),
    ], seedPlayback: [
      PlaybackState(contentId: 'done', position: 1000, progressPct: 100),
      PlaybackState(contentId: 'prog', position: 400, progressPct: 40),
    ]);

    ContentCard cardOf(String id) => tester.widget<ContentCard>(_card(id));
    expect(cardOf('done').progressPct, closeTo(100, 0.001));
    expect(cardOf('done').content.status, 'completed');
    expect(cardOf('prog').progressPct, closeTo(40, 0.001));
    expect(cardOf('prog').content.status, 'in_progress');

    await tester.tap(_card('done'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);

    expect(cardOf('done').progressPct, closeTo(100, 0.001));
    expect(cardOf('done').content.status, 'completed',
        reason: 'completedは降格されない');
    expect(cardOf('prog').progressPct, closeTo(40, 0.001));
    expect(cardOf('prog').content.status, 'in_progress');
    expect((await env.contentRepo.getById('done'))!.status, 'completed');
    expect(env.playbackRepo.store['done']!.progressPct, 100.0);
    expect(env.playbackRepo.saves, isEmpty, reason: '再生していないので書込みなし');
  });
}
