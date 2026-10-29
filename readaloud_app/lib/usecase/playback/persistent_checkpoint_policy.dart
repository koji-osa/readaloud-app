/// P6: Normal Player (Persistent) の再生位置を約30秒ごとに checkpoint 保存する
/// ための純粋な判定状態。I/O・timer は持たない（時計は注入可能）。
///
/// 呼び出し側（gate backend）は accepted position event ごとに [onPlaying] を
/// 呼び、true が返ったときだけ exclusive 区間で再検証して保存する。
/// 保存の成否は [markSucceeded]、完了は [markFinished] で戻す。
class PersistentCheckpointScheduler {
  PersistentCheckpointScheduler({
    this.interval = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration interval;
  final DateTime Function() _now;

  Object? _owner;
  int? _epoch;
  DateTime? _windowStart;
  int _lastPosition = 0;
  bool _inFlight = false;

  bool get inFlight => _inFlight;

  /// (owner, epoch) の新しい playback を見たら window を reset する（書込みなし）。
  /// 書込みが必要なら true（in-flight 化済み。呼び出し側は必ず [markFinished]）。
  bool onPlaying({
    required Object owner,
    required int epoch,
    required int position,
  }) {
    final now = _now();
    if (_owner != owner || _epoch != epoch || _windowStart == null) {
      _owner = owner;
      _epoch = epoch;
      _windowStart = now;
      _lastPosition = position;
      _inFlight = false;
      return false;
    }
    if (_inFlight) return false;
    if (now.difference(_windowStart!) < interval) return false;
    if (position <= _lastPosition) return false;
    _inFlight = true;
    return true;
  }

  /// checkpoint 保存に成功した。
  void markSucceeded({required int position}) {
    _lastPosition = position;
    _windowStart = _now();
  }

  /// 成否に関わらず必ず呼ぶ（in-flight 解除）。
  void markFinished() => _inFlight = false;
}
