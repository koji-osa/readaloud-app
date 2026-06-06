import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../viewmodel/add_content_viewmodel.dart';
import '../../usecase/content/save_content_usecase.dart';
import '../../usecase/content/fetch_url_content_usecase.dart';
import '../../usecase/content/extract_pdf_content_usecase.dart';
import '../../repository/impl/content_repository_impl.dart';
import '../../model/content.dart';
import '../player/player_screen.dart';
import '../home/home_screen.dart';
import '../../util/text_cleaner.dart';

final addContentViewModelProvider =
    StateNotifierProvider.autoDispose<AddContentViewModel, AddContentState>(
        (ref) {
  final repo = ContentRepositoryImpl();
  return AddContentViewModel(
    saveContent: SaveContentUseCase(repo),
    fetchUrl: FetchUrlContentUseCase(),
    extractPdf: ExtractPdfContentUseCase(),
  );
});

class AddScreen extends ConsumerStatefulWidget {
  final String? initialText; // Share Intentから渡されるテキスト
  const AddScreen({super.key, this.initialText});

  @override
  ConsumerState<AddScreen> createState() => _AddScreenState();
}

class _AddScreenState extends ConsumerState<AddScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _textController = TextEditingController();
  final _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    if (widget.initialText != null) {
      _textController.text = widget.initialText!;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _textController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _textController.text = data!.text!;
    }
  }

  Future<void> _startReading(Content content) async {
    if (mounted) {
      // 保存完了後・画面遷移前に一覧を更新（FIX-024）
      ref.read(contentListViewModelProvider.notifier).loadContents();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => PlayerScreen(content: content, autoPlay: true)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(addContentViewModelProvider);
    final vm = ref.read(addContentViewModelProvider.notifier);

    // エラー表示
    ref.listen(addContentViewModelProvider, (prev, next) {
      if (next.errorMessage != null) {
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
            // ヘッダー
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back,
                        color: Color(0xFF8888AA)),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Text(
                    '追加',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFF0F0F8),
                    ),
                  ),
                ],
              ),
            ),
            // タブ
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'テキスト'),
                Tab(text: 'URL'),
                Tab(text: 'ファイル'),
              ],
              labelColor: const Color(0xFF9B6FE0),
              unselectedLabelColor: const Color(0xFF44445A),
              indicatorColor: const Color(0xFF9B6FE0),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // テキストタブ
                  _TextTab(
                    controller: _textController,
                    onPaste: _pasteFromClipboard,
                    onStart: () async {
                      final content =
                          await vm.saveFromText(_textController.text);
                      if (content != null) await _startReading(content);
                    },
                    isLoading: state.isLoading,
                  ),
                  // URLタブ
                  _UrlTab(
                    controller: _urlController,
                    onStart: () async {
                      final content =
                          await vm.saveFromUrl(_urlController.text);
                      if (content != null) await _startReading(content);
                    },
                    isLoading: state.isLoading,
                  ),
                  // ファイルタブ
                  _FileTab(
                    onStart: (path) async {
                      final content = await vm.saveFromPdf(path);
                      if (content != null) await _startReading(content);
                    },
                    isLoading: state.isLoading,
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

// テキスト入力タブ
class _TextTab extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onPaste;
  final VoidCallback onStart;
  final bool isLoading;

  const _TextTab({
    required this.controller,
    required this.onPaste,
    required this.onStart,
    required this.isLoading,
  });

  @override
  State<_TextTab> createState() => _TextTabState();
}

class _TextTabState extends State<_TextTab> {
  bool _shouldClean = true; // デフォルトON（REQ-008）

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A3E),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF3A3A55)),
              ),
              child: TextField(
                controller: widget.controller,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  hintText: 'ここにテキストを入力または貼り付け...',
                  hintStyle: TextStyle(color: Color(0xFF44445A)),
                  border: InputBorder.none,
                ),
                style: const TextStyle(
                  color: Color(0xFFF0F0F8),
                  fontSize: 14,
                  height: 1.6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // クリップボードボタン
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: widget.onPaste,
              icon: const Icon(Icons.content_paste, size: 18),
              label: const Text('クリップボードから貼り付け'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF8888AA),
                side: const BorderSide(color: Color(0xFF3A3A55)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Share Intent案内
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E3A6E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF3A3A55)),
            ),
            child: const Row(
              children: [
                Text('💡', style: TextStyle(fontSize: 16)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '他アプリからテキストを選択→共有→このアプリを選ぶと自動入力されます',
                    style: TextStyle(fontSize: 11, color: Color(0xFF8888AA)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // REQ-008: URLや長い英数字・記号を省略するチェックボックス
          Row(
            children: [
              Checkbox(
                value: _shouldClean,
                onChanged: (v) => setState(() => _shouldClean = v ?? true),
                activeColor: const Color(0xFF7C5CBF),
                side: const BorderSide(color: Color(0xFF3A3A55)),
              ),
              const Expanded(
                child: Text(
                  'URLや長い英数字・記号を省略する',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8888AA)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _StartButton(
            onPressed: () {
              if (_shouldClean) {
                widget.controller.text =
                    TextCleaner.clean(widget.controller.text);
              }
              widget.onStart();
            },
            isLoading: widget.isLoading,
          ),
        ],
      ),
    );
  }
}

// URL入力タブ
class _UrlTab extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onStart;
  final bool isLoading;

  const _UrlTab({
    required this.controller,
    required this.onStart,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A3E),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF3A3A55)),
            ),
            child: TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'https://example.com/article',
                hintStyle: TextStyle(color: Color(0xFF44445A)),
                border: InputBorder.none,
              ),
              style: const TextStyle(color: Color(0xFFF0F0F8), fontSize: 14),
              keyboardType: TextInputType.url,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A3E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF3A3A55)),
            ),
            child: const Row(
              children: [
                Text('🔍', style: TextStyle(fontSize: 16)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'URLを入力するとWebページの本文を自動で抽出します',
                    style: TextStyle(fontSize: 12, color: Color(0xFF8888AA)),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          _StartButton(onPressed: onStart, isLoading: isLoading),
        ],
      ),
    );
  }
}

// ファイル選択タブ
class _FileTab extends StatelessWidget {
  final Function(String) onStart;
  final bool isLoading;

  const _FileTab({required this.onStart, required this.isLoading});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                // TODO: ファイルピッカーを実装
              },
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A3E),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFF3A3A55),
                    style: BorderStyle.solid,
                    width: 2,
                  ),
                ),
                child: const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('📄', style: TextStyle(fontSize: 48)),
                      SizedBox(height: 16),
                      Text(
                        'PDF / TXTファイルを選択',
                        style: TextStyle(
                          fontSize: 14,
                          color: Color(0xFF8888AA),
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'タップしてファイルを選ぶ',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF44445A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _StartButton(
            onPressed: () {},
            isLoading: isLoading,
          ),
        ],
      ),
    );
  }
}

class _StartButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool isLoading;

  const _StartButton({required this.onPressed, required this.isLoading});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: isLoading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF7C5CBF),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
        ),
        child: isLoading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text(
                '読み上げる',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
      ),
    );
  }
}
