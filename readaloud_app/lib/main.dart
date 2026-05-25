import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ui/onboarding/onboarding_screen.dart';
import 'ui/home/home_screen.dart';
import 'ui/add/add_screen.dart';
import 'repository/settings_repository.dart';
import 'repository/impl/settings_repository_impl.dart';
import 'model/setting.dart';
import 'util/notification_helper.dart';
import 'util/share_intent_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 通知の初期化
  await NotificationHelper.initialize();

  runApp(
    const ProviderScope(
      child: ReadAloudApp(),
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
    _checkInitialShareIntent();
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
