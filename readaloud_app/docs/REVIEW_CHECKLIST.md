# ReadAloud Review Checklist

## 目的・使い方

このチェックリストは、ReadAloudのコード変更をレビューする際に「何を疑うべきか」を再現するための問い集です。Reviewer個人の内部会話履歴（Claude内部Context）に依存せず、GitHubのlive artifacts（diff・git履歴／blame・PR本文・テスト結果）と、必要に応じたHandoff／Board等の外部Evidenceから、一定水準のレビューを再現できることを目指します。古いSnapshotではなく現物を優先する、という原則は変わりません。

固定の完成物ではなく、実際のPRレビュー・障害・回帰から得られた知見を育てていくLiving Review Assetです。新しい見落としが見つかった場合は「この失敗は、将来の別変更でも再利用できる問いとして本チェックリストに昇格すべきか？」を判断してください（詳細は末尾のMaintenance Rule参照）。

## レビューの進め方（Change-Specific Review Plan）

レビュー開始時、まず以下を行ってください。

1. **現物確認を先に行う。** repository / target branch / PRのlive stateを確認する。head SHA・base・diff・tests/CI結果・PR本文を必要に応じて確認する。古いHandoffやBoard上のSnapshotだけでレビュー結論を出さない。
2. **変更範囲を分類し、今回重点的に適用するLayer 2の項目群を選ぶ。** 下記「適用ガイド」は最低限の重点候補であり、閉じた対応表ではない。diffの影響が複数領域に波及する場合は、表にないグループも追加で適用する。
3. Layer 1（Universal）は変更内容によらず毎回目を通す。ただし明らかに非該当な項目はN/A（対象外）と判断してよい。
4. レビュー結果には、どの項目群を適用し、何を対象外としたかを記録する（下記「標準出力フォーマット」参照）。

---

## Layer 1: Universal Review Checks

どんな変更にも当てはまる一般原則です。

1. 0・null・空入力・空リストで破綻しないか？
2. 例外・失敗・timeout・取得不能などのfailure pathは適切に扱われているか？
3. 同値・tie・順序競合が起きたとき、挙動は決定的か（毎回同じ結果になるか）？
4. 同名・重複・複数候補が存在するとき、正しく識別・区別できるか？
5. 削除・置換・単純化した情報が、識別・fallback・順序・安全性など、見えない別の役割を持っていなかったか？
6. 状態遷移や永続化によって、画面表示と内部状態が乖離しないか？
7. 既存データ・過去バージョンとのbackward compatibilityは保たれるか？
8. 直接変更していない隣接機能へ副作用が及んでいないか？

### Review Evidence Discipline

9. ドキュメント・PR本文・コメント・引き継ぎ記録等の記述を鵜呑みにせず、実際のコード・git履歴（blame等）で挙動を確認したか？
10. 実装内容を変更・訂正した場合、PR本文等の記述も実装内容と一致するよう更新したか？

---

## Layer 2: ReadAloud Domain Regression Checks

ReadAloudで実際に再発防止価値が確認されている領域です。架空の詳細ルールを先回りして追加せず、実際のEvidenceが増えるごとに育てます（Web取込・PDF・TTS・DB・bookmark／reading position・AI API等は、実PR・不具合のEvidenceが蓄積されてから追加します）。各項目の具体的な由来は末尾の「Evidence Provenance」を参照してください。

### State / Selection
11. モード・画面・階層を切り替えた後も、selection state（選択状態）は意図通り保持・解除されるか？
12. three-state selection（フォルダの全選択・一部選択・未選択）や、親子選択の整合性は崩れないか？
13. 画面表示と、内部のselection管理ロジック（source of truth）がずれていないか？

### Identity / Path / Duplicate
14. 同名ファイル・同名項目が複数存在するとき、区別できるか？
15. パス等の識別情報を画面から削る変更で、識別能力そのものを失っていないか？
16. 人間可読な表示名と、内部の一意識別子（ID・URI等）の役割を混同していないか？

### Order / Hierarchy
17. フォルダ・ファイルの順序・ソート・tie（同値時の順序）は、階層構造の中でも崩れないか？
18. 階層の深さによって挙動を変える設計の場合、意図した深さでのみ適用されているか？
19. 空フォルダ、ルート直下のみ、フォルダのみ、ファイルのみ、といった境界ケースで、不自然な表示（例：不要な区切り線等）が出ないか？

### UI / Layout
20. 長い名称、2行以上、可変height、小さい画面幅、empty state、想定外の値で、レイアウトが崩れないか？
21. 自動テストでは判定しづらい主観的なUI品質（見た目のバランス等）について、実機確認の要否をレビュー結果に明記しているか？

### Test / Baseline Failure
22. 今回の変更で新たに発生したfailureと、変更前から存在する既存（baseline）failureを分離できているか？
23. 「今回の変更とは無関係な既存failureである」と判断する場合、その根拠（原因・変更ファイルとの関係・履歴等）を示しているか？
24. Missing test・カバーされていない境界ケースを、Blocking（マージ前に必須）とNon-blocking（実機確認等に委ねてよい）に分類しているか？

---

## Layer 3: 適用ガイド（Change-Specific Review Plan）

全項目を毎回機械的に適用する運用にはしません。変更の性質に応じて、重点対象を選んでください。この表は最低限の重点候補であり、閉じた対応表ではありません。

| 変更の種類 | 重点的に適用するLayer 2グループ |
|---|---|
| 一覧・ツリー等のUI表示変更 | State/Selection、Identity/Path/Duplicate、Order/Hierarchy、UI/Layout |
| データ処理・変換ロジックの変更 | Identity/Path/Duplicate、Test/Baseline Failure |
| 選択・操作系の変更 | State/Selection |

今後、TTS・Web取込・PDF・DB・bookmark／reading position・AI API等の領域で実PR・不具合のEvidenceが蓄積された場合、該当グループをこの表と上記Layer 2に追加してください。

---

## レビュー結果の標準出力フォーマット

- **Verdict**：Approve candidate / Changes needed / Insufficient Context のいずれか
- **Applied checklist scope**：今回重点適用したLayer 2グループ
- **Not applied / N/A**：明らかに非関連として除外した領域と、その簡潔な理由（該当する場合のみ）
- **Blocking findings**：マージ前に対応が必要な問題（なければ「なし」と明記）
- **Non-blocking findings**：対応は必須ではないが記録しておくべき点
- **Missing tests / regression checks**：未実施・不足しているテスト／回帰確認
- **Context不足時に必要なArtifact**：レビューを完結させるために追加で必要な情報
- **merge前確認事項**：Project主担当（ChatGPT側）またはユーザーへ伝えるべき確認事項

## Authority boundary（権限の境界）

- Reviewerはmerge・releaseを決定しません。最終的なmerge・release判断は常にユーザー（Product Owner）が行います。
- Reviewerの招集条件・Project Routing・役割分担は、最新のProject Registry／Handoffを正とし、本チェックリストでは固定しません。

## Maintenance Rule（このチェックリストの育て方）

実際のPRレビュー・障害・回帰で新しい見落としが見つかった場合、以下を自問してください。

> この失敗・見落としは、将来の別の変更でも再利用できるレビューの問いとして、このチェックリストに昇格すべきか？

昇格すべきと判断した場合、該当するLayer（Universal／Domain）へ追記してください。PR固有の一時的な詳細（特定のSHA・特定ファイルの行番号等）はチェックリスト本文には残さず、一般化した問いの形に抽象化し、由来は下記Evidence Provenanceへ追記してください。

## Evidence Provenance / Origin

各項目の一般化された問いは、以下の実際のPRレビュー・障害から抽出されています。当時の具体的な実装内容・SHA・findingsはGitHub／AI Collaboration Boardを正とし、本文には複製しません。

| チェック項目 | Evidence |
|---|---|
| Identity / Path / Duplicate（14・15） | PR #23：日付モードでファイル名のみ表示にした際、異なるフォルダの同名ファイルが区別できなくなる懸念。親フォルダ名の補助表示で対応 |
| Order / Hierarchy - tie挙動（17） | PR #21：`sortKeyOf`が同値のとき並び順が不定だった |
| Order / Hierarchy - 深さ限定設計（18） | PR #23：フォルダ・ファイル境界の区切り線はルート階層(depth==0)限定の設計。サブフォルダ内では意図的に非適用 |
| Test / Baseline Failure（22・23） | FIX-074／PR #23周辺：`test/widget_test.dart`の失敗は`sqflite`未初期化が原因で、UI変更PRとは無関係と確認した事例が複数回ある |
| Review Evidence Discipline（9・10） | PR #23：PR本文の「ファイル名を2行に折り返す」という説明が実装（ファイル名1行＋親フォルダ名を補助的に2行目）と食い違っていた事例。区切り線の色・太さ調整が、引き継ぎ記録では「未実装」とされていたが実際にはコード上で実装済みだった事例 |
