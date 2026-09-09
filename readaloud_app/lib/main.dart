import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show kReleaseMode, kProfileMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ui/onboarding/onboarding_screen.dart';
import 'ui/home/home_screen.dart';
import 'ui/add/add_screen.dart';
import 'ui/player/player_screen.dart';
import 'ui/quick_listen/quick_listen_screen.dart' show quickListenViewModelProvider;
import 'repository/settings_repository.dart';
import 'repository/impl/settings_repository_impl.dart';
import 'repository/tts/device_tts_service.dart';
import 'providers.dart';
import 'model/setting.dart';
import 'util/share_intent_handler.dart';
import 'util/external_input_handler.dart';
import 'util/debug_logger.dart';
import 'util/quick_listen_route_tracker.dart';
import 'util/share_fingerprint.dart';

const String kAppVersion = '1.2.21+42';

// No.94 Observability: ビルド時に`--dart-define=BUILD_COMMIT=<git sha>`で
// 埋め込む。未指定のbuildではbuildCommit=unknownとなる（既存buildを壊さない
// 最小構成のため、大規模なbuild system変更は行わない）。
const String kBuildCommit =
    String.fromEnvironment('BUILD_COMMIT', defaultValue: 'unknown');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // audio_service初期化（TtsAudioHandlerのシングルトンを生成）
  final audioHandler = await AudioService.init(
    builder: () => TtsAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.readaloud_app.audio',
      androidNotificationChannelName: 'ReadAloud',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
    ),
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
    'buildMode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
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
  final QuickListenRouteTracker _quickListenRouteTracker =
      QuickListenRouteTracker();

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
      unawaited(
          DebugLogger.instance.logEvent('app_entry_point_first_post_frame', {}));
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

    try {
      // 通常Content再生・Quick Listen再生のいずれかが裏で継続していると、
      // 単一のTtsAudioHandlerを取り合って状態汚染やTTS使用量の二重カウントに
      // つながるため、新しい共有を処理する前に両方とも明示的に停止しておく。
      // ログ自体は純粋なObservabilityで、DebugLoggerのseq採番＋write queueが
      // 呼び出し順を保証するため、ファイルI/O完了はawaitせず共有→Navigationの
      // タイミングに影響させない。stop()/close()本体は従来通りawaitする。
      unawaited(DebugLogger.instance
          .logEvent('player_stop_requested', {'flowId': flowId}));
      await ref.read(playerViewModelProvider.notifier).stop();
      unawaited(DebugLogger.instance
          .logEvent('player_stop_completed', {'flowId': flowId}));

      unawaited(DebugLogger.instance
          .logEvent('quick_listen_close_requested', {'flowId': flowId}));
      await ref.read(quickListenViewModelProvider.notifier).close();
      unawaited(DebugLogger.instance
          .logEvent('quick_listen_close_completed', {'flowId': flowId}));

      if (!mounted) {
        unawaited(DebugLogger.instance.logEvent('error', {
          'context': 'handle_shared_payload_not_mounted',
          'flowId': flowId,
        }));
        return;
      }

      // 直前のQuickListen routeがNavigator stack上に残っていれば、
      // ここで対象routeだけを除去する。URL共有でAddScreenへ分岐する場合も
      // 同じroute accumulation根因が起こりうるため、payload種別を判定する
      // 前に必ず呼ぶ（詳細はQuickListenRouteTrackerのdocコメント参照）。
      _quickListenRouteTracker.removeActiveQuickListen(
        context: context,
        flowId: flowId,
      );

      if (payload.kind == SharedContentKind.url) {
        unawaited(DebugLogger.instance.logEvent('navigation_push_requested', {
          'target': 'add_screen',
          'stackSource': 'share_handler',
          'flowId': flowId,
        }));
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AddScreen(initialUrl: value),
          ),
        );
      } else {
        _quickListenRouteTracker.openQuickListen(
          context: context,
          text: value,
          flowId: flowId,
        );
      }
    } catch (e) {
      // No.94 Observability: 例外は握りつぶさず、ログだけ追加してrethrowする
      // （既存の挙動・エラー伝播経路は変更しない）。
      unawaited(DebugLogger.instance.logEvent('share_pipeline_error', {
        'stage': 'payload_handler',
        'flowId': flowId,
        'errorType': e.runtimeType.toString(),
      }));
      rethrow;
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
