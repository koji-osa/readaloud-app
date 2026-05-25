import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'tts_service.dart';

// TODO: MP3データの再生実装が必要
// 現在はflutter_ttsでテキストを直接読み上げているが、
// 本来はGoogle Cloud TTS APIから取得したMP3データを
// audioplayers等のライブラリで再生する必要がある。
// Phase 2で対応予定。
class GoogleTtsService implements TtsService {
  final String apiKey;
  final Dio _dio = Dio();
  final FlutterTts _playerTts = FlutterTts();
  final _positionController = StreamController<int>.broadcast();
  final _statusController = StreamController<TtsStatus>.broadcast();

  int _startPosition = 0;
  int _currentPosition = 0;

  static const String _baseUrl =
      'https://texttospeech.googleapis.com/v1/text:synthesize';

  GoogleTtsService({required this.apiKey}) {
    _initPlayer();
  }

  void _initPlayer() {
    _playerTts.setProgressHandler((text, start, end, word) {
      _currentPosition = _startPosition + start;
      _positionController.add(_currentPosition);
    });

    _playerTts.setCompletionHandler(() {
      _statusController.add(TtsStatus.stopped);
    });

    _playerTts.setErrorHandler((message) {
      _statusController.add(TtsStatus.error);
    });
  }

  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async {
    _startPosition = startPosition;
    final speakText = text.substring(startPosition);

    try {
      final response = await _dio.post(
        '$_baseUrl?key=$apiKey',
        data: {
          'input': {'text': speakText},
          'voice': {
            'languageCode': 'ja-JP',
            'name': voiceId ?? 'ja-JP-Wavenet-A',
          },
          'audioConfig': {
            'audioEncoding': 'MP3',
            'speakingRate': speed,
            'pitch': (pitch - 1.0) * 20,
            'volumeGainDb': 0.0,
          },
        },
      );

      final audioContent = response.data['audioContent'] as String;
      // TODO: base64デコードしたMP3データをaudioplayersで再生する
      final audioBytes = base64Decode(audioContent);

      await _playerTts.setVolume(volume);
      _statusController.add(TtsStatus.playing);
      await _playerTts.speak(speakText);
    } catch (e) {
      _statusController.add(TtsStatus.error);
      rethrow;
    }
  }

  @override
  Future<void> pause() async {
    await _playerTts.pause();
    _statusController.add(TtsStatus.paused);
  }

  @override
  Future<void> stop() async {
    await _playerTts.stop();
    _statusController.add(TtsStatus.stopped);
  }

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async {
    try {
      final response = await _dio.get(
        'https://texttospeech.googleapis.com/v1/voices?key=$apiKey&languageCode=ja-JP',
      );
      final voices = response.data['voices'] as List;
      return voices.map((v) {
        final gender = v['ssmlGender'] as String;
        return VoiceInfo(
          id: v['name'],
          name: v['name'],
          languageCode: 'ja-JP',
          gender: gender == 'MALE'
              ? 'male'
              : gender == 'FEMALE'
                  ? 'female'
                  : 'neutral',
        );
      }).toList();
    } catch (e) {
      return [];
    }
  }

  @override
  Stream<int> get positionStream => _positionController.stream;

  @override
  Stream<TtsStatus> get statusStream => _statusController.stream;

  @override
  Future<void> dispose() async {
    await _playerTts.stop();
    await _positionController.close();
    await _statusController.close();
  }
}
