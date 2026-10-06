import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/folder_child.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/repository/vault_data_source.dart';
import 'package:readaloud_app/usecase/sources/folder_source_open_usecase.dart';

class _FakeVault implements VaultDataSource {
  _FakeVault(this._readFile);

  /// 本文を返す関数。テストごとに即値・Completer・例外を切り替える。
  final Future<String> Function(String uri) _readFile;

  @override
  Future<String?> pickDirectory() async => null;

  @override
  Future<List<VaultEntry>> listEntries(String rootUri) async => const [];

  @override
  Future<String> readFile(String uri) => _readFile(uri);

  @override
  Future<String?> getDirectoryName(String uri) async => 'Briefings';
}

_FakeVault _vaultWith(String body) => _FakeVault((_) async => body);

FolderChild _item({String name = '2026-10-05_デイリーブリーフィング.md', String? uri}) =>
    FolderChild(
      uri: uri ?? 'content://com.google.android.apps.docs.storage/tree/x/document/$name',
      name: name,
      mimeType: 'text/markdown',
      lastModified: DateTime(2026, 10, 5, 9).millisecondsSinceEpoch,
      isDirectory: false,
    );

void main() {
  const markdown = '---\ntitle: frontmatter-only\n---\n# 見出し\n\n本文の一文です。';

  group('resolve（generic Markdown 変換）', () {
    test('成功: Transient request と folder descriptor が規約どおり', () async {
      final usecase = FolderSourceOpenUseCase(vault: _vaultWith(markdown));
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
    });

    test('folderName 取得失敗（null）は空文字にせず null のまま保存する', () async {
      final usecase = FolderSourceOpenUseCase(vault: _vaultWith(markdown));

      final request = await usecase.resolve(item: _item(), folderName: null);

      expect(request.source!.vaultName, isNull);
    });

    test('先頭の YAML frontmatter だけを除去する', () async {
      const body = '---\ntitle: x\ntags: [a, b]\n---\n本文A';
      final usecase = FolderSourceOpenUseCase(vault: _vaultWith(body));

      final request = await usecase.resolve(item: _item(), folderName: 'F');

      expect(request.text, '本文A');
    });

    test('先頭以外の --- は frontmatter として除去しない', () async {
      const body = '本文B\n---\nfoo: bar\n---\n本文C';
      final usecase = FolderSourceOpenUseCase(vault: _vaultWith(body));

      final request = await usecase.resolve(item: _item(), folderName: 'F');

      expect(request.text, contains('本文B'));
      expect(request.text, contains('foo: bar'));
      expect(request.text, contains('本文C'));
    });

    test('ドル記号の価格を消さない（Obsidian の \$…\$ 変換を適用しない）', () async {
      const body = 'AAPLは\$180で引け、NVDAは\$120まで下落。';
      final usecase = FolderSourceOpenUseCase(vault: _vaultWith(body));

      final request = await usecase.resolve(item: _item(), folderName: 'F');

      expect(request.text, 'AAPLは\$180で引け、NVDAは\$120まで下落。');
    });

    test('%%…%% を含む本文を勝手に削除しない', () async {
      const body = '前文\n%%コメント%%\n後文';
      final usecase = FolderSourceOpenUseCase(vault: _vaultWith(body));

      final request = await usecase.resolve(item: _item(), folderName: 'F');

      expect(request.text, contains('%%コメント%%'));
      expect(request.text, contains('後文'));
    });

    test('標準 Markdown の既存変換（見出し・太字・リスト）は維持する', () async {
      const body = '# 見出し\n\n**太字**の文\n- 項目';
      final usecase = FolderSourceOpenUseCase(vault: _vaultWith(body));

      final request = await usecase.resolve(item: _item(), folderName: 'F');

      expect(request.text, contains('【見出し】'));
      expect(request.text, contains('太字の文'));
      expect(request.text, contains('・項目'));
    });

    test('読み取り失敗: read_failed', () async {
      final usecase = FolderSourceOpenUseCase(
        vault: _FakeVault((_) async => throw StateError('provider unavailable')),
      );

      await expectLater(
        usecase.resolve(item: _item(), folderName: 'F'),
        throwsA(isA<FolderSourceResolveException>()
            .having((e) => e.reason, 'reason', 'read_failed')),
      );
    });

    test('本文が空（frontmatterのみ等）: empty_body', () async {
      const frontmatterOnly = '---\ntitle: x\n---\n';
      final usecase = FolderSourceOpenUseCase(vault: _vaultWith(frontmatterOnly));

      await expectLater(
        usecase.resolve(item: _item(), folderName: 'F'),
        throwsA(isA<FolderSourceResolveException>()
            .having((e) => e.reason, 'reason', 'empty_body')),
      );
    });

    test('タイトルは Content の上限（100文字）に切り詰める', () async {
      final longName = '${'あ' * 150}.md';
      final usecase = FolderSourceOpenUseCase(vault: _vaultWith(markdown));

      final request = await usecase.resolve(item: _item(name: longName), folderName: 'B');

      expect(request.title!.length, 100);
    });
  });

  group('open（resolve → guard → openTransient）', () {
    test('成功時のみ openTransient が1回呼ばれ、結果は opened', () async {
      final usecase = FolderSourceOpenUseCase(vault: _vaultWith(markdown));
      final requests = <PlaybackRequest>[];

      final result = await usecase.open(
        item: _item(),
        folderName: 'Briefings',
        gate: FolderSourceOpenGate(),
        isMounted: () => true,
        openTransient: (r) async => requests.add(r),
      );

      expect(result, FolderSourceOpenResult.opened);
      expect(requests, hasLength(1));
      expect(requests.single.text, contains('本文の一文です'));
    });

    test('読み取り失敗（最新の意図）: failed、openTransient は呼ばれない', () async {
      final usecase = FolderSourceOpenUseCase(
        vault: _FakeVault((_) async => throw StateError('provider unavailable')),
      );
      var calls = 0;

      final result = await usecase.open(
        item: _item(),
        folderName: 'Briefings',
        gate: FolderSourceOpenGate(),
        isMounted: () => true,
        openTransient: (_) async => calls++,
      );

      expect(result, FolderSourceOpenResult.failed);
      expect(calls, 0);
    });

    test('latest-intent race: A開始 → B開始 → B resolve → A resolve では B だけ open', () async {
      final a = _item(name: 'a.md', uri: 'uri-a');
      final b = _item(name: 'b.md', uri: 'uri-b');
      final completerA = Completer<String>();
      final completerB = Completer<String>();
      final usecase = FolderSourceOpenUseCase(
        vault: _FakeVault((uri) => uri == 'uri-a' ? completerA.future : completerB.future),
      );
      final gate = FolderSourceOpenGate();
      final opened = <String>[];

      Future<FolderSourceOpenResult> run(FolderChild item) => usecase.open(
            item: item,
            folderName: 'F',
            gate: gate,
            isMounted: () => true,
            openTransient: (r) async => opened.add(r.source!.sourceFilename!),
          );

      final futureA = run(a);
      final futureB = run(b);

      completerB.complete('本文B');
      expect(await futureB, FolderSourceOpenResult.opened);
      expect(opened, ['b.md']);

      completerA.complete('本文A');
      expect(await futureA, FolderSourceOpenResult.stale);
      expect(opened, ['b.md']);
    });

    test('latest-intent race: 古い意図の読み取り失敗は failed ではなく stale', () async {
      final a = _item(name: 'a.md', uri: 'uri-a');
      final b = _item(name: 'b.md', uri: 'uri-b');
      final completerA = Completer<String>();
      final usecase = FolderSourceOpenUseCase(
        vault: _FakeVault((uri) => uri == 'uri-a'
            ? completerA.future
            : Future.value('本文B')),
      );
      final gate = FolderSourceOpenGate();
      final opened = <String>[];

      Future<FolderSourceOpenResult> run(FolderChild item) => usecase.open(
            item: item,
            folderName: 'F',
            gate: gate,
            isMounted: () => true,
            openTransient: (r) async => opened.add(r.source!.sourceFilename!),
          );

      final futureA = run(a);
      expect(await run(b), FolderSourceOpenResult.opened);

      completerA.completeError(StateError('provider unavailable'));
      expect(await futureA, FolderSourceOpenResult.stale);
      expect(opened, ['b.md']);
    });

    test('画面 dispose 後に resolve が完了しても openTransient は 0 回', () async {
      final completer = Completer<String>();
      final usecase = FolderSourceOpenUseCase(vault: _FakeVault((_) => completer.future));
      var mounted = true;
      var calls = 0;

      final future = usecase.open(
        item: _item(),
        folderName: 'F',
        gate: FolderSourceOpenGate(),
        isMounted: () => mounted,
        openTransient: (_) async => calls++,
      );

      mounted = false;
      completer.complete(markdown);

      expect(await future, FolderSourceOpenResult.stale);
      expect(calls, 0);
    });

    test('resolve 中のフォルダ変更・再読み込み（invalidate）後は openTransient しない', () async {
      final completer = Completer<String>();
      final usecase = FolderSourceOpenUseCase(vault: _FakeVault((_) => completer.future));
      final gate = FolderSourceOpenGate();
      var calls = 0;

      final future = usecase.open(
        item: _item(),
        folderName: 'F',
        gate: gate,
        isMounted: () => true,
        openTransient: (_) async => calls++,
      );

      gate.invalidate();
      completer.complete(markdown);

      expect(await future, FolderSourceOpenResult.stale);
      expect(calls, 0);
    });
  });
}
