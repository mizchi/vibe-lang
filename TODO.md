# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## Language/Stdlib Proposals (AI-first authoring)

- [ ] language: tolerant parser（壊れた途中コードを AST 化して保持）
  - vibe shell での書き散らしを最後に normalize 可能にする
- [ ] language: AST rewriter / macro API（構文正規化パスを定義可能にする）
  - desugar/normalize を言語内で記述し、自己ホスト実装を縮小

## Self-Host Compiler / Runtime Packaging

**現状**: strict-recursive selfbuild と CI gate は完了。compiler API export、統合 compile pipeline、module loader、selfhost source manifest、TypeDb cache probe は完成。
**残**: standalone selfhost CLI の I/O 境界、persistent cache の実配線、component packaging。

### Selfhost compiler modularization / cache

- [ ] selfhost CLI / test loop で persistent `TypeDb` を持ち回り、同一プロセス内の warm compile を実際に再利用する
  - 現状は `vibe/compiler` 側に cached API と probe はあるが、user-facing な compile/test loop にはまだ常駐 cache を配線していない
- [ ] selfhost compiler の module fingerprint cache を typecheck 再利用から codegen/link 手前まで拡張する
  - manifest entry 単位で lowered/module artifact を再利用できる形に寄せる
- [ ] `vibe/compiler` の論理分割を manifest `group` 列に合わせて進める
  - 候補: `core/`, `syntax/`, `checker/`, `codegen/`
  - 目的はディレクトリ整理そのものではなく、manifest と cache 単位を一致させること
- [ ] `selfhost_sources_bundle.vibe` の drift を release 導線で検知する
  - manifest 更新と bundle 再生成のズレを CI/pre-release で落としたい

### Selfhost CLI / I/O boundary

- [ ] selfhost CLI の責務を「純粋 compile 関数」までに固定するか、WASI I/O まで selfhost 側に持ち込むかを文書化する
  - 現状は `vibe_compile_wasi` が I/O を担当し、selfhost は純粋 compile API を提供
- [ ] 将来: WASI Preview2 Component Model の FS/environ import を codegen に追加
  - selfhost 単体 artifact を CLI として閉じるための前提条件

### Component Model / Adapter Compose

- [ ] mwac plug 相当を .vibe で実装するか builtin 化する
- [ ] selfhost compiler 全体を `.wasm` component として配布・実行できる形にする

## Release / Gate Integration

- [x] `release-check` に selfhost gate 群を束ねる
  - `sync-vbundle`, `test-selfhost-bootstrap`, `test-selfhost-wasi-selfbuild-kpi`, `test-selfhost-cutover`, `test-selfhost-check-parity`, `test-golden-wat` を `release-selfhost-gates` に集約
  - ローカル pre-release 導線から CI 相当の selfhost / golden WAT gate を実行可能にした
- [ ] selfhost bootstrap の heavy shard をさらに削る
  - 進捗ログと file 単位 batch 分割は入ったが、`parser_test` / `stmt_test` / `printer_test` のような巨大ファイルはまだ tail を引っ張る
  - 方針候補: test file 分割、backend 固定、weight cache の見直し

## Migration Cleanup

- [x] `map_builder*` 互換 alias の user-facing 残骸を掃除する
  - language tour / generated docs / comment を `MapBuilder::*` に統一
  - legacy alias は互換用に維持しつつ、desugar の non-command name と coverage で後方互換を固定
  - rename 用の `scripts/rename_builtins.py` は移行補助として維持し、恒久 API では旧名を増やさない
- [ ] `map_builder*` 互換 alias を削除する条件を固める
  - 条件案: docs と eval task の canonical 化完了、rename script の dry-run 実績、host/selfhost の alias coverage を維持したまま deprecation 期間を決める
  - 対象: host checker/runtime/codegen の互換層、selfhost builtin 正規化、alias 専用 wbtest

## ユーザビリティ改善

### 高優先度（日常的な不便）

- [x] `==` で String/値比較（既に動作していた。examples を `==` スタイルに更新済み）
- [x] Map 操作のビルトイン化: `Map::set(m, key, value)` 追加、`Map[K, V]` ジェネリック化、Hash トレイトバウンド
- [ ] メソッド構文の導入（`s.length()` 等。現状すべてフリー関数で `String::length(s)` が必要）

### 中優先度（ボイラープレート削減）

- [ ] 空 Map リテラル `map {}` のサポート
- [ ] Array スプレッド構文 `[...xs, new_item]`（ArrayBuilder::new 3ステップの簡略化）
- [ ] トレイトにメソッド定義を許可（現状マーカーのみ。ユーザー定義型の `Eq` 実装不可）
- [ ] `?` 演算子または `try` 式（`handle { ... } { Error(_) => ... }` のネスト軽減）

### 低優先度（構文・ツール）

- [ ] `export` ブロック重複の lint/warning
- [ ] ドキュメントコメント構文（`///` 等）
- [ ] `for-in` の accumulate パターン改善（fold 的な構文糖衣）

## 現在の .vibe 言語の制約と回避策

| 制約 | 影響 | 回避策 |
|------|------|--------|
| `~` (bit_not) 非対応 | ビット反転 | `x ^ 0x7FFFFFFFFFFFFFFF` で代用 |
| mutable closure 制限 | CodegenCtx 的な状態管理 | レコード + 関数引数で明示受け渡し |
| mwac/wite は MBT パッケージ | .vibe から直呼び不可 | P4 で対応 |

## WASM HTTP P3 Implementation

**Phase 3 残タスク**:
- [ ] `wasi:http/handler` interface export を codegen で直接生成（resource/stream 対応が必要、将来課題）

## Blocked / External

- [ ] HTTPS/TLS 非対応: HTTP のみ (port 80 デフォルト)
- [ ] IPv4 のみ: DNS 解決・IPv6 未対応

## Deferred

- [ ] `wasi:http/handler` interface export を codegen で直接生成（P4 の先、resource/stream/future 40+ 型）
