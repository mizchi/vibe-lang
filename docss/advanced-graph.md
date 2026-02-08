# Advanced Graph Extension Plan (for `mizchi/bit`)

このドキュメントは、`mizchi/bit` を **Git 互換のまま** 拡張し、
木構造グラフ/シンボル検索/増分更新を扱うための設計メモである。

- 対象: xsh の `HashRef / VersionRef / SymbolRef` モデルと連携するバックエンド
- 前提: 実装はリアルタイムで進行中。ここでは方針と契約のみ定義する
- 非目標: Git の object wire format (`blob/tree/commit/tag`) 自体の変更

## 1. 設計原則

1. Git 互換性を最優先する
- 標準オブジェクト形式・OID 計算は不変
- 通常の `git clone/fetch/push` と共存可能にする

2. 拡張は ref + blob で表現する
- 追加情報は「拡張 ref」配下に置く
- 既存の commit/tree に埋め込まず、再生成可能に保つ

3. 検索は派生インデックスとして扱う
- source of truth は常に content hash
- 検索インデックスは破損時に再構築可能

## 2. 互換レイヤと拡張レイヤ

## 2.1 互換レイヤ（不変）

- `objects/` (blob/tree/commit/tag)
- pack/idx
- 通常の refs (`refs/heads/*`, `refs/tags/*`)

## 2.2 拡張レイヤ（追加）

- `refs/bit/index/<name>`: インデックス root
- `refs/bit/oplog/<name>`: 操作ログ root（任意）
- `refs/bit/state/<name>`: 再開ポイント/メタ状態（任意）

各 root が指す先は通常の `blob`（JSON or binary chunk）。
Git から見るとただの追加 ref なので互換性を壊さない。

## 3. メタDAGデータモデル

最小構成:

1. Root Manifest
- `schema_version`
- `base_commit`（このインデックスが同期しているコミット）
- `created_at`
- `features`（`symbols`, `types`, `refs`, `imports`, ...）
- `chunk_roots`（各インデックス種別のエントリポイント）

2. Chunk（分割インデックス）
- 大規模化に備え、prefix/ハッシュ帯で分割
- 1 chunk = 1 blob（差分更新時に局所差し替え）

3. Optional Oplog
- `op_id`, `parent_op_ids`, `base_commit`, `kind`, `payload`
- 例: `rebind_symbol`, `update_version_ref`, `index_delta_apply`

## 4. キー設計（推奨）

`symbol_index`:
- `symbol_name -> [def_id]`
- `def_id -> {module_hash, span, signature_hash, kind}`

`type_index`:
- `normalized_type_sig -> [def_id]`

`ref_index`:
- `def_id -> [use_site]`
- `module_hash -> [imported_module_hash]`

`impact_index`（任意）:
- `module_hash -> reverse dependents`

ID は `module_hash + local_path + span` などから deterministic に生成する。
rename に耐えるため、「表示名」ではなく「定義位置+hash」基準を優先する。

## 5. 増分更新プロトコル

更新は常に `base_commit -> target_commit` 差分で行う。

1. changed paths を列挙
2. 変更モジュールのみ再解析
3. 古いエッジを tombstone or remove
4. 新しいエッジを追加
5. 新 manifest を blob 化し、`refs/bit/index/<name>` を CAS 更新

失敗時:
- ref 更新前ならロールバック不要（未公開）
- ref 更新後に失敗した派生処理は次回 `index verify/repair` で回復

## 6. CLI コマンド案

最小セット:

- `bit index build [--from <commit>] [--to <commit>]`
- `bit index update [--since <commit>]`
- `bit index query symbol <term>`
- `bit index query type <sig>`
- `bit index query refs <def-id>`
- `bit index verify`
- `bit index repair`

拡張（任意）:

- `bit op log`
- `bit op diff <op-a> <op-b>`
- `bit op apply <op-id>`

## 7. xsh との接続点

xsh 側は以下を満たすと接続しやすい:

1. `HashRef` を実行時の唯一IDにする
2. `VersionRef/SymbolRef` は alias として rebind 可能にする
3. `edit` は symbol 優先で復元し、曖昧時に `name#hashprefix` に落とす
4. IDE/LSIF は共通インデックス API を使う

これにより、
- 実行整合性: hash 基準で安定
- 人間可読性: symbol/version で維持
- 検索性能: sidecar index で担保
を同時に満たせる。

## 8. 互換性ガード

絶対にやらないこと:

- commit/tree/blob のバイト列定義変更
- OID 計算アルゴリズムのローカル改変（互換レイヤ内）
- packfile フォーマットの独自拡張

やってよいこと:

- 独自 ref を追加
- blob payload の独自スキーマ
- fetch/push 時の独自 ref 同期ポリシー

## 9. 導入フェーズ

Phase 1: Read-only index
- build/query/verify のみ

Phase 2: Incremental update
- update/repair + CAS 運用

Phase 3: Oplog integration
- 操作ログと index delta を統合

Phase 4: Advanced transfer (研究)
- operation projection/retraction を取り込んだ高次 diff/merge

## 10. 未解決論点

- chunk 圧縮戦略（JSONL vs binary）
- 巨大 repo のメモリ上限と streaming build
- rename/move 判定と `def_id` 安定性のトレードオフ
- マルチブランチ同時更新時の競合解決（最後に書いた manifest が勝つか、3-way merge するか）

