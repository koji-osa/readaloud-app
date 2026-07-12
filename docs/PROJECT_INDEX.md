# ReadAloud プロジェクト索引

**最終更新：** 2026年7月11日（v1.2.12.2時点）

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

**注：** 上記以外（画像・アイコン・iOS/Windows/macOS/Web等の各プラットフォーム標準設定ファイル計240件超）はFlutterの標準雛形であり、ReadAloud固有のロジックを含まないため索引から除外している。`docs/adr/`（ADR-001・002）はまだ未配置（詳細はセクション4）。

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

## 2. プロジェクト基本情報

| 項目 | 内容 |
|------|------|
| アプリ名 | ReadAloud（Android専用テキスト読み上げアプリ） |
| フレームワーク | Flutter 3.44.0 / Dart 3.12.0 |
| 状態管理 | Riverpod |
| ローカルDB | sqflite |
| アーキテクチャ | UI → ViewModel → UseCase → Repository → DAO（Clean Architecture・ADR-002で確定） |
| データの正本 | SQLite（ADR-001で確定。Markdown/Obsidian中心設計へは移行しない） |

---

## 3. ディレクトリ構成とファイル一覧

すべて `readaloud_app/lib/` 配下（Raw URL接頭辞：`https://raw.githubusercontent.com/koji-osa/readaloud-app/main/readaloud_app/lib/`）

### 3.1 model/（データモデル）

| ファイル | 役割 |
|---------|------|
| `model/content.dart` | 登録テキスト（コンテンツ）のモデル |
| `model/bookmark.dart` | ブックマーク・目次のモデル（maxLabelLength等） |
| `model/history.dart` | 読み上げ履歴のモデル |
| `model/playback_state.dart` | 再生状態のモデル |
| `model/setting.dart` | 設定値のモデル |
| `model/tts_playback_position.dart` | TTS再生位置のモデル |

### 3.2 db/（データベース）

| ファイル | 役割 |
|---------|------|
| `db/database_helper.dart` | SQLiteのDB定義・マイグレーション |
| `db/dao/content_dao.dart` | コンテンツのDAO |
| `db/dao/bookmark_dao.dart` | ブックマークのDAO |
| `db/dao/history_dao.dart` | 履歴のDAO |
| `db/dao/playback_dao.dart` | 再生状態のDAO |
| `db/dao/settings_dao.dart` | 設定のDAO |

### 3.3 repository/（データアクセス層）

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

### 3.4 repository/tts/（TTSエンジン）

| ファイル | 役割 |
|---------|------|
| `repository/tts/tts_service.dart` | TTSサービス共通インターフェース |
| `repository/tts/device_tts_service.dart` | Android内蔵TTS実装（FIX-064のPause/Resume補正含む） |
| `repository/tts/google_tts_service.dart` | Google Cloud TTS実装（REQ-042）。API呼び出しは実装済みだが、MP3再生部分が未完成（TODO：現状flutter_ttsで代替、本来はaudioplayers等でMP3再生が必要・Phase2対応予定） |
| `repository/tts/openai_tts_service.dart` | OpenAI TTS実装 |

### 3.5 usecase/（ユースケース層）

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

### 3.6 viewmodel/（状態管理層）

| ファイル | 役割 |
|---------|------|
| `viewmodel/player_viewmodel.dart` | 再生画面の状態管理。表分析後の新規テキスト作成・目次生成フローの中核（FIX-070関連） |
| `viewmodel/add_content_viewmodel.dart` | コンテンツ追加画面の状態管理 |
| `viewmodel/content_list_viewmodel.dart` | ホーム画面（一覧）の状態管理 |
| `viewmodel/settings_viewmodel.dart` | 設定画面の状態管理 |
| `viewmodel/onboarding_viewmodel.dart` | オンボーディング画面の状態管理 |

### 3.7 ui/（画面・UI）

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

### 3.8 util/（ユーティリティ）

| ファイル | 役割 |
|---------|------|
| `util/text_cleaner.dart` | テキストクリーニング処理（FIX-071でtable_analysis_service.dartからの利用は廃止） |
| `util/table_debug_logger.dart` | 表分析デバッグログ出力（FIX-050） |
| `util/debug_logger.dart` | 汎用デバッグログ |
| `util/share_intent_handler.dart` | Android共有インテント処理 |

### 3.9 その他

| ファイル | 役割 |
|---------|------|
| `main.dart` | エントリーポイント |
| `providers.dart` | Riverpodプロバイダ定義 |

---

## 4. 設計判断の記録（ADR）

**注：** ADR-001・002はまだGitHubリポジトリに未配置（Codespacesストレージ問題により保留中・セクション0参照）。配置後は `docs/adr/` を参照。

| ADR | 内容 |
|-----|------|
| ADR-001 | SQLiteをデータの正本（SSoT）とする |
| ADR-002 | データアクセスをRepository経由に統一する |

---

## 5. 開発の現在地・作業計画

最新のリリース状況・次回作業内容・全REQ/FIX一覧は、プロジェクトナレッジ内の「引き継ぎドキュメント」を参照すること。このファイルには含めない（重複管理を避けるため）。

---

## 6. AI協働開発について

このプロジェクトはClaude（実装）・ChatGPT（設計レビュー）・Gemini（技術リサーチ）の3AIで協働開発している。AI提案コードを採用する際は、既存クラス・メソッドの実在確認を必ず行うこと（開発ルール27・引き継ぎドキュメント参照）。
