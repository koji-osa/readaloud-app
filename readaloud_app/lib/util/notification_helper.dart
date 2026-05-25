import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../usecase/tts/check_tts_limit_usecase.dart';

class NotificationHelper {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  // 初期化（main.dartで呼び出す）
  static Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(settings);
    _initialized = true;
  }

  // TTS使用量アラート通知
  static Future<void> notifyTtsLimit(TtsLimitStatus status) async {
    if (status == TtsLimitStatus.normal) return;

    String title;
    String body;
    switch (status) {
      case TtsLimitStatus.nearLimit1:
        title = '⚠️ TTS使用量が80%に達しました';
        body  = '今月の残り使用量が少なくなっています。設定から上限を確認してください。';
        break;
      case TtsLimitStatus.nearLimit2:
        title = '🚨 TTS使用量が95%に達しました';
        body  = 'もうすぐ今月の上限に達します。内蔵TTSへの切替をご検討ください。';
        break;
      case TtsLimitStatus.exceeded:
        title = '🛑 TTS使用量が上限に達しました';
        body  = '今月のGoogle Cloud TTS使用量が上限を超えました。内蔵TTSに切り替えます。';
        break;
      default:
        return;
    }

    const androidDetails = AndroidNotificationDetails(
      'tts_limit_channel',
      'TTS使用量アラート',
      channelDescription: 'TTS使用量の上限に関する通知',
      importance: Importance.high,
      priority: Priority.high,
    );

    await _plugin.show(
      status.index,
      title,
      body,
      const NotificationDetails(android: androidDetails),
    );
  }
}
