import '../repository/tts/tts_service.dart';

/// audio_serviceのcustomState経由でTTS再生位置・状態を伝えるクラス
class TtsPlaybackPosition {
  final int charPosition; // 文字インデックス
  final bool isPlaying;
  final TtsStatus ttsStatus;

  /// 全チャンクを最後まで読み上げて自然終了した時だけ true（P5）。
  /// stop / pause / cancel / error では false。
  final bool isNaturalCompletion;

  const TtsPlaybackPosition({
    required this.charPosition,
    required this.isPlaying,
    required this.ttsStatus,
    this.isNaturalCompletion = false,
  });
}
