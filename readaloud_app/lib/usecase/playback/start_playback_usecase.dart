import 'dart:async';
import '../../repository/content_repository.dart';
import '../../repository/playback_repository.dart';
import '../../repository/tts/tts_service.dart';
import '../../model/playback_state.dart';
import '../tts/count_tts_usage_usecase.dart';

class StartPlaybackUseCase {
  final ContentRepository _contentRepo;
  final PlaybackRepository _playbackRepo;
  final TtsService _ttsService;
  final CountTtsUsageUseCase _countUsage;

  StreamSubscription<int>? _positionSubscription;

  StartPlaybackUseCase({
    required ContentRepository contentRepo,
    required PlaybackRepository playbackRepo,
    required TtsService ttsService,
    required CountTtsUsageUseCase countUsage,
  })  : _contentRepo = contentRepo,
        _playbackRepo = playbackRepo,
        _ttsService = ttsService,
        _countUsage = countUsage;

  Future<void> execute(String contentId) async {
    final content = await _contentRepo.getById(contentId);
    if (content == null) throw Exception('コンテンツが見つかりません: $contentId');

    // 再生状態を取得（なければ初期値で作成）
    final state = await _playbackRepo.getByContentId(contentId) ??
        PlaybackState(contentId: contentId);

    // コンテンツのステータスを「読書中」に更新
    await _contentRepo.update(
      content.copyWith(status: 'in_progress'),
    );

    // positionStreamを購読してCountTtsUsageUseCaseに位置を通知
    _positionSubscription?.cancel();
    _positionSubscription = _ttsService.positionStream.listen((position) {
      _countUsage.updatePosition(position);
    });

    // TTS使用量カウント開始
    _countUsage.startCounting(
      contentId: contentId,
      totalChars: content.charCount,
      startPosition: state.position,
    );

    // 読み上げ開始
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
