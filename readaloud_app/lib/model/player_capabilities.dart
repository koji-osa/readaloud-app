/// Player 画面の capability 構成（Detailed Design v1.2 FINAL §11 / PD-2）。
///
/// この 2 つの const 構成だけを持つ小さな値 object。参照は画面の
/// composition root（build で callback を渡す／null にする箇所）に限り、
/// 下位層へ feature flag として配らない。
final class PlayerCapabilities {
  const PlayerCapabilities({
    required this.bookmarks,
    required this.tocGeneration,
    required this.tableAnalysis,
    required this.voiceSelection,
    required this.speedSelection,
    required this.seekStep,
    required this.seekToEnd,
    required this.tapToSeek,
    required this.seekToStart,
    required this.libraryPromotion,
    required this.obsidianOpen,
  });

  final bool bookmarks;
  final bool tocGeneration;
  final bool tableAnalysis;
  final bool voiceSelection;
  final bool speedSelection;
  final bool seekStep;
  final bool seekToEnd;
  final bool tapToSeek;
  final bool seekToStart;
  final bool libraryPromotion;
  final bool obsidianOpen;

  /// Normal Player（Phase 1 で表示不変）。
  static const persistent = PlayerCapabilities(
    bookmarks: true,
    tocGeneration: true,
    tableAnalysis: true,
    voiceSelection: true,
    speedSelection: true,
    seekStep: true,
    seekToEnd: true,
    tapToSeek: true,
    seekToStart: true,
    libraryPromotion: false,
    obsidianOpen: true,
  );

  /// Transient Phase 1（PD-2）。
  static const transientPhase1 = PlayerCapabilities(
    bookmarks: false,
    tocGeneration: false,
    tableAnalysis: false,
    voiceSelection: false, // PD-2
    speedSelection: false, // PD-2（Transport 内部は対応、UI は出さない）
    seekStep: false, // PD-2（巻戻し/早送り非表示）
    seekToEnd: false,
    tapToSeek: true,
    seekToStart: true,
    libraryPromotion: true,
    obsidianOpen: false,
  );
}
