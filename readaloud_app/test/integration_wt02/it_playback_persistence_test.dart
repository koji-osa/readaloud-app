// RA-CC-AUTO-WT-02 / IT: playback-persistence integration tests
// (IT-04 P5, IT-05 P6, IT-06 stale owner, IT-07 interleave, IT-09 Transient,
// IT-10 fail-closed).
//
// Uses NEW APIs (TtsPlaybackPosition.isNaturalCompletion,
// NormalPlayerPlaybackGate.shared(checkpointInterval:, clock:)), so this file
// does not compile on base 5986e147.
//
// IT-03 (R-01) is NOT_TESTED: REQ-034 builds TableAnalysisService inside
// PlayerScreen (secure storage + network); no production seam may be added.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/ui/home/home_screen.dart';
import 'package:readaloud_app/ui/home/widgets/content_card.dart';
import 'package:readaloud_app/ui/player/player_screen.dart';
import 'package:readaloud_app/usecase/playback/playback_usage_accounting.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';

import 'it_harness.dart';

const _interval = Duration(seconds: 30);

/// Mutable fake clock for the P6 checkpoint scheduler.
class _Clock {
  DateTime now = DateTime(2026, 1, 1);
  void advance(Duration d) => now = now.add(d);
}

GateBuilder _gateWith(_Clock c) => (d) => NormalPlayerPlaybackGate.shared(
      transport: d.transport,
      resolver: d.resolver,
      playbackRepo: d.playbackRepo,
      savePlaybackState: d.savePlaybackState,
      accounting: d.accounting,
      checkpointInterval: _interval,
      clock: () => c.now,
    );

const _completion1000 = TtsPlaybackPosition(
    charPosition: 1000,
    isPlaying: false,
    ttsStatus: TtsStatus.stopped,
    isNaturalCompletion: true);

Content _existing(String id) =>
    Content(id: id, title: 'title-$id', body: itBody, sourceType: 'text');

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

/// Home -> card -> play, with position events flowing.
Future<ItEnv> _openPlaying(WidgetTester tester, _Clock clock,
    {int startPos = 300, List<PlaybackState> seed = const []}) async {
  final env = await pumpHome(tester,
      seedContents: [_existing('e1')],
      seedPlayback: seed,
      gateBuilder: _gateWith(clock));
  await tester.tap(find.byType(ContentCard));
  await tester.pumpAndSettle();
  expect(find.byType(PlayerScreen), findsOneWidget);
  await tester.tap(find.byIcon(Icons.play_arrow));
  await tester.pump();
  env.emitPlaying(startPos);
  await _flush(tester);
  return env;
}

void main() {
  setUp(() => DebugLogger.testSink = []);
  tearDown(() => DebugLogger.testSink = null);

  // ---------------------------------------------------------------- IT-04
  testWidgets(
      'IT-04 (P5): PlayerScreen+Home。自然終了eventでDB=本文長/100%/completed、'
      'usage 1回flush、owner clear。その後のstop/AppBar backで100%が下がらず、'
      '一覧も100%/completed', (tester) async {
    final clock = _Clock();
    final env = await _openPlaying(tester, clock);
    expect(env.transport.activeOwner, isNotNull);
    final savesBefore = env.playbackRepo.saves.length;

    env.emit(_completion1000);
    await _flush(tester);

    final db = env.playbackRepo.store['e1']!;
    expect(db.position, 1000, reason: 'DB position = body length');
    expect(db.progressPct, 100.0);
    expect((await env.contentRepo.getById('e1'))!.status, 'completed');
    expect(env.playbackRepo.saves.length - savesBefore, 1, reason: '完了書込みは1回');
    expect(await env.settingsRepo.get('tts_used_chars'), '1000',
        reason: 'usageは1回だけflush(0->1000)');
    expect(env.transport.activeOwner, isNull,
        reason: 'Transport owner cleared');
    final savesAfterCompletion = env.playbackRepo.saves.length;
    final stopsAfterCompletion = env.tts.stopCount;

    // 完了後にユーザーが Stop -> AppBar back しても 100% は下がらない。
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(env.playbackRepo.saves.length, savesAfterCompletion,
        reason: '後続stop/backは追加書込みしない(100%を下げない)');
    expect(env.tts.stopCount, stopsAfterCompletion,
        reason: 'owner clear後のstopはTTSに触れない');
    expect(await env.settingsRepo.get('tts_used_chars'), '1000',
        reason: 'usage二重加算なし');
    expect(env.playbackRepo.store['e1']!.progressPct, 100.0);
    expect(env.container.read(contentListViewModelProvider).progressMap['e1'],
        closeTo(100.0, 0.001));
    final card = tester.widget<ContentCard>(find.byType(ContentCard));
    expect(card.progressPct, closeTo(100.0, 0.001));
    expect(card.content.status, 'completed');
  });

  // ---------------------------------------------------------------- IT-05
  testWidgets(
      'IT-05 (P6): 65秒再生(5秒刻み)で30秒cadenceのcheckpointが2回、'
      'DB位置=最後のcheckpoint位置(600)。再起動相当のresolverがその位置から開始。'
      'pause中はcheckpointしない', (tester) async {
    final clock = _Clock();
    final env = await _openPlaying(tester, clock);
    final base = env.playbackRepo.saves.length;

    for (var i = 1; i <= 13; i++) {
      clock.advance(const Duration(seconds: 5));
      env.emitPlaying(300 + 25 * i);
      await _flush(tester);
    }
    // t=30(pos 450) と t=60(pos 600) で保存。t=65(pos 625) は未保存。
    expect(env.playbackRepo.saves.length - base, 2,
        reason: '65秒で checkpoint は2回(rate限定)');
    expect(env.playbackRepo.saves.map((s) => s.$2).skip(base).toList(),
        [450, 600]);
    final db = env.playbackRepo.store['e1']!;
    expect(db.position, 600);
    expect(db.progressPct, closeTo(60.0, 0.001));
    expect((await env.contentRepo.getById('e1'))!.status, isNot('completed'));

    // 再起動相当: 新しいresolverは最後のcheckpoint位置から開始する。
    final req = await env.core.resolver.resolveForStart('e1');
    expect(req.startPosition, 600);

    // pause: pause保存(既存)のみ。pause中の長時間・event到達でcheckpointしない。
    await tester.tap(find.byIcon(Icons.pause));
    await _flush(tester);
    final afterPause = env.playbackRepo.saves.length;
    clock.advance(const Duration(seconds: 120));
    env.emit(const TtsPlaybackPosition(
        charPosition: 640, isPlaying: false, ttsStatus: TtsStatus.paused));
    await _flush(tester);
    clock.advance(const Duration(seconds: 120));
    env.emit(const TtsPlaybackPosition(
        charPosition: 650, isPlaying: false, ttsStatus: TtsStatus.paused));
    await _flush(tester);
    expect(env.playbackRepo.saves.length, afterPause,
        reason: 'pause中はcheckpointしない');
    await tester.tap(find.byIcon(Icons.stop)); // 後始末(usage timer停止)
    await tester.pumpAndSettle();
  });

  // ---------------------------------------------------------------- IT-06
  group('IT-06 stale owner', () {
    test('完了op予約後に新session Bがstart: Aの完了は無視され、B/usageに影響しない', () async {
      final clock = _Clock();
      final core = ItCore(gateBuilder: _gateWith(clock));
      addTearDown(core.dispose);
      core.addContent('c1', 1000);
      core.addContent('c2', 500);
      await core.gate.start(sessionId: 'A', contentId: 'c1');
      core.emitPlaying(300);
      await settle();
      core.playbackRepo.store['c1'] =
          PlaybackState(contentId: 'c1', position: 300, progressPct: 30.0);
      final savesBefore = core.playbackRepo.saves.length;

      core.emit(_completion1000); // opはmicrotask予約のみ
      await core.gate.start(sessionId: 'B', contentId: 'c2');
      final usageAfterBStart = await core.usedChars();
      await settle();

      expect(core.playbackRepo.store['c1']!.progressPct, 30.0);
      expect(core.contentRepo.store['c1']!.status, isNot('completed'));
      expect(core.playbackRepo.store['c2'], isNull);
      expect(core.contentRepo.store['c2']!.status, isNot('completed'));
      expect(core.transport.activeOwner, PlaybackOwnerKey.normalPlayer('B'));
      expect(core.playbackRepo.saves.length, savesBefore, reason: 'A由来の書込みなし');
      expect(await core.usedChars(), usageAfterBStart,
          reason: 'A完了opがusageを動かさない');
    });

    test('checkpoint予約後に新session Bがstart: c1もc2も書かない', () async {
      final clock = _Clock();
      final core = ItCore(gateBuilder: _gateWith(clock));
      addTearDown(core.dispose);
      core.addContent('c1', 1000);
      core.addContent('c2', 500);
      await core.gate.start(sessionId: 'A', contentId: 'c1');
      core.emitPlaying(300);
      await settle();
      core.playbackRepo.store['c1'] =
          PlaybackState(contentId: 'c1', position: 300, progressPct: 30.0);
      final savesBefore = core.playbackRepo.saves.length;

      clock.advance(_interval);
      core.emitPlaying(450); // checkpoint予約のみ
      await core.gate.start(sessionId: 'B', contentId: 'c2');
      await settle();

      expect(core.playbackRepo.store['c1']!.position, 300);
      expect(core.playbackRepo.store['c2'], isNull);
      expect(core.playbackRepo.saves.length, savesBefore);
      expect(core.transport.activeOwner, PlaybackOwnerKey.normalPlayer('B'));
    });
  });

  // ---------------------------------------------------------------- IT-07
  group('IT-07 interleave', () {
    test('pending checkpoint vs pause/stop: 最終DBはユーザー操作の結果', () async {
      for (final op in ['pause', 'stop']) {
        final clock = _Clock();
        final core = ItCore(gateBuilder: _gateWith(clock));
        core.addContent('c1', 1000);
        await core.gate.start(sessionId: 'S', contentId: 'c1');
        core.emitPlaying(300);
        await settle();

        clock.advance(_interval);
        core.emitPlaying(450); // checkpoint 予約
        if (op == 'pause') {
          await core.gate.pause(sessionId: 'S', contentId: 'c1', position: 333);
        } else {
          await core.gate
              .stopForSession(sessionId: 'S', contentId: 'c1', position: 333);
        }
        await settle();

        expect(core.playbackRepo.store['c1']!.position, 333,
            reason: '$op の結果が最終(古いcheckpoint450で上書きされない)');
        await core.dispose();
      }
    });

    test('pending checkpoint vs seek相当(stop+直接保存): 最終は直接保存', () async {
      final clock = _Clock();
      final core = ItCore(gateBuilder: _gateWith(clock));
      addTearDown(core.dispose);
      core.addContent('c1', 1000);
      await core.gate.start(sessionId: 'S', contentId: 'c1');
      core.emitPlaying(300);
      await settle();

      clock.advance(_interval);
      core.emitPlaying(450);
      await core.gate
          .stopForSession(sessionId: 'S', contentId: 'c1', position: 450);
      await core.savePlayback
          .execute(contentId: 'c1', position: 120, progressPct: 12.0);
      await settle();

      expect(core.playbackRepo.store['c1']!.position, 120);
      expect(core.playbackRepo.store['c1']!.progressPct, 12.0);
    });

    test('完了後: 遅れたstop・遅れたplaying event(checkpoint)で完了が上書きされない', () async {
      final clock = _Clock();
      final core = ItCore(gateBuilder: _gateWith(clock));
      addTearDown(core.dispose);
      core.addContent('c1', 1000);
      await core.gate.start(sessionId: 'S', contentId: 'c1');
      core.emitPlaying(300);
      await settle();
      core.emit(_completion1000);
      await settle();
      final saves = core.playbackRepo.saves.length;

      await core.gate
          .stopForSession(sessionId: 'S', contentId: 'c1', position: 100);
      clock.advance(const Duration(seconds: 90));
      core.emitPlaying(900);
      await settle();

      expect(core.playbackRepo.saves.length, saves);
      expect(core.playbackRepo.store['c1']!.progressPct, 100.0);
      expect(core.contentRepo.store['c1']!.status, 'completed');
    });

    testWidgets(
        'rewind/fastForward(実PlayerViewModel)とcheckpoint: 最終DBはuser op結果',
        (tester) async {
      final clock = _Clock();
      final env = await _openPlaying(tester, clock);
      for (final icon in [Icons.replay_10, Icons.forward_10]) {
        clock.advance(_interval);
        env.emitPlaying(450 + (icon == Icons.forward_10 ? 100 : 0));
        final h = env.container.read(playerViewModelProvider).highlightPosition;
        final expected = icon == Icons.replay_10 ? h - 50 : h + 50;
        await tester.tap(find.byIcon(icon));
        await tester.pumpAndSettle();

        expect(env.playbackRepo.store['e1']!.position, expected,
            reason: '$icon の結果が最終DB(古いcheckpointではない)');
      }
      await tester.tap(find.byIcon(Icons.stop)); // 後始末(usage timer停止)
      await tester.pumpAndSettle();
    });
  });

  // ---------------------------------------------------------------- IT-09
  test(
      'IT-09 (Transient): Quick Listen相当のTransient ownerで完了+65秒再生: '
      'DB書込み0・usage不変・owner不変', () async {
    final clock = _Clock();
    final core = ItCore(gateBuilder: _gateWith(clock));
    addTearDown(core.dispose);
    core.addContent('c1', 1000);
    await core.transport.start(
      PlaybackOwnerKey.transient('Q'),
      PlaybackRequest(
          target: const TransientTarget(), text: 'x' * 1000, startPosition: 0),
      accounting: const NoUsageAccounting(),
    );
    final usageBefore = await core.usedChars();
    core.emitPlaying(100);
    await settle();
    for (var i = 1; i <= 13; i++) {
      clock.advance(const Duration(seconds: 5));
      core.emitPlaying(100 + 25 * i);
      await settle();
    }
    core.emit(_completion1000);
    await settle();

    expect(core.playbackRepo.saveCalls, 0, reason: 'DB write 0');
    expect(core.playbackRepo.store, isEmpty);
    expect(core.contentRepo.store['c1']!.status, isNot('completed'));
    expect(await core.usedChars(), usageBefore, reason: 'usage不変');
    expect(core.transport.activeOwner, PlaybackOwnerKey.transient('Q'),
        reason: 'Transient ownerは完了で変化しない');
    expect(core.tts.stopCount, 0);
  });

  // ---------------------------------------------------------------- IT-10
  group('IT-10 fail-closed', () {
    testWidgets('完了保存が例外: 例外が漏れず、DB/statusは完了前のまま、ownerはclear、back可能',
        (tester) async {
      final clock = _Clock();
      final env = await _openPlaying(tester, clock);
      final before = env.playbackRepo.store['e1'];
      final beforePos = before?.position;
      final beforePct = before?.progressPct;
      final beforeStatus = (await env.contentRepo.getById('e1'))!.status;
      env.playbackRepo.failSave = true;
      env.emit(_completion1000);
      await _flush(tester);

      expect(tester.takeException(), isNull);
      final after = env.playbackRepo.store['e1'];
      expect(after?.position, beforePos, reason: '完了前snapshotと同一(position)');
      expect(after?.progressPct, beforePct, reason: '完了前snapshotと同一(pct)');
      expect((await env.contentRepo.getById('e1'))!.status, beforeStatus,
          reason: 'status不変');
      expect(env.transport.activeOwner, isNull, reason: 'ownerはclear');

      env.playbackRepo.failSave = false;
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.widget<ContentCard>(find.byType(ContentCard)).progressPct,
          lessThan(100.0));
    });

    test('checkpoint保存が例外: 例外なし・backoff(1 interval内は再試行なし)・100%にならない',
        () async {
      final clock = _Clock();
      final core = ItCore(gateBuilder: _gateWith(clock));
      addTearDown(core.dispose);
      core.addContent('c1', 1000);
      await core.gate.start(sessionId: 'S', contentId: 'c1');
      core.emitPlaying(300);
      await settle();
      core.playbackRepo.failSave = true;
      final attemptsBefore = core.playbackRepo.saveCalls;

      clock.advance(_interval);
      core.emitPlaying(450);
      await settle();
      expect(core.playbackRepo.saveCalls - attemptsBefore, 1);
      for (var i = 1; i <= 5; i++) {
        clock.advance(const Duration(seconds: 5));
        core.emitPlaying(450 + 10 * i);
        await settle();
      }
      expect(core.playbackRepo.saveCalls - attemptsBefore, 1,
          reason: '失敗直後のbackoff(IO stormなし)');
      expect(core.playbackRepo.store, isEmpty);
      expect(core.contentRepo.store['c1']!.status, isNot('completed'));
    });

    test('本文が空 / Content欠損: 完了でも何も書かない(100%にならない)', () async {
      for (final mode in ['empty', 'missing']) {
        final core = ItCore(gateBuilder: _gateWith(_Clock()));
        core.addContent('c1', 1000);
        await core.gate.start(sessionId: 'S', contentId: 'c1');
        core.emitPlaying(300);
        await settle();
        if (mode == 'empty') {
          core.contentRepo.store['c1'] =
              Content(id: 'c1', title: 't', body: '', sourceType: 'text');
        } else {
          core.contentRepo.store.remove('c1');
        }
        final saves = core.playbackRepo.saveCalls;
        core.emit(_completion1000);
        await settle();

        expect(core.playbackRepo.saveCalls, saves, reason: '$mode: no write');
        expect(core.playbackRepo.store, isEmpty, reason: '$mode: no 100%');
        expect(core.transport.activeOwner, isNull);
        await core.dispose();
      }
    });

    test('完了eventが重複しても書込みは1回', () async {
      final core = ItCore(gateBuilder: _gateWith(_Clock()));
      addTearDown(core.dispose);
      core.addContent('c1', 1000);
      await core.gate.start(sessionId: 'S', contentId: 'c1');
      core.emitPlaying(300);
      await settle();
      final saves = core.playbackRepo.saves.length;
      core.emit(_completion1000);
      core.emit(_completion1000);
      core.emit(_completion1000);
      await settle();

      expect(core.playbackRepo.saves.length - saves, 1);
      expect(await core.usedChars(), '1000', reason: 'usage二重flushなし');
    });

    test('gate dispose時に完了op/checkpoint opが保留中: 例外なし・書込み0', () async {
      for (final kind in ['completion', 'checkpoint']) {
        final clock = _Clock();
        final core = ItCore(gateBuilder: _gateWith(clock));
        core.addContent('c1', 1000);
        await core.gate.start(sessionId: 'S', contentId: 'c1');
        core.emitPlaying(300);
        await settle();
        final saves = core.playbackRepo.saveCalls;

        if (kind == 'completion') {
          core.emit(_completion1000);
        } else {
          clock.advance(_interval);
          core.emitPlaying(450);
        }
        core.gate.dispose();
        await settle();

        expect(core.playbackRepo.saveCalls - saves, 0,
            reason: '$kind: dispose後に保留opは書込みしない');
        core.transport.dispose();
        await core.positions.close();
      }
    });
  });
}
