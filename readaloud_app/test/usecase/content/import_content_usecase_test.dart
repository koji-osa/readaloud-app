import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/parsed_content.dart';
import 'package:readaloud_app/model/raw_content.dart';
import 'package:readaloud_app/usecase/content/import_content_usecase.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/util/content_parser.dart';

void main() {
  group('ImportContentUseCase', () {
    late _FakeContentParser parser;
    late _FakeSaveContentUseCase saveContent;
    late ImportContentUseCase useCase;

    setUp(() {
      parser = _FakeContentParser();
      saveContent = _FakeSaveContentUseCase();
      useCase = ImportContentUseCase(saveContent);
    });

    test('parser.parse()の結果がSaveContentUseCaseにそのまま渡される', () async {
      const raw = RawContent(text: '# Note', metadata: {'noteUri': 'content://vault/note.md'});
      parser.result = ParsedContent(body: '変換後の本文');

      await useCase.execute(raw: raw, parser: parser, sourceType: 'obsidian');

      expect(parser.capturedRaw, same(raw));
      expect(saveContent.capturedBody, '変換後の本文');
    });

    test('sourceTypeが正しく伝播する', () async {
      const raw = RawContent(text: 'text');
      parser.result = ParsedContent(body: 'body');

      await useCase.execute(raw: raw, parser: parser, sourceType: 'obsidian');

      expect(saveContent.capturedSourceType, 'obsidian');
    });

    test('parsed.metadataにtitleがあればSaveContentUseCaseのtitle引数に渡す', () async {
      const raw = RawContent(text: 'text');
      parser.result = ParsedContent(
        body: 'body',
        metadata: {'title': 'メタデータのタイトル'},
      );

      await useCase.execute(raw: raw, parser: parser, sourceType: 'obsidian');

      expect(saveContent.capturedTitle, 'メタデータのタイトル');
    });

    test('parsed.metadataにtitleが無ければtitleはnullのまま渡す', () async {
      const raw = RawContent(text: 'text');
      parser.result = ParsedContent(body: 'body');

      await useCase.execute(raw: raw, parser: parser, sourceType: 'obsidian');

      expect(saveContent.capturedTitle, isNull);
    });

    test('sourceUrl・sourceFilenameが正しく伝播する', () async {
      const raw = RawContent(text: 'text');
      parser.result = ParsedContent(body: 'body');

      await useCase.execute(
        raw: raw,
        parser: parser,
        sourceType: 'file',
        sourceUrl: 'https://example.com',
        sourceFilename: 'note.md',
      );

      expect(saveContent.capturedSourceUrl, 'https://example.com');
      expect(saveContent.capturedSourceFilename, 'note.md');
    });

    test('shouldClean: trueの場合、parser.parse()後のbodyにTextCleanerが適用されて渡される', () async {
      const raw = RawContent(text: '# A');
      parser.result = ParsedContent(body: '本文 https://example.com の続き');

      await useCase.execute(
        raw: raw,
        parser: parser,
        sourceType: 'obsidian',
        shouldClean: true,
      );

      expect(saveContent.capturedBody, '本文 (URLの記載省略) の続き');
    });

    test('shouldCleanを指定しない場合(デフォルトfalse)はTextCleanerが適用されない', () async {
      const raw = RawContent(text: '# A');
      parser.result = ParsedContent(body: '本文 https://example.com の続き');

      await useCase.execute(raw: raw, parser: parser, sourceType: 'obsidian');

      expect(saveContent.capturedBody, '本文 https://example.com の続き');
    });

    test('SaveContentUseCaseの戻り値がそのまま返される', () async {
      const raw = RawContent(text: 'text');
      parser.result = ParsedContent(body: 'body');
      final expected = Content(title: 't', body: 'body', sourceType: 'obsidian');
      saveContent.returnValue = expected;

      final result = await useCase.execute(raw: raw, parser: parser, sourceType: 'obsidian');

      expect(result, same(expected));
    });
  });
}

class _FakeContentParser implements ContentParser {
  RawContent? capturedRaw;
  ParsedContent result = ParsedContent(body: '');

  @override
  Future<ParsedContent> parse(RawContent raw) async {
    capturedRaw = raw;
    return result;
  }
}

class _FakeSaveContentUseCase implements SaveContentUseCase {
  String? capturedBody;
  String? capturedSourceType;
  String? capturedTitle;
  String? capturedSourceUrl;
  String? capturedSourceFilename;
  Content? returnValue;

  @override
  Future<Content> execute({
    required String body,
    required String sourceType,
    String? title,
    String? sourceUrl,
    String? sourceFilename,
  }) async {
    capturedBody = body;
    capturedSourceType = sourceType;
    capturedTitle = title;
    capturedSourceUrl = sourceUrl;
    capturedSourceFilename = sourceFilename;
    return returnValue ??= Content(
      title: title ?? 'dummy',
      body: body,
      sourceType: sourceType,
    );
  }
}
