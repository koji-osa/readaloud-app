import 'dart:async';
import 'tts_service.dart';

// TODO: OpenAI TTS APIの実装が必要
// Phase 2で対応予定。
// API仕様: https://platform.openai.com/docs/api-reference/audio/createSpeech
// 料金: $15 / 100万文字（固定）
// 対応モデル: tts-1 / tts-1-hd
// 対応音声: alloy / echo / fable / onyx / nova / shimmer
class OpenAITtsService implements TtsService {
  final String apiKey;

  OpenAITtsService({required this.apiKey});

  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async {
    // TODO: OpenAI TTS APIを呼び出してMP3データを取得・再生する
    throw UnimplementedError('OpenAI TTSはPhase 2で実装予定です');
  }

  @override
  Future<void> pause() async {
    // TODO: 再生中断処理
    throw UnimplementedError('OpenAI TTSはPhase 2で実装予定です');
  }

  @override
  Future<void> stop() async {
    // TODO: 再生停止処理
    throw UnimplementedError('OpenAI TTSはPhase 2で実装予定です');
  }

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async {
    // OpenAI TTSの利用可能な音声一覧
    return [
      VoiceInfo(id: 'alloy',   name: 'Alloy',   languageCode: 'ja-JP', gender: 'neutral'),
      VoiceInfo(id: 'echo',    name: 'Echo',    languageCode: 'ja-JP', gender: 'male'),
      VoiceInfo(id: 'fable',   name: 'Fable',   languageCode: 'ja-JP', gender: 'neutral'),
      VoiceInfo(id: 'onyx',    name: 'Onyx',    languageCode: 'ja-JP', gender: 'male'),
      VoiceInfo(id: 'nova',    name: 'Nova',    languageCode: 'ja-JP', gender: 'female'),
      VoiceInfo(id: 'shimmer', name: 'Shimmer', languageCode: 'ja-JP', gender: 'female'),
    ];
  }

  @override
  Stream<int> get positionStream => const Stream.empty();

  @override
  Stream<TtsStatus> get statusStream => const Stream.empty();

  @override
  Future<void> dispose() async {
    // TODO: リソース解放処理
  }
}
