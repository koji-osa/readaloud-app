import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/util/obsidian_launcher.dart';

void main() {
  group('ObsidianLauncher.buildOpenUri', () {
    test('encodes an ASCII vault name and relative path', () {
      final uri = ObsidianLauncher.buildOpenUri(
        vaultName: 'MyVault',
        relativePath: 'note.md',
      );

      expect(
        uri.toString(),
        'obsidian://open?vault=MyVault&file=note.md',
      );
    });

    test('encodes Japanese characters in vault name and relative path', () {
      final uri = ObsidianLauncher.buildOpenUri(
        vaultName: '日本語Vault',
        relativePath: 'メモ帳.md',
      );

      expect(
        uri.toString(),
        'obsidian://open?vault=${Uri.encodeComponent('日本語Vault')}'
        '&file=${Uri.encodeComponent('メモ帳.md')}',
      );
      expect(uri.toString(), contains('%E6%97%A5%E6%9C%AC%E8%AA%9E'));
    });

    test('encodes spaces in vault name and relative path as %20', () {
      final uri = ObsidianLauncher.buildOpenUri(
        vaultName: 'My Vault',
        relativePath: 'folder name/my note.md',
      );

      expect(uri.toString(), contains('vault=My%20Vault'));
      expect(uri.toString(), contains('%20note.md'));
    });

    test('encodes slashes in the relative path as %2F so nested folders '
        'are preserved as a single query value', () {
      final uri = ObsidianLauncher.buildOpenUri(
        vaultName: 'Vault',
        relativePath: 'Projects/AI/note.md',
      );

      expect(
        uri.toString(),
        'obsidian://open?vault=Vault&file=Projects%2FAI%2Fnote.md',
      );
    });

    test('encodes vault name and relative path independently', () {
      // vaultNameとrelativePathにそれぞれ別の記号(&, =, #)を含めても、
      // 個別にエンコードされているためクエリ構造が壊れないことを確認する。
      final uri = ObsidianLauncher.buildOpenUri(
        vaultName: 'Vault & Co = Notes',
        relativePath: 'a#b&c=d.md',
      );

      expect(
        uri.queryParameters['vault'],
        'Vault & Co = Notes',
      );
      expect(
        uri.queryParameters['file'],
        'a#b&c=d.md',
      );
    });
  });

  group('ObsidianLauncher.openNote', () {
    test('returns notInstalled when canLaunchUrl returns false without '
        'attempting to launch', () async {
      var launchCalled = false;
      final launcher = ObsidianLauncher(
        canLaunch: (_) async => false,
        launch: (_) async {
          launchCalled = true;
          return true;
        },
      );

      final result = await launcher.openNote(
        vaultName: 'Vault',
        relativePath: 'note.md',
      );

      expect(result, ObsidianLaunchResult.notInstalled);
      expect(launchCalled, isFalse);
    });

    test('returns success when canLaunchUrl and launchUrl both succeed',
        () async {
      Uri? launchedUri;
      final launcher = ObsidianLauncher(
        canLaunch: (_) async => true,
        launch: (uri) async {
          launchedUri = uri;
          return true;
        },
      );

      final result = await launcher.openNote(
        vaultName: 'Vault',
        relativePath: 'note.md',
      );

      expect(result, ObsidianLaunchResult.success);
      expect(
        launchedUri.toString(),
        'obsidian://open?vault=Vault&file=note.md',
      );
    });

    test('returns launchFailed when canLaunchUrl succeeds but launchUrl '
        'returns false', () async {
      final launcher = ObsidianLauncher(
        canLaunch: (_) async => true,
        launch: (_) async => false,
      );

      final result = await launcher.openNote(
        vaultName: 'Vault',
        relativePath: 'note.md',
      );

      expect(result, ObsidianLaunchResult.launchFailed);
    });
  });

  group('ObsidianLauncher.openPlayStore', () {
    test('launches the Obsidian Play Store URL', () async {
      Uri? launchedUri;
      final launcher = ObsidianLauncher(
        launch: (uri) async {
          launchedUri = uri;
          return true;
        },
      );

      final result = await launcher.openPlayStore();

      expect(result, isTrue);
      expect(launchedUri.toString(), obsidianPlayStoreUrl);
    });
  });
}
