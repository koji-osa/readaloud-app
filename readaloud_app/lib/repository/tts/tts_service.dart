abstract class TtsService {
  // 読み上げ開始
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  });

  // 一時停止
  Future<void> pause();

  // 停止
  Future<void> stop();

  // 利用可能な声の一覧を取得
  Future<List<VoiceInfo>> getAvailableVoices();

  // 再生位置ストリーム（文字インデックスを流す）
  Stream<int> get positionStream;

  // 再生状態ストリーム
  Stream<TtsStatus> get statusStream;

  // リソース解放
  Future<void> dispose();
}

// 声の情報
class VoiceInfo {
  final String id;
  final String name;
  final String languageCode;
  final String gender; // "male" / "female" / "neutral"

  VoiceInfo({
    required this.id,
    required this.name,
    required this.languageCode,
    required this.gender,
  });
}

// 再生状態
enum TtsStatus {
  playing,
  paused,
  stopped,
  error,
}
