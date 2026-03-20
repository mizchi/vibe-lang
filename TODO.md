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

- [x] Phase 1: transitive import 対応 (ReExport チェーン解決)
- [ ] Phase 2: prelude 分離（builtin でない関数のみ library 化）
- [ ] Phase 3: HOF 選択的 inline
- [ ] WASI dep の inline codegen バグ修正
- [ ] wasmtime preload の WASI 解決

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
