/// REQ-008: URLや長い英数字・記号を省略するユーティリティ
class TextCleaner {
  /// URLを (URLの記載省略) に置換
  static final _urlPattern = RegExp(
    r'https?://[^\s\u3000-\u9fff\uff00-\uffef\u3040-\u309f\u30a0-\u30ff]+',
  );

  /// 英数字・記号のみで15文字以上の連続を検出
  static final _longAlphanumericPattern = RegExp(
    r'[a-zA-Z0-9!-/:-@\[-`{-~]{15,}',
  );

  /// 英字を含むかチェック
  static final _containsAlpha = RegExp(r'[a-zA-Z]');

  /// URLや長い英数字・記号を省略する
  static String clean(String text) {
    // 1. URLを先に置換（英数字パターンに引っかからないよう先に処理）
    String result = text.replaceAll(_urlPattern, '(URLの記載省略)');
    // 2. 英数字・記号15文字以上かつ英字を含む場合のみ置換
    result = result.replaceAllMapped(_longAlphanumericPattern, (match) {
      final s = match.group(0)!;
      if (s.contains(_containsAlpha)) {
        return '(英数字記号省略)';
      }
      return s; // 英字なし（純粋な数字・記号）はそのまま
    });
    return result;
  }
}
