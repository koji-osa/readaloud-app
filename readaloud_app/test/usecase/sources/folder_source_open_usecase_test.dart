import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/folder_child.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/repository/vault_data_source.dart';
import 'package:readaloud_app/usecase/sources/folder_source_open_usecase.dart';

class _FakeVault implements VaultDataSource {
  _FakeVault({this.body, this.throwOnRead = false});

  final String? body;
  final bool throwOnRead;

  @override
  Future<String?> pickDirectory() async => null;

  @override
  Future<List<VaultEntry>> listEntries(String rootUri) async => const [];

  @override
  Future<String> readFile(String uri) async {
    if (throwOnRead) throw StateError('provider unavailable');
    return body!;
  }

  @override
  Future<String?> getDirectoryName(String uri) async => 'Briefings';
}

FolderChild _item({String name = '2026-10-05_デイリーブリーフィング.md'}) => FolderChild(
      uri: 'content://com.google.android.apps.docs.storage/tree/x/document/y',
      name: name,
      mimeType: 'text/markdown',
      lastModified: DateTime(2026, 10, 5, 9).millisecondsSinceEpoch,
      isDirectory: false,
    );

void main() {
  const markdown = '---\ntitle: frontmatter-only\n---\n# 見出し\n\n本文の一文です。';

  test('成功: Transient request と folder descriptor が規約どおり', () async {
    final usecase = FolderSourceOpenUseCase(vault: _FakeVault(body: markdown));
    final item = _item();

    final request = await usecase.resolve(item: item, folderName: 'Briefings');

    expect(request.target, isA<TransientTarget>());
    expect(request.text, contains('本文の一文です'));
    expect(request.text, isNot(contains('frontmatter-only')));
    expect(request.title, '2026-10-05_デイリーブリーフィング');
    expect(request.source!.sourceType, 'folder');
    expect(request.source!.sourceUrl, item.uri);
    expect(request.source!.sourceFilename, item.name);
    expect(request.source!.externalType, isNull);
    expect(request.source!.vaultName, 'Briefings');
    expect(request.source!.relativePath, item.name);
    expect(request.source!.sourceType, isNot('url'));
  });

  test('成功時のみ openTransient が1回呼ばれる', () async {
    final usecase = FolderSourceOpenUseCase(vault: _FakeVault(body: markdown));
    var calls = 0;

    await usecase.open(
      item: _item(),
      folderName: 'Briefings',
      openTransient: (PlaybackRequest _) async => calls++,
    );

    expect(calls, 1);
  });

  test('読み取り失敗: 例外を投げ、openTransient は呼ばれない', () async {
    final usecase = FolderSourceOpenUseCase(vault: _FakeVault(throwOnRead: true));
    var calls = 0;

    await expectLater(
      usecase.open(
        item: _item(),
        folderName: 'Briefings',
        openTransient: (PlaybackRequest _) async => calls++,
      ),
      throwsA(isA<FolderSourceResolveException>()
          .having((e) => e.reason, 'reason', 'read_failed')),
    );
    expect(calls, 0);
  });

  test('本文が空（frontmatterのみ等）: empty_body、openTransient は呼ばれない', () async {
    const frontmatterOnly = '---\ntitle: x\n---\n';
    final usecase = FolderSourceOpenUseCase(vault: _FakeVault(body: frontmatterOnly));
    var calls = 0;

    await expectLater(
      usecase.open(
        item: _item(),
        folderName: 'Briefings',
        openTransient: (PlaybackRequest _) async => calls++,
      ),
      throwsA(isA<FolderSourceResolveException>()
          .having((e) => e.reason, 'reason', 'empty_body')),
    );
    expect(calls, 0);
  });

  test('タイトルは Content の上限（100文字）に切り詰める', () async {
    final longName = '${'あ' * 150}.md';
    final usecase = FolderSourceOpenUseCase(vault: _FakeVault(body: markdown));

    final request = await usecase.resolve(item: _item(name: longName), folderName: 'B');

    expect(request.title!.length, 100);
  });
}
