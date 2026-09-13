/// Normal Player single-route (Canonical Design v0.4.1) — identity value objects.
///
/// このファイルは Flutter に依存しない純粋な値オブジェクトのみを持つ。
/// Route を直接参照する型（rollback token 等）は `util/normal_player_session_tracker.dart`
/// 側に置く（RA-NPR-P04 review C-07: 専用 file を新設せず、既存の共有 file へ置く方針に従い、
/// util/ → usecase/ の逆依存を避けるため PlaybackOwnerKey を含め本 file は model 層に集約する）。
library;

import 'package:uuid/uuid.dart';

/// Normal Player の1回の論理的な起動（open）を表す immutable な値。
///
/// content が同一でも、開くたびに新しい [id] を持つ。同一 content の再 open /
/// re-share は正当な新規 event であり、content/hash による dedup は行わない
/// （Phase 1 NR-29 / INV-11）。
class NormalPlayerSession {
  NormalPlayerSession(
      {String? id, required this.contentId, DateTime? startedAt})
      : id = id ?? const Uuid().v4(),
        startedAt = startedAt ?? DateTime.now();

  final String id;
  final String contentId;
  final DateTime startedAt;
}

/// ある副作用（state write / DB write / navigation / TTS / transient UI 等）が
/// 「どの Player の起動によって要求されたか」を表す immutable token。
///
/// await 境界を跨いでも値は変化しない。ViewModel 側の mutable な紐付け
/// （attached session）を origin の代用にしてはならない（D9 / NRR-12）。
class PlayerOriginToken {
  const PlayerOriginToken({required this.sessionId, required this.contentId});

  final String sessionId;
  final String contentId;
}

/// TTS-stop / usage-accounting-flush / playback-position-save の結果を
/// 個別に記録する構造化された停止結果（v0.4.1 D7/D8/D12, B-01 closure）。
///
/// route 除去を許可してよいかどうかは [ttsStopConfirmed] のみで判定する。
/// accounting / position-save の失敗は、TTS-stop が成功していれば route 除去を
/// 妨げない。
class PlaybackStopOutcome {
  const PlaybackStopOutcome({
    this.applicable = true,
    required this.ttsStopSucceeded,
    required this.usageFlushSucceeded,
    required this.positionSaveSucceeded,
    this.ttsStopErrorType,
    this.usageFlushErrorType,
    this.positionSaveErrorType,
  });

  /// 該当する再生セッションが実在した（停止すべきものが実際にあった）か。
  /// false の場合、そもそも止めるべき TTS が無かったことを意味し、
  /// [ttsStopSucceeded] は vacuously true として扱う。
  final bool applicable;
  final bool ttsStopSucceeded;
  final bool usageFlushSucceeded;
  final bool positionSaveSucceeded;
  final String? ttsStopErrorType;
  final String? usageFlushErrorType;
  final String? positionSaveErrorType;

  /// D16: Normal Player route 除去を許可してよいかの唯一の判定条件。
  /// 「Player/TTS stop が該当しない」場合も true になる。
  bool get ttsStopConfirmed => !applicable || ttsStopSucceeded;

  /// 停止すべき再生セッションがそもそも存在しなかった場合。
  factory PlaybackStopOutcome.notApplicable() => const PlaybackStopOutcome(
        applicable: false,
        ttsStopSucceeded: true,
        usageFlushSucceeded: true,
        positionSaveSucceeded: true,
      );
}

/// teardown 第1相（`prepareForRemoval`）が返す除去1回分の券。
///
/// これ無しに `removeActivePlayerNow()` を呼べない（順序を型で強制する）。
/// [sessionId] / [claimId] が null の場合は「除去対象なし」を表す empty ticket。
class PlayerRemovalTicket {
  const PlayerRemovalTicket._({
    required this.sessionId,
    required this.contentId,
    required this.claimId,
    required this.flowId,
    required this.stopOutcome,
  });

  factory PlayerRemovalTicket.empty({required String flowId}) =>
      PlayerRemovalTicket._(
        sessionId: null,
        contentId: null,
        claimId: null,
        flowId: flowId,
        stopOutcome: PlaybackStopOutcome.notApplicable(),
      );

  factory PlayerRemovalTicket.forSession({
    required String sessionId,
    required String contentId,
    required String claimId,
    required String flowId,
    required PlaybackStopOutcome stopOutcome,
  }) =>
      PlayerRemovalTicket._(
        sessionId: sessionId,
        contentId: contentId,
        claimId: claimId,
        flowId: flowId,
        stopOutcome: stopOutcome,
      );

  final String? sessionId;
  final String? contentId;
  final String? claimId;
  final String flowId;
  final PlaybackStopOutcome stopOutcome;

  /// このticketが実在するPlayer registrationを表しているか（D8 step 4 の第1連言）。
  bool get representsCurrentPlayer => sessionId != null && claimId != null;
}

/// Normal Player の usage-accounting 上の「所有者」。
///
/// content identity でも Player session identity そのものでもない、専用の
/// value type（D2）。Normal Player と Quick Listen が互いの所有権を誤って
/// 主張できないよう、内部表現に `np:`/`ql:` prefix を持つ。
class PlaybackOwnerKey {
  const PlaybackOwnerKey._(this._value);

  factory PlaybackOwnerKey.normalPlayer(String sessionId) =>
      PlaybackOwnerKey._('np:$sessionId');

  factory PlaybackOwnerKey.quickListen(String sessionId) =>
      PlaybackOwnerKey._('ql:$sessionId');

  final String _value;

  @override
  bool operator ==(Object other) =>
      other is PlaybackOwnerKey && other._value == _value;

  @override
  int get hashCode => _value.hashCode;

  @override
  String toString() => _value;
}
