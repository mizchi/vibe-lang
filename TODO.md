# TODO

Spec-locked decisions are tracked in `docs/spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## ビルドパイプライン

### 既知の制約

- funcref table の cross-module 共有は未実装（HOF inline で回避済み）
- wasmtime `--preload` 自体は library module に WASI instance を提供できない
  linked debug build では preload-unsafe な dep を自動 inline して回避済み

### 残タスク

- [x] cross-module string concat の修正
- [x] `vibe build --debug` を selfhost compiler で使えるようにする（後述）
- [x] prelude を core module として事前コンパイル（builtin 関数の分離が必要）
- [x] typecheck のインクリメンタル化（import surface query + ripple verifier 修正）

## Selfhost compiler の debug build 対応

`vibe/compiler/` で linked debug build が動作するようになった (2026-03-20)。
ReExport チェーン解決、linked import alias re-export、func_import_count 修正済み。

### 既知のバグ

- [x] **WASI dep inline + linked import の codegen 不整合** —
  effect op import index の再計算が linked import 数を差し引いておらず、
  inline された `perform Fs::*` が別 library 関数に誤着地していた。
  linked build の effect import base を修正して解消。

- [x] **wasmtime --preload が WASI import を解決できない** —
  preload-unsafe (`Fs`/`Env`/WASI import 持ち) dep を library 化せず inline することで
  selfhost compiler の linked debug build は通るようになった。
  cached fast path は cached linked imports だけで再構成できない場合があるため、
  そのときは full compile にフォールバックする。

### 残タスク

- [x] Phase 1: transitive import 対応 (ReExport チェーン解決) — MoonBit host
- [x] Phase 2: prelude 分離（builtin でない関数のみ library 化）
- [x] Phase 3: HOF 選択的 inline
- [x] Phase 4: selfhost codegen の linked build 対応（下記）
- [x] WASI dep の inline codegen バグ修正
- [x] wasmtime preload の WASI 解決

### Phase 4: selfhost codegen の linked build 対応

selfhost compiler (`vibe/compiler/`) の codegen は monolithic のみ。
linked debug build を selfhost でも生成するには以下の移植が必要:

- [x] linked import の wasm import セクション生成 (`codegen/wasi/index.vibe`)
- [x] linked import の call 命令: fn_names/fn_indices 登録で resolve_func 対応
- [x] library mode: `library_mode=true` で全ユーザー関数 export
- [x] linked bundler: `compile_file_wasi_linked` (dep 分離 + linked imports)
- [x] library コンパイル: `compile_file_wasi_library` (dep を library .wasm に)
- [x] ReExport チェーン解決 (`resolve_reexport_chain` — 型定義 inline + 関数 linked import)
- [x] linked import alias 伝搬 (`let x = linked_fn` の capture/last 使用でも関数値化)
- [x] linked import alias の re-export (ExportLet + Ident → import re-export)
- [x] selfhost CLI で `build --debug` コマンド統合

目標: cached `vibe run vibe/compiler/index.vibe` を ~100ms に。

## CI 最適化

### CI プロファイル (2026-03-20)

9 並列ジョブ、wall time ~14min。

| ジョブ | 時間 | ステータス |
|--------|------|-----------|
| test (moon test + build parity + linked debug) | ~3min | 全 pass |
| wasm-compile-e2e (pattern match + WASM E2E) | ~14min | 全 pass (律速) |
| selfhost-gates (bootstrap, cutover, perf KPI) | ~4min | 全 pass |
| wasm-codegen-quick (probe, WAT, HTTP gates) | ~4min | 全 pass |
| 他5ジョブ | ~1-2min each | 全 pass |

### 完了

- [x] CI で wasm-codegen-integrity を3並列ジョブに分割 (16min → 14min)
- [x] `test-build-parity` を CI に追加
- [x] `test-fixtures-isolation` を CI に追加
- [x] `test-linked-debug-build` を CI に追加

### 残タスク

- [ ] wasm-compile-e2e の高速化（律速 ~14min）
- [x] selfhost dist validation 修正（`build_selfhost_dist.sh` の sample compile/run が通る）
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
- [x] wat_encoder: S 式完全対応（f32/f64, table/elem, br_table, call_indirect, float tokenizer）
- [ ] SIMD codegen: v128 命令の emit + lexer intrinsic 化
  - [x] SIMD scan primitives 実験 (skip_ws 7.7x, scan_ident 18x, find_byte 6.3x, memcmp 4.2x)
  - [ ] selfhost codegen に 0xFD prefix SIMD 命令 emit を追加
  - [ ] simd_skip_ws / simd_scan_alnum を builtin 化

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
