# TODO

Spec-locked decisions are tracked in `docs/spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## vbundle 廃止 (完了)

vbundle 形式を廃止し、`.vibe/cache.json` + `index.lock` に完全移行済み。
ソースコード・テスト・スクリプトから全 vbundle 参照を削除。

## カバレッジ計測

### 現在の計測結果 (2026-03-17)

| 対象 | lines | branches | コマンド |
|------|-------|----------|---------|
| vibe/wasm (純関数のみ) | 100% | 28.63% | `VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS=1 scripts/coverage_wasm_source.sh vibe/wasm/coverage_test.vibe` |
| vibe/compiler (selfhost) | 100% | 15.54% | `VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS=1 scripts/coverage_wasm_source.sh vibe/compiler/selfhost_coverage_run.vibe` |
| vibe/compiler (suite) | — | — | `just coverage-selfhost-suite` (root 外 import で一部失敗) |

### 次のステップ
- [ ] vibe/wasm: branches 28% → 50% (parse_* 関数のカバレッジ追加 — ヒープ制約回避が必要)
- [ ] vibe/compiler: branches 15% → 30% (eval_e2e テストの branch gap)
- [ ] compiled backend カバレッジ: Bytes/Fs 使用モジュールも計測可能に
  - `src/runtime_compile/compile.mbt`: WASI compile パスにカバレッジ計装
  - `src/cmd/vibe/cli.mbt`: test_cmd でカウンタ読み取り
  - wasmtime メモリダンプ or sidecar 経由
- [ ] selfhost suite coverage の root 外 import エラー修正
- [ ] CI にカバレッジ gate を組み込み (point/line/branch 最低率)

## Packed Bytes (obj_bytes) 残作業

`Bytes` の WASM メモリレイアウトを `obj_array` (4byte/elem) から `obj_bytes` (1byte/elem) に変更済み。
codegen のみの変更で型システムには影響なし。

### 残タスク
- GC backend: Bytes ハンドラが元々未実装（packed bytes scope 外）。別途対応時に packed 前提で実装
- ベンチ: WASM バイナリサイズ 694→673 bytes (-3%)。ランタイム計測は vibe CLI 再ビルド後

## vibe/wasm ツールチェーン
- [ ] wasm_opt: directize (call_indirect → call 変換)
- [ ] wasm_opt: call forwarding propagation
- [ ] wasm_opt: signature pruning (未使用パラメータ削除)
- [ ] wasm_opt: duckdb-mvp.wasm 対応 (39MB — Bytes bulk copy 高速化)
- [ ] wasm_runtime: nested block+loop+br のさらなるテスト
- [ ] wat_encoder: S 式 `(if (then (if ...)))` 完全対応

## vibe/x 準公式ライブラリ

- [ ] x/url — compiled test で `../regexp` import がルート外エラー
- [ ] x/template — 簡易テンプレートエンジン
- [ ] x/diff — テキスト差分 (Myers diff)

## Vibe 言語仕様の整合性

- [ ] function type / effect 表現を AST・型・parser・printer・checker で統一する
- [ ] selfhost evaluator の AST codec を full-fidelity にする
- [ ] method syntax を nominal sugar と trait dispatch のどちらにするか仕様として固定する
- [ ] import surface の kind 情報を AST に残す
- [ ] 演算子の型規則を checker と evaluator で一致させる
- [ ] 文字列補間を raw source 再 parse ではなく typed AST にする
- [ ] `loop` / `continue` の状態受け渡しを positional から named へ寄せる
- [ ] generic `impl` を AST だけ先行させる状態を解消する

## モジュール分離 (ルート制約ブロッカー)

- [ ] ルート制約の緩和: `vibe test` のルート判定を緩和し、兄弟ディレクトリからの import を許可
  - 現状: `vibe test vibe/parser/test.vibe` のルート = `vibe/parser/`、`../types/` はルート外エラー
  - 必要: `vibe/` 全体をルートとして認識するか、明示的なルート指定 (`--root vibe/`)
- [ ] ルート制約解消後: `vibe/types/` (ast.vibe, types.vibe) を分離
- [ ] ルート制約解消後: `vibe/parser/` (token, lexer, parser, printer) を分離
- [ ] 現状の論理分離 (`vibe/compiler/core/`, `vibe/compiler/syntax/`) は維持

## Self-Host Compiler

- [ ] MoonBit host CLI を bootstrap 専用へ縮退する
- [ ] selfhost perf gap を cutover 可能な水準まで詰める
- [ ] GC backend セルフコンパイルで ~350KB 配布形を実現する
- [ ] `vibe/compiler` の論理分割を manifest `group` 列に合わせて進める

## ユーザビリティ改善

- [ ] 軽量 struct リテラル sugar `Type { ... }`
- [ ] `String` を `for-in` 対象にする
- [ ] トレイトにメソッド定義を許可
- [ ] `?` 演算子または `try` 式

## 現在の .vibe 言語の制約

| 制約 | 回避策 |
|------|--------|
| `~` (bit_not) 非対応 | `x ^ 0x7FFFFFFFFFFFFFFF` で代用 |
| mutable closure 制限 | レコード + 関数引数で明示受け渡し |
| `[]` が常に `Array[Unit]` | `Array::slice([(sentinel)], 0, 0)` で型付き空配列 |
| 大文字始まり変数名は enum constructor | snake_case 必須 |
| `let (x, mut y)` 非対応 | `let (x, y0) = ...; let mut y = y0` |
