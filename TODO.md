# TODO

Spec-locked decisions are tracked in `docs/spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## ビルドパイプライン (`vibe build` / `vibe run`)

### 現在の実装 (2026-03-20)

| コマンド | 動作 | 速度 |
|---------|------|------|
| `vibe run file.vibe` | デフォルト linked debug。初回キャッシュ自動作成 | cached: **31ms** |
| `vibe build --debug` | linked build + library キャッシュ (.vibe/debug/) | cached: **10ms** |
| `vibe build --release` | monolithic + wite -Oz 最適化 | ~250ms |
| `VIBE_RUN_BACKEND=release vibe run` | monolithic フォールバック | ~250ms |

### debug linked build の仕組み

1. import 先を library .wasm としてコンパイル、`.vibe/debug/` にキャッシュ
2. user code のみ parse → codegen → wasm import で library 参照
3. `wasmtime --preload lib=.vibe/debug/lib.wasm user.wasm` で実行
4. ソース hash でキャッシュ無効化（変更時に自動再ビルド）

### 動作保証

- debug/release parity: 11 テストケース + 257 fixture で検証済み (0 mismatch)
- `just test-build-parity` で CI 検証可能

### 既知の制約

- cross-module string concat: library の heap_ptr 初期値と user data offset の関係で一部ケースで不正な結果（scalar/array/tuple は正常）
- HOF (高階関数) を export するモジュールは自動的に monolithic inline にフォールバック
- funcref table の cross-module 共有は未実装（HOF inline で回避済み）

### 残タスク

- [ ] cross-module string concat の修正 — library 側の heap_ptr 初期値を user data offset 以降にリセットする
- [ ] `vibe build --debug` を `vibe/compiler` (selfhost) で使えるようにする（後述）
- [ ] prelude を core module として事前コンパイル — prelude の builtin 関数が codegen 特殊処理に依存しており分離困難。段階的に対応
- [ ] typecheck のインクリメンタル化 — ripple query の改修。変更モジュールだけ再 typecheck

## Selfhost compiler の debug build 対応

### 背景

`vibe/compiler/` (selfhost compiler, ~10M) は `vibe build --debug` の最大の受益者。
現在の selfhost compilation は全モジュールを monolithic にバンドルするため数秒かかる。
debug linked build が動けば、ユーザーファイル変更時に **~10ms** でリビルド可能。

### 課題

1. **多段 import チェーン**: `vibe/compiler/index.vibe` は 20+ モジュールを import。linked build は直接 import のみ対応。transitive import の library 化が必要
2. **prelude 依存**: selfhost の各モジュールは prelude 関数 (array_map, String::concat 等) を使う。これらは codegen builtin として inline 展開されるため、library 分離すると codegen が処理できない
3. **HOF の多用**: selfhost compiler は高階関数を多用。HOF を含むモジュールは自動 inline にフォールバックするが、大部分のモジュールが HOF を含むため効果が限定的

### 対応計画

- [ ] **Phase 1: transitive import 対応** — `bundle_for_wasm_linked` で transitive import (import の import) も library 化。`collect_dependency_defs` の再帰ロジックを linked mode に拡張
- [ ] **Phase 2: prelude 分離** — prelude 関数のうち codegen builtin でないもの (array_fold, option_map 等) を library .wasm に分離。builtin 依存の関数 (String::concat, Array::push 等) は引き続き inline
- [ ] **Phase 3: HOF 選択的 inline** — HOF export がある場合でも、実際に user code から HOF 経由で呼ばれない export はlinked import のままにする。全 export を inline するのではなく、HOF 引数を取る export のみ inline

### 計測目標

| 操作 | 現在 | 目標 |
|------|------|------|
| `vibe run vibe/compiler/index.vibe` (初回) | ~9s | ~2s (library キャッシュ作成) |
| `vibe run vibe/compiler/index.vibe` (cached) | ~9s | **~100ms** |
| `vibe check vibe/compiler/index.vibe` | ~9s | ~1s (型チェックのみ) |

## テスト高速化

### 実施済み (2026-03-20)

- [x] `ensure_native_cli.sh` — ビルドキャッシュ (250ms → 20ms)、20 スクリプト + justfile 移行
- [x] `VIBE_SKIP_FIXTURES=1` — `just test` から fixture インタプリタ実行をスキップ
- [x] `just test-wasm-heavy` — wasm_opt/wasm_runtime を分離 (wasm_opt 258s → 10s with minify_zlib disabled)
- [x] テストバッチ化 — 同一ファイル内テストを 1 WASM にまとめてコンパイル
- [x] fixture isolation テスト — abort/crash/timeout をプロセス単位で検出
- [x] effect rewrite 無限再帰修正 — ネストされた Error+effect handler の修正
- [x] eval.mbt abort → raise — perform/spread でプロセスが死なないように

### 残タスク

- [ ] **P3: minify_zlib 個別対策** — 6 テストで ~222s。#13 で tracked。小さな fixture で基本テスト、zlib.wasm は CI の重量ジョブのみ
- [x] ~~vibe.exe test に linked build を適用~~ — 検証済み: batch compile は既に 1 回で済んでおり、linked build で削減できるのは compile の 270ms のみ (テスト全体 25s の 1%)。テスト時間の支配要因は wasmtime 上の WASM interpreter 実行 (~24s) であり、linked build では改善不可

## カバレッジ計測

### 現在の計測結果 (2026-03-18)

| 対象 | lines | branches | コマンド |
|------|-------|----------|---------|
| vibe/wasm (純関数のみ) | 100% | 28.63% | `scripts/coverage_wasm_source.sh vibe/wasm/coverage_test.vibe` |
| vibe/compiler (selfhost suite) | 99% | **45.34%** | `just coverage-selfhost-suite` |

### 目標: branch coverage 70%

- [ ] checker: check_expr/check_stmts の全 variant カバー
- [ ] parser: 全 Token 種別、エラーリカバリ、multiline string
- [ ] printer: 全 Stmt/Expr variant の roundtrip テスト
- [ ] lexer: hex literal, char escape, edge cases
- [ ] builtins: 全 builtin 関数の型チェック (92 builtins, ~30 未テスト)
- [ ] normalize/DCE: variant テスト、re-export chain、qualified enum ctor
- [ ] loader: cross-module merge 順序、circular import、version/symbol ref
- [ ] CI にカバレッジ gate を組み込み (branch 最低率)

## Effect System

### 実装済み

- [x] effect 宣言、perform 式、handle/resume (tail-resumptive inline)
- [x] with { Effect } スコープ追跡
- [x] perform Error::Throw → Raise desugar
- [x] effect rewrite の無限再帰修正

### 残タスク

- [ ] 関数呼び出しを跨ぐ perform の handler dispatch (CPS or stack switching)
- [ ] throw(x) → Perform("Error", "Throw", [x]) desugar (逆方向は完了)
- [ ] suberror の throw を Error effect 経由に統一
- [ ] Net → fine-grained capability effects (HttpServer, Socket, Fs 等)
- [ ] capability-based DCE (ADR-0027)
- [ ] WASI P3: effect → WIT マッピング、vibe serve コマンド

## vibe/wasm ツールチェーン

- [ ] wasm_opt: directize (call_indirect → call 変換)
- [ ] wasm_opt: call forwarding propagation
- [ ] wasm_opt: signature pruning (未使用パラメータ削除)
- [ ] wasm_opt: duckdb-mvp.wasm 対応 (39MB)
- [ ] wasm_runtime: nested block+loop+br テスト拡充
- [ ] wat_encoder: S 式 `(if (then (if ...)))` 完全対応

## Vibe 言語仕様の整合性

- [ ] function type / effect 表現を AST・型・parser・printer・checker で統一
- [ ] selfhost evaluator の AST codec を full-fidelity にする
- [ ] method syntax を nominal sugar と trait dispatch のどちらに固定するか
- [ ] import surface の kind 情報を AST に残す
- [ ] 演算子の型規則を checker と evaluator で一致させる
- [ ] 文字列補間を raw source 再 parse ではなく typed AST にする
- [ ] `loop` / `continue` の状態受け渡しを positional → named
- [ ] generic `impl` を AST だけ先行させる状態を解消

## モジュール分離 (ルート制約ブロッカー)

- [ ] ルート制約の緩和: `vibe test` で兄弟ディレクトリ import を許可
- [ ] ルート制約解消後: `vibe/types/`, `vibe/parser/` を分離

## Self-Host Compiler

- [ ] MoonBit host CLI を bootstrap 専用へ縮退
- [ ] selfhost perf gap を cutover 可能な水準まで詰める
- [ ] GC backend セルフコンパイルで ~350KB 配布形を実現
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
