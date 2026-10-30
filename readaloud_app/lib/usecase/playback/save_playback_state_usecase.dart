import '../../model/playback_state.dart';
import '../../repository/playback_repository.dart';
import '../../repository/content_repository.dart';
import 'seek_math.dart';

class SavePlaybackStateUseCase {
  final PlaybackRepository _playbackRepo;
  final ContentRepository _contentRepo;

  SavePlaybackStateUseCase({
    required PlaybackRepository playbackRepo,
    required ContentRepository contentRepo,
  })  : _playbackRepo = playbackRepo,
        _contentRepo = contentRepo;

  Future<void> execute({
    required String contentId,
    required int position,
    required double progressPct,
    double? speed,
    String? voiceId,
    double? pitch,
    double? volume,
  }) async {
    final existing = await _playbackRepo.getByContentId(contentId) ??
        PlaybackState(contentId: contentId);

    final updated = existing.copyWith(
      position: position,
      progressPct: progressPct,
      speed: speed,
      voiceId: voiceId,
      pitch: pitch,
      volume: volume,
      lastPlayedAt: DateTime.now().millisecondsSinceEpoch,
    );

    await _playbackRepo.save(updated);

    // 進捗100%なら完了ステータスに更新
    if (progressPct >= 100.0) {
      final content = await _contentRepo.getById(contentId);
      if (content != null) {
        await _contentRepo.update(content.copyWith(status: 'completed'));
      }
    }
  }

  /// 自然終了（P5）。位置=本文長 / 進捗100% を保存する（status は [execute] の
  /// 既存規則で completed）。Content 欠損・空本文は fail-closed で何も書かない。
  Future<void> executeCompletion({required String contentId}) async {
    final content = await _contentRepo.getById(contentId);
    if (content == null || content.body.isEmpty) return;
    await execute(
      contentId: contentId,
      position: content.body.length,
      progressPct: 100.0,
    );
  }

  /// 停止系（stop / pause / teardown / retire / adopt）の位置保存。
  ///
  /// 進捗率は「停止位置 ÷ 現在の Content.body.length」で計算する（RA-PROG-IMPL-A-01）。
  /// 旧実装は保存済みの進捗率から総文字数を逆算していたため、0% なら 100% へ、
  /// 正の値ならその値のまま凍結していた。
  ///
  /// - 位置は [0, 本文長] へ clamp する。範囲内の位置はそのまま保存する。
  /// - 本文長を確定できない（Content 欠損・空本文・非有限な結果）場合は、
  ///   既存の進捗率を維持し、status にも触れない（新たな 100% / completed を
  ///   作らない）。位置は 0 以上へ（空本文は 0 へ）丸める。
  /// - 100% に達した場合の completed 昇格は [execute] の既存規則に従う。
  ///   100% 未満への降格はここでは行わない（PR-B の範囲）。
  ///
  /// 既知の制約: 分母は DB の現在の本文長。再生中に表解説を挿入すると、再生セッションの
  /// `PlaybackRequest.text` より長くなり得るため、進捗率がわずかに小さくなる。
  Future<void> executeStop({
    required String contentId,
    required int position,
  }) async {
    final existing = await _playbackRepo.getByContentId(contentId) ??
        PlaybackState(contentId: contentId);
    final content = await _contentRepo.getById(contentId);
    final length = content?.body.length ?? 0;

    if (length > 0) {
      final clamped = position.clamp(0, length);
      final progressPct = SeekMath.progressPct(clamped, length);
      if (progressPct.isFinite) {
        await execute(
          contentId: contentId,
          position: clamped,
          progressPct: progressPct,
        );
        return;
      }
    }

    // 本文長を確定できない: 既存の進捗率を維持し、status には触れない。
    final fallbackPosition = length == 0 && content != null
        ? 0
        : (position < 0 ? 0 : position);
    await _playbackRepo.save(existing.copyWith(
      position: fallbackPosition,
      lastPlayedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }
}
