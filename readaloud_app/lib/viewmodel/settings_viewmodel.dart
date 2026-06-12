import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../repository/settings_repository.dart';
import '../model/setting.dart';
import '../usecase/tts/check_tts_limit_usecase.dart';

class SettingsState {
  final bool isLoading;
  final String? errorMessage;
  final String ttsProvider;
  final String defaultSpeed;
  final String defaultVoiceId;
  final String defaultPitch;
  final String defaultVolume;
  final String ttsMonthlyLimit;
  final String ttsAlertThreshold1;
  final String ttsAlertThreshold2;
  final String ttsUsedChars;
  final bool ttsFallbackDevice;
  final bool cloudSyncEnabled;
  final String aiProvider; // 'gemini' or 'claude'（REQ-023）
  final String tocPrompt; // REQ-031
  final String tablePrompt; // REQ-031

  SettingsState({
    this.isLoading = false,
    this.errorMessage,
    this.ttsProvider = 'device',
    this.defaultSpeed = '1.0',
    this.defaultVoiceId = '',
    this.defaultPitch = '1.0',
    this.defaultVolume = '1.0',
    this.ttsMonthlyLimit = '1000000',
    this.ttsAlertThreshold1 = '0.8',
    this.ttsAlertThreshold2 = '0.95',
    this.ttsUsedChars = '0',
    this.ttsFallbackDevice = true,
    this.cloudSyncEnabled = true,
    this.aiProvider = 'gemini',
    this.tocPrompt = '', // REQ-031
    this.tablePrompt = '', // REQ-031
  });

  SettingsState copyWith({
    bool? isLoading,
    String? errorMessage,
    String? ttsProvider,
    String? defaultSpeed,
    String? defaultVoiceId,
    String? defaultPitch,
    String? defaultVolume,
    String? ttsMonthlyLimit,
    String? ttsAlertThreshold1,
    String? ttsAlertThreshold2,
    String? ttsUsedChars,
    bool? ttsFallbackDevice,
    bool? cloudSyncEnabled,
    String? aiProvider,
    String? tocPrompt, // REQ-031
    String? tablePrompt, // REQ-031
  }) =>
      SettingsState(
        isLoading: isLoading ?? this.isLoading,
        errorMessage: errorMessage,
        ttsProvider: ttsProvider ?? this.ttsProvider,
        defaultSpeed: defaultSpeed ?? this.defaultSpeed,
        defaultVoiceId: defaultVoiceId ?? this.defaultVoiceId,
        defaultPitch: defaultPitch ?? this.defaultPitch,
        defaultVolume: defaultVolume ?? this.defaultVolume,
        ttsMonthlyLimit: ttsMonthlyLimit ?? this.ttsMonthlyLimit,
        ttsAlertThreshold1: ttsAlertThreshold1 ?? this.ttsAlertThreshold1,
        ttsAlertThreshold2: ttsAlertThreshold2 ?? this.ttsAlertThreshold2,
        ttsUsedChars: ttsUsedChars ?? this.ttsUsedChars,
        ttsFallbackDevice: ttsFallbackDevice ?? this.ttsFallbackDevice,
        cloudSyncEnabled: cloudSyncEnabled ?? this.cloudSyncEnabled,
        aiProvider: aiProvider ?? this.aiProvider,
        tocPrompt: tocPrompt ?? this.tocPrompt, // REQ-031
        tablePrompt: tablePrompt ?? this.tablePrompt, // REQ-031
      );

  // TTS使用量の割合（0.0〜1.0）
  double get ttsUsageRate {
    final used = int.tryParse(ttsUsedChars) ?? 0;
    final limit = int.tryParse(ttsMonthlyLimit) ?? 1000000;
    return limit > 0 ? used / limit : 0.0;
  }
}

class SettingsViewModel extends StateNotifier<SettingsState> {
  final SettingsRepository _settingsRepo;
  final CheckTtsLimitUseCase _checkTtsLimit;

  SettingsViewModel({
    required SettingsRepository settingsRepo,
    required CheckTtsLimitUseCase checkTtsLimit,
  })  : _settingsRepo = settingsRepo,
        _checkTtsLimit = checkTtsLimit,
        super(SettingsState()) {
    loadSettings();
    _checkTtsLimit.resetIfNewMonth();
  }

  // 設定を読み込む
  Future<void> loadSettings() async {
    state = state.copyWith(isLoading: true);
    try {
      final all = await _settingsRepo.getAll();
      state = state.copyWith(
        isLoading: false,
        ttsProvider: all[SettingKeys.ttsProvider] ?? 'device',
        defaultSpeed: all[SettingKeys.defaultSpeed] ?? '1.0',
        defaultVoiceId: all[SettingKeys.defaultVoiceId] ?? '',
        defaultPitch: all[SettingKeys.defaultPitch] ?? '1.0',
        defaultVolume: all[SettingKeys.defaultVolume] ?? '1.0',
        ttsMonthlyLimit: all[SettingKeys.ttsMonthlyLimit] ?? '1000000',
        ttsAlertThreshold1: all[SettingKeys.ttsAlertThreshold1] ?? '0.8',
        ttsAlertThreshold2: all[SettingKeys.ttsAlertThreshold2] ?? '0.95',
        ttsUsedChars: all[SettingKeys.ttsUsedChars] ?? '0',
        ttsFallbackDevice: all[SettingKeys.ttsFallbackDevice] != 'false',
        cloudSyncEnabled: all[SettingKeys.cloudSyncEnabled] != 'false',
        aiProvider: all[SettingKeys.aiProvider] ?? 'gemini',
        tocPrompt: all[SettingKeys.tocPrompt] ?? '', // REQ-031
        tablePrompt: all[SettingKeys.tablePrompt] ?? '', // REQ-031
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '設定の読み込みに失敗しました: $e',
      );
    }
  }

  // 設定を保存
  Future<void> saveSetting(String key, String value) async {
    try {
      await _settingsRepo.set(key, value);
      await loadSettings();
    } catch (e) {
      state = state.copyWith(errorMessage: '設定の保存に失敗しました: $e');
    }
  }

  // TTS使用量をリフレッシュ
  Future<void> refreshTtsUsage() async {
    final used = await _settingsRepo.get(SettingKeys.ttsUsedChars) ?? '0';
    state = state.copyWith(ttsUsedChars: used);
  }

  void clearError() => state = state.copyWith(errorMessage: null);
}
