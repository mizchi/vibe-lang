# Distributed Refs Design (x/module_graph + git/bit)

このドキュメントは、`x/module_graph` を前提にした
`git/bit` 最適化ストレージ方針をまとめる。

## 目的

- 不変データは content-addressed object として保存する。
- 可変データは ref 更新だけで管理する。
- `index.vibe` は人間向け manifest、`index.vdb` は機械向け entrypoint に寄せる。
- `index.lock` は段階的に `index.vdb` へ収束させる。

## 基本モデル

1. 不変 (`object`)
   - module 本体
   - advanced graph snapshot (`AdvancedGraphIndex`, CBOR)
   - advanced graph delta (`AdvancedGraphDelta`, CBOR)
   - lock snapshot (将来)
2. 可変 (`ref`)
   - head pointer
   - wal head pointer
   - lock head pointer (将来)

この分離により、同期・競合は ref レイヤに限定できる。

## Ref レイアウト

`git_dir` (`.git`) 配下で以下を利用する:

- `refs/bit/index/<scope>/graph/head`
- `refs/bit/index/<scope>/graph/wal_head`
- `refs/bit/index/<scope>/lock/head` (reserved)

`<scope>` は `vibe/std@0.1.0` のような namespace + version を想定。
`..` を含む scope は拒否する。

## 現在実装済み

`src/x/module_graph/advanced_graph_git_ref_native.mbt`:

- `write_advanced_graph_index_to_git_ref(git_dir, scope, index)`
- `read_advanced_graph_index_from_git_ref(git_dir, scope)`
- `write_advanced_graph_delta_to_git_ref(git_dir, scope, delta)`
- `read_advanced_graph_delta_from_git_ref(git_dir, scope)`
- `read_advanced_graph_delta_chain_from_git_ref(git_dir, scope)`

挙動:

- snapshot/delta は CBOR にシリアライズして blob object として書く。
- `graph/head` ref は snapshot hash を保持する。
- `graph/wal_head` ref は delta chain node hash を保持する。
  - node payload: `{ kind, delta_hash, prev }`
  - `push-delta` は `prev` をつないで append する。
- 復元時は `ObjectDb::load_lazy` + `ref -> hash -> object` 解決で読む。

テスト:

- `src/x/module_graph/advanced_graph_poc_test.mbt`
  - `advanced graph poc git ref snapshot roundtrip`
  - `advanced graph poc git ref delta roundtrip`
- `src/x/module_graph/advanced_graph_git_ref_native_test.mbt`
  - `advanced graph git ref delta chain replay`

## CLI 接続

`vibe index ref` を追加:

- `vibe index ref push <scope> <index-file>`
- `vibe index ref pull <scope> <out-index-file>`
- `vibe index ref push-delta <scope> <delta-file>`
- `vibe index ref pull-delta <scope> <out-delta-file>`

例:

```bash
just run index build examples/syntax.vibe -o /tmp/advanced-graph-index.json
just run index ref push vibe/std@0.1.0 /tmp/advanced-graph-index.json
just run index ref pull vibe/std@0.1.0 /tmp/advanced-graph-index.restored.json
```

`vibe index build` は entry から graph snapshot を作成し:

- `-o` で指定した index JSON を出力
- `index.vdb` に `graph_head` を出力
- `.vibe/objects/<graph_head>` に snapshot JSON を保存

## index.vibe / index.vdb / lock の整理

- `index.vibe`: manifest (`version`, `module`, policy) のみ。
- `index.vdb`: 実行に必要な pointer 集合 (`graph_head`, `wal_head`, 将来 `lock_head`)。
- `index.lock`: 互換期間中は並行維持し、最終的に `index.vdb` に統合する。

## converge (mizchi/converge) 連携案

`converge` は object 同期ではなく、ref 同期に使う:

1. `refs` テーブルを CRDT/LWW で同期（`scope`, `lane`, `hash`）。
2. object 本体は git/bit object store から取得。
3. 競合解決は ref のみ対象（object は immutable なので衝突しない）。

## lock/vdb 解決順（現状）

- loader は lock 読み込み時に `index.vdb` を先に見る。
  - `index.vdb` に lock payload (`path/version/symbol/module/annotation` または `lock` object) があれば採用。
  - lock payload が無い場合は `index.lock` へ fallback。
  - `index.lock` が無ければ `xsh.lock` へ fallback（legacy）。

## 次ステップ

1. `fetch/update-lock` の書き込み先を `index.vdb` 主体に寄せる。
2. `index.lock` 互換期間の終了条件を決める。
3. chain compact / prune policy を CLI (`index ref`) 側に追加する。
