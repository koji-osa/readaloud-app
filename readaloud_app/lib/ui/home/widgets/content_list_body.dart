import 'package:flutter/material.dart';
import '../../../viewmodel/content_list_viewmodel.dart';

/// Home のコンテンツ一覧領域の状態分岐。
///
/// loading / load failure / 真の empty / 一覧 を区別する。load failure
/// (errorMessage != null かつ contents 空) を「コンテンツがありません」として
/// 表示してはならない (No.152)。
class ContentListBody extends StatelessWidget {
  final ContentListState state;
  final VoidCallback onRetry;
  final Widget Function(BuildContext context) listBuilder;

  const ContentListBody({
    super.key,
    required this.state,
    required this.onRetry,
    required this.listBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = state.errorMessage;
    if (state.contents.isEmpty) {
      if (error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  error,
                  key: const Key('content_list_error_message'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFF87171)),
                ),
                const SizedBox(height: 12),
                TextButton(
                  key: const Key('content_list_retry'),
                  onPressed: onRetry,
                  child: const Text('再試行'),
                ),
              ],
            ),
          ),
        );
      }
      return const Center(
        child: Text(
          'コンテンツがありません\n＋ボタンから追加してください',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF8888AA)),
        ),
      );
    }
    final list = listBuilder(context);
    if (error == null) return list;
    // 既存の一覧がある状態での失敗(更新/削除など)は一覧を維持して通知のみ行う。
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  error,
                  key: const Key('content_list_error_banner'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFF87171),
                  ),
                ),
              ),
              TextButton(onPressed: onRetry, child: const Text('再試行')),
            ],
          ),
        ),
        Expanded(child: list),
      ],
    );
  }
}
