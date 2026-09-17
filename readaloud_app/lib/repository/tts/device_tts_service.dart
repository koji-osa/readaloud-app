import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../../model/tts_playback_position.dart';
import '../../util/debug_logger.dart';
import 'playback_resume_fence.dart';
import 'tts_service.dart';

class _TextChunk {
  final String text;
  final int startPosition;
  _TextChunk({required this.text, required this.startPosition});
}

class TtsAudioHandler extends BaseAudioHandler
    implements TtsService, PlaybackResumeFence {
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

  // Shared Player Core C3: owner-retiring teardown で resume state を破棄した
  // 状態。次の speak() まで notification Play / pause と audio interruption の
  // pause/resume を no-op にし、retire 済み text の復活と通知の再表示を防ぐ。
  bool _resumeFenced = false;

  // Shared Player Core C3 / PC-3: resume generation（単調増加）。
  // `discardResumeState()` と新しい `speak()` の開始で進める。platform await を
  // 跨いだ `play()` / `speak()` の continuation は、capture した generation が
  // 変わっていれば（fence または別 owner の開始が割り込んだ）resume/speak せずに
  // 終了する（TOCTOU closure）。
  int _resumeGeneration = 0;

  bool _isResumeGenerationCurrent(int generation) =>
      generation == _resumeGeneration && !_resumeFenced;

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
        DebugLogger.instance.logEvent('error', {
          'context': 'tts_error_handler',
          'errorType': message.runtimeType.toString(),
        });
        customState.add(TtsPlaybackPosition(
          charPosition: _currentPosition,
          isPlaying: false,
          ttsStatus: TtsStatus.error,
        ));
      });
    } catch (e) {
      DebugLogger.instance.logEvent('error', {
        'context': 'tts_audio_handler_init',
        'errorType': e.runtimeType.toString(),
      });
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
      // FIX-021調査用ログ（本文/word断片は記録しない。位置情報のみ）
      DebugLogger.instance.bufferProgress(
        'PROGRESS: chunkIndex=$index chunkStart=$chunkStart startOffset=$startOffset absolute=$absolutePosition isResuming=$_isResuming',
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
    // PC-3: この speak 自身の generation。以後の await 復帰ごとに、fence や
    // より新しい speak に supersede されていないかを確認する。
    final generation = ++_resumeGeneration;
    await _initFuture;
    if (generation != _resumeGeneration) return;
    _resumeFenced = false; // 新しい owner の再生開始で fence を解除（C3）
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
    if (generation != _resumeGeneration) return;
    _isStopped = false;

    // メディアセッションをアクティブ化（Bluetooth・通知ボタン対応）
    await AudioService.androidForceEnableMediaButtons();
    if (generation != _resumeGeneration) return;

    await _tts.setSpeechRate(speed * 0.5);
    await _tts.setPitch(pitch);
    await _tts.setVolume(volume);
    if (voiceId != null) {
      await _tts.setVoice({'name': voiceId, 'locale': 'ja-JP'});
    }
    if (generation != _resumeGeneration) return;

    // テキストをチャンクに分割
    _chunks = _splitText(text, startPosition);
    _currentChunkIndex = 0;

    // Observability: 実際にエンジンへ渡された開始位置を記録（本文は含めない）。
    // この時点ではまだ_playChunk()/_tts.speak()を呼んでおらず実際の発話は
    // 開始していないため、誤解を避けるためイベント名は"prepared"とする。
    await DebugLogger.instance.logEvent('tts_play_prepared', {
      'requestedStartPosition': startPosition,
      'chunkCount': _chunks.length,
      'firstChunkStartPosition': _chunks.isNotEmpty ? _chunks.first.startPosition : -1,
    });
    if (generation != _resumeGeneration) return;

    if (_chunks.isEmpty) return;

    // 前回の再生(別セッション/別コンテンツ)の_currentPositionが残っていると、
    // 実際に_playChunk()がチャンク先頭位置へ補正するより前に、この直後の
    // customState.addが古い位置をisPlaying:trueとして発信してしまう
    // （Quick Listen症状1調査で判明）。_playChunk()と同じ基準へ先に合わせておく。
    _currentPosition = _chunks.first.startPosition;

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
    // PC-3: 入口で generation を capture し、await 復帰ごとに再確認する。
    final generation = _resumeGeneration;
    await _initFuture;
    // retire 済み owner の text を復活させない（C3）
    if (!_isResumeGenerationCurrent(generation)) return;
    // メディアセッションをアクティブ化（Bluetooth・通知ボタン対応）
    await AudioService.androidForceEnableMediaButtons();
    if (!_isResumeGenerationCurrent(generation)) return;
    if (_isPaused && !_isStopped && _chunks.isNotEmpty) {
      // 一時停止からの再開
      _isPaused = false;
      _isResuming = true; // 再開直後フラグをセット（FIX-021）
      // FIX-021調査用ログ
      final chunkStart = _chunks.isNotEmpty ? _chunks[_currentChunkIndex].startPosition : 0;
      await DebugLogger.instance.onResume(_currentPosition, _currentChunkIndex, chunkStart);
      if (!_isResumeGenerationCurrent(generation)) return;
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
      // 停止後の再開（停止時の位置から）。speak() は開始時に generation を進め、
      // 以後の await 復帰でも fence / 新 owner による supersede を検査する。
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
    if (_resumeFenced) return; // fence 後に通知/controls を再表示しない（C3）
    _positionTimer?.cancel();
    _isPaused = true;
    _pausedPosition = _currentPosition; // 一時停止位置を保存（FIX-021）
    // FIX-021調査用ログ
    await DebugLogger.instance.onPause(_currentPosition, _currentChunkIndex);
    await DebugLogger.instance.logEvent('tts_pause', {
      'currentPosition': _currentPosition,
      'chunkIndex': _currentChunkIndex,
    });
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
    await DebugLogger.instance.logEvent('tts_stop', {
      'lastPosition': _lastStoppedPosition,
    });
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

  /// Shared Player Core C3（Detailed Design v1.2 FINAL §6.5）。
  ///
  /// owner guard を通過した owner-retiring teardown（stop 済み）からのみ
  /// 呼ばれる。`play()` の再開条件（`_isPaused && !_isStopped && chunks` と
  /// `_isStopped && _lastText != null`）を両方 false にし、notification Play /
  /// audio interruption resume から retire 済み text を再生できなくする。
  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async {
    // PC-3: 進行中の play()/speak() continuation を supersede する。
    _resumeGeneration++;
    await _initFuture;
    _resumeGeneration++;
    _positionTimer?.cancel();
    _resumeFenced = true;
    _lastText = null;
    _chunks = [];
    _currentChunkIndex = 0;
    _lastStoppedPosition = 0;
    _pausedPosition = 0;
    _isPaused = false;
    _isResuming = false;
    _isStopped = true;
    switch (notificationDisposition) {
      case NotificationDisposition.clearIfNoLiveOwner:
        // NEW-Q1=A: 他 live owner が無い terminal close では media notification
        // を完全に消す（audio_service 0.18 系で使える最小操作。実機表示は
        // T-C3d の Device Acceptance で確認する）。
        mediaItem.add(null);
        playbackState.add(playbackState.value.copyWith(
          playing: false,
          processingState: AudioProcessingState.idle,
          controls: [],
        ));
      case NotificationDisposition.handoff:
        // 旧 owner の media controls（Play）を無効化する。次 owner の speak()
        // が新しい media state を設定する。
        playbackState.add(playbackState.value.copyWith(
          playing: false,
          processingState: AudioProcessingState.idle,
          controls: [],
        ));
    }
    await DebugLogger.instance.logEvent('tts_resume_state_discarded', {
      'notificationDisposition': notificationDisposition.name,
    });
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
