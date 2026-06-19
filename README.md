# ReadAloud

情報を「読む」から「理解し、再利用する」へ。
Android向け音声情報活用プラットフォーム（Flutter製・個人開発）

個人開発のプロジェクトです。Web記事・PDF・長文テキストなどの情報を取り込み、構造化し、音声で消費できるようにすることを目指しています。

## このアプリについて

ReadAloudは単なるTTS（テキスト読み上げ）アプリではなく、「情報摂取支援」を目的としたアプリです。

- Web記事・PDF・AIとの対話など、様々な情報源を収集・蓄積
- AIによる自動目次生成・表の解説生成
- 音声での情報消費（読み上げ）
- ブックマーク・読み上げ履歴の管理
- バックグラウンド再生・Bluetooth操作対応
- 将来的な知識ネットワーク化

長期的には、Web記事・PDF・AIとの対話など複数の情報源を一元化し、構造化・可視化・知識の再利用を支援するプラットフォームを目指しています。詳細は [`docs/ReadAloud_Vision.md`](docs/ReadAloud_Vision.md) を参照してください。

なお本READMEのPhase表記は [`docs/ROADMAP.md`](docs/ROADMAP.md) のPhase0〜7に準拠しています。

## 開発状況

現在 v1.2.x を開発中です。Phase1（情報整理）の自動目次生成・表解析と、Phase2（理解促進）のTTS読み上げ・再生位置管理・表解説が中心です（Phase番号は[`docs/ROADMAP.md`](docs/ROADMAP.md)に準拠）。

実装済み：
- テキスト/URL/Share Intentからのコンテンツ登録
- Android内蔵TTSによる読み上げ（速度・声種選択）
- ブックマーク・読み上げ履歴
- AIによる自動目次作成・表の検出と解説生成（Gemini / Claude / Groq）

開発中・今後の予定は [`docs/ROADMAP.md`](docs/ROADMAP.md) を参照してください。

## 技術スタック

- Flutter 3.44.0 / Dart 3.12.0（Android専用）
- 状態管理: flutter_riverpod
- ローカルDB: sqflite
- TTS: flutter_tts（端末内蔵）/ audio_service
- AI連携: Gemini API・Claude API・Groq API（ユーザーが自身のAPIキーを設定）

APIキーはユーザーが設定画面で入力し、`flutter_secure_storage` により端末内に暗号化保存されます。開発者のサーバーにキーが送信されることはありません。

## 開発体制について

このプロジェクトは、複数のAIと協働しながら開発しています。

| 役割 | 担当 |
|------|------|
| 実装 | Claude |
| 設計・文書化・レビュー | ChatGPT |
| 技術リサーチ | Gemini |

開発はスマートフォン（Termux + GitHub Codespaces経由のSSH接続）で行っており、PCを使わない開発フローを採用しています。

AIが現状を素早く理解できるよう、`docs/` 配下に以下のドキュメントを用意しています。

- [`docs/AI_CONTEXT.md`](docs/AI_CONTEXT.md) - 新しくこのプロジェクトに関わるAI向けの概要
- [`docs/ReadAloud_Vision.md`](docs/ReadAloud_Vision.md) - プロジェクトの目的・将来像
- [`docs/ROADMAP.md`](docs/ROADMAP.md) - 開発フェーズと計画

## 注意事項

- 個人利用を主目的とした個人開発プロジェクトです
- Issue・Pull Requestは現在受け付けていません
- このリポジトリは主にAIによるコードレビュー・設計相談を目的として公開しています

このプロジェクトは、知識・思考・AIとの対話を長期的に蓄積し、人間とAIが共同で思考を発展させられる基盤を目指しています。

## ライセンス

未定