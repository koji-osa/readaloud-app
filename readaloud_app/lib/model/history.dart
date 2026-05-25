import 'package:uuid/uuid.dart';

class History {
  final String id;
  final String contentId;
  final int playedAt;
  final double progressPct;

  History({
    String? id,
    required this.contentId,
    int? playedAt,
    required this.progressPct,
  })  : id = id ?? const Uuid().v4(),
        playedAt = playedAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
        'id': id,
        'content_id': contentId,
        'played_at': playedAt,
        'progress_pct': progressPct,
      };

  factory History.fromMap(Map<String, dynamic> map) => History(
        id: map['id'],
        contentId: map['content_id'],
        playedAt: map['played_at'],
        progressPct: map['progress_pct'],
      );
}
