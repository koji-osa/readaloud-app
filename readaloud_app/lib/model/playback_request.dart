/// Shared Player Core（Detailed Design v1.2 FINAL §8）の再生要求 value object。
///
/// Transport は contentId を一切知らない。Persistent / Transient の区別は
/// [PlaybackTarget] の sealed 型でだけ表現し、nullable contentId による
/// 分岐を各所へ散らさない。
library;

import 'package:meta/meta.dart';

import 'content.dart';

sealed class PlaybackTarget {
  const PlaybackTarget();
}

/// Library に行を持たない一時再生。contentId は型として存在しない。
final class TransientTarget extends PlaybackTarget {
  const TransientTarget();
}

/// 実在する Library Content の再生。
final class PersistentTarget extends PlaybackTarget {
  const PersistentTarget._(this.contentId);

  /// 実在する [Content]（DB から読んだ／保存直後に得た）からのみ作る。
  factory PersistentTarget.of(Content content) =>
      PersistentTarget._(content.id);

  /// Normal Player facade 専用。登録済み `NormalPlayerSession` の contentId
  /// （= 既存 Content 行から生成された id）だけを受け取る経路で使う。
  ///
  /// 注意: `@internal` は package 外からの利用を analyzer が警告するだけで、
  /// package 内（Transient 側を含む）からの呼び出しを型として禁止するものでは
  /// ない。Transient 側が使わないことは、Transient controller が既存 contentId を
  /// 保持しない設計・レビュー、および import tripwire テストで担保する。
  @internal
  factory PersistentTarget.ofRegisteredSessionContentId(String contentId) =>
      PersistentTarget._(contentId);

  final String contentId;
}

final class PlaybackVoiceParams {
  const PlaybackVoiceParams({
    this.speed = 1.0,
    this.pitch = 1.0,
    this.volume = 1.0,
    this.voiceId,
  });

  final double speed;
  final double pitch;
  final double volume;
  final String? voiceId;
}

/// Content の既存カラムへ 1:1 で写像できる範囲だけを持つ（migration 不要）。
final class SourceDescriptor {
  const SourceDescriptor({
    required this.sourceType,
    this.sourceUrl,
    this.sourceFilename,
    this.externalType,
    this.vaultName,
    this.relativePath,
  });

  /// `Content.sourceType` と同じ語彙（'share' 等）。
  final String sourceType;
  final String? sourceUrl;
  final String? sourceFilename;
  final String? externalType;
  final String? vaultName;
  final String? relativePath;
}

final class PlaybackRequest {
  PlaybackRequest({
    required this.target,
    required this.text,
    this.title,
    required int startPosition,
    this.voice = const PlaybackVoiceParams(),
    this.source,
  }) : startPosition = startPosition.clamp(0, text.length);

  final PlaybackTarget target;

  /// 解決済み本文 snapshot。session 中は不変（Source 消失・更新の影響を受けない）。
  final String text;
  final String? title;

  /// [0, text.length] に clamp して保持する。
  final int startPosition;
  final PlaybackVoiceParams voice;

  /// promotion 用 provenance。Persistent では null。
  final SourceDescriptor? source;

  PlaybackRequest withStartPosition(int position) => PlaybackRequest(
        target: target,
        text: text,
        title: title,
        startPosition: position,
        voice: voice,
        source: source,
      );

  PlaybackRequest withVoice(PlaybackVoiceParams voice) => PlaybackRequest(
        target: target,
        text: text,
        title: title,
        startPosition: startPosition,
        voice: voice,
        source: source,
      );
}
