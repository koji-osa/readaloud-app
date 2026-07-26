import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/repository/obsidian_repository.dart';
import 'package:readaloud_app/repository/vault_data_source.dart';
import 'package:readaloud_app/usecase/obsidian/obsidian_importer.dart';

void main() {
  group('ObsidianImporter', () {
    late _FakeObsidianRepository repository;
    late ObsidianImporter importer;

    setUp(() {
      repository = _FakeObsidianRepository();
      importer = ObsidianImporter(repository);
    });

    test('複数ノートが正常に変換される', () async {
      repository.contents['content://vault/note1.md'] = '# Note1';
      repository.contents['content://vault/note2.md'] = '# Note2';

      final results = await importer.importNotes(const [
        VaultEntry(
          uri: 'content://vault/note1.md',
          relativePath: 'note1.md',
          name: 'note1.md',
        ),
        VaultEntry(
          uri: 'content://vault/note2.md',
          relativePath: 'note2.md',
          name: 'note2.md',
        ),
      ]);

      expect(results, hasLength(2));

      expect(results[0].noteUri, 'content://vault/note1.md');
      expect(results[0].isSuccess, isTrue);
      expect(results[0].error, isNull);
      expect(results[0].content!.text, '# Note1');
      expect(results[0].content!.metadata, {
        'noteUri': 'content://vault/note1.md',
        'title': 'note1',
      });

      expect(results[1].noteUri, 'content://vault/note2.md');
      expect(results[1].isSuccess, isTrue);
      expect(results[1].content!.text, '# Note2');
      expect(results[1].content!.metadata['title'], 'note2');
    });

    test('拡張子が.md以外、または存在しない場合も適切にタイトルが生成される', () async {
      repository.contents['content://vault/note3'] = '# NoExt';
      repository.contents['content://vault/note4.markdown'] = '# OtherExt';

      final results = await importer.importNotes(const [
        VaultEntry(
          uri: 'content://vault/note3',
          relativePath: 'note3',
          name: 'note3',
        ),
        VaultEntry(
          uri: 'content://vault/note4.markdown',
          relativePath: 'note4.markdown',
          name: 'note4.markdown',
        ),
      ]);

      expect(results[0].content!.metadata['title'], 'note3');
      expect(results[1].content!.metadata['title'], 'note4');
    });

    test('先頭がドットのみのファイル名の場合、名前がそのままタイトルになる', () async {
      repository.contents['content://vault/.hidden'] = '# Hidden';

      final results = await importer.importNotes(const [
        VaultEntry(
          uri: 'content://vault/.hidden',
          relativePath: '.hidden',
          name: '.hidden',
        ),
      ]);

      expect(results[0].content!.metadata['title'], '.hidden');
    });

    test('一部のノート読み込みが失敗しても他の取り込みは継続される', () async {
      repository.contents['content://vault/note1.md'] = '# Note1';
      repository.errors['content://vault/note2.md'] = Exception('read failed');
      repository.contents['content://vault/note3.md'] = '# Note3';

      final results = await importer.importNotes(const [
        VaultEntry(
          uri: 'content://vault/note1.md',
          relativePath: 'note1.md',
          name: 'note1.md',
        ),
        VaultEntry(
          uri: 'content://vault/note2.md',
          relativePath: 'note2.md',
          name: 'note2.md',
        ),
        VaultEntry(
          uri: 'content://vault/note3.md',
          relativePath: 'note3.md',
          name: 'note3.md',
        ),
      ]);

      expect(results, hasLength(3));

      expect(results[0].isSuccess, isTrue);
      expect(results[0].content!.text, '# Note1');

      expect(results[1].noteUri, 'content://vault/note2.md');
      expect(results[1].isSuccess, isFalse);
      expect(results[1].content, isNull);
      expect(results[1].error, isNotNull);

      expect(results[2].isSuccess, isTrue);
      expect(results[2].content!.text, '# Note3');
    });
  });
}

class _FakeObsidianRepository implements ObsidianRepository {
  final Map<String, String> contents = {};
  final Map<String, Object> errors = {};

  @override
  Future<String> readNoteContent(String uri) async {
    final error = errors[uri];
    if (error != null) {
      throw error;
    }
    final content = contents[uri];
    if (content == null) {
      throw StateError('No content registered for uri: $uri');
    }
    return content;
  }

  @override
  Future<String?> pickVaultDirectory() async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<String?> getVaultUri() async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<List<VaultEntry>> listNotes() async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<void> writeNote(String path, String content) async =>
      throw UnimplementedError('not used in this test');
}
