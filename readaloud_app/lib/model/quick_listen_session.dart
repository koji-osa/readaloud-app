import 'package:uuid/uuid.dart';
import '../util/text_cleaner.dart';

/// Androidから共有された通常テキストをその場で読み上げるための一時セッション。
///
/// Content DBのprimary keyや一時的なDB rowには一切依存しない、純粋な
/// in-memoryモデル。「閉じる」で破棄されればDBには何も残らず、
/// 「保存」で初めてSaveContentUseCase経由の通常Contentへ昇格する。
class QuickListenSession {
  final String id;
  final String text;
  final String? title;
  final String sourceType;
  final int createdAt;
  final bool saved;

  QuickListenSession({
    String? id,
    required this.text,
    this.title,
    this.sourceType = 'share',
    int? createdAt,
    this.saved = false,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  /// Android共有(ACTION_SEND text/plain)から届いたテキストでセッションを作る。
  ///
  /// 変更前のAddScreen「テキスト」タブはURL・長い英数字記号を省略する
  /// TextCleaner(REQ-008)をデフォルトONで適用していた。Quick Listenでも
  /// 同じデフォルト挙動に揃えるため、共有由来のセッションは常にクレンジング
  /// 済みのテキストで読み上げ・保存する（チェックボックスでのOFF切り替えは
  /// Quick ListenのMVP UIには含めない）。
  factory QuickListenSession.fromSharedText(String text, {String? title}) {
    return QuickListenSession(text: TextCleaner.clean(text), title: title);
  }

  QuickListenSession copyWith({bool? saved}) => QuickListenSession(
        id: id,
        text: text,
        title: title,
        sourceType: sourceType,
        createdAt: createdAt,
        saved: saved ?? this.saved,
      );
}
