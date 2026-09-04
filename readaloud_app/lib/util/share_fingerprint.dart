import 'dart:convert';

import 'package:crypto/crypto.dart';

/// No.94 Observability専用のprivacy-safe fingerprintヘルパー。
///
/// 生の共有本文そのものは一切保持・返却せず、UTF-8バイト列に対する
/// SHA-256ダイジェスト(hex文字列)とcharCountのみを提供する。
/// native Intent/plugin/Dart classify/main handler/Quick Listen sessionの
/// 各境界で同じ計算式(SHA-256 of UTF-8 bytes、生値とtrim後の値それぞれ)を
/// 使うことで、ログ上でハッシュを突き合わせるだけでどの境界でpayloadが
/// 変化したかを判定できるようにする。
///
/// 【比較ルール（重要）】DartとKotlin(native)の`trim()`が完全に同一の
/// Unicode正規化仕様であることは今回の実装では保証していない
/// （境界文字がUnicode空白カテゴリの端に近い場合など、理論上ズレうる）。
/// そのため境界間の比較には以下の優先順位を使うこと:
///   1. native raw hash ↔ Dart raw hash
///      = native/plugin境界のprimary identity（trimの実装差に依存しない）。
///   2. Dart trimmed hash ↔ Quick Listen raw/session hash
///      = post-trim境界（Quick Listenへ渡す直前にDart側で`trim()`している
///        ため、以降は必ずDart自身のtrim()同士の比較になる）。
///   3. native trimmed hashは上記1のraw比較を補強する補助情報として扱う
///      （nativeとDartのtrim()差異を切り分けたい場合の参考値）。
/// SHA-256(UTF-8 original string)そのものは、trim実装に依存しないcanonical
/// comparisonとして常に維持する。
class ShareFingerprint {
  const ShareFingerprint._();

  /// [value]のUTF-8バイト列に対するSHA-256のhex文字列。
  static String sha256Hex(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// 生値とtrim後の値それぞれのcharCount/SHA-256をまとめて計算する。
  static ShareTextMetrics metricsOf(String value) {
    final trimmed = value.trim();
    return ShareTextMetrics(
      charCount: value.length,
      trimmedCharCount: trimmed.length,
      payloadHash: sha256Hex(value),
      trimmedPayloadHash: sha256Hex(trimmed),
    );
  }
}

/// [ShareFingerprint.metricsOf]の結果。
class ShareTextMetrics {
  final int charCount;
  final int trimmedCharCount;
  final String payloadHash;
  final String trimmedPayloadHash;

  const ShareTextMetrics({
    required this.charCount,
    required this.trimmedCharCount,
    required this.payloadHash,
    required this.trimmedPayloadHash,
  });

  /// DebugLogger.logEvent()へそのまま渡せるフィールドmapを返す。
  /// charCount/trimmedCharCount/payloadHash/trimmedPayloadHashのみで、
  /// 本文そのものは一切含まない。
  Map<String, Object?> toLogFields() => {
        'charCount': charCount,
        'trimmedCharCount': trimmedCharCount,
        'payloadHash': payloadHash,
        'trimmedPayloadHash': trimmedPayloadHash,
      };
}
