import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/folder_child.dart';
import 'package:readaloud_app/usecase/sources/recent_folder_grouping.dart';

FolderChild md(String name, DateTime at) => FolderChild(
      uri: 'content://test/doc/${Uri.encodeComponent(name)}',
      name: name,
      mimeType: 'text/markdown',
      lastModified: at.millisecondsSinceEpoch,
      isDirectory: false,
    );

FolderChild dir(String name, DateTime at) => FolderChild(
      uri: 'content://test/doc/dir-$name',
      name: name,
      mimeType: 'vnd.android.document/directory',
      lastModified: at.millisecondsSinceEpoch,
      isDirectory: true,
    );

void main() {
  // 2026-10-05（今日）15:00 ローカル。窓 = 9/29〜10/5（7暦日）。
  final now = DateTime(2026, 10, 5, 15);

  group('7暦日の境界（端末ローカル 0:00 基準）', () {
    test('今日・6日前(9/29 0:00)は含み、7日前(9/28 23:59)は含まない', () {
      final children = [
        md('today.md', DateTime(2026, 10, 5, 0, 0)),
        md('sixDaysAgo.md', DateTime(2026, 9, 29, 0, 0)),
        md('sevenDaysAgo.md', DateTime(2026, 9, 28, 23, 59)),
      ];
      final result = RecentFolderGrouping.select(children, now: now);
      final names = result.groups.expand((g) => g.items.map((i) => i.name));
      expect(result.state, FolderSourceState.ok);
      expect(names, containsAll(['today.md', 'sixDaysAgo.md']));
      expect(names, isNot(contains('sevenDaysAgo.md')));
    });

    test('同じ「今日」なら now より後の時刻も含める（暦日判定）', () {
      final children = [md('laterToday.md', DateTime(2026, 10, 5, 23, 30))];
      final result = RecentFolderGrouping.select(children, now: now);
      expect(result.state, FolderSourceState.ok);
      expect(result.groups.single.day, DateTime(2026, 10, 5));
    });

    test('明日0:00（startOfTomorrow）以降は除外', () {
      final children = [
        md('tomorrowStart.md', DateTime(2026, 10, 6, 0, 0)),
        md('tomorrowLater.md', DateTime(2026, 10, 6, 1)),
      ];
      final result = RecentFolderGrouping.select(children, now: now);
      expect(result.state, FolderSourceState.noRecent);
      expect(result.groups, isEmpty);
    });

    test('昨日23:59:59.999は含み、6日前より前（9/28 23:59:59.999）は除外', () {
      final children = [
        md('yesterdayLate.md', DateTime(2026, 10, 4, 23, 59, 59, 999)),
        md('beforeWindow.md', DateTime(2026, 9, 28, 23, 59, 59, 999)),
      ];
      final result = RecentFolderGrouping.select(children, now: now);
      final names = result.groups.expand((g) => g.items.map((i) => i.name)).toList();
      expect(names, ['yesterdayLate.md']);
    });
  });

  group('日別グルーピング', () {
    test('昨日と一昨日は別グループ（統合しない）', () {
      final children = [
        md('c.md', DateTime(2026, 10, 4, 9)), // 昨日
        md('d.md', DateTime(2026, 10, 3, 9)), // 一昨日
      ];
      final result = RecentFolderGrouping.select(children, now: now);
      expect(result.groups.length, 2);
      expect(result.groups[0].day, DateTime(2026, 10, 4));
      expect(result.groups[1].day, DateTime(2026, 10, 3));
    });

    test('グループ順は日付の新しい順', () {
      final children = [
        md('old.md', DateTime(2026, 9, 30, 8)),
        md('new.md', DateTime(2026, 10, 5, 8)),
        md('mid.md', DateTime(2026, 10, 2, 8)),
      ];
      final result = RecentFolderGrouping.select(children, now: now);
      final days = result.groups.map((g) => g.day).toList();
      expect(days, [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 2),
        DateTime(2026, 9, 30),
      ]);
    });

    test('ラベル: 今日 / 昨日 / それ以外は M/d', () {
      expect(RecentFolderGrouping.labelFor(DateTime(2026, 10, 5), now: now), '今日');
      expect(RecentFolderGrouping.labelFor(DateTime(2026, 10, 4), now: now), '昨日');
      expect(RecentFolderGrouping.labelFor(DateTime(2026, 10, 3), now: now), '10/3');
    });
  });

  group('グループ内ソート', () {
    test('lastModified 降順、同値はファイル名昇順', () {
      final sameTime = DateTime(2026, 10, 5, 10);
      final children = [
        md('b.md', sameTime),
        md('a.md', sameTime),
        md('z.md', DateTime(2026, 10, 5, 11)),
      ];
      final result = RecentFolderGrouping.select(children, now: now);
      final names = result.groups.single.items.map((i) => i.name).toList();
      expect(names, ['z.md', 'a.md', 'b.md']);
    });
  });

  group('状態分類（Phase 1 §10）', () {
    test('Markdown が1件もない → noMarkdown（ディレクトリや他拡張子のみ）', () {
      final children = [
        dir('sub.md', DateTime(2026, 10, 5)),
        FolderChild(
          uri: 'content://x/txt',
          name: 'note.txt',
          mimeType: 'text/plain',
          lastModified: DateTime(2026, 10, 5).millisecondsSinceEpoch,
          isDirectory: false,
        ),
      ];
      final result = RecentFolderGrouping.select(children, now: now);
      expect(result.state, FolderSourceState.noMarkdown);
    });

    test('Markdown はあるが窓の外のみ → noRecent', () {
      final children = [md('old.md', DateTime(2026, 8, 1))];
      final result = RecentFolderGrouping.select(children, now: now);
      expect(result.state, FolderSourceState.noRecent);
    });

    test('全 .md の lastModified が 0 → modifiedTimeUnavailable（0 を今日扱いしない）', () {
      final children = [
        const FolderChild(
          uri: 'content://x/a',
          name: 'a.md',
          mimeType: 'text/markdown',
          lastModified: 0,
          isDirectory: false,
        ),
      ];
      final result = RecentFolderGrouping.select(children, now: now);
      expect(result.state, FolderSourceState.modifiedTimeUnavailable);
      expect(result.groups, isEmpty);
    });

    test('一部だけ lastModified 0 → 0 のものは除外し、他は通常表示', () {
      final children = [
        const FolderChild(
          uri: 'content://x/unknown',
          name: 'unknown.md',
          mimeType: 'text/markdown',
          lastModified: 0,
          isDirectory: false,
        ),
        md('known.md', DateTime(2026, 10, 5, 9)),
      ];
      final result = RecentFolderGrouping.select(children, now: now);
      expect(result.state, FolderSourceState.ok);
      expect(result.groups.single.items.map((i) => i.name), ['known.md']);
    });

    test('拡張子判定は大文字小文字を無視、ディレクトリは対象外', () {
      expect(RecentFolderGrouping.isMarkdownFile(md('X.MD', now)), isTrue);
      expect(RecentFolderGrouping.isMarkdownFile(dir('d.md', now)), isFalse);
      expect(RecentFolderGrouping.isMarkdownFile(md('x.markdown', now)), isFalse);
    });
  });
}
