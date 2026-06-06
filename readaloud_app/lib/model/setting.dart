class Setting {
  final String key;
  final String value;
  final int updatedAt;

  Setting({
    required this.key,
    required this.value,
    int? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
        'key': key,
        'value': value,
        'updated_at': updatedAt,
      };

  factory Setting.fromMap(Map<String, dynamic> map) => Setting(
        key: map['key'],
        value: map['value'],
        updatedAt: map['updated_at'],
      );

  Setting copyWith({String? value}) => Setting(
        key: key,
        value: value ?? this.value,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
}

// 設定キーの定数定義
class SettingKeys {
  static const String deviceId             = 'device_id';
  static const String ttsApiKey            = 'tts_api_key';
  static const String ttsProvider          = 'tts_provider';
  static const String defaultSpeed         = 'default_speed';
  static const String defaultVoiceId       = 'default_voice_id';
  static const String defaultPitch         = 'default_pitch';
  static const String defaultVolume        = 'default_volume';
  static const String ttsMonthlyLimit      = 'tts_monthly_limit';
  static const String ttsAlertThreshold1   = 'tts_alert_threshold_1';
  static const String ttsAlertThreshold2   = 'tts_alert_threshold_2';
  static const String ttsUsedChars         = 'tts_used_chars';
  static const String ttsResetDate         = 'tts_reset_date';
  static const String ttsFallbackDevice    = 'tts_fallback_device';
  static const String cloudSyncEnabled     = 'cloud_sync_enabled';
  static const String onboardingCompleted  = 'onboarding_completed';
  static const String sortOrder            = 'sort_order';
  static const String geminiApiKey         = 'gemini_api_key';
}
