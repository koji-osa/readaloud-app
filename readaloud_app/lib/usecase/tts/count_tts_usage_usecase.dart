import 'dart:async';
import '../../model/normal_player_session.dart';
import '../../repository/settings_repository.dart';
import '../../model/setting.dart';
import 'check_tts_limit_usecase.dart';

class CountTtsUsageUseCase {
  final SettingsRepository _settingsRepo;
  final CheckTtsLimitUseCase _checkLimit;

  Timer? _timer;
  int _lastPosition = 0;
  int _currentPosition = 0;

  /// 現在計測中の owner（v0.4.1 D2/D13）。Normal Player と Quick Listen は
  /// それぞれ別の owner key（`np:`/`ql:` prefix）を渡すため、同じ counter
  /// instance を複数箇所が共有していても互いの操作を誤って乗っ取れない。
  PlaybackOwnerKey? _activeOwner;

  /// claim 済みだが未だ永続化できていない使用量（CI-1）。
  /// `_addUsage` が失敗しても chars を失わず、次回の flush で再試行する。
  int _pendingUnflushed = 0;

  // 永続書込みの直列化用 tail。個々の書込みが失敗しても tail 自体は常に
  // 正常完了させ、以後の呼び出しでも chain が使い続けられるようにする（CI-1）。
  Future<void> _writeTail = Future<void>.value();

  CountTtsUsageUseCase({
    required SettingsRepository settingsRepo,
    required CheckTtsLimitUseCase checkLimit,
  })  : _settingsRepo = settingsRepo,
        _checkLimit = checkLimit;

  // カウント開始（10秒ごとに使用量を加算）
  void startCounting({
    required PlaybackOwnerKey owner,
    required int totalChars,
    required int startPosition,
  }) {
    _activeOwner = owner;
    _lastPosition = startPosition;
    _currentPosition = startPosition;

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_activeOwner != owner) {
        _timer?.cancel();
        return;
      }
      final delta = _currentPosition - _lastPosition;
      _lastPosition = _currentPosition; // await前に同期claim
      final toFlush = _pendingUnflushed + (delta > 0 ? delta : 0);
      _pendingUnflushed = 0;
      if (toFlush <= 0) return;
      unawaited(_enqueueAddUsage(toFlush).catchError((_) {
        // タイマー起点の失敗は呼び出し元が存在しないため、chars を戻して
        // 次回flushで再試行する（unhandled async errorを作らない）。
        _pendingUnflushed += toFlush;
      }));
    });
  }

  // 現在の再生位置を更新
  void updatePosition(int position) {
    _currentPosition = position;
  }

  /// owner が現在の active owner と一致しない場合は完全に no-op とする
  /// （他 owner の timer を cancel することも含めて何もしない。D13）。
  Future<void> stopCounting(PlaybackOwnerKey owner) async {
    if (_activeOwner != owner) return;
    _timer?.cancel();
    _timer = null;

    final remaining = _currentPosition - _lastPosition;
    _lastPosition = _currentPosition; // await前に同期claim
    final toFlush = _pendingUnflushed + (remaining > 0 ? remaining : 0);
    _pendingUnflushed = 0;
    if (toFlush <= 0) return;
    try {
      await _enqueueAddUsage(toFlush);
    } catch (e) {
      // 失敗分は次回のflushで再試行できるよう保持しつつ、呼び出し元へは
      // エラーを観測可能なまま伝える（CI-1: 失敗を黙って成功扱いにしない）。
      _pendingUnflushed += toFlush;
      rethrow;
    }
  }

  /// 内部直列化 tail に載せて `_addUsage` を実行する。
  /// tail 自体（[_writeTail]）は常に正常完了し、失敗しても chain は生き続ける。
  /// 呼び出し元には別の Future（[Completer]）経由で本物のエラーを返す。
  Future<void> _enqueueAddUsage(int chars) {
    final completer = Completer<void>();
    _writeTail = _writeTail.then((_) async {
      try {
        await _addUsage(chars);
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> _addUsage(int chars) async {
    if (chars <= 0) return;

    final usedStr = await _settingsRepo.get(SettingKeys.ttsUsedChars) ?? '0';
    final used = int.tryParse(usedStr) ?? 0;
    final newUsed = used + chars;

    await _settingsRepo.set(SettingKeys.ttsUsedChars, newUsed.toString());

    // 上限チェック
    await _checkLimit.execute(newUsed);
  }

  void dispose() {
    _timer?.cancel();
  }
}
