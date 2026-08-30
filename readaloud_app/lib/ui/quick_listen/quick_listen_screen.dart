import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../model/quick_listen_session.dart';
import '../../providers.dart';
import '../../repository/impl/content_repository_impl.dart';
import '../../repository/impl/settings_repository_impl.dart';
import '../../usecase/content/save_content_usecase.dart';
import '../../usecase/tts/check_tts_limit_usecase.dart';
import '../../usecase/tts/count_tts_usage_usecase.dart';
import '../../viewmodel/quick_listen_viewmodel.dart';
import '../home/home_screen.dart';
import '../player/widgets/highlight_text.dart';

final quickListenViewModelProvider = StateNotifierProvider.autoDispose<
    QuickListenViewModel, QuickListenState>((ref) {
  final audioHandler = ref.read(audioHandlerProvider);
  final settingsRepo = SettingsRepositoryImpl();
  final checkTtsLimit = CheckTtsLimitUseCase(settingsRepo: settingsRepo);
  final countTtsUsage = CountTtsUsageUseCase(
    settingsRepo: settingsRepo,
    checkLimit: checkTtsLimit,
  );
  return QuickListenViewModel(
    ttsService: audioHandler,
    settingsRepo: settingsRepo,
    saveContent: SaveContentUseCase(ContentRepositoryImpl()),
    countUsage: countTtsUsage,
    positionStream: audioHandler.customState,
    getCurrentPosition: () => audioHandler.currentPosition,
  );
});

/// 共有された通常テキストをDBに保存せずその場で読み上げるための画面。
/// 「保存」を押すまでContent DBには一切書き込まれない。
class QuickListenScreen extends ConsumerStatefulWidget {
  final String initialText;
  final String? initialTitle;

  const QuickListenScreen({
    super.key,
    required this.initialText,
    this.initialTitle,
  });

  @override
  ConsumerState<QuickListenScreen> createState() => _QuickListenScreenState();
}

class _QuickListenScreenState extends ConsumerState<QuickListenScreen> {
  @override
  void initState() {
    super.initState();
    // ref.read()はinitState内でも安全（ref.watchのみ避ければよい）。
    // postFrameCallbackを介さないことで、セッション未設定の空表示が一瞬
    // 出てしまう問題も避けられる。
    ref.read(quickListenViewModelProvider.notifier).start(
          QuickListenSession(
            text: widget.initialText,
            title: widget.initialTitle,
          ),
        );
  }

  Future<void> _close() async {
    await ref.read(quickListenViewModelProvider.notifier).close();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _save() async {
    final content =
        await ref.read(quickListenViewModelProvider.notifier).save();
    if (!mounted || content == null) return;
    ref.read(contentListViewModelProvider.notifier).loadContents();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ReadAloudに保存しました'),
        backgroundColor: Color(0xFF7C5CBF),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(quickListenViewModelProvider);
    final vm = ref.read(quickListenViewModelProvider.notifier);
    final session = state.session;

    ref.listen(quickListenViewModelProvider, (prev, next) {
      if (next.errorMessage != null && next.errorMessage != prev?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.errorMessage!),
            backgroundColor: const Color(0xFFF87171),
          ),
        );
        vm.clearError();
      }
    });

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 18, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF8888AA)),
                    onPressed: _close,
                  ),
                  const Expanded(
                    child: Text(
                      'Quick Listen',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF0F0F8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: HighlightText(
                  text: session?.text ?? '',
                  highlightPosition: state.highlightPosition,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: state.hasSaved || state.isSaving || session == null
                          ? null
                          : _save,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF9B6FE0),
                        side: const BorderSide(color: Color(0xFF3A3A55)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(state.hasSaved ? '保存済み' : 'ReadAloudに保存'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    iconSize: 56,
                    color: const Color(0xFF7C5CBF),
                    icon: Icon(
                      state.isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                    ),
                    onPressed: session == null
                        ? null
                        : (state.isPlaying ? vm.pause : vm.play),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
