import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/ui/home/widgets/content_list_body.dart';
import 'package:readaloud_app/viewmodel/content_list_viewmodel.dart';

const _emptyText = 'コンテンツがありません\n＋ボタンから追加してください';

Widget _host(ContentListState state, {VoidCallback? onRetry}) => MaterialApp(
      home: Scaffold(
        body: ContentListBody(
          state: state,
          onRetry: onRetry ?? () {},
          listBuilder: (_) => const Text('LIST', key: Key('list')),
        ),
      ),
    );

void main() {
  testWidgets('loading は spinner', (tester) async {
    await tester.pumpWidget(_host(ContentListState(isLoading: true)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('load failure(error && 空)は empty 文言を出さず再試行を出す', (tester) async {
    var retried = 0;
    await tester.pumpWidget(_host(
      ContentListState(errorMessage: 'コンテンツの取得に失敗しました: x'),
      onRetry: () => retried++,
    ));
    expect(find.text(_emptyText), findsNothing);
    expect(find.byKey(const Key('content_list_error_message')), findsOneWidget);
    await tester.tap(find.byKey(const Key('content_list_retry')));
    expect(retried, 1);
  });

  testWidgets('真の empty は empty 文言', (tester) async {
    await tester.pumpWidget(_host(ContentListState()));
    expect(find.text(_emptyText), findsOneWidget);
    expect(find.byKey(const Key('content_list_error_message')), findsNothing);
  });

  testWidgets('一覧あり + error は一覧を維持して banner を出す', (tester) async {
    await tester.pumpWidget(_host(ContentListState(
      contents: [Content(title: 't', body: 'b', sourceType: 'manual')],
      errorMessage: '削除に失敗しました: x',
    )));
    expect(find.byKey(const Key('list')), findsOneWidget);
    expect(find.byKey(const Key('content_list_error_banner')), findsOneWidget);
    expect(find.text(_emptyText), findsNothing);
  });

  testWidgets('一覧あり・error なしは一覧のみ', (tester) async {
    await tester.pumpWidget(_host(ContentListState(
      contents: [Content(title: 't', body: 'b', sourceType: 'manual')],
    )));
    expect(find.byKey(const Key('list')), findsOneWidget);
    expect(find.byKey(const Key('content_list_error_banner')), findsNothing);
  });
}
