import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../viewmodel/onboarding_viewmodel.dart';
import '../../repository/impl/settings_repository_impl.dart';
import '../home/home_screen.dart';

final onboardingViewModelProvider =
    StateNotifierProvider<OnboardingViewModel, OnboardingState>((ref) {
  return OnboardingViewModel(SettingsRepositoryImpl());
});

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  final List<_OnboardingPage> _pages = [
    _OnboardingPage(
      icon: '▶',
      title: 'ReadAloud',
      subtitle: 'テキストを、声に変える。',
      features: [
        ('📄', 'URLやPDFをそのまま読み上げ'),
        ('🎙', '自然な音声でどこでも学習'),
        ('🔖', 'ブックマークで学習をサポート'),
      ],
    ),
    _OnboardingPage(
      icon: '🎙',
      title: '3つの入力方法',
      subtitle: 'あなたのスタイルに合わせて選べる',
      features: [
        ('📝', 'テキスト入力・貼り付け・クリップボード'),
        ('🔗', 'URLからWebページの本文を自動抽出'),
        ('📄', 'PDFやテキストファイルに対応'),
      ],
    ),
    _OnboardingPage(
      icon: '🔑',
      title: 'APIキーを設定する',
      subtitle: 'Google Cloud TTSを使うために\nAPIキーが必要です',
      features: [],
      isApiKeyPage: true,
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _complete() async {
    await ref.read(onboardingViewModelProvider.notifier).completeOnboarding();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (index) => setState(() => _currentPage = index),
                itemCount: _pages.length,
                itemBuilder: (context, index) =>
                    _OnboardingPageWidget(page: _pages[index]),
              ),
            ),
            // ドットインジケーター
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _pages.length,
                (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: i == _currentPage ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: i == _currentPage
                        ? const Color(0xFF9B6FE0)
                        : const Color(0xFF44445A),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            // ボタン
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _currentPage < _pages.length - 1
                          ? _nextPage
                          : _complete,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF7C5CBF),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(26),
                        ),
                      ),
                      child: Text(
                        _currentPage < _pages.length - 1 ? 'はじめる' : '設定してはじめる',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  if (_currentPage == _pages.length - 1) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _complete,
                      child: const Text(
                        'あとで設定する',
                        style: TextStyle(color: Color(0xFF8888AA)),
                      ),
                    ),
                  ],
                  if (_currentPage < _pages.length - 1) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _complete,
                      child: const Text(
                        'スキップ',
                        style: TextStyle(color: Color(0xFF44445A)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _OnboardingPage {
  final String icon;
  final String title;
  final String subtitle;
  final List<(String, String)> features;
  final bool isApiKeyPage;

  _OnboardingPage({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.features,
    this.isApiKeyPage = false,
  });
}

class _OnboardingPageWidget extends StatelessWidget {
  final _OnboardingPage page;

  const _OnboardingPageWidget({required this.page});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // アイコン円
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF2A2A3E),
              border: Border.all(
                color: const Color(0xFF7C5CBF),
                width: 2,
              ),
            ),
            child: Center(
              child: Text(
                page.icon,
                style: const TextStyle(fontSize: 48),
              ),
            ),
          ),
          const SizedBox(height: 32),
          Text(
            page.title,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Color(0xFFF0F0F8),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            page.subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF8888AA),
              height: 1.6,
            ),
          ),
          const SizedBox(height: 32),
          if (!page.isApiKeyPage)
            ...page.features.map(
              (f) => Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A3E),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF3A3A55)),
                ),
                child: Row(
                  children: [
                    Text(f.$1, style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 12),
                    Text(
                      f.$2,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFFF0F0F8),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (page.isApiKeyPage) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A3E),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF3A3A55)),
              ),
              child: const TextField(
                decoration: InputDecoration(
                  hintText: 'APIキーを入力...',
                  hintStyle: TextStyle(color: Color(0xFF44445A)),
                  border: InputBorder.none,
                ),
                style: TextStyle(color: Color(0xFFF0F0F8)),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF3D2B6E),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF5B3F9E)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '💡  無料枠について',
                    style: TextStyle(
                      color: Color(0xFF9B6FE0),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '月100万文字まで無料で利用できます。上限アラートはアプリ内で設定できます。',
                    style: TextStyle(
                      color: Color(0xFF8888AA),
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
