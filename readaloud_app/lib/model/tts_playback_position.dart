import '../repository/tts/tts_service.dart';

/// audio_serviceのcustomState経由でTTS再生位置・状態を伝えるクラス
class TtsPlaybackPosition {
  final int charPosition; // 文字インデックス
  final bool isPlaying;
  final TtsStatus ttsStatus;

  const TtsPlaybackPosition({
    required this.charPosition,
    required this.isPlaying,
    required this.ttsStatus,
  });
}
