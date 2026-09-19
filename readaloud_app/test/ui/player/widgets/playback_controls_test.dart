import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/ui/player/widgets/playback_controls.dart';

// Slice 5: PlaybackControls の nullable callback 化後も、全 callback を渡す
// Normal Player の表示・操作は不変であること（NP 表示不変の固定）と、
// Transient Phase 1（PD-2）で非表示要素が描画されないこと。
void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  }

  testWidgets(
      'Normal Player構成: 速度・声・先頭/巻戻し/再生/早送り/末尾・停止/A-Bがすべて表示され、'
      '各callbackが従来どおり呼ばれる', (tester) async {
    final calls = <String>[];
    await pump(
      tester,
      PlaybackControls(
        isPlaying: false,
        speed: 1.0,
        voiceId: 'voice-a',
        availableVoices: const ['voice-a', 'voice-b'],
        onPlay: () => calls.add('play'),
        onPause: () => calls.add('pause'),
        onStop: () => calls.add('stop'),
        onSeekToStart: () => calls.add('start'),
        onSeekToEnd: () => calls.add('end'),
        onRewind: () => calls.add('rewind'),
        onFastForward: () => calls.add('ff'),
        onSpeedChange: (s) => calls.add('speed:$s'),
        onVoiceChange: (v) => calls.add('voice:$v'),
      ),
    );

    for (final s in ['0.75x', '1.0x', '1.5x', '1.75x', '2.0x', '2.5x']) {
      expect(find.text(s), findsOneWidget);
    }
    expect(find.text('voice-a'), findsOneWidget);
    expect(find.text('voice-b'), findsOneWidget);
    for (final icon in [
      Icons.skip_previous,
      Icons.replay_10,
      Icons.play_arrow,
      Icons.forward_10,
      Icons.skip_next,
      Icons.stop,
      Icons.repeat,
    ]) {
      expect(find.byIcon(icon), findsOneWidget, reason: '$icon');
    }
    expect(find.text('停止'), findsOneWidget);
    expect(find.text('A-B'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.skip_previous));
    await tester.tap(find.byIcon(Icons.replay_10));
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.tap(find.byIcon(Icons.forward_10));
    await tester.tap(find.byIcon(Icons.skip_next));
    await tester.tap(find.byIcon(Icons.stop));
    await tester.tap(find.text('1.5x'));
    await tester.tap(find.text('voice-b'));
    expect(calls, [
      'start',
      'rewind',
      'play',
      'ff',
      'end',
      'stop',
      'speed:1.5',
      'voice:voice-b'
    ]);
  });

  testWidgets('Transient Phase 1構成（PD-2）: 再生/一時停止と先頭からだけを表示する', (tester) async {
    await pump(
      tester,
      PlaybackControls(
        isPlaying: true,
        speed: 1.0,
        onPlay: () {},
        onPause: () {},
        onSeekToStart: () {},
        onStop: null,
        onSeekToEnd: null,
        onRewind: null,
        onFastForward: null,
        onSpeedChange: null,
        onVoiceChange: null,
      ),
    );

    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    for (final icon in [
      Icons.replay_10,
      Icons.forward_10,
      Icons.skip_next,
      Icons.stop,
      Icons.repeat,
    ]) {
      expect(find.byIcon(icon), findsNothing, reason: '$icon');
    }
    expect(find.text('1.0x'), findsNothing, reason: '速度変更UIは出さない');
  });
}
