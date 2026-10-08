# ReadAloud プロジェクト索引

**最終更新:** 2026-10-08  
**基準リリース:** v1.2.24 (`1.2.24+45`)  
**v1.2.24 release source commit:** `773a8f993d3837094b874ba5f78522bf53fac692`

## このファイルについて

AI（ChatGPT・Claude Code・Gemini等）がReadAloudの全体像と現在の主要構造を短時間で把握するための索引です。

この索引は**Navigation / Context Projection**であり、Canonical Stateではありません。現在状態を判断するときは、GitHub `main` / Release、Project RegistryのLatest Handoff、実行環境、Android実機Evidenceをlive確認し、差分があれば現物を優先してください。

Raw URL基本形: `https://raw.githubusercontent.com/koji-osa/readaloud-app/main/[ファイルパス]`

---

## 0. 現在のスナップショット

| 項目 | 現在値 |
|---|---|
| アプリ | ReadAloud（Android向け情報摂取支援アプリ） |
| 最新正式Release | `v1.2.24` |
| Version | `1.2.24+45` |
| Current main HEAD | live GitHub `main`で確認（この索引には固定SHAを置かない） |
| Flutter baseline | Flutter 3.44.0 / Dart 3.12 |
| Android baseline | target/compile 36、build-tools 36.0.0 |
| 状態管理 | Riverpod |
| Library永続化 | SQLite / sqflite |
| Sources Phase 1 | Markdown Folder Source（SAF、direct child `.md`、Recent 7暦日） |
| Playback基盤 | Shared Player Core + Transient / Persistent policy |

### Authorityの区別

- **Library内部の永続状態・保存コンテンツ**: SQLite側がAuthority。
- **外部Source Original**: SAF / provider側がAuthority。
- **Library Promotion後**: 保存時snapshot + provenanceを保持し、Sourceと自動同期しない。
- **Source消失後**: Libraryに保存したsnapshotは引き続き再生可能。

旧索引の「すべてのデータの正本 = SQLite」という一括表現は、Sources導入後の設計を正確に表さないため、この区別を優先してください。

---

## 1. 最初に読むもの

### Current State / Handoff
Notion Project Registry「readaloudアプリ開発・関連情報」の `Latest Handoff URL` を最初に確認してください。

2026-10-08時点のLatest Handoff: `readaloudアプリ開発・関連情報 Handoff Package 2026-10-08`

参照順:
1. `00_readaloudアプリ開発・関連情報_引継ぎ起動プロンプト_2026-10-08`
2. `01_readaloudアプリ開発・関連情報_Handoff Core_2026-10-08`
3. `02_readaloudアプリ開発・関連情報_Current State_2026-10-08`
4. `03_readaloudアプリ開発・関連情報_Session Operation Guide_2026-10-08`
5. `04_readaloudアプリ開発・関連情報_Asset Recovery Appendix_2026-10-08`

### GitHub docs
| ファイル | 用途 |
|---|---|
| `README.md` | リポジトリトップ |
| `docs/AI_CONTEXT.md` | AI向けプロジェクト概要 |
| `docs/PROJECT_INDEX.md` | GitHub側プロジェクト索引 |
| `docs/ReadAloud_Vision.md` | 将来ビジョン・思想 |
| `docs/ROADMAP.md` | ロードマップ |
| `docs/REVIEW_CHECKLIST.md` | Review時のチェック項目 |

---

## 2. アーキテクチャ概要

基本レイヤー:

`UI → ViewModel → UseCase → Repository → DAO / Platform Provider`

PlaybackとSourcesでは、単純なDB CRUDだけでなく以下の境界を重視します。

### Shared Player Core
- Shared Playback TransportはDB-independent。
- shared mega-ViewModelを作らない。
- Persistent side effectはPersistence boundaryの後ろへ隔離。
- Normal Playerのsession/navigation ownershipを維持。
- Transientはephemeralだがprimitiveではない。
- Library / Sources境界はPlayer capability差ではなく**lifecycle / persistence policy**。

### Sources
上位contract:

`resolve(sourceReference) → playableRepresentation`

- Provider / SAF / folderはmechanismでありarchitecture centerではない。
- metadata-first / content-on-demand。
- Phase 1はtext-first。
- tapしたSourceだけをresolveし、existing Transient playbackへ渡す。

---

## 3. Sources Phase 1 / Markdown Folder Source

v1.2.24で正式リリース。

### Product Contract
- top-level `Sources`。
- Obsidian専用ではなく**Markdown Folder Source**。
- user-selected SAF folderを設定。Obsidian vault設定とは分離。
- 直下の`.md`のみ。再帰なし。
- Recent = ローカル暦の**今日＋過去6暦日**。
- list時はmetadataのみ。本文はtapした1件だけread。
- Source openはexisting Shared Player / Transient経路を使い、開始時paused。
- Library Promotionはsnapshot + provenance、no auto-sync。
- saved判定のPhase 1 identityは `source_type='folder' AND source_url=<child SAF URI>`。

### 主要ファイル
| ファイル | 役割 |
|---|---|
| `lib/ui/sources/sources_screen.dart` | Sources画面 |
| `lib/viewmodel/sources_viewmodel.dart` | Sources状態管理 |
| `lib/usecase/sources/recent_folder_grouping.dart` | Recent 7暦日 / grouping / sort |
| `lib/usecase/sources/folder_source_open_usecase.dart` | selected Markdown resolve → playback request |
| `lib/repository/folder_children_lister.dart` | folder direct-child metadata listing abstraction |
| `lib/model/folder_child.dart` | folder child metadata model |
| `lib/util/markdown_content_parser.dart` | generic Markdown parser |
| `lib/util/player_entry_coordinator.dart` | playback entry coordination |

---

## 4. Quick Listen / Shared Playback

### 主要ファイル
| ファイル | 役割 |
|---|---|
| `lib/ui/quick_listen/` | Quick Listen UI |
| `lib/viewmodel/quick_listen_viewmodel.dart` | Quick Listen state / playback coordination |
| `lib/model/quick_listen_session.dart` | Transient Quick Listen session |
| `lib/model/playback_request.dart` | playback request / source descriptor |
| `lib/model/player_capabilities.dart` | capability policy |
| `lib/model/normal_player_session.dart` | Normal Player session |
| `lib/util/player_entry_coordinator.dart` | Transient / Persistent entry coordination |
| `lib/util/normal_player_session_tracker.dart` | Normal Player session lifecycle |

v1.2.24ではQuick Listenのprovider lifecycle timingを修正し、Sources経由およびAndroid Share経由の実機AcceptanceをPASS済み。

---

## 5. 既存主要領域

### Library / Home
- `lib/ui/home/home_screen.dart`
- `lib/viewmodel/content_list_viewmodel.dart`
- `lib/repository/content_repository.dart`
- `lib/repository/impl/content_repository_impl.dart`
- `lib/db/dao/content_dao.dart`

### Normal Player
- `lib/ui/player/`
- `lib/viewmodel/player_viewmodel.dart`
- `lib/model/normal_player_session.dart`

### Obsidian Import（Phase 1 Sourcesとは別機能）
- `lib/viewmodel/obsidian_import_viewmodel.dart`
- `lib/repository/obsidian_repository.dart`
- `lib/usecase/obsidian/`
- `lib/util/obsidian_extension_processor.dart`

既存Obsidian Importはimport-oriented。Sources Phase 1はImportせず直接playbackできる別経路であり、Obsidian専用設計へ統合しない。

### Android Share / external input
- `lib/util/external_input_handler.dart`
- `lib/util/player_entry_coordinator.dart`
- Quick Listen経路へ接続。

### AI / table analysis
- `lib/repository/table_analysis_service.dart`
- `lib/repository/gemini_service.dart`
- `lib/repository/claude_service.dart`
- `lib/repository/groq_service.dart`

### TTS
- `lib/repository/tts/`
- `lib/usecase/tts/`

---

## 6. v1.2.24 Release lineage

Sources Phase 1:

`aab49e72 → 85c08356 → cad3411f → 9b0f730 → 466e9234`

- `85c08356`: initial Sources Phase 1 implementation
- `cad3411f`: implementation corrections
- `9b0f730`: Quick Listen lifecycle correction
- `466e9234`: PR #38 normal merge commit

Release preparation:

`466e9234 → 444d1448 → 773a8f99`

- `444d1448`: v1.2.24 version-only preparation
- `773a8f99`: PR #39 normal merge commit / release source

Release artifact:
- annotated tag `v1.2.24`
- final APK size `58,402,482 bytes`
- SHA-256 `37e58ca9f0381015de13ec8eb1d6a25c60d1417e5187789eaf37dfa1ca9b74c9`

---

## 7. 検証状態

### Sources / Quick Listen
- Independent Review: no BLOCKER / MAJOR
- Exact Diff Review: PASS
- Android Compile: PASS
- Device Acceptance: PASS
- full tests at final PR #38 stage: 482 PASS / 1 known baseline FAIL (`databaseFactory not initialized`)
- analyze: error 0 / warning 0

### Google Drive mixed-folder PoC
実研究ブリーフfolder 233 direct entries:
- initial: 560ms
- refresh: 655ms
- Google Docs混在hangは再現せず

結論:
- Google Docs混在を恒常的原因とするEvidenceなし。
- 新release blockerなし。
- ただしprovider query timeout/cancellationがないため、間欠stall時の無期限loadingリスクは残る。

**PR #38 formal Performance Acceptanceは`DEFERRED`の履歴を維持する。PoC結果で遡及的にPASSへ変更しない。**

---

## 8. 現在の残課題 / 次サイクル

### Priority 1 — No.152 Home/Library initial list inconsistency
Library Promotion後にDB rowが存在してもHome/Library UIが空表示になる場合がある。

現在のEvidenceではSources保存失敗より、`ContentListViewModel` / async loading / progress lookup / UI state pipeline側を優先して調査する。

### Priority 2 — cloud SAF provider stall robustness
- timeout
- cancellation
- retry UX
- 再発時のADB/log evidence

provider固有hackではなくgeneric Sources robustnessとして設計する。

### Priority 3 — F-QL-01 MINOR
`quick_listen_navigation_test.dart`の古いコメント修正。production behaviorへの影響なし。

### Later
- `.txt` folder source
- PDF / Web / Brief専用Source
- deeper provider integration

これらはv1.2.24実運用EvidenceとAI HUB側Markdown Artifact Deliveryの進展を見てからDecisionする。

---

## 9. AI HUB / Knowledge Operationsとの責務境界

2026-10-08、AI HUBではtext-first durable AI-generated ArtifactについてMarkdown-first Canonical Representation原則を採択済み。

ReadAloudはそのArtifactを利用するSource / Playback surfaceとなり得るが、以下はKnowledge Operations / Governance側責務:
- Scheduled Artifact persistence
- Canonical Authority
- Daily / Research Brief Production format activation
- Receipt / integrity pipeline

ReadAloud側で外部Delivery問題を独自Transport workaroundとして再実装しない。

---

## 10. AI協働開発ルール

- ChatGPT: architecture / decision / integration
- Claude Code: implementation / code-grounded executor
- Gemini: broad research
- Claude Opus: architecture red-team
- User: final product / merge / release decision

高リスク作業ではexact branch / exact HEAD / exact mainをGateに固定する。

詳細実行プロンプトはGoogle Docへ保存し、チャット本文は識別子・対象・exact HEAD・短い概要・Doc linkだけにする。

禁止:
- direct main push
- force push / force tag rewrite
- Human Decisionなしのmerge / release / tag / version bump
- gateなしDB schema migration
- 無断Codespace deletion / cleanup

---

## 11. Current Handoff / Research Logs

Latest Handoff:
- `readaloudアプリ開発・関連情報 Handoff Package 2026-10-08`

主要研究ログ:
- No.152 `Home初期表示の一覧不整合`
- No.154 `Sources Drive一覧ハングPoC—混在要因否定`
- No.156 `Sources Phase 1・v1.2.24正式リリース`

次の出発点は**No.152の独立調査**。
