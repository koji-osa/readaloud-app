// Playback Session Lifecycle Hardening — Detailed Design v1.2 FINAL §15.4.4.
//
// AudioService.init() は cacheManager ??= DefaultCacheManager() を実行し、
// DefaultCacheManager は path_provider に到達するため、plain `flutter test`
// 下では使えない。ReadAloud の MediaItem は artUri を持たない
// (device_tts_service.dart の speak() 参照) ため、artwork読み込み経路
// (_loadArtwork / getFileFromMemory 等) は到達不能である。このfakeは型を
// 満たすだけでよく、想定外の呼び出しは（黙って妥当な値を返すのではなく）
// 明示的に throw する — もしartwork読み込みが将来到達可能になった場合、
// テストがそれを黙らせず報告するようにするため。
//
// テスト専用。production コードから import してはならない。

import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:file/file.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class FakeCacheManager implements BaseCacheManager {
  Never _unexpected(String method) => throw StateError(
      'FakeCacheManager.$method was called unexpectedly. ReadAloud\'s '
      'MediaItem never sets artUri, so artwork loading should be '
      'unreachable in this suite — if this fires, artwork loading has '
      'become reachable and needs a real seam.');

  @override
  Future<File> getSingleFile(String url,
          {String? key, Map<String, String>? headers}) =>
      _unexpected('getSingleFile');

  @override
  @Deprecated('Prefer to use the new getFileStream method')
  Stream<FileInfo> getFile(String url,
          {String? key, Map<String, String>? headers}) =>
      _unexpected('getFile');

  @override
  Stream<FileResponse> getFileStream(String url,
          {String? key, Map<String, String>? headers, bool? withProgress}) =>
      _unexpected('getFileStream');

  @override
  Future<FileInfo> downloadFile(String url,
          {String? key, Map<String, String>? authHeaders, bool force = false}) =>
      _unexpected('downloadFile');

  @override
  Future<FileInfo?> getFileFromCache(String key,
          {bool ignoreMemCache = false}) =>
      _unexpected('getFileFromCache');

  @override
  Future<FileInfo?> getFileFromMemory(String key) =>
      _unexpected('getFileFromMemory');

  @override
  Future<File> putFile(
    String url,
    Uint8List fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) =>
      _unexpected('putFile');

  @override
  Future<File> putFileStream(
    String url,
    Stream<List<int>> source, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) =>
      _unexpected('putFileStream');

  @override
  Future<void> removeFile(String key) => _unexpected('removeFile');

  @override
  Future<void> emptyCache() => _unexpected('emptyCache');

  @override
  Future<void> dispose() => _unexpected('dispose');
}
