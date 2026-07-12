# ReadAloud プロジェクト索引

**最終更新：** 2026年7月11日（v1.2.12.2時点）

## 必読（コード修正前に必ず確認）

- プロジェクトナレッジ内の「引き継ぎドキュメント」（現在の開発状況・次回作業計画・全REQ/FIX一覧）
- 開発ルール27（引き継ぎドキュメント内）：AI提案コードで既存のクラス・メソッド・Provider・Repository APIを利用する場合、採用前に必ず実在確認を行うこと

---

## このファイルについて

AI（Claude・ChatGPT・Gemini等）がReadAloudプロジェクトの全体像を素早く把握するための索引です。まずこのファイルを読み、必要に応じて個別ファイルを参照してください。

**Raw URLの基本形：** `https://raw.githubusercontent.com/koji-osa/readaloud-app/main/[ファイルパス]`

---

## 0. リポジトリ全体構成（ドキュメント・設定ファイル）

| ファイル | 内容 |
|---------|------|
| `README.md` | リポジトリトップページ |
| `docs/AI_CONTEXT.md` | AI向けプロジェクト概要 |
| `docs/ReadAloud_Vision.md` | 将来ビジョン・思想（Phase0〜7） |
| `docs/ROADMAP.md` | 開発ロードマップ |
| `readaloud_app/README.md` | Flutterプロジェクト標準README（Flutter雛形。内容は薄い） |
| `readaloud_app/pubspec.yaml` | 依存パッケージ・アプリバージョン定義 |
| `readaloud_app/analysis_options.yaml` | Dart静的解析のルール設定 |
| `readaloud_app/android/app/src/main/AndroidManifest.xml` | Android権限・Intent設定（TTS Intent・Share Intent等） |
| `readaloud_app/test/widget_test.dart` | Flutter標準のスモークテスト（雛形のまま未拡張。品質保証プロセス整備時に拡張候補） |

**注：** 上記以外（画像・アイコン・iOS/Windows/macOS/Web等の各プラットフォーム標準設定ファイル計240件超）はFlutterの標準雛形であり、ReadAloud固有のロジックを含まないため索引から除外している。`docs/adr/`（ADR-001・002）はまだ未配置（詳細はセクション6）。

---

## 1. まず読むべきドキュメント（優先順）

| ファイル | 内容 |
|---------|------|
| `docs/AI_CONTEXT.md` | プロジェクト概要・AI向けサマリー |
| `docs/ReadAloud_Vision.md` | 将来ビジョン・思想（Phase0〜7） |
| `docs/ROADMAP.md` | 開発ロードマップ |
| `README.md` | リポジトリトップ |
| 引き継ぎドキュメント（プロジェクトナレッジ内） | 開発の現在地・次回作業計画・全REQ/FIX一覧。最新版のファイル名は都度確認すること |

---

## 2. AI推奨読書順（コードを読む場合）

新しい機能追加・不具合修正でコードを読む場合、以下の順で読むと全体像を把握しやすい。

1. `docs/AI_CONTEXT.md`（プロジェクト概要）
2. `docs/ReadAloud_Vision.md`（思想）
3. `docs/ROADMAP.md`（計画）
4. `readaloud_app/lib/providers.dart`（Riverpodプロバイダ定義・依存関係の全体像）
5. `readaloud_app/lib/main.dart`（エントリーポイント）
6. 対象機能の ViewModel（状態管理）
7. 対象機能の UseCase（ビジネスロジック）
8. 対象機能の Repository（データアクセス抽象化）
9. 対象機能の DAO（実際のDB操作）

この順序は、ReadAloudのアーキテクチャ（UI→ViewModel→UseCase→Repository→DAO・ADR-002で確定）に沿っている。

---

## 3. プロジェクト基本情報

| 項目 | 内容 |
|------|------|
| アプリ名 | ReadAloud（Android専用テキスト読み上げアプリ） |
| フレームワーク | Flutter 3.44.0 / Dart 3.12.0 |
| 状態管理 | Riverpod |
| ローカルDB | sqflite |
| アーキテクチャ | UI → ViewModel → UseCase → Repository → DAO（Clean Architecture・ADR-002で確定） |
| データの正本 | SQLite（ADR-001で確定。Markdown/Obsidian中心設計へは移行しない） |

---

## 4. 機能別索引（目的から探す）

「〇〇を直したい・調べたい」という目的ベースで関連ファイルをまとめたもの。ディレクトリ構成（セクション5）と併用すること。

### 表分析・表解説機能（FIX-068〜073関連）

- `repository/table_analysis_service.dart`（中核・AIへのプロンプト送信とexcerpt位置特定）
- `repository/gemini_service.dart` / `claude_service.dart` / `groq_service.dart`（AI API連携）
- `viewmodel/player_viewmodel.dart`（表分析後の新規テキスト作成・目次生成フロー）
- `util/text_cleaner.dart`（旧クリーニング処理。FIX-071で利用は廃止済み）
- `util/table_debug_logger.dart`（表分析デバッグログ）

### TTS（読み上げ）機能

- `repository/tts/tts_service.dart`（共通インターフェース）
- `repository/tts/device_tts_service.dart`（Android内蔵TTS・FIX-064のPause/Resume補正）
- `repository/tts/google_tts_service.dart`（Google Cloud TTS・MP3再生部分は未完成）
- `repository/tts/openai_tts_service.dart`（OpenAI TTS）
- `usecase/tts/check_tts_limit_usecase.dart` / `count_tts_usage_usecase.dart`（使用量管理）

### コンテンツ登録・URL取得・PDF取り込み

- `usecase/content/fetch_url_content_usecase.dart`（URL取得・REQ-038/049の基盤）
- `usecase/content/extract_pdf_content_usecase.dart`（PDF取り込み・REQ-041）
- `usecase/content/save_content_usecase.dart` / `update_content_usecase.dart` / `delete_content_usecase.dart`
- `viewmodel/add_content_viewmodel.dart`（コンテンツ追加画面）
- `util/share_intent_handler.dart`（Android共有インテント処理）

### ブックマーク・目次機能

- `model/bookmark.dart`（モデル・maxLabelLength等）
- `repository/bookmark_repository.dart` / `impl/bookmark_repository_impl.dart`
- `usecase/bookmark/add_bookmark_usecase.dart` / `delete_bookmark_usecase.dart`
- `ui/player/widgets/bookmark_panel.dart`（UI・目次コピー機能実装済み）

### 再生画面・UI（REQ-045・046コピー機能等）

- `ui/player/player_screen.dart`（再生画面本体）
- `ui/player/widgets/seek_bar.dart`（シークバー・時刻表示）
- `ui/player/widgets/playback_controls.dart`（再生コントロール）
- `ui/player/widgets/highlight_text.dart`（ハイライト表示）

### ホーム画面・一覧

- `ui/home/home_screen.dart`
- `ui/home/widgets/content_card.dart`
- `ui/home/widgets/tts_usage_banner.dart`
- `viewmodel/content_list_viewmodel.dart`

### 設定画面

- `ui/settings/settings_screen.dart`
- `viewmodel/settings_viewmodel.dart`
- `repository/settings_repository.dart` / `impl/settings_repository_impl.dart`

---

## 5. ディレクトリ構成とファイル一覧

すべて `readaloud_app/lib/` 配下（Raw URL接頭辞：`https://raw.githubusercontent.com/koji-osa/readaloud-app/main/readaloud_app/lib/`）

### 5.1 model/（データモデル）

| ファイル | 役割 |
|---------|------|
| `model/content.dart` | 登録テキスト（コンテンツ）のモデル |
| `model/bookmark.dart` | ブックマーク・目次のモデル（maxLabelLength等） |
| `model/history.dart` | 読み上げ履歴のモデル |
| `model/playback_state.dart` | 再生状態のモデル |
| `model/setting.dart` | 設定値のモデル |
| `model/tts_playback_position.dart` | TTS再生位置のモデル |

### 5.2 db/（データベース）

| ファイル | 役割 |
|---------|------|
| `db/database_helper.dart` | SQLiteのDB定義・マイグレーション |
| `db/dao/content_dao.dart` | コンテンツのDAO |
| `db/dao/bookmark_dao.dart` | ブックマークのDAO |
| `db/dao/history_dao.dart` | 履歴のDAO |
| `db/dao/playback_dao.dart` | 再生状態のDAO |
| `db/dao/settings_dao.dart` | 設定のDAO |

### 5.3 repository/（データアクセス層）

| ファイル | 役割 |
|---------|------|
| `repository/content_repository.dart` | コンテンツRepositoryインターフェース |
| `repository/impl/content_repository_impl.dart` | 同実装 |
| `repository/bookmark_repository.dart` | ブックマークRepositoryインターフェース |
| `repository/impl/bookmark_repository_impl.dart` | 同実装 |
| `repository/history_repository.dart` | 履歴Repositoryインターフェース |
| `repository/impl/history_repository_impl.dart` | 同実装 |
| `repository/playback_repository.dart` | 再生状態Repositoryインターフェース |
| `repository/impl/playback_repository_impl.dart` | 同実装 |
| `repository/settings_repository.dart` | 設定Repositoryインターフェース |
| `repository/impl/settings_repository_impl.dart` | 同実装 |
| `repository/table_analysis_service.dart` | 表分析・表解説処理（AI連携）。FIX-068〜071・sanitizeExcerpt関連の主要ファイル |
| `repository/gemini_service.dart` | Gemini API連携 |
| `repository/claude_service.dart` | Claude API連携 |
| `repository/groq_service.dart` | Groq API連携 |

### 5.4 repository/tts/（TTSエンジン）

| ファイル | 役割 |
|---------|------|
| `repository/tts/tts_service.dart` | TTSサービス共通インターフェース |
| `repository/tts/device_tts_service.dart` | Android内蔵TTS実装（FIX-064のPause/Resume補正含む） |
| `repository/tts/google_tts_service.dart` | Google Cloud TTS実装（REQ-042）。API呼び出しは実装済みだが、MP3再生部分が未完成（TODO：現状flutter_ttsで代替、本来はaudioplayers等でMP3再生が必要・Phase2対応予定） |
| `repository/tts/openai_tts_service.dart` | OpenAI TTS実装 |

### 5.5 usecase/（ユースケース層）

| ファイル | 役割 |
|---------|------|
| `usecase/content/save_content_usecase.dart` | コンテンツ保存 |
| `usecase/content/update_content_usecase.dart` | コンテンツ更新 |
| `usecase/content/delete_content_usecase.dart` | コンテンツ削除 |
| `usecase/content/get_all_contents_usecase.dart` | コンテンツ一覧取得 |
| `usecase/content/fetch_url_content_usecase.dart` | URL先の本文取得（REQ-038・049の基盤） |
| `usecase/content/extract_pdf_content_usecase.dart` | PDF本文抽出（REQ-041） |
| `usecase/bookmark/add_bookmark_usecase.dart` | ブックマーク追加 |
| `usecase/bookmark/delete_bookmark_usecase.dart` | ブックマーク削除 |
| `usecase/playback/start_playback_usecase.dart` | 再生開始 |
| `usecase/playback/stop_playback_usecase.dart` | 再生停止 |
| `usecase/playback/save_playback_state_usecase.dart` | 再生状態保存 |
| `usecase/playback/set_ab_repeat_usecase.dart` | A-Bリピート設定 |
| `usecase/tts/check_tts_limit_usecase.dart` | TTS使用量上限チェック |
| `usecase/tts/count_tts_usage_usecase.dart` | TTS使用量カウント |

### 5.6 viewmodel/（状態管理層）

| ファイル | 役割 |
|---------|------|
| `viewmodel/player_viewmodel.dart` | 再生画面の状態管理。表分析後の新規テキスト作成・目次生成フローの中核（FIX-070関連） |
| `viewmodel/add_content_viewmodel.dart` | コンテンツ追加画面の状態管理 |
| `viewmodel/content_list_viewmodel.dart` | ホーム画面（一覧）の状態管理 |
| `viewmodel/settings_viewmodel.dart` | 設定画面の状態管理 |
| `viewmodel/onboarding_viewmodel.dart` | オンボーディング画面の状態管理 |

### 5.7 ui/（画面・UI）

| ファイル | 役割 |
|---------|------|
| `ui/home/home_screen.dart` | ホーム画面（コンテンツ一覧） |
| `ui/home/widgets/content_card.dart` | コンテンツカードUI |
| `ui/home/widgets/tts_usage_banner.dart` | TTS使用量バナー |
| `ui/add/add_screen.dart` | コンテンツ追加画面 |
| `ui/player/player_screen.dart` | 再生画面（REQ-045・046コピー機能実装済み） |
| `ui/player/widgets/seek_bar.dart` | シークバー（時刻表示レイアウト変更済み） |
| `ui/player/widgets/bookmark_panel.dart` | ブックマークパネル（目次コピー機能実装済み） |
| `ui/player/widgets/playback_controls.dart` | 再生コントロールUI |
| `ui/player/widgets/highlight_text.dart` | ハイライトテキスト表示 |
| `ui/settings/settings_screen.dart` | 設定画面 |
| `ui/onboarding/onboarding_screen.dart` | オンボーディング画面 |

### 5.8 util/（ユーティリティ）

| ファイル | 役割 |
|---------|------|
| `util/text_cleaner.dart` | テキストクリーニング処理（FIX-071でtable_analysis_service.dartからの利用は廃止） |
| `util/table_debug_logger.dart` | 表分析デバッグログ出力（FIX-050） |
| `util/debug_logger.dart` | 汎用デバッグログ |
| `util/share_intent_handler.dart` | Android共有インテント処理 |

### 5.9 その他

| ファイル | 役割 |
|---------|------|
| `main.dart` | エントリーポイント |
| `providers.dart` | Riverpodプロバイダ定義 |

---

## 6. 設計判断の記録（ADR）

**注：** ADR-001・002はまだGitHubリポジトリに未配置（Codespacesストレージ問題により保留中・セクション0参照）。配置後は `docs/adr/` を参照。

| ADR | 内容 |
|-----|------|
| ADR-001 | SQLiteをデータの正本（SSoT）とする |
| ADR-002 | データアクセスをRepository経由に統一する |

---

## 7. 開発の現在地・作業計画

最新のリリース状況・次回作業内容・全REQ/FIX一覧は、プロジェクトナレッジ内の「引き継ぎドキュメント」を参照すること。このファイルには含めない（重複管理を避けるため）。

---

## 8. AI協働開発について

このプロジェクトはClaude（実装）・ChatGPT（設計レビュー）・Gemini（技術リサーチ）の3AIで協働開発している。AI提案コードを採用する際は、既存クラス・メソッドの実在確認を必ず行うこと（開発ルール27・引き継ぎドキュメント参照）。

---

## 9. このファイルの更新ルール

新しいDartファイルを追加・削除・名称変更した場合は、この索引（特にセクション4・5）も同時に更新すること。機能追加時は、まずセクション4（機能別索引）に該当する見出しがあるか確認し、なければ新設する。
