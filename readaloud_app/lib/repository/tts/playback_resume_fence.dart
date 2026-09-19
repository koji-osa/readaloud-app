/// owner を恒久 retire する teardown で、media notification をどう扱うか
/// （Detailed Design v1.2 FINAL §6.5 / NEW-Q1=A）。
enum NotificationDisposition {
  /// terminal close。owner guard を通過した時点で他 live owner は存在しない
  /// ため、media notification を完全に消す。
  clearIfNoLiveOwner,

  /// shareTeardown / routeRemoval。旧 owner の resume state と media controls
  /// を無効化し、次 owner の speak() が新しい media state を設定する。
  handoff,
}

/// 再生の「復活可能な残骸」（notification Play / audio interruption resume で
/// 旧 text を再生できる状態）を破棄するための狭い interface。
///
/// `TtsService` は拡張しない。production では `TtsAudioHandler` が実装し、
/// `SharedPlaybackTransport` へ必須注入される。
abstract interface class PlaybackResumeFence {
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  });
}
