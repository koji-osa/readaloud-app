import 'package:uuid/uuid.dart';

/// Androidから共有された通常テキストをその場で読み上げるための一時セッション。
///
/// Content DBのprimary keyや一時的なDB rowには一切依存しない、純粋な
/// in-memoryモデル。「閉じる」で破棄されればDBには何も残らず、
/// 「保存」で初めてSaveContentUseCase経由の通常Contentへ昇格する。
class QuickListenSession {
  final String id;
  final String text;
  final String? title;
  final String sourceType;
  final int createdAt;
  final bool saved;

  QuickListenSession({
    String? id,
    required this.text,
    this.title,
    this.sourceType = 'share',
    int? createdAt,
    this.saved = false,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  QuickListenSession copyWith({bool? saved}) => QuickListenSession(
        id: id,
        text: text,
        title: title,
        sourceType: sourceType,
        createdAt: createdAt,
        saved: saved ?? this.saved,
      );
}
