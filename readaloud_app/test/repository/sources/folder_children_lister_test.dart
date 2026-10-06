import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/repository/folder_children_lister.dart';

/// MainActivity の `com.example.readaloud_app/sources_folder` チャネルの応答を模擬する。
/// null cursor は native 側で `unavailable` に写像されるため、ここでは error code の契約を検証する。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.example.readaloud_app/sources_folder');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('正常 0 件は空リスト（unavailable ではない）', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => <dynamic>[]);

    final children = await NativeFolderChildrenLister().listDirectChildren('content://t');

    expect(children, isEmpty);
  });

  test('unavailable（null cursor を含む provider 不達）は FolderUnavailableException', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );

    await expectLater(
      NativeFolderChildrenLister().listDirectChildren('content://t'),
      throwsA(isA<FolderUnavailableException>()),
    );
  });

  test('permission_denied は FolderPermissionLostException', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'permission_denied'),
    );

    await expectLater(
      NativeFolderChildrenLister().listDirectChildren('content://t'),
      throwsA(isA<FolderPermissionLostException>()),
    );
  });
}
