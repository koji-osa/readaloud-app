import 'package:flutter/material.dart';

/// ノートの更新日時に基づく5つの日付グループ。
///
/// 「今週」は暦週(月曜始まり等)ではなく、判定基準日([now])から見た
/// 直近7日間のうち「今日・昨日・一昨日」を除いた3〜6日前の固定幅。
/// 曜日に関わらず常に4日分の幅になり、境界が安定する。
enum DateGroup {
  today('今日'),
  yesterday('昨日'),
  dayBeforeYesterday('一昨日'),
  thisWeek('今週'),
  older('それ以前');

  const DateGroup(this.label);

  final String label;
}

/// [lastModifiedMillis](epochミリ秒)が[now]から見てどの[DateGroup]に
/// 属するかを、日付(年月日)の差分から判定する純粋関数。
///
/// 時刻ではなく日付単位で比較するため、例えば23:59更新のノートも
/// 日付が変わった直後は「昨日」ではなく引き続き当日中は「今日」になる。
/// [lastModifiedMillis]が0(SAFで取得不可)の場合や、時計のずれ等で未来の
/// 日時になっている場合も含め、日付差が0以下は「今日」に丸める。
DateGroup dateGroupOf(int lastModifiedMillis, DateTime now) {
  final noteDate = DateTime.fromMillisecondsSinceEpoch(lastModifiedMillis);
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(noteDate.year, noteDate.month, noteDate.day);
  final dayDiff = today.difference(target).inDays;

  if (dayDiff <= 0) return DateGroup.today;
  if (dayDiff == 1) return DateGroup.yesterday;
  if (dayDiff == 2) return DateGroup.dayBeforeYesterday;
  if (dayDiff <= 6) return DateGroup.thisWeek;
  return DateGroup.older;
}

/// [DateGroup]1件分の表示データ。[items]は更新日時の降順に並んでいる。
class DateGroupBucket<T> {
  const DateGroupBucket({required this.group, required this.items});

  final DateGroup group;
  final List<T> items;
}

/// [items]を[lastModifiedOf]の値から5つの[DateGroup]に振り分け、
/// 該当ノートが0件のグループを除いた上で、グループ表示順
/// (今日→昨日→一昨日→今週→それ以前)のリストを返す。
///
/// 各グループ内は[lastModifiedOf]の降順(新しい順)。同値の場合は
/// [idOf]の昇順でタイブレークし、並び順を決定的にする。
List<DateGroupBucket<T>> groupItemsByDate<T>({
  required List<T> items,
  required int Function(T item) lastModifiedOf,
  required String Function(T item) idOf,
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  final buckets = <DateGroup, List<T>>{
    for (final group in DateGroup.values) group: <T>[],
  };

  for (final item in items) {
    final group = dateGroupOf(lastModifiedOf(item), effectiveNow);
    buckets[group]!.add(item);
  }

  final result = <DateGroupBucket<T>>[];
  for (final group in DateGroup.values) {
    final groupItems = buckets[group]!;
    if (groupItems.isEmpty) continue;

    groupItems.sort((a, b) {
      final cmp = lastModifiedOf(b).compareTo(lastModifiedOf(a));
      if (cmp != 0) return cmp;
      return idOf(a).compareTo(idOf(b));
    });
    result.add(DateGroupBucket<T>(group: group, items: groupItems));
  }
  return result;
}

/// [items]内で選択済みの件数から、グループ見出しのチェックボックス状態を判定する。
///
/// 1件も選択されていなければfalse、全件選択済みならtrue、
/// 一部のみ選択済みならnull(中間状態)を返す。
bool? groupCheckState<T>(
  List<T> items,
  Set<String> selectedIds,
  String Function(T item) idOf,
) {
  if (items.isEmpty) return false;

  final selectedCount = items.where((item) => selectedIds.contains(idOf(item))).length;
  if (selectedCount == 0) return false;
  if (selectedCount == items.length) return true;
  return null;
}

/// [lastModifiedMillis]を[group]に応じた表示形式の文字列に変換する。
///
/// 「今日・昨日・一昨日」は当日中の判別が主目的のため時刻("14:32")、
/// 「今週・それ以前」は日付の判別が主目的のため月日("7/27")で表示する。
/// [lastModifiedMillis]が0以下(SAFで取得不可)の場合、Unixエポック
/// (1970年)由来の日付を実際の更新日時のように表示してしまうと
/// 誤解を招くため、「日時不明」を返す。
String formatNoteDateTime(int lastModifiedMillis, DateGroup group) {
  if (lastModifiedMillis <= 0) return '日時不明';

  final dt = DateTime.fromMillisecondsSinceEpoch(lastModifiedMillis);
  switch (group) {
    case DateGroup.today:
    case DateGroup.yesterday:
    case DateGroup.dayBeforeYesterday:
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    case DateGroup.thisWeek:
    case DateGroup.older:
      return '${dt.month}/${dt.day}';
  }
}

/// [relativePath]から[name]部分を取り除いた親フォルダパスを返す。
///
/// 日付モードでは同名ファイルがフォルダ違いで存在すると区別できないため、
/// ファイル名の下に添える補助表示として使う。ルート直下のファイル
/// ([relativePath]と[name]が一致する場合)は親フォルダを持たないため
/// 空文字を返す(呼び出し側は空文字の場合、行自体を表示しない)。
String parentFolderPath(String relativePath, String name) {
  if (relativePath == name) return '';

  final withoutName = relativePath.substring(
    0,
    relativePath.length - name.length,
  );
  return withoutName.endsWith('/')
      ? withoutName.substring(0, withoutName.length - 1)
      : withoutName;
}

/// フラットなアイテムのリストを、更新日時の[DateGroup]ごとに見出し付きで
/// 表示する汎用ウィジェット。[FolderTreeView]と異なり階層や開閉状態を
/// 持たないため、常に全グループ・全件を展開表示するシンプルな構成。
///
/// - [lastModifiedOf]: 各アイテムの更新日時(epochミリ秒)を返す。
/// - [labelOf]: 各アイテムの表示名を返す。日付モードではフォルダ階層が
///   視覚的な手がかりにならないため、フルパスではなくファイル名のみを
///   渡すことを想定する(長いフォルダ名でファイル名が埋もれるのを防ぐため)。
/// - [parentFolderOf]: 各アイテムの親フォルダ名を返す(例:
///   [parentFolderPath]を使ってrelativePathから算出)。ファイル名だけでは
///   区別できない同名ファイルのために、ファイル名の下に小さく表示する。
///   ルート直下のファイル等、親フォルダがない場合は空文字を返すことで
///   2行目自体を非表示にできる。
/// - [idOf]: 選択状態の管理に使う一意なIDを返す(例: URI)。
/// - [selectedIds]: 選択中のアイテムIDの集合。呼び出し側(ViewModel等)が保持する。
/// - [onSelectionChanged]: チェックボックス操作時に呼ばれる。
///   グループ見出しをタップした場合は配下の全アイテムIDがまとめて渡される。
/// - [now]: グループ判定の基準時刻。省略時は[DateTime.now()](テスト時のみ指定を想定)。
class DateGroupView<T> extends StatelessWidget {
  const DateGroupView({
    super.key,
    required this.items,
    required this.lastModifiedOf,
    required this.labelOf,
    required this.parentFolderOf,
    required this.idOf,
    required this.selectedIds,
    required this.onSelectionChanged,
    this.now,
  });

  final List<T> items;
  final int Function(T item) lastModifiedOf;
  final String Function(T item) labelOf;
  final String Function(T item) parentFolderOf;
  final String Function(T item) idOf;
  final Set<String> selectedIds;
  final void Function(List<String> ids, bool selected) onSelectionChanged;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final buckets = groupItemsByDate<T>(
      items: items,
      lastModifiedOf: lastModifiedOf,
      idOf: idOf,
      now: now,
    );

    final rows = <_DateRow<T>>[];
    for (final bucket in buckets) {
      rows.add(_DateRow<T>.header(bucket));
      for (final item in bucket.items) {
        rows.add(_DateRow<T>.item(item, bucket.group));
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        if (row.bucket != null) {
          final bucket = row.bucket!;
          final checkState = groupCheckState<T>(bucket.items, selectedIds, idOf);
          return _DateGroupHeaderRow(
            label: bucket.group.label,
            count: bucket.items.length,
            checkState: checkState,
            onTap: () {
              final ids = bucket.items.map(idOf).toList();
              onSelectionChanged(ids, checkState != true);
            },
          );
        }

        final item = row.item as T;
        final id = idOf(item);
        final selected = selectedIds.contains(id);
        return _DateItemRow(
          label: labelOf(item),
          parentFolder: parentFolderOf(item),
          time: formatNoteDateTime(lastModifiedOf(item), row.group!),
          selected: selected,
          onTap: () => onSelectionChanged([id], !selected),
        );
      },
    );
  }
}

/// [DateGroupView]内部で使う、見出し行/アイテム行のいずれかを表す行データ。
class _DateRow<T> {
  const _DateRow.header(this.bucket)
      : item = null,
        group = null;

  const _DateRow.item(T this.item, DateGroup this.group) : bucket = null;

  final DateGroupBucket<T>? bucket;
  final T? item;
  final DateGroup? group;
}

class _DateGroupHeaderRow extends StatelessWidget {
  const _DateGroupHeaderRow({
    required this.label,
    required this.count,
    required this.checkState,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool? checkState;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          children: [
            IgnorePointer(
              child: Checkbox(
                value: checkState,
                tristate: true,
                onChanged: (_) {},
                activeColor: const Color(0xFF7C5CBF),
                side: const BorderSide(color: Color(0xFF3A3A55)),
              ),
            ),
            Expanded(
              child: Text(
                '$label ($count)',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF0F0F8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateItemRow extends StatelessWidget {
  const _DateItemRow({
    required this.label,
    required this.parentFolder,
    required this.time,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String parentFolder;
  final String time;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 親フォルダ名の2行目が表示される場合に備え、高さは固定せず最小44に留める。
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const SizedBox(width: 32),
              IgnorePointer(
                child: Checkbox(
                  value: selected,
                  onChanged: (_) {},
                  activeColor: const Color(0xFF7C5CBF),
                  side: const BorderSide(color: Color(0xFF3A3A55)),
                ),
              ),
              const Icon(
                Icons.description_outlined,
                size: 18,
                color: Color(0xFF8888AA),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFFF0F0F8),
                      ),
                    ),
                    if (parentFolder.isNotEmpty)
                      Text(
                        parentFolder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF8888AA),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                time,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8888AA),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
