import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/util/share_fingerprint.dart';

void main() {
  group('ShareFingerprint.sha256Hex', () {
    test('同一文字列は同一hashを返す', () {
      final a = ShareFingerprint.sha256Hex('same value');
      final b = ShareFingerprint.sha256Hex('same value');
      expect(a, b);
    });

    test('異なる文字列は異なるhashを返す', () {
      final a = ShareFingerprint.sha256Hex('value A');
      final b = ShareFingerprint.sha256Hex('value B');
      expect(a, isNot(b));
    });

    test('64桁の小文字hex文字列を返す', () {
      final hash = ShareFingerprint.sha256Hex('any value');
      expect(hash, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('package:cryptoのSHA-256(UTF-8)実装と一致する（実装delegateの正しさを検証）', () {
      const value = '共有テキストfingerprint検証用';
      final expected = crypto.sha256.convert(utf8.encode(value)).toString();
      expect(ShareFingerprint.sha256Hex(value), expected);
    });

    test('空文字でも例外にならずhashを計算できる', () {
      expect(() => ShareFingerprint.sha256Hex(''), returnsNormally);
      expect(ShareFingerprint.sha256Hex(''), ShareFingerprint.sha256Hex(''));
    });

    test('日本語テキストのhashも安定して同一値になる', () {
      const text = '共有されたテキストの日本語本文';
      expect(ShareFingerprint.sha256Hex(text), ShareFingerprint.sha256Hex(text));
    });

    test('絵文字・サロゲートペアを含む文字列でも例外にならずhashを計算できる', () {
      const text = '共有テキスト😀🎉👨‍👩‍👧‍👦';
      expect(() => ShareFingerprint.sha256Hex(text), returnsNormally);
      expect(ShareFingerprint.sha256Hex(text), ShareFingerprint.sha256Hex(text));
    });

    test('改行を含む文字列とtrim後の文字列は異なるhashになりうる', () {
      const withNewline = '\n共有テキスト\n';
      final rawHash = ShareFingerprint.sha256Hex(withNewline);
      final trimmedHash = ShareFingerprint.sha256Hex(withNewline.trim());
      expect(rawHash, isNot(trimmedHash));
    });
  });

  group('ShareFingerprint.metricsOf', () {
    test('charCount/trimmedCharCountはString.lengthベースで一致する', () {
      const value = '  共有テキスト  ';
      final metrics = ShareFingerprint.metricsOf(value);
      expect(metrics.charCount, value.length);
      expect(metrics.trimmedCharCount, value.trim().length);
    });

    test('rawとtrimmedのhashが異なるフィールドとして両方得られる', () {
      const value = ' abc ';
      final metrics = ShareFingerprint.metricsOf(value);
      expect(metrics.payloadHash, ShareFingerprint.sha256Hex(value));
      expect(metrics.trimmedPayloadHash, ShareFingerprint.sha256Hex(value.trim()));
      expect(metrics.payloadHash, isNot(metrics.trimmedPayloadHash));
    });

    test('前後空白がない文字列ではrawとtrimmedのhashが一致する', () {
      const value = 'abc';
      final metrics = ShareFingerprint.metricsOf(value);
      expect(metrics.payloadHash, metrics.trimmedPayloadHash);
    });

    test('toLogFields()は本文を含まずcharCount/hash系のみを返す（Privacy検証）', () {
      const secret = 'SECRET_TEST_PAYLOAD_12345';
      final fields = ShareFingerprint.metricsOf(secret).toLogFields();

      expect(
        fields.keys,
        containsAll(
            ['charCount', 'trimmedCharCount', 'payloadHash', 'trimmedPayloadHash']),
      );
      for (final value in fields.values) {
        expect(value.toString(), isNot(contains(secret)));
      }
    });
  });
}
