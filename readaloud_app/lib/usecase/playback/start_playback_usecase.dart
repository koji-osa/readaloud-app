import 'dart:async';
import '../../model/normal_player_session.dart';
import '../../model/tts_playback_position.dart';
import '../../repository/content_repository.dart';
import '../../repository/playback_repository.dart';
import '../../repository/tts/tts_service.dart';
import '../../model/playback_state.dart';
import '../tts/count_tts_usage_usecase.dart';
import '../../util/debug_logger.dart';

class StartPlaybackUseCase {
  final ContentRepository _contentRepo;
  final PlaybackRepository _playbackRepo;
  // TtsAudioHandler（具象クラス）ではなく position stream を直接受け取る。
  // QuickListenViewModel の positionStream 注入と同じ方式にすることで、
  // fake stream によるテスト容易性を確保する（audio_service の重量な
  // 具象クラスをテストでfakeする必要が無くなる）。
  final Stream<dynamic> _positionStream;
  final TtsService _ttsService;
  final CountTtsUsageUseCase _countUsage;

  StreamSubscription<dynamic>? _positionSubscription;

  // v0.4.1 D15 position-stream gating: BehaviorSubject相当の customState は
  // resubscribe直後に直前の（別session由来の）最終値を再送しうる。このuse
  // case自身のspeak()呼び出しによる「このsession自身の再生開始」を確認する
  // までは、usage計測へposition更新を反映しない（Quick Listenの既存実証済み
  // パターンと同型）。
  bool _hasCalledSpeakForCurrentExecute = false;
  bool _acceptPositionUpdates = false;

  StartPlaybackUseCase({
    required ContentRepository contentRepo,
    required PlaybackRepository playbackRepo,
    required Stream<dynamic> positionStream,
    required TtsService ttsService,
    required CountTtsUsageUseCase countUsage,
  })  : _contentRepo = contentRepo,
        _playbackRepo = playbackRepo,
        _positionStream = positionStream,
        _ttsService = ttsService,
        _countUsage = countUsage;

  Future<void> execute(String contentId,
      {required PlaybackOwnerKey owner}) async {
    final content = await _contentRepo.getById(contentId);
    if (content == null) throw Exception('コンテンツが見つかりません: $contentId');

    // 再生状態を取得（なければ初期値で作成）
    final state = await _playbackRepo.getByContentId(contentId) ??
        PlaybackState(contentId: contentId);

    // コンテンツのステータスを「読書中」に更新
    await _contentRepo.update(
      content.copyWith(status: 'in_progress'),
    );

    _hasCalledSpeakForCurrentExecute = false;
    _acceptPositionUpdates = false;

    // customStateを購読してCountTtsUsageUseCaseに位置を通知
    _positionSubscription?.cancel();
    _positionSubscription = _positionStream.listen((data) {
      if (data is! TtsPlaybackPosition) return;
      if (!_acceptPositionUpdates &&
          _hasCalledSpeakForCurrentExecute &&
          data.isPlaying) {
        _acceptPositionUpdates = true;
      }
      if (!_acceptPositionUpdates) return;
      _countUsage.updatePosition(data.charPosition);
    });

    // TTS使用量カウント開始
    _countUsage.startCounting(
      owner: owner,
      totalChars: content.charCount,
      startPosition: state.position,
    );

    // Observability: play()相当の直前状態を記録（本文は含めない）
    await DebugLogger.instance.logEvent('tts_play_requested', {
      'origin': 'player',
      'contentId': contentId,
      'startPositionPassedToSpeak': state.position,
    });

    // 読み上げ開始直前にゲートを開ける。これ以降に届くcustomStateイベントの
    // うち、実際にisPlaying==trueとなる最初のイベント（=このexecute()自身の
    // 再生開始）以降だけがusage計測へ反映されるようになる。
    _hasCalledSpeakForCurrentExecute = true;
    await _ttsService.speak(
      text: content.body,
      startPosition: state.position,
      speed: state.speed,
      pitch: state.pitch,
      volume: state.volume,
      voiceId: state.voiceId,
    );
  }

  void dispose() {
    _positionSubscription?.cancel();
  }
}
