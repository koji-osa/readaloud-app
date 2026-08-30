import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/util/share_intent_handler.dart';

SharedFile _file({required String? value, required SharedMediaType type}) =>
    SharedFile(value: value, type: type);

void main() {
  group('ShareIntentHandler.classify', () {
    test('SharedMediaType.URLはSharedContentKind.urlとして分類される', () {
      final payload = ShareIntentHandler.classify([
        _file(value: 'https://example.com/article', type: SharedMediaType.URL),
      ]);

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.url);
      expect(payload.value, 'https://example.com/article');
    });

    test('SharedMediaType.TEXTはSharedContentKind.textとして分類される（Quick Listen対象）', () {
      final payload = ShareIntentHandler.classify([
        _file(value: 'ただの共有テキスト', type: SharedMediaType.TEXT),
      ]);

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.text);
      expect(payload.value, 'ただの共有テキスト');
    });

    test('空リストの場合はnullを返す', () {
      expect(ShareIntentHandler.classify([]), isNull);
    });

    test('valueがnullまたは空白のみの場合はnullを返す（不正payloadの安全な処理）', () {
      expect(
        ShareIntentHandler.classify([
          _file(value: null, type: SharedMediaType.TEXT),
        ]),
        isNull,
      );
      expect(
        ShareIntentHandler.classify([
          _file(value: '   ', type: SharedMediaType.TEXT),
        ]),
        isNull,
      );
    });

    test('TEXT/URL以外の種別（画像等）は無視して次の候補を探す', () {
      final payload = ShareIntentHandler.classify([
        _file(value: '/path/to/image.png', type: SharedMediaType.IMAGE),
        _file(value: '共有テキスト', type: SharedMediaType.TEXT),
      ]);

      expect(payload, isNotNull);
      expect(payload!.kind, SharedContentKind.text);
    });
  });
}
