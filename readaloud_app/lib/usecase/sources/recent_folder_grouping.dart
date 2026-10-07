import '../../model/folder_child.dart';

/// Sources の Recent 一覧の状態（Phase 1 §10）。
enum FolderSourceState { ok, noMarkdown, noRecent, modifiedTimeUnavailable }

/// 端末ローカル日付の1日分グループ（`day` は 0:00 の日付のみ）。
class RecentDayGroup {
  const RecentDayGroup({required this.day, required this.items});

  final DateTime day;
  final List<FolderChild> items;
}

class RecentFolderSelection {
  const RecentFolderSelection({
    required this.state,
    required this.groups,
  });

  final FolderSourceState state;

  /// 日付の新しい順。グループ内は lastModified 降順、同値はファイル名昇順。
  final List<RecentDayGroup> groups;
}

/// Recent 対象（直下の `.md`・過去7暦日）の選別・日別グルーピング・状態分類。
///
/// 純粋関数のみ。Android / DocumentsProvider / 本文読み取りには依存しない。
/// 再帰処理は行わない（呼び出し側が渡す children は直下のみ）。
class RecentFolderGrouping {
  RecentFolderGrouping._();

  /// 今日を含む過去7暦日（今日・昨日・…・6日前）。
  static const int windowDays = 7;

  static RecentFolderSelection select(
    List<FolderChild> children, {
    required DateTime now,
  }) {
    final today = DateOnly.of(now);
    // 暦日境界: startOfToday - 6日 <= lastModified < startOfTomorrow（ローリング時間ではない）。
    final windowStartMs =
        DateTime(today.year, today.month, today.day - (windowDays - 1)).millisecondsSinceEpoch;
    final endExclusiveMs =
        DateTime(today.year, today.month, today.day + 1).millisecondsSinceEpoch;

    final markdown = children.where(_isMarkdownFile).toList();
    if (markdown.isEmpty) {
      return const RecentFolderSelection(
        state: FolderSourceState.noMarkdown,
        groups: [],
      );
    }

    final withTime = markdown.where((c) => c.lastModified > 0).toList();
    if (withTime.isEmpty) {
      return const RecentFolderSelection(
        state: FolderSourceState.modifiedTimeUnavailable,
        groups: [],
      );
    }

    final byDay = <DateTime, List<FolderChild>>{};
    for (final child in withTime) {
      if (child.lastModified < windowStartMs || child.lastModified >= endExclusiveMs) continue;
      final day = DateOnly.of(DateTime.fromMillisecondsSinceEpoch(child.lastModified));
      byDay.putIfAbsent(day, () => []).add(child);
    }

    if (byDay.isEmpty) {
      return const RecentFolderSelection(
        state: FolderSourceState.noRecent,
        groups: [],
      );
    }

    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    final groups = [
      for (final day in days)
        RecentDayGroup(
          day: day,
          items: byDay[day]!..sort(_compareWithinGroup),
        ),
    ];

    return RecentFolderSelection(state: FolderSourceState.ok, groups: groups);
  }

  /// グループ見出し。今日 / 昨日 / それ以外は `M/d`。
  static String labelFor(DateTime day, {required DateTime now}) {
    final today = DateOnly.of(now);
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    if (day == today) return '今日';
    if (day == yesterday) return '昨日';
    return '${day.month}/${day.day}';
  }

  static bool isMarkdownFile(FolderChild child) => _isMarkdownFile(child);

  static bool _isMarkdownFile(FolderChild child) =>
      !child.isDirectory && child.name.toLowerCase().endsWith('.md');

  static int _compareWithinGroup(FolderChild a, FolderChild b) {
    final byTime = b.lastModified.compareTo(a.lastModified);
    if (byTime != 0) return byTime;
    return a.name.compareTo(b.name);
  }
}

/// 端末ローカル日付（時刻を落とした日付）。`DateTime` の等価判定に使う。
class DateOnly {
  DateOnly._();

  static DateTime of(DateTime value) {
    final local = value.toLocal();
    return DateTime(local.year, local.month, local.day);
  }
}
