import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ui/onboarding/onboarding_screen.dart';
import 'ui/home/home_screen.dart';
import 'ui/add/add_screen.dart';
import 'repository/settings_repository.dart';
import 'repository/impl/settings_repository_impl.dart';
import 'repository/tts/device_tts_service.dart';
import 'providers.dart';
import 'model/setting.dart';
import 'util/share_intent_handler.dart';
import 'util/debug_logger.dart';


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
  await DebugLogger.instance.init(appVersion: '1.1.8+18');

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

class _AppEntryPointState extends ConsumerState<AppEntryPoint> {
  bool _isLoading = true;
  bool _onboardingCompleted = false;
  late ShareIntentHandler _shareIntentHandler;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
    _initShareIntent();
  }

  void _initShareIntent() {
    _shareIntentHandler = ShareIntentHandler(
      onTextReceived: (text) {
        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AddScreen(initialText: text),
            ),
          );
        }
      },
    );
    _shareIntentHandler.startListening();
  }

  Future<void> _checkInitialShareIntent() async {
    final text = await _shareIntentHandler.getInitialSharedText();
    if (text != null && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AddScreen(initialText: text),
        ),
      );
    }
  }

  @override
  void dispose() {
    _shareIntentHandler.dispose();
    super.dispose();
  }

  Future<void> _checkOnboarding() async {
    final SettingsRepository repo = SettingsRepositoryImpl();
    final completed = await repo.get(SettingKeys.onboardingCompleted);
    setState(() {
      _onboardingCompleted = completed == 'true';
      _isLoading = false;
    });
    // オンボーディング確認後にShare Intentを確認
    await _checkInitialShareIntent();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }
    return _onboardingCompleted
        ? const HomeScreen()
        : const OnboardingScreen();
  }
}
