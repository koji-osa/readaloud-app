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

    test('http://・https://いずれもネイティブ側がURL型であればurlとして分類される', () {
      final httpsPayload = ShareIntentHandler.classify([
        _file(value: 'https://example.com/article', type: SharedMediaType.URL),
      ]);
      final httpPayload = ShareIntentHandler.classify([
        _file(value: 'http://example.com/article', type: SharedMediaType.URL),
      ]);

      expect(httpsPayload!.kind, SharedContentKind.url);
      expect(httpPayload!.kind, SharedContentKind.url);
    });

    test('URLを含む通常文章はネイティブ側でTEXT判定されるため、Quick Listen対象のtextのまま扱う', () {
      // URLUtil.isValidUrl()は文字列全体が厳密なURLである場合のみtrueになるため、
      // 前後に文章が付くとネイティブ側でTEXT判定される。ここではその前提を
      // Dart側のclassify()が正しく尊重する（勝手にURL扱いへ格上げしない）ことを確認する。
      final payload = ShareIntentHandler.classify([
        _file(
          value: 'これ面白かった見て https://example.com/article',
          type: SharedMediaType.TEXT,
        ),
      ]);

      expect(payload!.kind, SharedContentKind.text);
    });

    test('valueの前後空白はclassify()では保持され、トリムは呼び出し側の責務とする', () {
      final payload = ShareIntentHandler.classify([
        _file(value: '  https://example.com/article  ', type: SharedMediaType.URL),
      ]);

      expect(payload!.value, '  https://example.com/article  ');
    });

    test('flowIdを渡すとSharedTextPayloadにそのまま伝播する（share flowの相関ID）', () {
      final payload = ShareIntentHandler.classify(
        [_file(value: '共有テキスト', type: SharedMediaType.TEXT)],
        flowId: 'stream-1',
      );

      expect(payload!.flowId, 'stream-1');
    });

    test('flowId未指定時は空文字（既存呼び出し・テストとの後方互換）', () {
      final payload = ShareIntentHandler.classify([
        _file(value: '共有テキスト', type: SharedMediaType.TEXT),
      ]);

      expect(payload!.flowId, '');
    });
  });
}
