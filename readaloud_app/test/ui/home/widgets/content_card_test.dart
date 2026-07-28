import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/ui/home/widgets/content_card.dart';
import 'package:readaloud_app/util/obsidian_launcher.dart';
import 'package:readaloud_app/util/obsidian_open_handler.dart';

Content _buildContent({
  String? externalType,
  String? vaultName,
  String? relativePath,
}) {
  return Content(
    title: 'title',
    body: 'body',
    sourceType: externalType == 'obsidian' ? 'obsidian' : 'text',
    externalType: externalType,
    vaultName: vaultName,
    relativePath: relativePath,
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: child),
  );
}

void main() {
  group('ContentCard obsidian button placement', () {
    testWidgets(
        'shows the obsidian icon button when the content is linked to '
        'obsidian and the card is not in select mode', (tester) async {
      final content = _buildContent(
        externalType: 'obsidian',
        vaultName: 'MyVault',
        relativePath: 'note.md',
      );

      await tester.pumpWidget(_wrap(ContentCard(
        content: content,
        onTap: () {},
        onDelete: () {},
        onEditTitle: (_) {},
      )));

      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    });

    testWidgets(
        'hides the obsidian icon button when the content is not linked to '
        'obsidian', (tester) async {
      final content = _buildContent(externalType: null);

      await tester.pumpWidget(_wrap(ContentCard(
        content: content,
        onTap: () {},
        onDelete: () {},
        onEditTitle: (_) {},
      )));

      expect(find.byIcon(Icons.open_in_new), findsNothing);
    });

    testWidgets('hides the obsidian icon button while in select mode',
        (tester) async {
      final content = _buildContent(
        externalType: 'obsidian',
        vaultName: 'MyVault',
        relativePath: 'note.md',
      );

      await tester.pumpWidget(_wrap(ContentCard(
        content: content,
        onTap: () {},
        onDelete: () {},
        onEditTitle: (_) {},
        isSelectMode: true,
      )));

      expect(find.byIcon(Icons.open_in_new), findsNothing);
    });
  });

  group('ContentCard obsidian button tap handling', () {
    testWidgets(
        'tapping the obsidian icon opens the note via ObsidianOpenHandler '
        'without triggering the card onTap callback', (tester) async {
      final content = _buildContent(
        externalType: 'obsidian',
        vaultName: 'MyVault',
        relativePath: 'note.md',
      );
      var cardTapped = false;
      var launchCalled = false;
      final handler = ObsidianOpenHandler(
        launcher: ObsidianLauncher(
          canLaunch: (_) async => true,
          launch: (_) async {
            launchCalled = true;
            return true;
          },
        ),
      );

      await tester.pumpWidget(_wrap(ContentCard(
        content: content,
        onTap: () => cardTapped = true,
        onDelete: () {},
        onEditTitle: (_) {},
        obsidianOpenHandler: handler,
      )));

      await tester.tap(find.byIcon(Icons.open_in_new));
      await tester.pumpAndSettle();

      expect(launchCalled, isTrue);
      expect(cardTapped, isFalse);
    });

    testWidgets(
        'tapping the obsidian icon shows the not-installed dialog when '
        'Obsidian cannot be launched', (tester) async {
      final content = _buildContent(
        externalType: 'obsidian',
        vaultName: 'MyVault',
        relativePath: 'note.md',
      );
      final handler = ObsidianOpenHandler(
        launcher: ObsidianLauncher(
          canLaunch: (_) async => false,
          launch: (_) async => true,
        ),
      );

      await tester.pumpWidget(_wrap(ContentCard(
        content: content,
        onTap: () {},
        onDelete: () {},
        onEditTitle: (_) {},
        obsidianOpenHandler: handler,
      )));

      await tester.tap(find.byIcon(Icons.open_in_new));
      await tester.pumpAndSettle();

      expect(find.text('Obsidianアプリが見つかりません'), findsOneWidget);
    });
  });
}
