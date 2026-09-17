import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/util/auto_title.dart';

// PD-3: Transient 見出しと SaveContentUseCase の保存時自動タイトルが同一ロジック。
void main() {
  test('share/text/obsidian は本文先頭30文字（trim・改行→空白）', () {
    const body = '  一行目\n二行目の本文がここに続いていて三十文字を超える長さになっています  ';
    final expected = body.trim().replaceAll('\n', ' ').substring(0, 30);
    expect(autoTitleFromBody(body, 'share'), expected);
    expect(autoTitleFromBody(body, 'text'), expected);
    expect(autoTitleFromBody('短い', 'obsidian'), '短い');
  });

  test('url / file の既存分岐を維持する', () {
    expect(autoTitleFromBody('body', 'url', sourceUrl: 'https://e.x'),
        'https://e.x');
    expect(autoTitleFromBody('body', 'file', sourceFilename: 'note.v1.md'),
        'note.v1');
    expect(autoTitleFromBody('body', 'file'), 'body');
  });

  test('SaveContentUseCaseのtitle未指定時の自動タイトルはautoTitleFromBodyと一致する', () async {
    final repo = _Repo();
    const body = '共有された本文。\nこれは保存時の自動タイトル生成を確認するためのテキストです。';
    final content =
        await SaveContentUseCase(repo).execute(body: body, sourceType: 'share');
    expect(content.title, autoTitleFromBody(body, 'share'));
  });
}

class _Repo implements ContentRepository {
  @override
  Future<void> save(Content content) async {}

  @override
  Future<List<Content>> getAll() async => [];

  @override
  Future<List<Content>> getByStatus(String status) async => [];

  @override
  Future<Content?> getById(String id) async => null;

  @override
  Future<void> update(Content content) async {}

  @override
  Future<void> delete(String id) async {}
}
