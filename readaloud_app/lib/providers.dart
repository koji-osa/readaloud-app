import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'repository/tts/device_tts_service.dart';
import 'repository/impl/content_repository_impl.dart';
import 'repository/impl/playback_repository_impl.dart';
import 'repository/impl/settings_repository_impl.dart';
import 'usecase/content/library_promotion_service.dart';
import 'usecase/content/save_content_usecase.dart';
import 'usecase/playback/persistent_playback_resolver.dart';
import 'usecase/playback/playback_defaults_reader.dart';
import 'usecase/playback/playback_usage_accounting.dart';
import 'usecase/playback/save_playback_state_usecase.dart';
import 'usecase/playback/shared_playback_transport.dart';
import 'usecase/tts/check_tts_limit_usecase.dart';
import 'usecase/tts/count_tts_usage_usecase.dart';
import 'util/normal_player_session_tracker.dart';
import 'viewmodel/quick_listen_viewmodel.dart';

// audio_serviceのシングルトンをRiverpodで提供
final audioHandlerProvider = Provider<TtsAudioHandler>((ref) {
  throw UnimplementedError(
      'audioHandlerProviderはProviderScopeのoverridesで初期化してください');
});

/// Shared Player Core（Detailed Design v1.2 FINAL §5）: Normal Player と
/// Transient が共有する唯一の再生 Transport。app-shared / 非 autoDispose /
/// DB 非依存。破棄は provider lifecycle のみ（R-7）。
final sharedPlaybackTransportProvider =
    Provider<SharedPlaybackTransport>((ref) {
  final audioHandler = ref.read(audioHandlerProvider);
  final transport = SharedPlaybackTransport(
    tts: audioHandler,
    positionStream: audioHandler.customState,
    currentPosition: () => audioHandler.currentPosition,
    resumeFence: audioHandler,
  );
  ref.onDispose(transport.dispose);
  return transport;
});

/// Normal Player の playback/usage-accounting stack。app-shared 1 instance
/// として提供する（Canonical v0.4.1 D3）。ここで CountTtsUsageUseCase を
/// autoDispose provider の外で保持することで、複数の Normal Player session を
/// またいで同一 instance が使われ続け、D13 の owner-aware guard
/// （stale stop が別 session の counter を汚染しない）が実際に意味を持つ。
///
/// Shared Player Core: usage counter はアプリ内でこの1 instanceだけで、
/// Persistent 用 [PersistentUsageAccounting] 経由でのみ使われる（PD-1 / AC-14）。
final normalPlayerPlaybackGateProvider =
    Provider<NormalPlayerPlaybackGate>((ref) {
  final contentRepo = ContentRepositoryImpl();
  final playbackRepo = PlaybackRepositoryImpl();
  final settingsRepo = SettingsRepositoryImpl();

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

  final gate = NormalPlayerPlaybackGate.shared(
    transport: ref.read(sharedPlaybackTransportProvider),
    resolver: PersistentPlaybackResolver(
      contentRepo: contentRepo,
      playbackRepo: playbackRepo,
    ),
    playbackRepo: playbackRepo,
    savePlaybackState: savePlaybackState,
    accounting: PersistentUsageAccounting(countTtsUsage),
  );
  // R-7: gate の破棄は provider の lifecycle だけが行う（VM dispose では破棄しない）。
  ref.onDispose(() {
    gate.dispose();
    countTtsUsage.dispose();
  });
  return gate;
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

/// Transient（Quick Listen）controller。
///
/// Shared Player Core: QL専用の CountTtsUsageUseCase は生成しない
/// （PD-1: Transient は usage 計上対象外。counter は Persistent 用 1 instance のみ）。
/// write-capable な SettingsRepository は read-only adapter の内部にだけ閉じる（INV-T1）。
/// Pre-Commit M-1: UI（quick_listen_screen.dart）から provider 層へ移した。
final quickListenViewModelProvider =
    StateNotifierProvider.autoDispose<QuickListenViewModel, QuickListenState>(
        (ref) {
  final defaultsReader =
      SettingsPlaybackDefaultsReader(SettingsRepositoryImpl());
  return QuickListenViewModel(
    transport: ref.read(sharedPlaybackTransportProvider),
    defaultsReader: defaultsReader,
    // Library への唯一の書込み seam（新規 Content 行 + その行の初期 PlaybackState のみ）。
    promotion: LibraryPromotionService(
      saveContent: SaveContentUseCase(ContentRepositoryImpl()),
      playbackRepo: PlaybackRepositoryImpl(),
      defaultsReader: defaultsReader,
    ),
  );
});
