# ADR-0015: 分散 Ref (Git Object ストレージ)

- Date: 2026-02-17
- Status: accepted

## Context

コンテンツアドレスモジュール（ADR-0004）の不変オブジェクトと、可変の状態ポインタ（graph head, WAL head）を効率的に保存・同期する仕組みが必要だった。Git の object store は content-addressed ストレージとして実績があり、ref によるポインタ管理も備えている。

## Decision

不変データと可変データを分離し、Git object + ref で管理する。

### 不変 (object)

- module 本体
- advanced graph snapshot (`AdvancedGraphIndex`, CBOR)
- advanced graph delta (`AdvancedGraphDelta`, CBOR)
- lock snapshot（将来）

### 可変 (ref)

```
refs/bit/index/<scope>/graph/head       # snapshot hash
refs/bit/index/<scope>/graph/wal_head   # delta chain node hash
refs/bit/index/<scope>/lock/head        # (reserved)
```

`<scope>` は `vibe/std@0.1.0` 形式。`..` を含む scope は拒否。

### delta chain

- WAL head は delta chain node を指す
- node payload: `{ kind, delta_hash, prev }`
- `push-delta` は `prev` をつないで append

### メタデータ整理

- `index.vibe`: manifest（version, module, policy）のみ
- `index.vdb`: 実行に必要な pointer 集合（graph_head, wal_head, 将来 lock_head）
- `index.lock`: 互換期間中は並行維持し、最終的に `index.vdb` に統合

### CLI

```bash
vibe index ref push <scope> <index-file>
vibe index ref pull <scope> <out-index-file>
vibe index ref push-delta <scope> <delta-file>
vibe index ref pull-delta <scope> <out-delta-file>
```

## Consequences

- 同期・競合は ref レイヤに限定され、object は immutable なので衝突しない
- Git インフラ（fetch/push）をそのまま同期に利用可能
- `index.lock` → `index.vdb` 統合の移行期間管理が必要
- delta chain の compact/prune ポリシーの設計が今後必要
