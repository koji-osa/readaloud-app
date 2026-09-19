import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/usecase/playback/seek_math.dart';

// T-C4: SeekMath が Normal Player 既存式（player_viewmodel.dart の rewind /
// fastForward / seekTo / progress 計算）と同値であることをテーブルで固定する。
void main() {
  // --- player_viewmodel.dart の既存式（逐語）---
  int npRewind(int highlightPosition, double speed, int len) {
    final charsPerSecond = (5 * speed).round();
    final rewindChars = 10 * charsPerSecond;
    return (highlightPosition - rewindChars).clamp(0, len);
  }

  int npFastForward(int highlightPosition, double speed, int len) {
    final charsPerSecond = (5 * speed).round();
    final forwardChars = 10 * charsPerSecond;
    return (highlightPosition + forwardChars).clamp(0, len);
  }

  int npSeekTo(double progressPct, int len) =>
      (len * progressPct / 100).round();

  double npProgress(int position, int len) =>
      (position / len * 100).clamp(0.0, 100.0);

  const positions = [0, 1, 49, 50, 51, 120, 999, 1000, 1500];
  const speeds = [0.75, 1.0, 1.5, 1.75, 2.0, 2.5];
  const lengths = [1, 60, 1000];

  test('stepBack / stepForward は NP rewind / fastForward と同値', () {
    for (final len in lengths) {
      for (final speed in speeds) {
        for (final pos in positions) {
          expect(SeekMath.stepBack(pos, speed, len), npRewind(pos, speed, len),
              reason: 'pos=$pos speed=$speed len=$len');
          expect(SeekMath.stepForward(pos, speed, len),
              npFastForward(pos, speed, len),
              reason: 'pos=$pos speed=$speed len=$len');
        }
      }
    }
  });

  test('fromProgress / progressPct は NP seekTo / 進捗式と同値', () {
    for (final len in lengths) {
      for (final pct in [0.0, 0.5, 12.3, 50.0, 99.9, 100.0]) {
        expect(SeekMath.fromProgress(pct, len), npSeekTo(pct, len));
      }
      for (final pos in positions) {
        expect(SeekMath.progressPct(pos, len), npProgress(pos, len));
      }
    }
  });

  test('seek-to-start は0、tap位置は[0, len]にclamp、末尾はlen', () {
    expect(SeekMath.startPosition, 0);
    expect(SeekMath.clampTap(-3, 10), 0);
    expect(SeekMath.clampTap(4, 10), 4);
    expect(SeekMath.clampTap(99, 10), 10);
    expect(SeekMath.endPosition(10), 10);
  });
}
