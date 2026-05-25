import 'dart:async';
import '../../repository/settings_repository.dart';
import '../../model/setting.dart';
import 'check_tts_limit_usecase.dart';

class CountTtsUsageUseCase {
  final SettingsRepository _settingsRepo;
  final CheckTtsLimitUseCase _checkLimit;

  Timer? _timer;
  int _lastPosition = 0;
  int _currentPosition = 0;

  CountTtsUsageUseCase({
    required SettingsRepository settingsRepo,
    required CheckTtsLimitUseCase checkLimit,
  })  : _settingsRepo = settingsRepo,
        _checkLimit = checkLimit;

  // カウント開始（10秒ごとに使用量を加算）
  void startCounting({
    required String contentId,
    required int totalChars,
    required int startPosition,
  }) {
    _lastPosition = startPosition;
    _currentPosition = startPosition;

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) async {
      await _addUsage(_currentPosition - _lastPosition);
      _lastPosition = _currentPosition;
    });
  }

  // 現在の再生位置を更新
  void updatePosition(int position) {
    _currentPosition = position;
  }

  // カウント停止（端数を加算）
  Future<void> stopCounting(String contentId) async {
    _timer?.cancel();
    _timer = null;

    // 端数を加算
    final remaining = _currentPosition - _lastPosition;
    if (remaining > 0) {
      await _addUsage(remaining);
    }
    _lastPosition = _currentPosition;
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
