import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/ui/widgets/date_group_view.dart';

class _Note {
  const _Note(this.id, this.label, this.lastModified, [this.parentFolder = '']);
  final String id;
  final String label;
  final int lastModified;
  final String parentFolder;
}

DateTime _at(int year, int month, int day, [int hour = 12, int minute = 0]) =>
    DateTime(year, month, day, hour, minute);

void main() {
  // 基準日時: 2026-07-30(木) 10:00
  final now = _at(2026, 7, 30, 10, 0);

  group('dateGroupOf', () {
    test('同日(時刻違い)は今日', () {
      final millis = _at(2026, 7, 30, 23, 59).millisecondsSinceEpoch;
      expect(dateGroupOf(millis, now), DateGroup.today);
    });

    test('未来時刻も今日に丸められる', () {
      final millis = _at(2026, 7, 31, 0, 0).millisecondsSinceEpoch;
      expect(dateGroupOf(millis, now), DateGroup.today);
    });

    test('1日前は昨日', () {
      final millis = _at(2026, 7, 29).millisecondsSinceEpoch;
      expect(dateGroupOf(millis, now), DateGroup.yesterday);
    });

    test('2日前は一昨日', () {
      final millis = _at(2026, 7, 28).millisecondsSinceEpoch;
      expect(dateGroupOf(millis, now), DateGroup.dayBeforeYesterday);
    });

    test('3日前は今週(境界)', () {
      final millis = _at(2026, 7, 27).millisecondsSinceEpoch;
      expect(dateGroupOf(millis, now), DateGroup.thisWeek);
    });

    test('6日前は今週(境界)', () {
      final millis = _at(2026, 7, 24).millisecondsSinceEpoch;
      expect(dateGroupOf(millis, now), DateGroup.thisWeek);
    });

    test('7日前はそれ以前(境界)', () {
      final millis = _at(2026, 7, 23).millisecondsSinceEpoch;
      expect(dateGroupOf(millis, now), DateGroup.older);
    });

    test('lastModifiedが0(取得不可)はそれ以前に含まれる', () {
      expect(dateGroupOf(0, now), DateGroup.older);
    });
  });

  group('groupItemsByDate', () {
    test('グループ内は更新日時の降順に並ぶ', () {
      final items = [
        _Note('id-1', 'a', _at(2026, 7, 30, 9, 0).millisecondsSinceEpoch),
        _Note('id-2', 'b', _at(2026, 7, 30, 15, 0).millisecondsSinceEpoch),
        _Note('id-3', 'c', _at(2026, 7, 30, 12, 0).millisecondsSinceEpoch),
      ];

      final buckets = groupItemsByDate<_Note>(
        items: items,
        lastModifiedOf: (n) => n.lastModified,
        idOf: (n) => n.id,
        now: now,
      );

      expect(buckets, hasLength(1));
      expect(buckets.first.group, DateGroup.today);
      expect(buckets.first.items.map((n) => n.id), ['id-2', 'id-3', 'id-1']);
    });

    test('同値の場合はidの昇順でタイブレークする', () {
      final sameMillis = _at(2026, 7, 30).millisecondsSinceEpoch;
      final items = [
        _Note('id-c', 'c', sameMillis),
        _Note('id-a', 'a', sameMillis),
        _Note('id-b', 'b', sameMillis),
      ];

      final buckets = groupItemsByDate<_Note>(
        items: items,
        lastModifiedOf: (n) => n.lastModified,
        idOf: (n) => n.id,
        now: now,
      );

      expect(buckets.first.items.map((n) => n.id), ['id-a', 'id-b', 'id-c']);
    });

    test('0件のグループは結果に含まれない', () {
      final items = [
        _Note('id-1', 'today', _at(2026, 7, 30).millisecondsSinceEpoch),
        _Note('id-2', 'older', _at(2020, 1, 1).millisecondsSinceEpoch),
      ];

      final buckets = groupItemsByDate<_Note>(
        items: items,
        lastModifiedOf: (n) => n.lastModified,
        idOf: (n) => n.id,
        now: now,
      );

      expect(buckets.map((b) => b.group), [DateGroup.today, DateGroup.older]);
    });

    test('グループの表示順は今日→昨日→一昨日→今週→それ以前', () {
      final items = [
        _Note('id-older', 'x', _at(2026, 7, 1).millisecondsSinceEpoch),
        _Note('id-week', 'x', _at(2026, 7, 25).millisecondsSinceEpoch),
        _Note('id-2ago', 'x', _at(2026, 7, 28).millisecondsSinceEpoch),
        _Note('id-yesterday', 'x', _at(2026, 7, 29).millisecondsSinceEpoch),
        _Note('id-today', 'x', _at(2026, 7, 30).millisecondsSinceEpoch),
      ];

      final buckets = groupItemsByDate<_Note>(
        items: items,
        lastModifiedOf: (n) => n.lastModified,
        idOf: (n) => n.id,
        now: now,
      );

      expect(buckets.map((b) => b.group), [
        DateGroup.today,
        DateGroup.yesterday,
        DateGroup.dayBeforeYesterday,
        DateGroup.thisWeek,
        DateGroup.older,
      ]);
    });
  });

  group('groupCheckState', () {
    final items = [const _Note('id-a', 'a', 0), const _Note('id-b', 'b', 0)];

    test('未選択ならfalse', () {
      expect(groupCheckState<_Note>(items, {}, (n) => n.id), isFalse);
    });

    test('全選択ならtrue', () {
      expect(
        groupCheckState<_Note>(items, {'id-a', 'id-b'}, (n) => n.id),
        isTrue,
      );
    });

    test('一部選択ならnull(中間状態)', () {
      expect(groupCheckState<_Note>(items, {'id-a'}, (n) => n.id), isNull);
    });

    test('空リストはfalse', () {
      expect(groupCheckState<_Note>(<_Note>[], {'id-a'}, (n) => n.id), isFalse);
    });
  });

  group('formatNoteDateTime', () {
    test('今日・昨日・一昨日は時刻形式', () {
      final millis = _at(2026, 7, 30, 14, 32).millisecondsSinceEpoch;
      expect(formatNoteDateTime(millis, DateGroup.today), '14:32');
      expect(formatNoteDateTime(millis, DateGroup.yesterday), '14:32');
      expect(formatNoteDateTime(millis, DateGroup.dayBeforeYesterday), '14:32');
    });

    test('今週・それ以前は月日形式', () {
      final millis = _at(2026, 7, 27, 14, 32).millisecondsSinceEpoch;
      expect(formatNoteDateTime(millis, DateGroup.thisWeek), '7/27');
      expect(formatNoteDateTime(millis, DateGroup.older), '7/27');
    });

    test('lastModifiedMillisが0(取得不可)の場合は「日時不明」', () {
      expect(formatNoteDateTime(0, DateGroup.older), '日時不明');
    });
  });

  group('parentFolderPath', () {
    test('フォルダ階層があればファイル名を除いた部分を返す', () {
      expect(parentFolderPath('Projects/AI/note.md', 'note.md'), 'Projects/AI');
    });

    test('1階層のみでもファイル名を除いた部分を返す', () {
      expect(parentFolderPath('Projects/note.md', 'note.md'), 'Projects');
    });

    test('ルート直下のファイル(relativePathとnameが一致)は空文字を返す', () {
      expect(parentFolderPath('note.md', 'note.md'), '');
    });
  });

  group('DateGroupView (widget)', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    final items = [
      _Note('id-today', 'today.md', _at(2026, 7, 30, 9, 0).millisecondsSinceEpoch),
      _Note('id-yesterday', 'yesterday.md', _at(2026, 7, 29).millisecondsSinceEpoch),
    ];

    testWidgets('グループ見出しとノートが表示される', (tester) async {
      await tester.pumpWidget(wrap(DateGroupView<_Note>(
        items: items,
        lastModifiedOf: (n) => n.lastModified,
        labelOf: (n) => n.label,
        parentFolderOf: (n) => n.parentFolder,
        idOf: (n) => n.id,
        selectedIds: const {},
        onSelectionChanged: (_, __) {},
        now: now,
      )));

      expect(find.text('今日 (1)'), findsOneWidget);
      expect(find.text('昨日 (1)'), findsOneWidget);
      expect(find.text('today.md'), findsOneWidget);
      expect(find.text('yesterday.md'), findsOneWidget);
    });

    testWidgets('ノート名は1行で省略表示になる', (tester) async {
      await tester.pumpWidget(wrap(DateGroupView<_Note>(
        items: items,
        lastModifiedOf: (n) => n.lastModified,
        labelOf: (n) => n.label,
        parentFolderOf: (n) => n.parentFolder,
        idOf: (n) => n.id,
        selectedIds: const {},
        onSelectionChanged: (_, __) {},
        now: now,
      )));

      final labelText = tester.widget<Text>(find.text('today.md'));
      expect(labelText.maxLines, 1);
      expect(labelText.overflow, TextOverflow.ellipsis);
    });

    testWidgets('親フォルダがあるノートは2行目に親フォルダ名が表示される', (tester) async {
      final itemsWithFolder = [
        _Note(
          'id-today',
          'today.md',
          _at(2026, 7, 30, 9, 0).millisecondsSinceEpoch,
          'Projects/AI',
        ),
      ];

      await tester.pumpWidget(wrap(DateGroupView<_Note>(
        items: itemsWithFolder,
        lastModifiedOf: (n) => n.lastModified,
        labelOf: (n) => n.label,
        parentFolderOf: (n) => n.parentFolder,
        idOf: (n) => n.id,
        selectedIds: const {},
        onSelectionChanged: (_, __) {},
        now: now,
      )));

      expect(find.text('today.md'), findsOneWidget);
      expect(find.text('Projects/AI'), findsOneWidget);
    });

    testWidgets('親フォルダがないノート(ルート直下)は2行目自体が表示されない', (tester) async {
      await tester.pumpWidget(wrap(DateGroupView<_Note>(
        items: items,
        lastModifiedOf: (n) => n.lastModified,
        labelOf: (n) => n.label,
        parentFolderOf: (n) => n.parentFolder,
        idOf: (n) => n.id,
        selectedIds: const {},
        onSelectionChanged: (_, __) {},
        now: now,
      )));

      // items内の全ノートはparentFolderが空文字(デフォルト値)。
      final row = tester.widget<Column>(find.ancestor(
        of: find.text('today.md'),
        matching: find.byType(Column),
      ));
      expect(row.children, hasLength(1));
    });

    testWidgets('ノート行タップで単体選択のコールバックが呼ばれる', (tester) async {
      List<String>? calledIds;
      bool? calledSelected;

      await tester.pumpWidget(wrap(DateGroupView<_Note>(
        items: items,
        lastModifiedOf: (n) => n.lastModified,
        labelOf: (n) => n.label,
        parentFolderOf: (n) => n.parentFolder,
        idOf: (n) => n.id,
        selectedIds: const {},
        onSelectionChanged: (ids, selected) {
          calledIds = ids;
          calledSelected = selected;
        },
        now: now,
      )));

      await tester.tap(find.text('today.md'));
      await tester.pumpAndSettle();

      expect(calledIds, ['id-today']);
      expect(calledSelected, isTrue);
    });

    testWidgets('未選択グループの見出しタップで配下全件がまとめて選択される', (tester) async {
      List<String>? calledIds;
      bool? calledSelected;

      await tester.pumpWidget(wrap(DateGroupView<_Note>(
        items: items,
        lastModifiedOf: (n) => n.lastModified,
        labelOf: (n) => n.label,
        parentFolderOf: (n) => n.parentFolder,
        idOf: (n) => n.id,
        selectedIds: const {},
        onSelectionChanged: (ids, selected) {
          calledIds = ids;
          calledSelected = selected;
        },
        now: now,
      )));

      await tester.tap(find.text('今日 (1)'));
      await tester.pumpAndSettle();

      expect(calledIds, ['id-today']);
      expect(calledSelected, isTrue);
    });
  });
}
