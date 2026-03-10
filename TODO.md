# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## Language/Stdlib Proposals (AI-first authoring)

- [ ] language: tolerant parser（壊れた途中コードを AST 化して保持）
  - vibe shell での書き散らしを最後に normalize 可能にする
- [ ] language: AST rewriter / macro API（構文正規化パスを定義可能にする）
  - desugar/normalize を言語内で記述し、自己ホスト実装を縮小

## Self-Host Compiler / Runtime Packaging

**現状**: strict-recursive selfbuild と CI gate は完了。compiler API export、統合 compile pipeline、module loader、selfhost source manifest、bundle drift check、TypeDb cache probe、selfhost CLI batch cache は完成。
**残**: host 側 loop への cache 再利用、component packaging。

### Selfhost compiler modularization / cache

- [ ] host `src/cmd/vibe` 側の compile/test loop にも selfhost と同じ persistent cache パターンを持ち込む
  - 現状は `vibe/compiler/cli_cache.vibe` 側で warm reuse はできるが、host CLI 全体の compile/test orchestration は別レイヤ
- [ ] selfhost compiler の module fingerprint cache を typecheck 再利用から codegen/link 手前まで拡張する
  - manifest entry 単位で lowered/module artifact を再利用できる形に寄せる
- [ ] `vibe/compiler` の論理分割を manifest `group` 列に合わせて進める
  - 候補: `core/`, `syntax/`, `checker/`, `codegen/`
  - 目的はディレクトリ整理そのものではなく、manifest と cache 単位を一致させること
### Selfhost CLI / I/O boundary

- [x] selfhost CLI の責務を「純粋 compile 関数」までに固定するか、WASI I/O まで selfhost 側に持ち込むかを文書化する
  - ADR-0022: selfhost compiler は pure compile API に留め、filesystem / environ / stdio は `vibe_compile_wasi` など host wrapper 側で扱う
- [ ] 将来: WASI Preview2 Component Model の FS/environ import を codegen に追加
  - selfhost 単体 artifact を CLI として閉じるための前提条件

### Component Model / Adapter Compose

- [ ] mwac plug 相当を .vibe で実装するか builtin 化する
- [ ] selfhost compiler 全体を `.wasm` component として配布・実行できる形にする

## Release / Gate Integration

- [ ] selfhost bootstrap の heavy shard をさらに削る
  - 進捗ログ、file 単位 batch、`selfhost_test_batch_weights.seed.json` の refresh 導線、`parser` / `stmt` / `printer` / `fixture` / `eval` / `eval_stmt` / `eval_selfhost` / `eval_selfhost2` / `eval_selfhost3` / `type_db` / `eval_e2e` / `checker_stmt` / `checker` / `cst_lower` の分割までは入った
  - refresh helper は bootstrap cache の実 path (`_build/bench/selfhost_bootstrap/...`) に追従済み
  - `selfhost_s5_*` と `codegen_parser_test` は compiled bootstrap から外し、別導線で扱う前提に寄せた
  - bootstrap 先頭 batch は 88 files まで分散済み
  - printer 系は `printer_function_test` / `printer_literal_test` / `printer_block_test` / `printer_operator_test` / `printer_call_test` / `printer_loop_test` / `printer_effect_test` まで分割済み
  - `stmt_decl_test` は import/use、data 宣言、type 宣言に分割済み、`cst_lower_expr_test` も literal/ops・binding/call・controlflow に分割済み
  - `parser_test` は operator/function/literal へ分割済み、`parser_controlflow_test` / `parser_destructure_test` は loop / invalid keyword まで分離済み
  - `fixture_selfhost_test` は parse / roundtrip に分割済み
  - `stmt_fn_regression_test` は `stmt_fn_tuple_regression_test` に、`fixture_test` は parse / roundtrip に分割済み
  - direct compiled 実測で重い候補は `compiler_test`、`stmt_regression_test`、`checker_stmt_regression_test`、`parser_flow_test`、`codegen_lexer_test`
  - 次の実作業候補: `stmt_regression_test` / `checker_stmt_regression_test` の再分割、`compiler_test` の compile_source 系を独立 file に切り出す
- [ ] compiled bootstrap から外した重い回帰ケースの扱いを固定する
  - `codegen_parser_test` は release binary でも 240s で完走しないため、専用 gate か fixture 化に寄せたい
  - `selfhost_s5_*` は selfbuild / artifact gate と責務が重複しているので、compiled bootstrap では走らせない前提を文書化したい
- [ ] `vibe_normalize_all` の explicit exclude を外す
  - 現状 `vibe/compiler/coverage_selfhost_suite_lib.vibe` は native normalize crash 回避のため batch 対象から外している
  - normalize engine 側の crash を直して exclude なしで回したい

## Migration Cleanup

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
