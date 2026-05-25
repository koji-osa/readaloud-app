import '../../repository/settings_repository.dart';
import '../../model/setting.dart';

class CheckTtsLimitUseCase {
  final SettingsRepository _settingsRepo;

  // アラート通知用コールバック
  final void Function(TtsLimitStatus status)? onLimitStatus;

  CheckTtsLimitUseCase({
    required SettingsRepository settingsRepo,
    this.onLimitStatus,
  }) : _settingsRepo = settingsRepo;

  Future<TtsLimitStatus> execute(int usedChars) async {
    final limitStr = await _settingsRepo.get(SettingKeys.ttsMonthlyLimit)
        ?? '1000000';
    final threshold1Str = await _settingsRepo.get(SettingKeys.ttsAlertThreshold1)
        ?? '0.8';
    final threshold2Str = await _settingsRepo.get(SettingKeys.ttsAlertThreshold2)
        ?? '0.95';

    final limit = int.tryParse(limitStr) ?? 1000000;
    final threshold1 = double.tryParse(threshold1Str) ?? 0.8;
    final threshold2 = double.tryParse(threshold2Str) ?? 0.95;

    final usageRate = usedChars / limit;

    TtsLimitStatus status;
    if (usageRate >= 1.0) {
      status = TtsLimitStatus.exceeded;
    } else if (usageRate >= threshold2) {
      status = TtsLimitStatus.nearLimit2;
    } else if (usageRate >= threshold1) {
      status = TtsLimitStatus.nearLimit1;
    } else {
      status = TtsLimitStatus.normal;
    }

    onLimitStatus?.call(status);
    return status;
  }

  // 月次リセット（アプリ起動時に呼ぶ）
  Future<void> resetIfNewMonth() async {
    final resetDateStr = await _settingsRepo.get(SettingKeys.ttsResetDate);
    final now = DateTime.now();
    final currentMonth =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-01';

    if (resetDateStr == null || resetDateStr != currentMonth) {
      await _settingsRepo.set(SettingKeys.ttsUsedChars, '0');
      await _settingsRepo.set(SettingKeys.ttsResetDate, currentMonth);
    }
  }
}

enum TtsLimitStatus {
  normal,      // 正常（80%未満）
  nearLimit1,  // 警告（80%以上）
  nearLimit2,  // 危険（95%以上）
  exceeded,    // 上限到達（100%以上）
  // TODO: exceeded時のフォールバック処理（内蔵TTSへの切替）は
  // ViewModel層（PlayerViewModel）で対応する。
  // tts_fallback_device設定がtrueの場合はDeviceTtsServiceに切替え、
  // falseの場合は再生停止してユーザーに通知する。
}
