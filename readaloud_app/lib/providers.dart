import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'repository/tts/device_tts_service.dart';

// audio_serviceのシングルトンをRiverpodで提供
final audioHandlerProvider = Provider<TtsAudioHandler>((ref) {
  throw UnimplementedError('audioHandlerProviderはProviderScopeのoverridesで初期化してください');
});
