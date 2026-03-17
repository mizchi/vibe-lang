# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## カバレッジ計測

### 現在の計測結果 (2026-03-17)

| 対象 | lines | branches | コマンド |
|------|-------|----------|---------|
| vibe/wasm (純関数のみ) | 100% | 28.63% | `VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS=1 scripts/coverage_wasm_source.sh vibe/wasm/coverage_test.vibe` |
| vibe/compiler (selfhost) | 100% | 15.54% | `VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS=1 scripts/coverage_wasm_source.sh vibe/compiler/selfhost_coverage_run.vibe` |
| vibe/compiler (suite) | — | — | `just coverage-selfhost-suite` (root 外 import で一部失敗) |

### 完了済み
- [x] Bytes codegen を --wasm backend に追加 (new/push/set/slice/concat/to_array)
- [x] coverage_enabled → need_heap 自動初期化
- [x] coverage script が `_start` export に対応
- [x] `compile_module_wasm_for_exec_with_coverage` 追加
- [x] vibe/wasm/coverage_test.vibe 作成 (31 tests, 6 coverage tests)

### 次のステップ
- [ ] vibe/wasm: branches 28% → 50% (parse_* 関数のカバレッジ追加 — ヒープ制約回避が必要)
- [ ] vibe/compiler: branches 15% → 30% (eval_e2e テストの branch gap)
- [ ] compiled backend カバレッジ: Bytes/Fs 使用モジュールも計測可能に
  - `src/runtime_compile/compile.mbt`: WASI compile パスにカバレッジ計装
  - `src/cmd/vibe/cli.mbt`: test_cmd でカウンタ読み取り
  - wasmtime メモリダンプ or sidecar 経由
- [ ] selfhost suite coverage の root 外 import エラー修正
- [ ] CI にカバレッジ gate を組み込み (point/line/branch 最低率)

## vibe/wasm ツールチェーン

### 完了 (2026-03-17)
- [x] wasm_parser — WASM 1.0 全セクション + GC 型対応 (148 tests)
- [x] wat_parser — WAT テキストトークナイザー/パーサー (82 tests)
- [x] wat_encoder — WAT → WASM コンパイラ, S 式対応 (10 tests)
- [x] component_parser — Component Model バイナリパーサー (48 tests)
- [x] wasm_runtime — WASM インタプリタ, GC 対応, 94+ opcodes (64 tests)
- [x] wasm_opt — WASM 最適化, peephole/DCE/coalesce/minify (75 tests)
- [x] WebAssembly spec tests — i32 + control flow (65 tests)
- [x] zlib.wasm 最適化: 171,100 → 57,878 bytes (66.2% 削減, wasmtime OK)
- [x] wite テストフィクスチャ移植 (6 fixtures, 21 tests)

### 残タスク
- [ ] wasm_opt: directize (call_indirect → call 変換)
- [ ] wasm_opt: call forwarding propagation
- [ ] wasm_opt: signature pruning (未使用パラメータ削除)
- [ ] wasm_opt: duckdb-mvp.wasm 対応 (39MB — Bytes bulk copy 高速化)
- [ ] wasm_runtime: nested block+loop+br のさらなるテスト
- [ ] wat_encoder: S 式 `(if (then (if ...)))` 完全対応

## vibe/x 準公式ライブラリ

- [x] x/fmt — printf 風文字列フォーマット (24/24 pass)
- [ ] x/url — compiled test で `../regexp` import がルート外エラー
- [x] x/uuid — UUID v4 生成 (11/11 pass)
- [x] x/color — ANSI カラー出力 (15/15 pass)
- [x] x/regexp — 正規表現 (91/91 pass)
- [x] x/toml — TOML パーサー (28/28 pass)
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
