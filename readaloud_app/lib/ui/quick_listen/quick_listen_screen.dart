import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../model/player_capabilities.dart';
import '../../model/playback_request.dart';
import '../../model/quick_listen_session.dart';
import '../../providers.dart';
import '../../util/auto_title.dart';
import '../home/home_screen.dart';
import '../player/widgets/highlight_text.dart';
import '../player/widgets/playback_controls.dart';
import '../../util/debug_logger.dart';

// Pre-Commit M-1: provider 定義は provider 層（providers.dart）へ移した。
// 既存の import 経路（`quick_listen_screen.dart` から provider を参照する側）を
// 保つため re-export だけを残す（UI → provider の一方向依存）。
export '../../providers.dart' show quickListenViewModelProvider;

/// 共有された通常テキスト等をDBに保存せずその場で読み上げるTransient Player画面。
/// 「Libraryに保存」を押すまでContent DBには一切書き込まれない。
class QuickListenScreen extends ConsumerStatefulWidget {
  /// 共有テキスト（生）。[initialRequest] が無い場合に TextCleaner を1回だけ適用する。
  final String? initialText;
  final String? initialTitle;

  /// 解決済みの Transient 再生要求（`openTransient(request:)` 経路）。
  final PlaybackRequest? initialRequest;

  const QuickListenScreen({
    super.key,
    this.initialText,
    this.initialTitle,
    this.initialRequest,
  }) : assert(initialText != null || initialRequest != null);

  @override
  ConsumerState<QuickListenScreen> createState() => _QuickListenScreenState();
}

class _QuickListenScreenState extends ConsumerState<QuickListenScreen> {
  /// widget構築時点で確定する、この画面のsession（purely in-memoryな値オブジェクトの
  /// 構築であり、provider変更ではないためbuild中でも安全）。
  late final QuickListenSession _initialSession = () {
    final request = widget.initialRequest;
    return request != null
        ? QuickListenSession(request: request)
        : QuickListenSession.fromSharedText(
            widget.initialText!,
            title: widget.initialTitle,
          );
  }();

  String get _sessionId => _initialSession.id;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    // RA-QL-LIFECYCLE-FIX-01: Riverpodは新規mount時のbuild中（widget tree
    // がbuild-lock下にある間）のprovider変更を許さない（実機Device
    // Acceptanceで確認。initStateもこのlock下で実行され得る）。
    //
    // 最初のbuild()はquickListenViewModelProviderをwatchするが、session
    // はまだ反映されていないため、widget構築時に確定済みの[_initialSession]
    // から直接表示する（空表示を避ける。詳細はbuild()参照）。provider への
    // start()反映は、最初のbuild()がwatchを確立しbuildScopeが完了した直後
    // まで1 microtaskだけ遅延する（Timer/delay-msは使わない）。
    //
    // 最初のbuild()がこのscreen自身の中でquickListenViewModelProviderを
    // 既にwatchしているため、このmicrotaskが実行される時点でprovider
    // には有効なlistenerが存在し、autoDisposeで消えることもない。
    Future.microtask(() {
      if (!mounted) return;
      ref.read(quickListenViewModelProvider.notifier).start(_initialSession);
    });
    DebugLogger.instance.logEvent('quick_listen_screen_mounted', {
      'sessionId': _sessionId,
    });
  }

  @override
  void dispose() {
    DebugLogger.instance.logEvent('quick_listen_screen_disposed', {
      'sessionId': _sessionId,
    });
    super.dispose();
  }

  /// terminal close（× / system back / predictive back）。INV-T3:
  /// この画面自身の session を expectedOwner とする owner-safe teardown の
  /// 結果に関わらず、自分の route だけを identity-safe に閉じる。
  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    await ref
        .read(quickListenViewModelProvider.notifier)
        .close(sessionId: _sessionId);
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else if (route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
  }

  Future<void> _save() async {
    final content =
        await ref.read(quickListenViewModelProvider.notifier).save();
    if (!mounted || content == null) return;
    ref.read(contentListViewModelProvider.notifier).loadContents();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Libraryに保存しました'),
        backgroundColor: Color(0xFF7C5CBF),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(quickListenViewModelProvider);
    final vm = ref.read(quickListenViewModelProvider.notifier);
    // provider側がまだ自分のsessionを反映していない最初のbuildでは、
    // widget構築時に確定済みの_initialSessionから直接表示する（空表示を
    // 避ける）。再生操作（play/pause/save等）はprovider側のsessionが
    // 必要なため、その間はno-opのままにする（start()は1microtask後に
    // 必ず反映されるため、人間の操作がこのわずかな窓に間に合うことはない）。
    final providerSession =
        state.session?.id == _sessionId ? state.session : null;
    final session = providerSession;
    final request = providerSession?.request ?? _initialSession.request;
    // capability の判定はこの composition root でだけ行う（PD-2）。
    const caps = PlayerCapabilities.transientPhase1;

    ref.listen(quickListenViewModelProvider, (prev, next) {
      if (next.errorMessage != null &&
          next.errorMessage != prev?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.errorMessage!),
            backgroundColor: const Color(0xFFF87171),
          ),
        );
        vm.clearError();
      }
    });

    // PD-3: Sourceタイトル、無ければ既存の自動タイトル（「Quick Listen」は表示しない）。
    final heading = request.title ??
        autoTitleFromBody(request.text, request.source?.sourceType ?? 'share');

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _close();
      },
      child: Scaffold(
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
                    Expanded(
                      child: Text(
                        heading,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
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
                    text: request.text,
                    highlightPosition: state.highlightPosition,
                    onTap: caps.tapToSeek && session != null
                        ? (position) => vm.seekToPosition(position)
                        : null,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: PlaybackControls(
                  isPlaying: state.isPlaying,
                  speed: request.voice.speed,
                  onPlay: session == null ? () {} : vm.play,
                  onPause: session == null ? () {} : vm.pause,
                  onSeekToStart: caps.seekToStart && session != null
                      ? vm.seekToStart
                      : null,
                  // PD-2: 以下は Transient Phase 1 では表示しない。
                  onStop: null,
                  onSeekToEnd: null,
                  onRewind: null,
                  onFastForward: null,
                  onSpeedChange: null,
                  onVoiceChange: null,
                ),
              ),
              if (caps.libraryPromotion)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed:
                          state.hasSaved || state.isSaving || session == null
                              ? null
                              : _save,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF9B6FE0),
                        side: const BorderSide(color: Color(0xFF3A3A55)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(state.hasSaved ? '保存済み' : 'Libraryに保存'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
