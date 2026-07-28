import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/ui/player/player_screen.dart';

Content _buildContent({
  String? externalType,
  String? vaultName,
  String? relativePath,
}) {
  return Content(
    title: 'title',
    body: 'body',
    sourceType: 'text',
    externalType: externalType,
    vaultName: vaultName,
    relativePath: relativePath,
  );
}

void main() {
  group('PlayerScreen.showObsidianButtonFor', () {
    test(
        'returns true when externalType is obsidian and vaultName/relativePath '
        'are both non-empty strings', () {
      final content = _buildContent(
        externalType: 'obsidian',
        vaultName: 'MyVault',
        relativePath: 'note.md',
      );

      expect(PlayerScreen.showObsidianButtonFor(content), isTrue);
    });

    test('returns false when externalType is not obsidian', () {
      final content = _buildContent(
        externalType: 'other',
        vaultName: 'MyVault',
        relativePath: 'note.md',
      );

      expect(PlayerScreen.showObsidianButtonFor(content), isFalse);
    });

    test('returns false when externalType is null', () {
      final content = _buildContent(
        externalType: null,
        vaultName: 'MyVault',
        relativePath: 'note.md',
      );

      expect(PlayerScreen.showObsidianButtonFor(content), isFalse);
    });

    test('returns false when externalType is obsidian but vaultName is null',
        () {
      final content = _buildContent(
        externalType: 'obsidian',
        vaultName: null,
        relativePath: 'note.md',
      );

      expect(PlayerScreen.showObsidianButtonFor(content), isFalse);
    });

    test(
        'returns false when externalType is obsidian but vaultName is an '
        'empty string', () {
      final content = _buildContent(
        externalType: 'obsidian',
        vaultName: '',
        relativePath: 'note.md',
      );

      expect(PlayerScreen.showObsidianButtonFor(content), isFalse);
    });

    test(
        'returns false when externalType is obsidian but relativePath is null',
        () {
      final content = _buildContent(
        externalType: 'obsidian',
        vaultName: 'MyVault',
        relativePath: null,
      );

      expect(PlayerScreen.showObsidianButtonFor(content), isFalse);
    });

    test(
        'returns false when externalType is obsidian but relativePath is an '
        'empty string', () {
      final content = _buildContent(
        externalType: 'obsidian',
        vaultName: 'MyVault',
        relativePath: '',
      );

      expect(PlayerScreen.showObsidianButtonFor(content), isFalse);
    });
  });
}
