import 'package:flutter/material.dart';

import '../model/content.dart';
import 'obsidian_launcher.dart';

/// 「Obsidianで開く」ボタンがタップされた際の共通処理。
///
/// PlayerScreen・ホーム画面のコンテンツ一覧など、複数の画面から
/// 同じ挙動（openNote呼び出し・未インストール時ダイアログ・失敗時スナックバー）
/// を利用するため、ここに切り出している。
class ObsidianOpenHandler {
  ObsidianOpenHandler({ObsidianLauncher? launcher})
      : _launcher = launcher ?? ObsidianLauncher();

  final ObsidianLauncher _launcher;

  /// [content]のvaultName・relativePathを使ってObsidianアプリでノートを開く。
  /// 起動結果に応じて、未インストール時のダイアログや失敗時のスナックバーを表示する。
  Future<void> open(BuildContext context, Content content) async {
    final vaultName = content.vaultName;
    final relativePath = content.relativePath;
    if (vaultName == null || relativePath == null) return;

    final result = await _launcher.openNote(
      vaultName: vaultName,
      relativePath: relativePath,
    );

    if (!context.mounted) return;

    switch (result) {
      case ObsidianLaunchResult.success:
        break;
      case ObsidianLaunchResult.notInstalled:
        await _showNotInstalledDialog(context);
        break;
      case ObsidianLaunchResult.launchFailed:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Obsidianを開けませんでした'),
            backgroundColor: Colors.redAccent,
          ),
        );
        break;
    }
  }

  Future<void> _showNotInstalledDialog(BuildContext context) async {
    final shouldOpenStore = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A3E),
        title: const Text(
          'Obsidianアプリが見つかりません',
          style: TextStyle(color: Color(0xFFF0F0F8), fontSize: 15),
        ),
        content: const Text(
          'Obsidianアプリがインストールされていないため開けませんでした。ストアからインストールしますか？',
          style: TextStyle(color: Color(0xFF8888AA), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル',
                style: TextStyle(color: Color(0xFF8888AA))),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('ストアを開く',
                style: TextStyle(color: Color(0xFF9B6FE0))),
          ),
        ],
      ),
    );

    if (shouldOpenStore == true) {
      await _launcher.openPlayStore();
    }
  }
}
