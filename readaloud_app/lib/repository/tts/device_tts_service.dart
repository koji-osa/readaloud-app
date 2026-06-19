import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../../model/tts_playback_position.dart';
import '../../util/debug_logger.dart';
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
  bool _isResuming = false; // 一時停止からの再開直後フラグ（FIX-021）
  int _pausedPosition = 0;  // 一時停止時の位置（FIX-021）
  int _currentPosition = 0;

  // 現在の再生位置を外部から取得（FIX-026）
  int get currentPosition => _currentPosition;
  late final Future<void> _initFuture;

  // 停止後の再開用に最後の再生パラメータを保持
  String? _lastText;
  int _lastStoppedPosition = 0;
  double _lastSpeed = 1.0;
  double _lastPitch = 1.0;
  double _lastVolume = 1.0;
  String? _lastVoiceId;
  Timer? _positionTimer;

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
          _isResuming = false; // 次チャンクへ進む際にリセット（FIX-064）
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
    // 再開中でない場合のみチャンク先頭を現在位置にセット（FIX-064）
    if (!_isResuming) {
      _currentPosition = chunk.startPosition;
    }
    customState.add(TtsPlaybackPosition(
      charPosition: _currentPosition,
      isPlaying: true,
      ttsStatus: TtsStatus.playing,
    ));

    // チャンクごとにsetProgressHandlerを設定（indexをクロージャでキャプチャしてズレを防止）
    _positionTimer?.cancel();
    _tts.setProgressHandler((text, startOffset, endOffset, word) {
      if (_isStopped || _isPaused) return;
      final chunkStart = chunk.startPosition;
      int absolutePosition;
      if (_isResuming) {
        // 再開後はチャンク切り替わりまで_pausedPositionを基準にstartOffsetを加算（FIX-021）
        absolutePosition = _pausedPosition + startOffset;
        _currentPosition = absolutePosition;
      } else {
        absolutePosition = chunkStart + startOffset;
        _currentPosition = absolutePosition;
      }
      // FIX-021調査用ログ
      DebugLogger.instance.bufferProgress(
        'PROGRESS: chunkIndex=$index chunkStart=$chunkStart startOffset=$startOffset absolute=$absolutePosition isResuming=$_isResuming word=$word',
      );
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
    _isResuming = false; // FIX-021
    _pausedPosition = 0; // FIX-021
    await _tts.stop();
    await Future.delayed(const Duration(milliseconds: 100));
    _isStopped = false;

    // メディアセッションをアクティブ化（Bluetooth・通知ボタン対応）
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
    await AudioService.androidForceEnableMediaButtons();
    if (_isPaused && !_isStopped && _chunks.isNotEmpty) {
      // 一時停止からの再開
      _isPaused = false;
      _isResuming = true; // 再開直後フラグをセット（FIX-021）
      // FIX-021調査用ログ
      final chunkStart = _chunks.isNotEmpty ? _chunks[_currentChunkIndex].startPosition : 0;
      await DebugLogger.instance.onResume(_currentPosition, _currentChunkIndex, chunkStart);
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
    _pausedPosition = _currentPosition; // 一時停止位置を保存（FIX-021）
    // FIX-021調査用ログ
    await DebugLogger.instance.onPause(_currentPosition, _currentChunkIndex);
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
    _isResuming = false; // FIX-021
    _pausedPosition = 0; // FIX-021
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

  // タスクリストからスワイプで削除された時に通知を消す（FIX-022）
  @override
  Future<void> onTaskRemoved() async {
    await stop();
    await super.onTaskRemoved();
  }

  // シングルトンのためdispose()は何もしない
  @override
  Future<void> dispose() async {}
}
