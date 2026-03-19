# TODO

Spec-locked decisions are tracked in `docs/spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## ビルドパイプライン

### 既知の制約

- cross-module string concat: library heap_ptr と user data offset の関係で一部不正
- funcref table の cross-module 共有は未実装（HOF inline で回避済み）

### 残タスク

- [ ] cross-module string concat の修正
- [ ] `vibe build --debug` を selfhost compiler で使えるようにする（後述）
- [ ] prelude を core module として事前コンパイル（builtin 関数の分離が必要）
- [ ] typecheck のインクリメンタル化（ripple query 改修）

## Selfhost compiler の debug build 対応

`vibe/compiler/` (~10M) で linked build を有効化する計画。

- [ ] Phase 1: transitive import 対応
- [ ] Phase 2: prelude 分離（builtin でない関数のみ library 化）
- [ ] Phase 3: HOF 選択的 inline

目標: cached `vibe run vibe/compiler/index.vibe` を ~100ms に。

## CI 最適化

### 現在の `just test` プロファイル (2026-03-20)

| ステップ | 時間 |
|---------|------|
| moon test --target js (957 tests) | 13s |
| cli_e2e native (78 tests) | 21s |
| vibe.exe test (E2E) | 65s |
| その他 | ~8s |
| **合計** | **~107s** |

### 改善タスク

- [ ] CI で `test` / `test-fixtures` / `test-wasm-heavy` を並列ジョブに分離
- [ ] `test-build-parity` を CI に追加
- [ ] `test-fixtures-isolation` を CI に追加（crash/timeout 検出）
- [ ] P3: minify_zlib 個別対策 (#13)

## カバレッジ

目標: branch coverage 70%

- [ ] checker/parser/printer/lexer/builtins の全 variant カバー
- [ ] normalize/DCE/loader のテスト拡充
- [ ] CI にカバレッジ gate を組み込み

## Effect System

- [ ] 関数呼び出しを跨ぐ perform の handler dispatch (CPS or stack switching)
- [ ] throw(x) → Perform("Error", "Throw", [x]) desugar
- [ ] suberror の throw を Error effect 経由に統一
- [ ] Net → fine-grained capability effects
- [ ] WASI P3: effect → WIT マッピング、vibe serve コマンド

## vibe/wasm ツールチェーン

- [ ] wasm_opt: directize, call forwarding, signature pruning
- [ ] wasm_opt: duckdb-mvp.wasm 対応 (39MB)
- [ ] wasm_runtime: テスト拡充
- [ ] wat_encoder: S 式完全対応

## 言語仕様の整合性

- [ ] function type / effect 表現の AST 統一
- [ ] method syntax の仕様固定
- [ ] 演算子型規則の checker/evaluator 一致
- [ ] 文字列補間を typed AST 化

## モジュール分離

- [ ] ルート制約の緩和（兄弟ディレクトリ import 許可）
- [ ] `vibe/types/`, `vibe/parser/` の分離

## Self-Host Compiler

- [ ] MoonBit host CLI を bootstrap 専用へ縮退
- [ ] selfhost perf gap を cutover 水準まで詰める
- [ ] GC backend セルフコンパイルで ~350KB 配布形
- [ ] `vibe/compiler` の論理分割

## ユーザビリティ改善

- [ ] 軽量 struct リテラル sugar `Type { ... }`
- [ ] `String` を `for-in` 対象にする
- [ ] トレイトにメソッド定義を許可
- [ ] `?` 演算子または `try` 式
