// RA-CC-AUTO-WT-02-CONT-01 / W2-R-03 (Human Decision A): replay after natural
// completion restarts from 0 instead of starting at body length (silent).
//
// Real Resolver / Transport / NormalPlayerPlaybackGate.shared over the
// in-memory fakes of it_harness.dart. A recording TTS captures speak() args and
// behaves like a real engine: it emits a position event only when there is
// text left to read from startPosition.
//
// IT-03 (R-01) stays NOT_TESTED: TableAnalysisService is constructed inside
// PlayerScreen (player_screen.dart), no seam without production change.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/ui/home/widgets/content_card.dart';
import 'package:readaloud_app/ui/player/player_screen.dart';
import 'package:readaloud_app/usecase/content/delete_content_usecase.dart';
import 'package:readaloud_app/usecase/content/get_all_contents_usecase.dart';
import 'package:readaloud_app/usecase/content/update_content_usecase.dart';
import 'package:readaloud_app/usecase/playback/persistent_playback_resolver.dart';
import 'package:readaloud_app/usecase/playback/playback_usage_accounting.dart';
import 'package:readaloud_app/usecase/playback/save_playback_state_usecase.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/normal_player_session_tracker.dart';
import 'package:readaloud_app/viewmodel/content_list_viewmodel.dart';

import 'it_harness.dart';

const _len = 1000;

const _completion = TtsPlaybackPosition(
    charPosition: _len,
    isPlaying: false,
    ttsStatus: TtsStatus.stopped,
    isNaturalCompletion: true);

class _Speak {
  _Speak(this.text, this.startPosition);
  final String text;
  final int startPosition;
}

/// Real-engine-like fake: records speak() and emits a first position event
/// only when startPosition < text.length (otherwise stays silent, like the
/// real engine with no chunks).
class _RecTts implements TtsService {
  _RecTts(this._emit);
  final void Function(int pos) _emit;
  final List<_Speak> speaks = [];
  int stopCount = 0;
  int pauseCount = 0;

  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async {
    speaks.add(_Speak(text, startPosition));
    if (startPosition < text.length) {
      scheduleMicrotask(() => _emit(startPosition));
    }
  }

  @override
  Future<void> pause() async => pauseCount++;

  @override
  Future<void> stop() async => stopCount++;

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async => [];

  @override
  Future<void> dispose() async {}
}

class _NoopFence implements PlaybackResumeFence {
  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async {}
}

/// Same wiring as [ItCore] but with the recording TTS.
class _Core {
  _Core() {
    tts = _RecTts(emitPlaying);
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
    gate = NormalPlayerPlaybackGate.shared(
      transport: transport,
      resolver: resolver,
      playbackRepo: playbackRepo,
      savePlaybackState: savePlayback,
      accounting: PersistentUsageAccounting(CountTtsUsageUseCase(
        settingsRepo: settingsRepo,
        checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      )),
    );
  }

  final contentRepo = ItContentRepository();
  final playbackRepo = ItPlaybackRepository();
  final settingsRepo = ItSettingsRepository();
  final StreamController<dynamic> positions =
      StreamController<dynamic>.broadcast(sync: true);
  int handlerPosition = 0;
  late final _RecTts tts;
  late final SharedPlaybackTransport transport;
  late final SavePlaybackStateUseCase savePlayback;
  late final PersistentPlaybackResolver resolver;
  late final NormalPlayerPlaybackGate gate;

  void emit(TtsPlaybackPosition p) {
    handlerPosition = p.charPosition;
    positions.add(p);
  }

  void emitPlaying(int pos) => emit(TtsPlaybackPosition(
      charPosition: pos, isPlaying: true, ttsStatus: TtsStatus.playing));

  void addContent(String id,
          {int len = _len, String status = 'unread', String? body}) =>
      contentRepo.store[id] = Content(
          id: id,
          title: 't-$id',
          body: body ?? ('x' * len),
          sourceType: 'text',
          status: status);

  Future<void> dispose() async {
    gate.dispose();
    transport.dispose();
    await positions.close();
  }
}

/// Natural completion of [id] through the real gate (session [session]).
Future<void> _completeNaturally(_Core c, String id, String session) async {
  await c.gate.start(sessionId: session, contentId: id);
  c.emitPlaying(300);
  await settle();
  c.emit(_completion);
  await settle();
}

void main() {
  setUp(() => DebugLogger.testSink = []);
  tearDown(() => DebugLogger.testSink = null);

  test('AC-W2-01: 自然終了後のplay -> speakは0から・本文非空・live positionが届く(無音でない)',
      () async {
    final c = _Core();
    addTearDown(c.dispose);
    c.addContent('c1');
    await _completeNaturally(c, 'c1', 'A');
    expect(c.playbackRepo.store['c1']!.position, _len);
    expect(c.contentRepo.store['c1']!.status, 'completed');

    final updates = <int>[];
    final sub = c.gate.liveUpdates(sessionId: 'B').listen((u) {
      if (u.isPlaying) updates.add(u.position);
    });
    addTearDown(sub.cancel);
    await c.gate.start(sessionId: 'B', contentId: 'c1');
    await settle();

    expect(c.tts.speaks.length, 2, reason: '初回+再生');
    expect(c.tts.speaks.last.startPosition, 0);
    expect(c.tts.speaks.last.text, isNotEmpty);
    expect(c.tts.speaks.last.text.length, _len);
    expect(updates, isNotEmpty, reason: 'live position event到達(無音でない)');
    expect(updates.first, 0);
    expect(c.contentRepo.store['c1']!.status, 'in_progress');
  });

  test('AC-W2-03: in_progress mid位置pはpから開始(guard)', () async {
    final c = _Core();
    addTearDown(c.dispose);
    c.addContent('c1', status: 'in_progress');
    c.playbackRepo.store['c1'] =
        PlaybackState(contentId: 'c1', position: 300, progressPct: 30.0);
    await c.gate.start(sessionId: 'S', contentId: 'c1');
    await settle();
    expect(c.tts.speaks.single.startPosition, 300);
    expect(c.tts.speaks.single.text.length, _len);
    expect(c.playbackRepo.saveCalls, 0);
    expect(c.playbackRepo.store['c1']!.position, 300);
  });

  testWidgets('AC-W2-04: 開くだけ(setContent)では completed/100% 不変・DB書込みなし・再生しない',
      (tester) async {
    final env = await pumpHome(
      tester,
      seedContents: [
        Content(
            id: 'e1',
            title: 'title-e1',
            body: itBody,
            sourceType: 'text',
            status: 'completed')
      ],
      seedPlayback: [
        PlaybackState(
            contentId: 'e1', position: itBody.length, progressPct: 100.0)
      ],
    );
    await tester.tap(find.byType(ContentCard));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);

    expect(env.playbackRepo.saveCalls, 0, reason: 'open only: DB write 0');
    expect(env.playbackRepo.store['e1']!.position, itBody.length);
    expect(env.playbackRepo.store['e1']!.progressPct, 100.0);
    expect((await env.contentRepo.getById('e1'))!.status, 'completed');
    expect(env.tts.speakCount, 0);
    expect(tester.takeException(), isNull);
  });

  group('AC-W2-05 empty body / missing content', () {
    test('本文が空: 例外なし・保存なし・本文のspeakなし', () async {
      final c = _Core();
      addTearDown(c.dispose);
      c.addContent('c1', body: '');
      Object? thrown;
      try {
        await c.gate.start(sessionId: 'S', contentId: 'c1');
      } catch (e) {
        thrown = e;
      }
      await settle();
      expect(thrown, isNull, reason: 'gate.startは空本文でも例外を漏らさない');
      expect(c.tts.speaks.where((s) => s.text.isNotEmpty), isEmpty);
      for (final s in c.tts.speaks) {
        expect(s.startPosition, 0);
      }
      expect(c.playbackRepo.saveCalls, 0, reason: 'no extra save');
      expect(c.playbackRepo.store, isEmpty);
    });

    test('Content欠損: speakなし・保存なし', () async {
      final c = _Core();
      addTearDown(c.dispose);
      Object? thrown;
      try {
        await c.gate.start(sessionId: 'S', contentId: 'missing');
      } catch (e) {
        thrown = e; // VM.play catches this (existing behavior)
      }
      await settle();
      expect(thrown, isNotNull, reason: 'resolverは既存どおり例外(VM.playがcatch)');
      expect(c.tts.speaks, isEmpty);
      expect(c.playbackRepo.saveCalls, 0);
      expect(c.playbackRepo.store, isEmpty);
      expect(c.contentRepo.store, isEmpty);
      expect(c.transport.activeOwner, isNull);
    });
  });

  test(
      'AC-W2-06: 旧session AのstopForSession/pause/teardownは replay中のB と DB を壊さない',
      () async {
    final c = _Core();
    addTearDown(c.dispose);
    c.addContent('c1');
    await _completeNaturally(c, 'c1', 'A');
    final savesAfterCompletion = c.playbackRepo.saves.length;

    await c.gate.start(sessionId: 'B', contentId: 'c1'); // replay
    await settle();
    final stopsBefore = c.tts.stopCount;
    final pausesBefore = c.tts.pauseCount;
    expect(c.transport.activeOwner, PlaybackOwnerKey.normalPlayer('B'));

    await c.gate
        .stopForSession(sessionId: 'A', contentId: 'c1', position: 1000);
    await c.gate.pause(sessionId: 'A', contentId: 'c1', position: 1000);
    await c.gate.teardownForSession(
        sessionId: 'A', contentId: 'c1', reason: TeardownReason.routeRemoval);
    await settle();

    expect(c.playbackRepo.saves.length, savesAfterCompletion,
        reason: '旧Aの操作は書込みしない');
    expect(c.playbackRepo.store['c1']!.position, _len,
        reason: '完了時のDB値のまま(Aの値で上書きもBで壊しもしない)');
    expect(c.tts.stopCount, stopsBefore, reason: 'Bの再生を止めない');
    expect(c.tts.pauseCount, pausesBefore);
    expect(c.transport.activeOwner, PlaybackOwnerKey.normalPlayer('B'));
    expect(c.contentRepo.store['c1']!.status, 'in_progress');
  });

  test(
      'AC-W2-07: 自然終了 -> play(0から) -> 途中stop q -> DB位置q・pct q/len*100・'
      'in_progress・一覧整合', () async {
    final c = _Core();
    addTearDown(c.dispose);
    c.addContent('c1');
    await _completeNaturally(c, 'c1', 'A');
    expect(c.playbackRepo.store['c1']!.progressPct, 100.0);

    await c.gate.start(sessionId: 'B', contentId: 'c1');
    await settle();
    expect(c.tts.speaks.last.startPosition, 0, reason: '0から再開');
    expect(c.handlerPosition, 0, reason: 'engineがposition 0を通知(無音でない)');

    const q = 400;
    c.emitPlaying(q);
    await settle();
    await c.gate.stopForSession(sessionId: 'B', contentId: 'c1', position: q);
    await settle();

    final db = c.playbackRepo.store['c1']!;
    expect(db.position, q);
    expect(db.progressPct, closeTo(q / _len * 100, 0.001));
    expect(c.contentRepo.store['c1']!.status, 'in_progress');

    final vm = ContentListViewModel(
      getAllContents: GetAllContentsUseCase(c.contentRepo),
      deleteContent: DeleteContentUseCase(c.contentRepo),
      updateContent: UpdateContentUseCase(c.contentRepo),
      playbackRepo: c.playbackRepo,
    );
    addTearDown(vm.dispose);
    await vm.loadContents();
    expect(vm.state.progressMap['c1'], closeTo(40.0, 0.001));
    expect(vm.state.contents.single.status, 'in_progress');
  });

  test(
      'AC-W2-08: Transient(Quick Listen相当) 完了+再play: 永続書込み0・Content/Playback不変',
      () async {
    final c = _Core();
    addTearDown(c.dispose);
    c.addContent('c1', status: 'completed');
    c.playbackRepo.store['c1'] =
        PlaybackState(contentId: 'c1', position: _len, progressPct: 100.0);
    final usageBefore = await c.settingsRepo.get('tts_used_chars');

    for (var round = 0; round < 2; round++) {
      await c.transport.start(
        PlaybackOwnerKey.transient('Q$round'),
        PlaybackRequest(
            target: const TransientTarget(),
            text: 'y' * _len,
            startPosition: 0),
        accounting: const NoUsageAccounting(),
      );
      c.emitPlaying(100);
      await settle();
      c.emit(_completion);
      await settle();
    }

    expect(c.tts.speaks.map((s) => s.startPosition), [0, 0]);
    expect(c.playbackRepo.saveCalls, 0, reason: 'persistent write 0');
    expect(c.playbackRepo.store['c1']!.position, _len);
    expect(c.contentRepo.store['c1']!.status, 'completed');
    expect(await c.settingsRepo.get('tts_used_chars'), usageBefore);
  });
}
