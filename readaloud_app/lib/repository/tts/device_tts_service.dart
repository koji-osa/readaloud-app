import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';
import 'tts_service.dart';

class DeviceTtsService implements TtsService {
  final FlutterTts _tts = FlutterTts();
  final _positionController = StreamController<int>.broadcast();
  final _statusController = StreamController<TtsStatus>.broadcast();

  String _currentText = '';
  int _startPosition = 0;
  int _currentPosition = 0;

  DeviceTtsService() {
    _init();
  }

  void _init() {
    _tts.setLanguage('ja-JP');

    _tts.setProgressHandler((text, start, end, word) {
      _currentPosition = _startPosition + start;
      _positionController.add(_currentPosition);
    });

    _tts.setCompletionHandler(() {
      _statusController.add(TtsStatus.stopped);
    });

    _tts.setErrorHandler((message) {
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
    _currentText = text;
    _startPosition = startPosition;

    await _tts.setSpeechRate(speed * 0.5);
    await _tts.setPitch(pitch);
    await _tts.setVolume(volume);

    if (voiceId != null) {
      await _tts.setVoice({'name': voiceId, 'locale': 'ja-JP'});
    }

    _statusController.add(TtsStatus.playing);
    await _tts.speak(text.substring(startPosition));
  }

  @override
  Future<void> pause() async {
    await _tts.pause();
    _statusController.add(TtsStatus.paused);
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
    _statusController.add(TtsStatus.stopped);
  }

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async {
    final voices = await _tts.getVoices;
    if (voices == null) return [];
    return (voices as List).map((v) {
      final map = v as Map;
      return VoiceInfo(
        id: map['name'] ?? '',
        name: map['name'] ?? '',
        languageCode: map['locale'] ?? 'ja-JP',
        gender: 'neutral',
      );
    }).toList();
  }

  @override
  Stream<int> get positionStream => _positionController.stream;

  @override
  Stream<TtsStatus> get statusStream => _statusController.stream;

  @override
  Future<void> dispose() async {
    await _tts.stop();
    await _positionController.close();
    await _statusController.close();
  }
}
