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

      final results = await importer.importNotes([
        'content://vault/note1.md',
        'content://vault/note2.md',
      ]);

      expect(results, hasLength(2));

      expect(results[0].noteUri, 'content://vault/note1.md');
      expect(results[0].isSuccess, isTrue);
      expect(results[0].error, isNull);
      expect(results[0].content!.text, '# Note1');
      expect(results[0].content!.metadata, {'noteUri': 'content://vault/note1.md'});

      expect(results[1].noteUri, 'content://vault/note2.md');
      expect(results[1].isSuccess, isTrue);
      expect(results[1].content!.text, '# Note2');
    });

    test('一部のノート読み込みが失敗しても他の取り込みは継続される', () async {
      repository.contents['content://vault/note1.md'] = '# Note1';
      repository.errors['content://vault/note2.md'] = Exception('read failed');
      repository.contents['content://vault/note3.md'] = '# Note3';

      final results = await importer.importNotes([
        'content://vault/note1.md',
        'content://vault/note2.md',
        'content://vault/note3.md',
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
    return contents[uri] ?? '';
  }

  @override
  Future<String?> pickVaultDirectory() async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<List<VaultEntry>> listNotes() async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<void> writeNote(String path, String content) async =>
      throw UnimplementedError('not used in this test');
}
