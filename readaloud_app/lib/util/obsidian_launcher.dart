import 'package:url_launcher/url_launcher.dart' as url_launcher;

/// Google PlayストアのObsidianアプリページ。
const String obsidianPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=md.obsidian';

/// [ObsidianLauncher.openNote]の結果。
enum ObsidianLaunchResult {
  /// Obsidianアプリの起動に成功した。
  success,

  /// Obsidianアプリがインストールされていない、またはobsidian://スキームを
  /// 処理できるアプリが存在しない。
  notInstalled,

  /// 起動可否の事前確認は通ったが、実際の起動に失敗した。
  launchFailed,
}

/// URLが起動可能か事前確認する関数の型。テスト時に差し替える。
typedef UrlLauncherCanLaunch = Future<bool> Function(Uri url);

/// URLを実際に起動する関数の型。テスト時に差し替える。
typedef UrlLauncherLaunch = Future<bool> Function(Uri url);

/// ObsidianアプリをURIスキーム(obsidian://)で起動するサービス。
///
/// url_launcherパッケージへの依存はこのファイル内に閉じ込め、
/// canLaunchUrl/launchUrlはコンストラクタ注入した関数経由で呼び出すことで、
/// プラットフォームチャンネルに依存せずテストできるようにする。
class ObsidianLauncher {
  ObsidianLauncher({
    UrlLauncherCanLaunch? canLaunch,
    UrlLauncherLaunch? launch,
  })  : _canLaunch = canLaunch ?? url_launcher.canLaunchUrl,
        _launch = launch ?? _defaultLaunch;

  final UrlLauncherCanLaunch _canLaunch;
  final UrlLauncherLaunch _launch;

  /// [vaultName]と[relativePath]から、Obsidianアプリで対象ノートを開くための
  /// URIを組み立てる。vaultNameとrelativePathはそれぞれ独立に
  /// [Uri.encodeComponent]でエンコードする。
  ///
  /// 起動処理から分離しているため、URI生成のみを単体テストできる。
  static Uri buildOpenUri({
    required String vaultName,
    required String relativePath,
  }) {
    final encodedVault = Uri.encodeComponent(vaultName);
    final encodedFile = Uri.encodeComponent(relativePath);
    return Uri.parse(
      'obsidian://open?vault=$encodedVault&file=$encodedFile',
    );
  }

  /// [vaultName]と[relativePath]が指すノートをObsidianアプリで開く。
  Future<ObsidianLaunchResult> openNote({
    required String vaultName,
    required String relativePath,
  }) async {
    final uri = buildOpenUri(
      vaultName: vaultName,
      relativePath: relativePath,
    );

    bool canLaunch;
    try {
      canLaunch = await _canLaunch(uri);
    } catch (_) {
      return ObsidianLaunchResult.notInstalled;
    }
    if (!canLaunch) {
      return ObsidianLaunchResult.notInstalled;
    }

    try {
      final launched = await _launch(uri);
      return launched
          ? ObsidianLaunchResult.success
          : ObsidianLaunchResult.launchFailed;
    } catch (_) {
      return ObsidianLaunchResult.launchFailed;
    }
  }

  /// Obsidianアプリが見つからない場合に、Google Playストアの
  /// Obsidianアプリページを開く。
  Future<bool> openPlayStore() async {
    try {
      return await _launch(Uri.parse(obsidianPlayStoreUrl));
    } catch (_) {
      return false;
    }
  }
}

Future<bool> _defaultLaunch(Uri url) {
  return url_launcher.launchUrl(
    url,
    mode: url_launcher.LaunchMode.externalApplication,
  );
}
