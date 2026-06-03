import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../../model/tts_playback_position.dart';
import 'tts_service.dart';

class _TextChunk {
  final String text;
  final int startPosition;
  _TextChunk({required this.text, required this.startPosition});
}

class TtsAudioHandler extends BaseAudioHandler implements TtsService {
  final FlutterTts _tts = FlutterTts();

  List<_TextChunk> _chunks = [];
  int _currentChunkIndex = 0;
  bool _isStopped = false;
  bool _isPaused = false;
  int _currentPosition = 0;
  late final Future<void> _initFuture;

  // 停止後の再開用に最後の再生パラメータを保持
  String? _lastText;
  int _lastStoppedPosition = 0;
  double _lastSpeed = 1.0;
  double _lastPitch = 1.0;
  double _lastVolume = 1.0;
  String? _lastVoiceId;
  Timer? _positionTimer;
  DateTime? _chunkStartTime;

  TtsAudioHandler() {
    _initFuture = _init();
  }

  Future<void> _init() async {
    try {
      // audio_sessionの設定（電話着信時の自動停止・再開）
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          pause();
        } else {
          if (event.type == AudioInterruptionType.pause) {
            play();
          }
        }
      });

      await _tts.setLanguage('ja-JP');

      _tts.setCompletionHandler(() async {
        try {
          if (_isStopped || _isPaused) return;
          _currentChunkIndex++;
          if (_currentChunkIndex < _chunks.length) {
            await _playChunk(_currentChunkIndex);
          } else {
            // 全チャンク再生完了
            _positionTimer?.cancel();
            _isStopped = true;
            _lastStoppedPosition = 0;
            customState.add(TtsPlaybackPosition(
              charPosition: _currentPosition,
              isPlaying: false,
              ttsStatus: TtsStatus.stopped,
            ));
            playbackState.add(playbackState.value.copyWith(
              playing: false,
              processingState: AudioProcessingState.completed,
              controls: [],
            ));
          }
        } catch (e) {
          customState.add(TtsPlaybackPosition(
            charPosition: _currentPosition,
            isPlaying: false,
            ttsStatus: TtsStatus.error,
          ));
        }
      });

      _tts.setErrorHandler((message) {
        customState.add(TtsPlaybackPosition(
          charPosition: _currentPosition,
          isPlaying: false,
          ttsStatus: TtsStatus.error,
        ));
      });
    } catch (e) {
      customState.add(TtsPlaybackPosition(
        charPosition: 0,
        isPlaying: false,
        ttsStatus: TtsStatus.error,
      ));
    }
  }

  Future<void> _playChunk(int index) async {
    if (index >= _chunks.length) return;
    final chunk = _chunks[index];
    _currentPosition = chunk.startPosition;
    customState.add(TtsPlaybackPosition(
      charPosition: _currentPosition,
      isPlaying: true,
      ttsStatus: TtsStatus.playing,
    ));

    // タイマーで推定位置を定期更新（500ms間隔）
    _positionTimer?.cancel();
    _chunkStartTime = DateTime.now();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (_isStopped || _isPaused) {
        timer.cancel();
        return;
      }
      final elapsed = DateTime.now().difference(_chunkStartTime!).inMilliseconds;
      final charsPerMs = (5.0 * _lastSpeed) / 1000.0;
      final estimatedOffset = (elapsed * charsPerMs).round();
      final nextChunkStart = (index + 1 < _chunks.length)
          ? _chunks[index + 1].startPosition
          : (_chunks.last.startPosition + _chunks.last.text.length);
      final estimatedPosition = (chunk.startPosition + estimatedOffset)
          .clamp(chunk.startPosition, nextChunkStart - 1);
      _currentPosition = estimatedPosition;
      customState.add(TtsPlaybackPosition(
        charPosition: _currentPosition,
        isPlaying: true,
        ttsStatus: TtsStatus.playing,
      ));
    });

    await _tts.speak(chunk.text);
  }

  List<_TextChunk> _splitText(String text, int startPosition) {
    final chunks = <_TextChunk>[];

    // startPositionの範囲チェック
    final clampedStart = startPosition.clamp(0, text.length);
    final targetText = text.substring(clampedStart);
    int offset = clampedStart;

    // 句読点で分割してセグメントを作成
    final segments = <String>[];
    final buffer = StringBuffer();
    for (int i = 0; i < targetText.length; i++) {
      buffer.write(targetText[i]);
      final c = targetText[i];
      if (c == '。' || c == '！' || c == '？' || c == '\n') {
        segments.add(buffer.toString());
        buffer.clear();
      }
      // 2,000文字上限で強制分割
      if (buffer.length >= 2000) {
        segments.add(buffer.toString());
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) {
      segments.add(buffer.toString());
    }

    // セグメントを2,000文字以内のチャンクにまとめる
    final chunkBuffer = StringBuffer();
    int chunkStart = offset;
    for (final seg in segments) {
      if (chunkBuffer.length + seg.length > 2000) {
        if (chunkBuffer.isNotEmpty) {
          chunks.add(_TextChunk(
            text: chunkBuffer.toString(),
            startPosition: chunkStart,
          ));
          chunkStart += chunkBuffer.length;
          chunkBuffer.clear();
        }
      }
      chunkBuffer.write(seg);
    }
    if (chunkBuffer.isNotEmpty) {
      chunks.add(_TextChunk(
        text: chunkBuffer.toString(),
        startPosition: chunkStart,
      ));
    }

    return chunks;
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
    await _initFuture;
    // メディアセッションをアクティブ化（Bluetooth・通知ボタン対応）
    // 再生パラメータを保持（停止後の再開用）
    _lastText = text;
    _lastSpeed = speed;
    _lastPitch = pitch;
    _lastVolume = volume;
    _lastVoiceId = voiceId;
    _lastStoppedPosition = startPosition;

    // 前回の再生を確実に停止（フラグを先にtrueにして誤発火防止）
    _isStopped = true;
    _isPaused = false;
    await _tts.stop();
    await Future.delayed(const Duration(milliseconds: 100));
    _isStopped = false;

    // Bluetooth A2DP接続を確立（極小音量でダミー音声を流してブツっ音を防止）
    await _tts.setVolume(0.01);
    await _tts.speak('.');
    await Future.delayed(const Duration(milliseconds: 300));
    await _tts.stop();
    // A2DP確立後にメディアセッションをアクティブ化
    await AudioService.androidForceEnableMediaButtons();

    await _tts.setSpeechRate(speed * 0.5);
    await _tts.setPitch(pitch);
    await _tts.setVolume(volume);
    if (voiceId != null) {
      await _tts.setVoice({'name': voiceId, 'locale': 'ja-JP'});
    }

    // テキストをチャンクに分割
    _chunks = _splitText(text, startPosition);
    _currentChunkIndex = 0;

    if (_chunks.isEmpty) return;

    // 通知領域にメディア情報を設定
    mediaItem.add(const MediaItem(
      id: 'tts_playback',
      title: '読み上げ中',
      artist: 'ReadAloud',
    ));

    customState.add(TtsPlaybackPosition(
      charPosition: _currentPosition,
      isPlaying: true,
      ttsStatus: TtsStatus.playing,
    ));
    playbackState.add(playbackState.value.copyWith(
      playing: true,
      processingState: AudioProcessingState.ready,
      controls: [MediaControl.pause, MediaControl.stop],
    ));

    await _playChunk(0);
  }

  // 通知領域の再生ボタン・電話着信終了後の再開
  @override
  Future<void> play() async {
    await _initFuture;
    // メディアセッションをアクティブ化（Bluetooth・通知ボタン対応）
    if (_isPaused && !_isStopped && _chunks.isNotEmpty) {
      // 一時停止からの再開
      _isPaused = false;
      customState.add(TtsPlaybackPosition(
        charPosition: _currentPosition,
        isPlaying: true,
        ttsStatus: TtsStatus.playing,
      ));
      playbackState.add(playbackState.value.copyWith(
        playing: true,
        controls: [MediaControl.pause, MediaControl.stop],
      ));
      await _playChunk(_currentChunkIndex);
    } else if (_isStopped && _lastText != null) {
      // 停止後の再開（停止時の位置から）
      await speak(
        text: _lastText!,
        startPosition: _lastStoppedPosition,
        speed: _lastSpeed,
        pitch: _lastPitch,
        volume: _lastVolume,
        voiceId: _lastVoiceId,
      );
    }
  }

  @override
  Future<void> pause() async {
    await _initFuture;
    _positionTimer?.cancel();
    _isPaused = true;
    await _tts.pause();
    customState.add(TtsPlaybackPosition(
      charPosition: _currentPosition,
      isPlaying: false,
      ttsStatus: TtsStatus.paused,
    ));
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      controls: [MediaControl.play, MediaControl.stop],
    ));
  }

  @override
  Future<void> stop() async {
    await _initFuture;
    // 停止時の位置を保持
    _lastStoppedPosition = _currentPosition;
    _positionTimer?.cancel();
    _isStopped = true;
    _chunks = [];
    await _tts.stop();
    customState.add(TtsPlaybackPosition(
      charPosition: _currentPosition,
      isPlaying: false,
      ttsStatus: TtsStatus.stopped,
    ));
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle,
      controls: [MediaControl.play],
    ));
  }

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async {
    final voices = await _tts.getVoices;
    if (voices == null) return [];
    return (voices as List).map((v) {
      final map = v as Map<dynamic, dynamic>;
      final id = map['name']?.toString() ?? '';
      final locale = map['locale']?.toString() ?? 'ja-JP';
      return VoiceInfo(
        id: id,
        name: id,
        languageCode: locale,
        gender: 'neutral',
      );
    }).toList();
  }

  // シングルトンのためdispose()は何もしない
  @override
  Future<void> dispose() async {}
}
