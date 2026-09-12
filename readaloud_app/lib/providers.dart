import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'repository/tts/device_tts_service.dart';
import 'repository/impl/content_repository_impl.dart';
import 'repository/impl/playback_repository_impl.dart';
import 'repository/impl/settings_repository_impl.dart';
import 'usecase/playback/save_playback_state_usecase.dart';
import 'usecase/playback/start_playback_usecase.dart';
import 'usecase/playback/stop_playback_usecase.dart';
import 'usecase/tts/check_tts_limit_usecase.dart';
import 'usecase/tts/count_tts_usage_usecase.dart';
import 'util/normal_player_session_tracker.dart';

// audio_serviceのシングルトンをRiverpodで提供
final audioHandlerProvider = Provider<TtsAudioHandler>((ref) {
  throw UnimplementedError(
      'audioHandlerProviderはProviderScopeのoverridesで初期化してください');
});

/// Normal Player の playback/usage-accounting stack。app-shared 1 instance
/// として提供する（Canonical v0.4.1 D3）。ここで CountTtsUsageUseCase を
/// autoDispose provider の外で保持することで、複数の Normal Player session を
/// またいで同一 instance が使われ続け、D13 の owner-aware guard
/// （stale stop が別 session の counter を汚染しない）が実際に意味を持つ。
final normalPlayerPlaybackGateProvider =
    Provider<NormalPlayerPlaybackGate>((ref) {
  final contentRepo = ContentRepositoryImpl();
  final playbackRepo = PlaybackRepositoryImpl();
  final settingsRepo = SettingsRepositoryImpl();
  final audioHandler = ref.read(audioHandlerProvider);

  final checkTtsLimit = CheckTtsLimitUseCase(
    settingsRepo: settingsRepo,
    onLimitStatus: (status) {
      // 通知不要（バナーで表示）
    },
  );
  final countTtsUsage = CountTtsUsageUseCase(
    settingsRepo: settingsRepo,
    checkLimit: checkTtsLimit,
  );
  final savePlaybackState = SavePlaybackStateUseCase(
    playbackRepo: playbackRepo,
    contentRepo: contentRepo,
  );

  return NormalPlayerPlaybackGate(
    startPlayback: StartPlaybackUseCase(
      contentRepo: contentRepo,
      playbackRepo: playbackRepo,
      positionStream: audioHandler.customState,
      ttsService: audioHandler,
      countUsage: countTtsUsage,
    ),
    stopPlayback: StopPlaybackUseCase(
      playbackRepo: playbackRepo,
      ttsService: audioHandler,
      countUsage: countTtsUsage,
      saveState: savePlaybackState,
    ),
    getCurrentPosition: () => audioHandler.currentPosition,
  );
});

/// Normal Player の session 権威（D3: app-shared Riverpod、autoDisposeしない）。
/// content・PlayerViewModel・TTS state は保持しない。navigation identity と
/// retirement claim のみを保持する。
final normalPlayerSessionTrackerProvider =
    Provider<NormalPlayerSessionTracker>((ref) {
  return NormalPlayerSessionTracker(
    playbackGate: ref.read(normalPlayerPlaybackGateProvider),
  );
});
