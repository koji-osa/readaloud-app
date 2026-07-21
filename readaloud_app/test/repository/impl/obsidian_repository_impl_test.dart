import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/setting.dart';
import 'package:readaloud_app/repository/impl/obsidian_repository_impl.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/vault_data_source.dart';

void main() {
  group('ObsidianRepositoryImpl', () {
    late _FakeVaultDataSource vaultDataSource;
    late _FakeSettingsRepository settingsRepository;
    late ObsidianRepositoryImpl repository;

    setUp(() {
      vaultDataSource = _FakeVaultDataSource();
      settingsRepository = _FakeSettingsRepository();
      repository = ObsidianRepositoryImpl(vaultDataSource, settingsRepository);
    });

    group('pickVaultDirectory', () {
      test('saves the picked uri to SettingsRepository and returns it',
          () async {
        vaultDataSource.pickDirectoryResult = 'content://vault/root';

        final result = await repository.pickVaultDirectory();

        expect(result, 'content://vault/root');
        expect(
          settingsRepository.values[SettingKeys.obsidianVaultUri],
          'content://vault/root',
        );
      });

      test('does not touch SettingsRepository when the user cancels',
          () async {
        vaultDataSource.pickDirectoryResult = null;

        final result = await repository.pickVaultDirectory();

        expect(result, isNull);
        expect(
          settingsRepository.values.containsKey(SettingKeys.obsidianVaultUri),
          isFalse,
        );
      });
    });

    group('listNotes', () {
      test('returns an empty list without calling listEntries when no vault '
          'uri is saved', () async {
        final notes = await repository.listNotes();

        expect(notes, isEmpty);
        expect(vaultDataSource.listEntriesCalledWith, isNull);
      });

      test('calls listEntries with the saved vault uri and returns its '
          'result', () async {
        settingsRepository.values[SettingKeys.obsidianVaultUri] =
            'content://vault/root';
        const entries = [
          VaultEntry(
            uri: 'content://vault/root/note.md',
            relativePath: 'note.md',
            name: 'note.md',
          ),
        ];
        vaultDataSource.listEntriesResult = entries;

        final notes = await repository.listNotes();

        expect(notes, entries);
        expect(vaultDataSource.listEntriesCalledWith, 'content://vault/root');
      });
    });

    group('readNoteContent', () {
      test(
        'builds a VaultEntry with the given uri and empty '
        'relativePath/name, then delegates to readFile',
        () async {
          vaultDataSource.readFileResult = '# Note';

          final content = await repository.readNoteContent(
            'content://vault/root/note.md',
          );

          expect(content, '# Note');
          expect(
            vaultDataSource.readFileCalledWith,
            const VaultEntry(
              uri: 'content://vault/root/note.md',
              relativePath: '',
              name: '',
            ),
          );
        },
      );
    });

    group('writeNote', () {
      test('throws UnimplementedError', () {
        expect(
          () => repository.writeNote('note.md', 'content'),
          throwsUnimplementedError,
        );
      });
    });
  });
}

class _FakeVaultDataSource implements VaultDataSource {
  String? pickDirectoryResult;
  List<VaultEntry> listEntriesResult = [];
  String readFileResult = '';

  String? listEntriesCalledWith;
  VaultEntry? readFileCalledWith;

  @override
  Future<String?> pickDirectory() async => pickDirectoryResult;

  @override
  Future<List<VaultEntry>> listEntries(String rootUri) async {
    listEntriesCalledWith = rootUri;
    return listEntriesResult;
  }

  @override
  Future<String> readFile(VaultEntry entry) async {
    readFileCalledWith = entry;
    return readFileResult;
  }
}

class _FakeSettingsRepository implements SettingsRepository {
  final Map<String, String> values = {};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<Map<String, String>> getAll() async => Map.of(values);
}
