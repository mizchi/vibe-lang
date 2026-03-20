# TODO

Spec-locked decisions are tracked in `docs/spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## ビルドパイプライン

### 既知の制約

- cross-module string concat: library heap_ptr と user data offset の関係で一部不正
- funcref table の cross-module 共有は未実装（HOF inline で回避済み）
- WASI dep の monolithic inline で codegen 不整合（後述: debug build 対応セクション）
- wasmtime --preload が library module に WASI を提供できない（後述: debug build 対応セクション）

### 残タスク

- [ ] cross-module string concat の修正
- [ ] `vibe build --debug` を selfhost compiler で使えるようにする（後述）
- [ ] prelude を core module として事前コンパイル（builtin 関数の分離が必要）
- [ ] typecheck のインクリメンタル化（ripple query 改修）

## Selfhost compiler の debug build 対応

`vibe/compiler/` で linked debug build が動作するようになった (2026-03-20)。
ReExport チェーン解決、linked import alias re-export、func_import_count 修正済み。

### 既知のバグ

- [ ] **WASI dep の inline で codegen 不整合** — `cli_cache`, `module_loader`, `type_db` など
  WASI effect (Fs, Env) を持つ dep を monolithic inline すると、bundled AST の codegen で
  `local_set` の stack underflow が発生する (func validation error)。
  原因: inline された dep のコードで、ローカル変数管理か closure capture が
  linked imports 存在下で正しく機能していない。
  回避策: WASI dep は linked import のまま、`-W unknown-imports-default=y` でスタブ化。

- [ ] **wasmtime --preload が WASI import を解決できない** — wasmtime の `--preload` は
  ライブラリモジュールに WASI instance を提供しない。WASI import を持つ library .wasm は
  preload 時にインスタンス化できない。
  回避策: `-W unknown-imports-default=y` で未解決 import をスタブ化。
  WASI 関数を呼ぶパスが `_start` から到達しなければ動作する。
  根本解決案:
  - ライブラリの FS 呼び出しを entry module 経由のトランポリンに変換
  - wasm-merge で全モジュールを結合してから実行
  - component model linking を使う

### 残タスク

- [x] Phase 1: transitive import 対応 (ReExport チェーン解決) — MoonBit host
- [ ] Phase 2: prelude 分離（builtin でない関数のみ library 化）
- [ ] Phase 3: HOF 選択的 inline
- [ ] Phase 4: selfhost codegen の linked build 対応（下記）
- [ ] WASI dep の inline codegen バグ修正
- [ ] wasmtime preload の WASI 解決

### Phase 4: selfhost codegen の linked build 対応

selfhost compiler (`vibe/compiler/`) の codegen は monolithic のみ。
linked debug build を selfhost でも生成するには以下の移植が必要:

- [x] linked import の wasm import セクション生成 (`codegen/wasi/index.vibe`)
- [x] linked import の call 命令: fn_names/fn_indices 登録で resolve_func 対応
- [x] library mode: `library_mode=true` で全ユーザー関数 export
- [x] linked bundler: `compile_file_wasi_linked` (dep 分離 + linked imports)
- [x] library コンパイル: `compile_file_wasi_library` (dep を library .wasm に)
- [x] ReExport チェーン解決 (`resolve_reexport_chain` — 型定義 inline + 関数 linked import)
- [ ] linked import alias 伝搬 (`let x = linked_fn` → fn_indices 登録)
- [ ] linked import alias の re-export (ExportLet + Ident → import re-export)
- [ ] selfhost CLI で `build --debug` コマンド統合

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
- [ ] selfhost dist validation 修正（`no functions found to compile` バグ）
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
