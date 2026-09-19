import '../../model/setting.dart';
import '../../repository/settings_repository.dart';

/// 再生既定値の read-only seam（Detailed Design v1.2 FINAL §7.4 / INV-T1）。
///
/// Transient controller は write-capable な `SettingsRepository` を直接受け取らず、
/// この interface だけを受け取る。write API は型として露出しない。
abstract interface class PlaybackDefaultsReader {
  Future<double> readDefaultSpeed();
}

final class SettingsPlaybackDefaultsReader implements PlaybackDefaultsReader {
  SettingsPlaybackDefaultsReader(this._settings);

  final SettingsRepository _settings; // adapter 内部だけに閉じる

  @override
  Future<double> readDefaultSpeed() async {
    final raw = await _settings.get(SettingKeys.defaultSpeed) ?? '1.0';
    return double.tryParse(raw) ?? 1.0;
  }
}
