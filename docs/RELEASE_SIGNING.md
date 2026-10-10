# Release 署名の継続性

Release APK は **v1.2.23 以前と同じ signer** で署名する(上書き更新でデータを保持するため)。

- 期待 signer 証明書 SHA-256: `c40d3d43e05e46a22119ad28f1343d93f9fe0ad912a44b2bb027be2a562ff568`
- 定義場所: `readaloud_app/android/app/build.gradle.kts` の `expectedReleaseCertSha256`
- Release は debug keystore に fallback しない。入力が無い・不一致なら **build は失敗する**(fail-closed)。
- 鍵の rotation / lineage は対象外。

## 署名入力(repo 外・Git 管理外)

keystore 本体は repo の外に置く(Git / Drive / Notion / GitHub / Codespaces へ置かない)。

`readaloud_app/android/key.properties`(`.gitignore` 済み)を作成する:

```properties
storeFile=C:/absolute/path/to/legacy/debug.keystore
storePassword=...
keyAlias=androiddebugkey
keyPassword=...
```

`storeFile` は絶対パス(Windows でも `/` 区切りで書く。`\` は properties で escape 扱いになる)。パスワードは docs・ログ・PR に書かない。

## Release build(Windows PC)

```
cd readaloud_app
flutter build apk --release
```

build は次を自動で行う:

1. `verifyReleaseSigningInputs`(assemble 前): keystore の証明書 SHA-256 を期待値と照合。不一致・入力欠落で停止。
2. 署名(v2)。
3. `verifyReleaseApkSigner`(assemble 後): `apksigner verify --print-certs` の signer が期待値と一致することを確認。

Acceptance 用 APK も同じ経路で build する(debug 署名・手動再署名は使わない)。

## 他の build

- `flutter test` / `flutter run` / debug build は署名入力を必要としない。
- Codespaces は Release 署名入力を持たないため、Release build は fail-closed で失敗する(意図どおり)。
