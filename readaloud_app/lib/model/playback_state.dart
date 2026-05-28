class PlaybackState {
  final String contentId;
  final int position;
  final double progressPct;
  final double speed;
  final String? voiceId;
  final double pitch;
  final double volume;
  final int? repeatStart;
  final int? repeatEnd;
  final int? lastPlayedAt;
  final int updatedAt;

  static const double minSpeed = 0.5;
  static const double maxSpeed = 3.0;
  static const double minPitch = 0.5;
  static const double maxPitch = 2.0;

  PlaybackState({
    required this.contentId,
    this.position = 0,
    this.progressPct = 0.0,
    this.speed = 1.0,
    this.voiceId,
    this.pitch = 1.0,
    this.volume = 1.0,
    this.repeatStart,
    this.repeatEnd,
    this.lastPlayedAt,
    int? updatedAt,
  })  : assert(speed >= minSpeed && speed <= maxSpeed,
            '速度は${minSpeed}〜${maxSpeed}の範囲にしてください'),
        assert(pitch >= minPitch && pitch <= maxPitch,
            '音程は${minPitch}〜${maxPitch}の範囲にしてください'),
        assert(volume >= 0.0 && volume <= 1.0,
            '音量は0.0〜1.0の範囲にしてください'),
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
        'content_id': contentId,
        'position': position,
        'progress_pct': progressPct,
        'speed': speed,
        'voice_id': voiceId,
        'pitch': pitch,
        'volume': volume,
        'repeat_start': repeatStart,
        'repeat_end': repeatEnd,
        'last_played_at': lastPlayedAt,
        'updated_at': updatedAt,
      };

  factory PlaybackState.fromMap(Map<String, dynamic> map) => PlaybackState(
        contentId: map['content_id'],
        position: map['position'],
        progressPct: map['progress_pct'],
        speed: map['speed'],
        voiceId: map['voice_id'],
        pitch: map['pitch'],
        volume: map['volume'],
        repeatStart: map['repeat_start'],
        repeatEnd: map['repeat_end'],
        lastPlayedAt: map['last_played_at'],
        updatedAt: map['updated_at'],
      );

  PlaybackState copyWith({
    int? position,
    double? progressPct,
    double? speed,
    String? voiceId,
    double? pitch,
    double? volume,
    int? repeatStart,
    int? repeatEnd,
    int? lastPlayedAt,
  }) =>
      PlaybackState(
        contentId: contentId,
        position: position ?? this.position,
        progressPct: progressPct ?? this.progressPct,
        speed: speed ?? this.speed,
        voiceId: voiceId ?? this.voiceId,
        pitch: pitch ?? this.pitch,
        volume: volume ?? this.volume,
        repeatStart: repeatStart ?? this.repeatStart,
        repeatEnd: repeatEnd ?? this.repeatEnd,
        lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
}
