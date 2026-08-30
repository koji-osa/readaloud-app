import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/content.dart';
import '../model/quick_listen_session.dart';
import '../model/setting.dart';
import '../model/tts_playback_position.dart';
import '../repository/settings_repository.dart';
import '../repository/tts/tts_service.dart';
import '../usecase/content/save_content_usecase.dart';
import '../usecase/tts/count_tts_usage_usecase.dart';

class QuickListenState {
  final QuickListenSession? session;
  final bool isPlaying;
  final int highlightPosition;
  final TtsStatus ttsStatus;
  final bool isSaving;
  final Content? savedContent;
  final String? errorMessage;

  const QuickListenState({
    this.session,
    this.isPlaying = false,
    this.highlightPosition = 0,
    this.ttsStatus = TtsStatus.stopped,
    this.isSaving = false,
    this.savedContent,
    this.errorMessage,
  });

  bool get hasSaved => savedContent != null;

  QuickListenState copyWith({
    QuickListenSession? session,
    bool? isPlaying,
    int? highlightPosition,
    TtsStatus? ttsStatus,
    bool? isSaving,
    Content? savedContent,
    String? errorMessage,
  }) =>
      QuickListenState(
        session: session ?? this.session,
        isPlaying: isPlaying ?? this.isPlaying,
        highlightPosition: highlightPosition ?? this.highlightPosition,
        ttsStatus: ttsStatus ?? this.ttsStatus,
        isSaving: isSaving ?? this.isSaving,
        savedContent: savedContent ?? this.savedContent,
        errorMessage: errorMessage,
      );
}

/// Quick Listen専用の再生アダプタ。
///
/// 既存のTtsService(audio_service)をそのまま利用して読み上げを行い、
/// Content DB・PlaybackRepository・BookmarkRepositoryのいずれにも依存しない。
/// 再生位置は外部（TtsAudioHandler.customState）から渡されるstreamで受け取るだけで、
/// DBへは一切書き込まない。
class QuickListenViewModel extends StateNotifier<QuickListenState> {
  final TtsService _ttsService;
  final SettingsRepository _settingsRepo;
  final SaveContentUseCase _saveContent;
  final CountTtsUsageUseCase _countUsage;
  final int Function() _getCurrentPosition;

  StreamSubscription<dynamic>? _positionSubscription;

  QuickListenViewModel({
    required TtsService ttsService,
    required SettingsRepository settingsRepo,
    required SaveContentUseCase saveContent,
    required CountTtsUsageUseCase countUsage,
    required Stream<dynamic> positionStream,
    required int Function() getCurrentPosition,
  })  : _ttsService = ttsService,
        _settingsRepo = settingsRepo,
        _saveContent = saveContent,
        _countUsage = countUsage,
        _getCurrentPosition = getCurrentPosition,
        super(const QuickListenState()) {
    _positionSubscription = positionStream.listen((data) {
      if (data is! TtsPlaybackPosition) return;
      state = state.copyWith(
        highlightPosition: data.charPosition,
        isPlaying: data.isPlaying,
        ttsStatus: data.ttsStatus,
      );
    });
  }

  /// 新しい共有テキストでセッションを開始する。
  /// 既存セッションがある場合はMVP仕様として単純に置き換える（DB操作なし）。
  void start(QuickListenSession session) {
    state = QuickListenState(session: session);
  }

  Future<void> play() async {
    final session = state.session;
    if (session == null || session.text.trim().isEmpty) return;
    try {
      final defaultSpeedStr =
          await _settingsRepo.get(SettingKeys.defaultSpeed) ?? '1.0';
      final speed = double.tryParse(defaultSpeedStr) ?? 1.0;
      _countUsage.startCounting(
        contentId: 'quick-listen:${session.id}',
        totalChars: session.text.length,
        startPosition: state.highlightPosition,
      );
      await _ttsService.speak(
        text: session.text,
        startPosition: state.highlightPosition,
        speed: speed,
      );
      state = state.copyWith(isPlaying: true);
    } catch (e) {
      state = state.copyWith(errorMessage: '再生に失敗しました: $e');
    }
  }

  Future<void> pause() async {
    final position = _getCurrentPosition();
    await _countUsage.stopCounting('quick-listen');
    await _ttsService.pause();
    state = state.copyWith(isPlaying: false, highlightPosition: position);
  }

  /// セッションを破棄する。TTSを止めるだけでDBへの変更は一切行わない。
  Future<void> close() async {
    await _countUsage.stopCounting('quick-listen');
    await _ttsService.stop();
    state = const QuickListenState();
  }

  /// 通常Contentへ昇格保存する（DBへは初めてここで1回だけ書き込む）。
  /// 既に保存済み・保存処理中の場合は何もせず既存の結果を返す（二重保存防止）。
  Future<Content?> save() async {
    final session = state.session;
    if (session == null) return null;
    if (state.isSaving || state.hasSaved) return state.savedContent;

    state = state.copyWith(isSaving: true, errorMessage: null);
    try {
      final content = await _saveContent.execute(
        body: session.text,
        sourceType: session.sourceType,
        title: session.title,
      );
      state = state.copyWith(
        isSaving: false,
        savedContent: content,
        session: session.copyWith(saved: true),
      );
      return content;
    } catch (e) {
      state = state.copyWith(
        isSaving: false,
        errorMessage: '保存に失敗しました: $e',
      );
      return null;
    }
  }

  void clearError() => state = state.copyWith(errorMessage: null);

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _countUsage.dispose();
    super.dispose();
  }
}
