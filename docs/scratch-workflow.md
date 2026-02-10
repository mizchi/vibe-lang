# Scratch Workflow Design (Unison-like)

このドキュメントは、`xsh eval` / `repl` の日常運用を
Unison 風の「名前空間 head 更新」モデルに寄せるための設計案。

## 目的

- 外部 shell では `xsh eval "let x = 1"` だけで継続作業できる。
- `xsh` shell 内では `let x = 1` をそのまま評価し、同じ scratch に積む。
- ファイルは最終成果物として `write_file` で materialize する。
- lock / graph / scratch head を `index.xdb` に集約する。

## 用語

- `workspace`: 最寄りの `index.xsh` ルート。
- `namespace`: `scratch` などの評価先。
- `head`: namespace の現在状態を指す content hash。
- `materialize`: DAG から `.xsh` ファイルを再構成して書き出す。

## UX フロー

1. ユーザーは任意の場所で `xsh eval "..."` を実行。
2. CLI は最寄り `index.xsh` を探索し、`index.xdb` の `active_namespace` を解決。
3. `--db` 未指定なら `scratch` namespace に評価結果を適用。
4. `xsh apply <entry>` で lock / graph / head を同期。
5. `xsh write_file <symbol> <path>` で成果物を書き出す。

`repl` も同じ `active_namespace` を使う。  
`--db` を使う場合は明示指定を優先する。

## index.xdb 拡張案

既存の `graph_head` に加えて、以下を保持する。

```json
{
  "graph_head": "<hash>",
  "active_namespace": "scratch",
  "namespaces": {
    "scratch": {
      "head": "<hash>",
      "updated_at": "2026-02-10T00:00:00Z",
      "history_head": "<hash-or-empty>"
    }
  },
  "lock": {
    "path": {},
    "version": {},
    "symbol": {},
    "module": {},
    "annotation": {}
  }
}
```

方針:

- `index.xdb` が真実ソース。
- `index.lock` は互換期間中の派生物。
- `namespaces.*.head` は immutable object を指す。

## コマンド設計

### 1) eval / repl

- `xsh eval "expr"`:
  - デフォルトで `active_namespace` に評価を積む。
  - `--ns <name>` で namespace 切り替え。
  - `--db` 指定時のみ旧挙動を優先。
- `xsh repl`:
  - 同じ namespace head を使う。
  - `:ns <name>` でセッション中切替可能。

### 2) apply

- `xsh apply <entry>`:
  - `path/version/symbol/module/annotation` を再解決。
  - prelude を同期。
  - graph index を再生成し `graph_head` 更新。
  - scratch namespace の head 参照を保存。

### 3) symbols（新規）

- 現状実装:
  - `xsh symbols [--json] <entry>`
  - `<entry>` を起点に index + scratch を解決し、一覧を返す。
  - 各 symbol に `index_status` を付与:
    - `managed`: `index` 側に含まれる（lock/module/symbol ref から到達）
    - `scratch-only`: scratch にのみ存在
    - `shadowed`: index と scratch で衝突
  - plain 出力: `status<TAB>origin<TAB>kind<TAB>name<TAB>path#short-hash`
  - `--json` 出力: `status/origin/kind/name/path/hash/short_hash/signature/module_hash`

### 4) write_file（materialize）

- 現状実装:
  - `xsh write_file [--entry file] [--no-deps] [--dry-run] [--json] <selector> <out-file>`
  - `selector` は `name` / `name#hash` / `#hash` を許可。
  - `name` 指定時は `scratch -> index` の順で解決。
  - 既定は selector の module source 全体を書き出し、`--no-deps` は selector span のみ書き出す。
  - `--dry-run` は選択結果だけ表示してファイルを書き出さない。
  - `--json` は結果を機械可読 JSON で返す。
- 将来拡張:
  - DAG 閉包 materialize と `--dry-run`、`--fork` を追加する。

### 5) history reset（新規）

- `xsh history reset [--ns scratch] [--hard]`
  - soft reset（既定）:
    - `history_head` を切り替え、namespace は保持。
  - hard reset:
    - namespace head を初期状態へ戻す。
    - ローカル履歴ログも削除。

REPL でも `:history reset` を提供。

## 解決ルール

名前解決優先順位:

1. 明示 selector（`name#hash` / `#hash`）
2. 対象 namespace の最新 binding
3. index 管理下の export

衝突時:

- 単純な `name` が複数候補ならエラー。
- 候補一覧と推奨 selector を表示。

## 実装フェーズ

### Phase 1 (最短)

- `eval/repl` の default sink を `scratch` に変更。
- `index.xdb` に `active_namespace` と `scratch.head` を保存。
- `symbols` と `history reset` を read-only / reset-only で提供。

### Phase 2

- `write_file` の selector 解決と DAG materialize を実装。
- `index_status` 判定を lock/module graph と統合。

### Phase 3

- 複数 namespace の merge/rebase（Unison 的 patch 運用）。
- remote ref 同期時に namespace head も配布対象化。

## 非目標（現時点）

- Rust の borrow checker 相当の静的保証。
- def-level 最小閉包最適化（まず module-level 閉包で十分）。
- リモート協調編集の衝突自動解決。
