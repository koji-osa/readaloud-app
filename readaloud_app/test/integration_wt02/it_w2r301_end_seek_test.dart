// RA-CC-AUTO-WT-02-CONT-02 / W2-R3-01: fast-forward / bookmark seek that
// reaches the end while playing must not auto-replay (consistent with
// seekToEnd). Drives the real PlayerViewModel via PlayerScreen + Home with the
// it_harness fakes.
//
// Limitation: the harness TTS only counts speak() calls (no start position),
// so AC-301-06 observes the restart via speak count + the real resolver.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/ui/home/widgets/content_card.dart';
import 'package:readaloud_app/ui/player/player_screen.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/viewmodel/player_viewmodel.dart';

import 'it_harness.dart';

final int _len = itBody.length; // 1000

Content _existing(String id) =>
    Content(id: id, title: 'title-$id', body: itBody, sourceType: 'text');

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

/// Home -> card -> play (when [playing]), position events flowing at [startPos].
Future<ItEnv> _open(WidgetTester tester,
    {required int startPos, bool playing = true}) async {
  final env = await pumpHome(tester, seedContents: [_existing('e1')]);
  await tester.tap(find.byType(ContentCard));
  await tester.pumpAndSettle();
  expect(find.byType(PlayerScreen), findsOneWidget);
  if (playing) {
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    env.emitPlaying(startPos);
    await _flush(tester);
  } else {
    env.core.handlerPosition = startPos;
  }
  return env;
}

PlayerOriginToken _origin(WidgetTester tester) => PlayerOriginToken(
    sessionId: tester.widget<PlayerScreen>(find.byType(PlayerScreen)).sessionId,
    contentId: 'e1');

PlayerViewModel _vm(ItEnv env) =>
    env.container.read(playerViewModelProvider.notifier);

bool _isPlaying(ItEnv env) =>
    env.container.read(playerViewModelProvider).isPlaying;

Future<void> _expectEndState(ItEnv env) async {
  final db = env.playbackRepo.store['e1']!;
  expect(db.position, _len);
  expect(db.progressPct, 100.0);
  expect((await env.contentRepo.getById('e1'))!.status, 'completed');
  expect(_isPlaying(env), isFalse);
  // 注: ユーザーstop後もTransport ownerは保持される(既存仕様。seekToEndも同様)。
  // そのため owner clear ではなく、呼び出し側で speak/stop 回数を検証する。
}

void main() {
  setUp(() => DebugLogger.testSink = []);
  tearDown(() => DebugLogger.testSink = null);

  testWidgets(
      'AC-301-01: 再生中FFが終端に到達 -> 再speakなし・DB len/100/completed・isPlaying=false',
      (tester) async {
    final env = await _open(tester, startPos: _len - 20);
    final speaks = env.tts.speakCount;
    final stops = env.tts.stopCount;

    await tester.tap(find.byIcon(Icons.forward_10));
    await tester.pumpAndSettle();

    expect(env.tts.stopCount, stops + 1, reason: '停止は行われる');
    expect(env.tts.speakCount, speaks, reason: '終端では自動再生しない');
    await _expectEndState(env);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AC-301-02: 再生中FFが途中 -> 従来どおり自動再生(speak +1)(guard)',
      (tester) async {
    final env = await _open(tester, startPos: 300);
    final speaks = env.tts.speakCount;

    await tester.tap(find.byIcon(Icons.forward_10));
    await tester.pumpAndSettle();

    expect(env.tts.speakCount, speaks + 1);
    final db = env.playbackRepo.store['e1']!;
    expect(db.position, 350);
    expect(db.progressPct, closeTo(35.0, 0.001));
    expect(_isPlaying(env), isTrue);
    expect((await env.contentRepo.getById('e1'))!.status, 'in_progress');

    await tester.tap(find.byIcon(Icons.stop)); // 後始末
    await tester.pumpAndSettle();
  });

  testWidgets('AC-301-03: 再生中ブックマークシークが終端(len) -> 再speakなし・DB 100/completed',
      (tester) async {
    final env = await _open(tester, startPos: 300);
    final speaks = env.tts.speakCount;

    await _vm(env).seekToBookmark(origin: _origin(tester), position: _len);
    await tester.pumpAndSettle();

    expect(env.tts.speakCount, speaks, reason: '終端では自動再生しない');
    await _expectEndState(env);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AC-301-04: 再生中ブックマークシークが途中 -> その位置から再開(guard)', (tester) async {
    final env = await _open(tester, startPos: 300);
    final speaks = env.tts.speakCount;

    await _vm(env).seekToBookmark(origin: _origin(tester), position: 600);
    await tester.pumpAndSettle();

    expect(env.tts.speakCount, speaks + 1);
    final db = env.playbackRepo.store['e1']!;
    expect(db.position, 600);
    expect(db.progressPct, closeTo(60.0, 0.001));
    expect(_isPlaying(env), isTrue);

    await tester.tap(find.byIcon(Icons.stop)); // 後始末
    await tester.pumpAndSettle();
  });

  testWidgets('AC-301-05: 停止中のFF/ブックマークが終端 -> speakなし(guard)', (tester) async {
    final env = await _open(tester, startPos: _len - 20, playing: false);
    expect(_isPlaying(env), isFalse);

    await tester.tap(find.byIcon(Icons.forward_10));
    await tester.pumpAndSettle();
    expect(env.tts.speakCount, 0);
    expect(_isPlaying(env), isFalse);

    await _vm(env).seekToBookmark(origin: _origin(tester), position: _len);
    await tester.pumpAndSettle();
    expect(env.tts.speakCount, 0);
    expect(_isPlaying(env), isFalse);
    expect(env.playbackRepo.store['e1']!.position, _len);
    expect(env.playbackRepo.store['e1']!.progressPct, 100.0);
  });

  testWidgets('AC-301-06: AC-301-01後の▶は0から再生を再開(CONT-01 A維持)(guard)',
      (tester) async {
    final env = await _open(tester, startPos: _len - 20);
    await tester.tap(find.byIcon(Icons.forward_10));
    await tester.pumpAndSettle();
    await _expectEndState(env);
    final speaks = env.tts.speakCount;

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    await _flush(tester);

    expect(env.tts.speakCount, speaks + 1, reason: '▶で再生が始まる');
    expect(_isPlaying(env), isTrue);
    expect((await env.contentRepo.getById('e1'))!.status, 'in_progress');
    // 開始位置は resolver 経由(CONT-01 A): 保存位置==len でも 0。
    final req = await env.core.resolver.resolveForStart('e1');
    expect(req.startPosition, 0);

    await tester.tap(find.byIcon(Icons.stop)); // 後始末
    await tester.pumpAndSettle();
  });
}
