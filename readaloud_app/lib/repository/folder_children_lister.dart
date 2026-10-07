import 'package:flutter/services.dart';

import '../model/folder_child.dart';

/// Folder Source 直下の children metadata を1回で列挙する（再帰しない・本文は読まない）。
abstract class FolderChildrenLister {
  Future<List<FolderChild>> listDirectChildren(String treeUri);
}

/// 権限が無い／失効した（SAF grant 喪失）。
class FolderPermissionLostException implements Exception {
  const FolderPermissionLostException();
}

/// フォルダに到達できない（provider 不達・ツリー不正等）。
class FolderUnavailableException implements Exception {
  const FolderUnavailableException();
}

/// Android `DocumentsContract` による native 列挙（MainActivity の
/// `com.example.readaloud_app/sources_folder` チャネル）。
class NativeFolderChildrenLister implements FolderChildrenLister {
  static const MethodChannel _channel =
      MethodChannel('com.example.readaloud_app/sources_folder');

  @override
  Future<List<FolderChild>> listDirectChildren(String treeUri) async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'listDirectChildren',
        {'treeUri': treeUri},
      );
      return (raw ?? const <dynamic>[])
          .map((e) => _fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
    } on PlatformException catch (e) {
      if (e.code == 'permission_denied') {
        throw const FolderPermissionLostException();
      }
      throw const FolderUnavailableException();
    }
  }

  FolderChild _fromMap(Map<String, dynamic> map) => FolderChild(
        uri: map['uri'] as String,
        name: map['name'] as String,
        mimeType: map['mimeType'] as String,
        lastModified: (map['lastModified'] as num).toInt(),
        isDirectory: map['isDirectory'] as bool,
      );
}
