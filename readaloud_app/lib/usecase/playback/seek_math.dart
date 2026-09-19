/// seek 位置計算の純関数（Detailed Design v1 §14 Slice 5 / T-C4）。
///
/// Normal Player 既存式（player_viewmodel.dart の rewind / fastForward /
/// seekTo / seekToEnd）の逐語抽出。seek の実行手順（stop → 保存 → 再開）は
/// 永続化の有無で異なるため各 controller に残す。
abstract final class SeekMath {
  static const int startPosition = 0;

  /// 10 秒相当の巻き戻し位置。
  static int stepBack(int position, double speed, int textLength) {
    final charsPerSecond = (5 * speed).round();
    final rewindChars = 10 * charsPerSecond;
    return (position - rewindChars).clamp(0, textLength);
  }

  /// 10 秒相当の早送り位置。
  static int stepForward(int position, double speed, int textLength) {
    final charsPerSecond = (5 * speed).round();
    final forwardChars = 10 * charsPerSecond;
    return (position + forwardChars).clamp(0, textLength);
  }

  /// 進捗 % から文字位置。
  static int fromProgress(double progressPct, int textLength) =>
      (textLength * progressPct / 100).round();

  /// 文字位置から進捗 %（[0, 100]）。
  static double progressPct(int position, int textLength) =>
      (position / textLength * 100).clamp(0.0, 100.0);

  /// 本文タップ位置を [0, textLength] に clamp する。
  static int clampTap(int position, int textLength) =>
      position.clamp(0, textLength);

  static int endPosition(int textLength) => textLength;
}
