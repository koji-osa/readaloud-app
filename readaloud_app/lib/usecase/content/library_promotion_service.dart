import 'dart:async';

import '../../model/content.dart';
import '../../model/playback_request.dart';
import '../../model/playback_state.dart';
import '../../repository/playback_repository.dart';
import '../../util/debug_logger.dart';
import '../playback/playback_defaults_reader.dart';
import 'save_content_usecase.dart';

/// Transient → Library の昇格入力。既存 contentId は型として受け取らない。
final class PromotionInput {
  const PromotionInput({
    required this.request,
    required this.position,
    required this.speed,
  });

  /// 保存時点の Transient request（`TransientTarget` のみ受け付ける）。
  /// `text` は解決済み snapshot で、保存時に Source から再取得しない。
  final PlaybackRequest request;

  /// 保存時点の再生位置（[0, text.length] に clamp して使う）。
  final int position;

  /// 保存時点の再生速度（Transient session の速度 = defaultSpeed 由来）。
  final double speed;
}

final class PromotionResult {
  const PromotionResult({
    required this.content,
    required this.handoffApplied,
    this.handoffErrorType,
  });

  final Content content;

  /// 新 Content 行へ初期 PlaybackState（position / speed）を書いたか。
  final bool handoffApplied;
  final String? handoffErrorType;
}

/// Transient の唯一の Library 書込み seam（Detailed Design v1.2 FINAL §7.5 / §10）。
///
/// 新規 Content 行を作り、その戻り値の id に対してだけ初期 PlaybackState を
/// 書く。既存行を書き換える API を持たない。保存後の Transient 継続再生位置は
/// Library へ反映しない（保存時 handoff のみ）。
class LibraryPromotionService {
  LibraryPromotionService({
    required SaveContentUseCase saveContent,
    required PlaybackRepository playbackRepo,
    required PlaybackDefaultsReader defaultsReader,
  })  : _saveContent = saveContent,
        _playbackRepo = playbackRepo,
        _defaultsReader = defaultsReader;

  final SaveContentUseCase _saveContent;
  final PlaybackRepository _playbackRepo;
  final PlaybackDefaultsReader _defaultsReader;

  Future<PromotionResult> promote(PromotionInput input) async {
    final request = input.request;
    if (request.target is! TransientTarget) {
      throw ArgumentError.value(
          request.target, 'input.request.target', 'TransientTarget only');
    }
    final source = request.source;

    // 7a: body snapshot + provenance（既存カラムのみ。PD-3: title は Source
    // タイトル、無ければ SaveContentUseCase の既存自動生成に委ねる）。
    final content = await _saveContent.execute(
      body: request.text,
      sourceType: source?.sourceType ?? 'share',
      title: request.title,
      sourceUrl: source?.sourceUrl,
      sourceFilename: source?.sourceFilename,
      externalType: source?.externalType,
      vaultName: source?.vaultName,
      relativePath: source?.relativePath,
    );

    // 7b: position + speed handoff。Content insert 成功後にだけ行い（FK 充足）、
    // 失敗しても Content 保存は巻き戻さない。
    final text = request.text;
    final position = input.position.clamp(0, text.length);
    try {
      final defaultSpeed = await _defaultsReader.readDefaultSpeed();
      if (position == 0 && input.speed == defaultSpeed) {
        // 行を作らず、NP setContent の既存「初回 defaultSpeed 初期化」経路に任せる。
        return PromotionResult(content: content, handoffApplied: false);
      }
      final progressPct =
          text.isEmpty ? 0.0 : (position / text.length * 100).clamp(0.0, 100.0);
      await _playbackRepo.save(PlaybackState(
        contentId: content.id,
        position: position,
        progressPct: progressPct,
        speed: input.speed,
      ));
      return PromotionResult(content: content, handoffApplied: true);
    } catch (e) {
      unawaited(DebugLogger.instance.logEvent('error', {
        'context': 'library_promotion_handoff',
        'errorType': e.runtimeType.toString(),
      }));
      return PromotionResult(
        content: content,
        handoffApplied: false,
        handoffErrorType: e.runtimeType.toString(),
      );
    }
  }
}
