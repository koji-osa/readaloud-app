import 'package:uuid/uuid.dart';
import '../util/text_cleaner.dart';
import 'playback_request.dart';

/// Androidから共有された通常テキストをその場で読み上げるための一時（Transient）セッション。
///
/// Content DBのprimary keyや一時的なDB rowには一切依存しない、純粋な
/// in-memoryモデル。「閉じる」で破棄されればDBには何も残らず、
/// 「保存」で初めてLibraryPromotionService経由の通常Contentへ昇格する。
///
/// Shared Player Core（Detailed Design v1.2 FINAL §8.2）: identity/lifecycle
/// のみを持ち、再生 payload（text / title / source）は [request] に一元化する。
class QuickListenSession {
  QuickListenSession({
    String? id,
    required this.request,
    int? createdAt,
    this.saved = false,
    this.promotedContentId,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  /// Android共有(ACTION_SEND text/plain)から届いたテキストでセッションを作る。
  ///
  /// 変更前のAddScreen「テキスト」タブはURL・長い英数字記号を省略する
  /// TextCleaner(REQ-008)をデフォルトONで適用していた。Quick Listenでも
  /// 同じデフォルト挙動に揃えるため、共有由来のセッションは常にクレンジング
  /// 済みのテキストで読み上げ・保存する。TextCleaner.clean は**ここで1回だけ**
  /// 適用する（INV-18）。
  factory QuickListenSession.fromSharedText(
    String text, {
    String? title,
    double speed = 1.0,
  }) =>
      QuickListenSession(
        request: PlaybackRequest(
          target: const TransientTarget(),
          text: TextCleaner.clean(text),
          title: title,
          startPosition: 0,
          voice: PlaybackVoiceParams(speed: speed),
          source: const SourceDescriptor(sourceType: 'share'),
        ),
      );

  final String id;

  /// canonical payload。
  final PlaybackRequest request;
  final int createdAt;
  final bool saved;

  /// promotion 後に得た Library Content の id（表示用のみ。Target へは変換しない）。
  final String? promotedContentId;

  QuickListenSession copyWith({
    bool? saved,
    String? promotedContentId,
    PlaybackRequest? request,
  }) =>
      QuickListenSession(
        id: id,
        request: request ?? this.request,
        createdAt: createdAt,
        saved: saved ?? this.saved,
        promotedContentId: promotedContentId ?? this.promotedContentId,
      );
}
