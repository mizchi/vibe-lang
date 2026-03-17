# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## Compiled Backend カバレッジ計装 (最優先)

compiled (WASI) backend で vibe ソースの分岐カバレッジを計測可能にする。
現状は `--wasm` backend のみカバレッジ計装があり、`Bytes` 等 WASI 依存の vibe/wasm モジュールは計測不可。

### Phase 1: compile_module_wasm_for_exec に coverage オプション追加
- [ ] `src/runtime_compile/compile.mbt`: `compile_module_wasm_for_exec` に `coverage?: Bool` 引数追加
- [ ] `compile_module_wasm_with_coverage` と同等のカウンタ挿入を WASI compile パスに適用
- [ ] `__vibe_cov_base` / `__vibe_cov_count` グローバルを WASI module にも export

### Phase 2: test_cmd でカバレッジ読み取り
- [ ] `src/cmd/vibe/cli.mbt`: `test_cmd_sequential` でカバレッジモード時に wasmtime 実行後のメモリからカウンタ読み取り
- [ ] `VIBE_TEST_COVERAGE=1` 環境変数で test 実行時にカバレッジ計装を有効化
- [ ] カウンタ読み取り方法: wasmtime の `--invoke` 後に memory export から i32 配列を読む or sidecar file 経由

### Phase 3: レポート生成
- [ ] 既存の `coverage_wasm_source.mjs` のレポート生成ロジックを再利用
- [ ] `vibe test --coverage` で point/line/branch のサマリーを出力
- [ ] `justfile` に `coverage-vibe-wasm` レシピ追加

### Phase 4: vibe/wasm モジュールのカバレッジ計測
- [ ] vibe/wasm の各モジュールに対してカバレッジ計測を実行
- [ ] 分岐カバレッジ gate (BranchIfThen/BranchIfElse/BranchMatchArm) を設定
- [ ] CI に組み込み

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
