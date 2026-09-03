import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/quick_listen_session.dart';

void main() {
  group('QuickListenSession', () {
    test('id・createdAtが未指定でも自動生成され、savedはデフォルトfalse', () {
      final session = QuickListenSession(text: '本文');

      expect(session.id, isNotEmpty);
      expect(session.createdAt, greaterThan(0));
      expect(session.saved, isFalse);
      expect(session.sourceType, 'share');
    });

    test('copyWith(saved: true)はid・text・createdAtを維持したままsavedのみ更新する', () {
      final session = QuickListenSession(text: '本文', title: 'タイトル');

      final saved = session.copyWith(saved: true);

      expect(saved.id, session.id);
      expect(saved.text, session.text);
      expect(saved.title, session.title);
      expect(saved.createdAt, session.createdAt);
      expect(saved.saved, isTrue);
    });
  });

  group('QuickListenSession.fromSharedText', () {
    // 回帰監査で判明: 旧AddScreen「テキスト」タブはURL・長い英数字記号を省略する
    // TextCleaner(REQ-008)をデフォルトONで適用していた。Quick Listenでも同じ
    // デフォルト挙動に揃える方針とした（プロダクト判断済み）ため、共有由来の
    // セッションは常にクレンジングされたテキストを保持することを固定する。
    test('URLは(URLの記載省略)に置き換えられてから保持される', () {
      final session = QuickListenSession.fromSharedText(
        'これ面白かった見て https://example.com/article すごくいい',
      );

      expect(session.text, 'これ面白かった見て (URLの記載省略) すごくいい');
    });

    test('15文字以上の英数字記号(英字含む)は(英数字記号省略)に置き換えられる', () {
      final session = QuickListenSession.fromSharedText(
        'エラーコード: AbCdEfGhIjKlMnOpQr が出ました',
      );

      expect(session.text, 'エラーコード: (英数字記号省略) が出ました');
    });

    test('URLを含まない通常の日本語文はそのまま保持される', () {
      final session = QuickListenSession.fromSharedText('こんにちは、今日はいい天気ですね。');

      expect(session.text, 'こんにちは、今日はいい天気ですね。');
    });

    test('通常のコンストラクタ(QuickListenSession())はクレンジングを行わない', () {
      // 直接コンストラクタを使う経路(例: セッション置換時のcopyWith等)まで
      // 二重にクレンジングされないことを確認する。
      final session = QuickListenSession(text: 'https://example.com/raw');

      expect(session.text, 'https://example.com/raw');
    });

    test('titleはそのまま引き継がれる', () {
      final session =
          QuickListenSession.fromSharedText('本文', title: '共有元のタイトル');

      expect(session.title, '共有元のタイトル');
    });
  });
}
