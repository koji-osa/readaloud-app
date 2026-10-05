import '../db/dao/content_dao.dart';

/// Sources 専用の read-only 保存済み判定（本文は読まない）。
/// [ContentRepository] を広げず、Sources 側だけが依存する。
abstract class SourcesLibraryLookup {
  /// Library に保存済みの Folder Source（`source_type='folder'`）の source_url 集合。
  Future<Set<String>> savedFolderSourceUris();
}

class ContentDaoSourcesLibraryLookup implements SourcesLibraryLookup {
  ContentDaoSourcesLibraryLookup({ContentDao? dao}) : _dao = dao ?? ContentDao();

  final ContentDao _dao;

  @override
  Future<Set<String>> savedFolderSourceUris() => _dao.sourceUrlsOfType('folder');
}
