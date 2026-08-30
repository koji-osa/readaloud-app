import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';

void main() {
  group('SaveContentUseCase', () {
    late _FakeContentRepository repository;
    late SaveContentUseCase useCase;

    setUp(() {
      repository = _FakeContentRepository();
      useCase = SaveContentUseCase(repository);
    });

    test('externalType・vaultName・relativePathが指定されるとContentに設定され、'
        'そのまま保存される', () async {
      final content = await useCase.execute(
        body: '本文',
        sourceType: 'obsidian',
        externalType: 'obsidian',
        vaultName: 'MyVault',
        relativePath: 'Projects/note.md',
      );

      expect(content.externalType, 'obsidian');
      expect(content.vaultName, 'MyVault');
      expect(content.relativePath, 'Projects/note.md');
      expect(repository.saved.single.externalType, 'obsidian');
      expect(repository.saved.single.vaultName, 'MyVault');
      expect(repository.saved.single.relativePath, 'Projects/note.md');
    });

    test('externalType・vaultName・relativePathを指定しない場合はいずれもnullになる', () async {
      final content = await useCase.execute(
        body: '本文',
        sourceType: 'text',
      );

      expect(content.externalType, isNull);
      expect(content.vaultName, isNull);
      expect(content.relativePath, isNull);
    });

    // Quick Listen導入により、共有経由のテキストはsourceType: 'share'として
    // 保存されるようになった(従来のtext tab経由の手動保存は'text'のまま)。
    // タイトル自動生成ロジックが両者で同じ挙動(本文先頭30文字)であることを
    // 固定し、将来'share'にだけ異なる生成ルールが誤って追加されないようにする。
    test('sourceType:shareのタイトル自動生成はsourceType:textと同じ(本文先頭30文字)', () async {
      const body = 'これはQuick Listenで共有されたテキストの本文サンプルです。三十文字を超える長さにしています。';

      final shareContent =
          await useCase.execute(body: body, sourceType: 'share');
      final textContent =
          await useCase.execute(body: body, sourceType: 'text');

      expect(shareContent.title, textContent.title);
    });
  });
}

class _FakeContentRepository implements ContentRepository {
  final List<Content> saved = [];

  @override
  Future<void> save(Content content) async {
    saved.add(content);
  }

  @override
  Future<List<Content>> getAll() async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<List<Content>> getByStatus(String status) async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<Content?> getById(String id) async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<void> update(Content content) async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<void> delete(String id) async =>
      throw UnimplementedError('not used in this test');
}
