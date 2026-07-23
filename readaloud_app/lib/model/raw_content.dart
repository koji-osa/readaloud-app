/// 各種インポート元(Obsidian, URL, PDF等)から取り込んだコンテンツを
/// 表す共通データ形式。
class RawContent {
  const RawContent({required this.text, this.metadata = const {}});

  /// 取り込んだ本文。
  final String text;

  /// 取り込み元に関する付加情報(例: 'noteUri')。
  final Map<String, dynamic> metadata;
}
