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
}
