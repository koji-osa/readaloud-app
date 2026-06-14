import 'package:uuid/uuid.dart';

class Bookmark {
  final String id;
  final String contentId;
  final int position;
  final String? label;
  final int createdAt;

  static const int maxLabelLength = 65; // FIX-063

  Bookmark({
    String? id,
    required this.contentId,
    required this.position,
    String? label,
    int? createdAt,
  })  : assert(label == null || label.length <= maxLabelLength,
            'ラベルは${maxLabelLength}文字以内にしてください'),
        id = id ?? const Uuid().v4(),
        label = label,
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
        'id': id,
        'content_id': contentId,
        'position': position,
        'label': label,
        'created_at': createdAt,
      };

  factory Bookmark.fromMap(Map<String, dynamic> map) => Bookmark(
        id: map['id'],
        contentId: map['content_id'],
        position: map['position'],
        label: map['label'],
        createdAt: map['created_at'],
      );
}
