import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show kReleaseMode, kProfileMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ui/onboarding/onboarding_screen.dart';
import 'ui/home/home_screen.dart';
import 'ui/add/add_screen.dart';
import 'repository/settings_repository.dart';
import 'repository/impl/settings_repository_impl.dart';
import 'repository/tts/device_tts_service.dart';
import 'providers.dart';
import 'model/quick_listen_session.dart';
import 'model/setting.dart';
import 'usecase/playback/shared_playback_transport.dart' show TeardownReason;
import 'util/share_intent_handler.dart';
import 'util/external_input_handler.dart';
import 'util/debug_logger.dart';
import 'util/player_entry_coordinator.dart';
import 'util/share_fingerprint.dart';

const String kAppVersion = '1.2.23+44';

// No.94 Observability: ビルド時に`--dart-define=BUILD_COMMIT=<git sha>`で
// 埋め込む。未指定のbuildではbuildCommit=unknownとなる（既存buildを壊さない
// 最小構成のため、大規模なbuild system変更は行わない）。
const String kBuildCommit =
    String.fromEnvironment('BUILD_COMMIT', defaultValue: 'unknown');

/// production の audio_service 設定。T1b / platform-boundary test が
/// literal を複製して「自分自身を検証する」のを防ぐため、唯一の定義点とする。
const AudioServiceConfig kAudioServiceConfig = AudioServiceConfig(
  androidNotificationChannelId: 'com.example.readaloud_app.audio',
  androidNotificationChannelName: 'ReadAloud',
  androidNotificationOngoing: false,
  androidStopForegroundOnPause: true,
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // audio_service初期化（TtsAudioHandlerのシングルトンを生成）
  final audioHandler = await AudioService.init(
    builder: () => TtsAudioHandler(),
    config: kAudioServiceConfig,
  );

  await AudioService.androidForceEnableMediaButtons();

  // FIX-021調査用ログ初期化
  await DebugLogger.instance.init(appVersion: kAppVersion);

  // No.94 Observability: どのAPKが入っていたかをログ冒頭で確認できるようにする。
  final versionParts = kAppVersion.split('+');
  unawaited(DebugLogger.instance.logEvent('app_build_identity', {
    'versionName': versionParts.first,
    'versionCode': versionParts.length > 1 ? versionParts[1] : 'unknown',
    'buildCommit': kBuildCommit,
    'buildMode':
        kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
  }));
  unawaited(DebugLogger.instance.logEvent('app_entry_init', {
    'buildCommit': kBuildCommit,
  }));

  runApp(
    ProviderScope(
      overrides: [
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const ReadAloudApp(),
    ),
  );
}

class ReadAloudApp extends ConsumerWidget {
  const ReadAloudApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'ReadAloud',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C5CBF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0C0C18),
        useMaterial3: true,
      ),
      home: const AppEntryPoint(),
    );
  }
}

// オンボーディング完了済みかチェックして画面を振り分け
class AppEntryPoint extends ConsumerStatefulWidget {
  const AppEntryPoint({super.key});

  @override
  ConsumerState<AppEntryPoint> createState() => _AppEntryPointState();
}

class _AppEntryPointState extends ConsumerState<AppEntryPoint>
    with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _onboardingCompleted = false;
  late ShareIntentHandler _shareIntentHandler;
  late ExternalInputHandler _externalInputHandler;

  // Persistent Share Observability Phase 1: build()のたびに大量ログを
  // 出さないよう、直前に記録したroot targetを保持し、変化した時だけ記録する。
  String? _lastLoggedRootTarget;
  bool _firstPostFrameLogged = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(DebugLogger.instance.logEvent('app_entry_point_mounted', {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 最初のframe描画後に1回だけ記録する。native Activityがresumed済み
      // なのに、Flutter widget側がどこまで進んでいたかを事後確認するための
      // マーカー（No.94診断用、Observability only）。
      if (_firstPostFrameLogged) return;
      _firstPostFrameLogged = true;
      unawaited(DebugLogger.instance
          .logEvent('app_entry_point_first_post_frame', {}));
    });
    _checkOnboarding();
    _initShareIntent();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(DebugLogger.instance.logEvent('app_lifecycle_state_changed', {
      'state': state.name,
    }));
  }

  // Persistent Share Observability Phase 1: build()が返そうとしている
  // root targetが変化した時だけ記録する（loading/home/onboarding）。
  void _logRootTargetIfChanged(String target) {
    if (_lastLoggedRootTarget == target) return;
    _lastLoggedRootTarget = target;
    unawaited(
        DebugLogger.instance.logEvent('app_root_target', {'target': target}));
  }

  void _initShareIntent() {
    _shareIntentHandler = ShareIntentHandler(
      onPayloadReceived: _handleSharedPayload,
    );
    // No.94 Share Event Architecture (Architecture Z): Androidの
    // text/plain ACTION_SEND / ACTION_PROCESS_TEXTはいずれも
    // ExternalInputHandler（native側ExternalInputEntryActivity +
    // 統合pending bridge。詳細はutil/external_input_handler.dartおよび
    // android/.../ExternalInputEntryActivity.kt参照）を唯一の配信経路
    // とする。flutter_sharing_intentのDart側stream(getMediaStream())を
    // Androidでも起動したままにすると、二重配信riskがある
    // （AndroidManifestはACTION_SEND/ACTION_PROCESS_TEXTのいずれも
    // MainActivityへは渡していないため、Androidでstreamを止めても
    // 他の共有機能は失われない）。非Android platformは従来どおり
    // flutter_sharing_intentが唯一の共有経路であり、この変更の影響を
    // 受けない。
    if (!Platform.isAndroid) {
      _shareIntentHandler.startListening();
    }
    _externalInputHandler = ExternalInputHandler(
      onPayloadReceived: _handleSharedPayload,
    );
    _externalInputHandler.startListening();
  }

  Future<void> _checkInitialShareIntent() async {
    // No.94 Share Event Architecture (Architecture Z): AndroidではACTION_SEND/
    // ACTION_PROCESS_TEXTいずれもExternalInputHandler経由でのみ取得し、
    // flutter_sharing_intentのgetInitialSharing()は呼ばない（結果に
    // 関わらずreturnする）。ExternalInputEntryActivityが両方の唯一の
    // ingressであるため、旧ProcessTextHandler/ActionSendHandler間の
    // arbitration（hasDeliveredProcessTextベースのfall-through回避）は
    // 単一handlerへの統合により構造的に不要化した。
    if (Platform.isAndroid) {
      await _externalInputHandler.pullInitialExternalInput();
      return;
    }

    final payload = await _shareIntentHandler.getInitialSharedPayload();
    if (payload != null) await _handleSharedPayload(payload);
  }

  // URL共有は既存のWeb import(URLタブ)へ、通常テキストの共有はQuick Listenへ振り分ける。
  // アプリ内部の「テキスト追加」はここを経由しないため、従来どおり手動保存のまま。
  Future<void> _handleSharedPayload(SharedTextPayload payload) async {
    // No.94 Observability: main.dart受領境界。mounted/空文字チェックより前に
    // 記録することで、そこで早期returnするケースでもcharCount/hashを
    // 確認できるようにする（本文そのものは含めない）。
    unawaited(DebugLogger.instance.logEvent('share_payload_handler_entered', {
      'flowId': payload.flowId,
      'kind': payload.kind.name,
      ...ShareFingerprint.metricsOf(payload.value).toLogFields(),
    }));

    if (!mounted) return;
    final value = payload.value.trim();
    if (value.isEmpty) return;
    // share_received/share_classifiedと同じflowIdをここから先のログにも
    // 付与し、initial/stream経路が重なっても1本のshare flowとして
    // 追跡できるようにする。
    final flowId = payload.flowId;

    // Shared Player Core Slice 6: D8 二相 teardown（NP retire → stop確認 →
    // Transient retire → mounted checkpoint → Transient route除去 → NP route除去
    // → covering push、除去〜pushはzero-await、claimはfinallyで解放）は
    // PlayerEntryCoordinator へ順序を変えずに抽出した。share 到着は
    // owner-retiring handoff（shareTeardown）として旧 owner の resume state を
    // fence してから次 owner へ渡す。
    final coordinator = ref.read(playerEntryCoordinatorProvider);
    if (payload.kind == SharedContentKind.url) {
      await coordinator.openCovering(
        context: context,
        isMounted: () => mounted,
        flowId: flowId,
        reason: TeardownReason.shareTeardown,
        pushCovering: (ctx) {
          unawaited(DebugLogger.instance.logEvent('navigation_push_requested', {
            'target': 'add_screen',
            'stackSource': 'share_handler',
            'flowId': flowId,
          }));
          Navigator.of(ctx).push(
            MaterialPageRoute(
              builder: (_) => AddScreen(initialUrl: value),
            ),
          );
        },
      );
    } else {
      await coordinator.openTransient(
        context: context,
        isMounted: () => mounted,
        // 共有 text は TextCleaner を1回だけ適用して request にする（INV-18）。
        request: QuickListenSession.fromSharedText(value).request,
        flowId: flowId,
        reason: TeardownReason.shareTeardown,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(DebugLogger.instance.logEvent('app_entry_point_disposed', {}));
    _shareIntentHandler.dispose();
    _externalInputHandler.dispose();
    super.dispose();
  }

  Future<void> _checkOnboarding() async {
    unawaited(DebugLogger.instance.logEvent('onboarding_check_started', {}));
    final SettingsRepository repo = SettingsRepositoryImpl();
    final completed = await repo.get(SettingKeys.onboardingCompleted);
    setState(() {
      _onboardingCompleted = completed == 'true';
      _isLoading = false;
    });
    unawaited(DebugLogger.instance.logEvent('onboarding_check_completed', {
      'onboardingCompleted': _onboardingCompleted,
    }));
    // オンボーディング確認後にShare Intentを確認
    await _checkInitialShareIntent();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      _logRootTargetIfChanged('loading');
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_onboardingCompleted) {
      _logRootTargetIfChanged('home');
      return const HomeScreen();
    }
    _logRootTargetIfChanged('onboarding');
    return const OnboardingScreen();
  }
}
