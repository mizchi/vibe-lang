# Done

Completed items archived from `TODO.md`.

## 2026-03-07

- **WASM eval interpreter 大幅拡張**: block stack ベースの制御フロー（block/loop/br/br_if）、global.get/set、i64.load/store、i32.load8_u、内部関数呼び出し（cabi_realloc 等）の再帰実行、型セクション/関数セクションパースによる正確なパラメータ数取得
- **WAT disassembler 拡張**: global.get/set、i64.load/store オペコード対応、グローバルセクション(id=6)のパース・レンダリング
- **GC codegen 型サポート拡張**: Array(T)→gc array ref、Func→funcref、Param(型パラメータ)→anyref、Num→I64、Named with args(Option等)→anyref fallback
- **codegen: enum ctor tag double-counting fix**: scan_needs_stmt と compile_stmt の両方で tag が振られるバグを修正
- **codegen: compile_expr の共通ヘルパー抽出**: emit_ctor_obj_nullary, emit_ctor_alloc_header, emit_ctor_field_store, emit_tagged_ptr, emit_direct_call_post, emit_closure_create, emit_lambda_capture_prologue, record_lambda_meta, emit_letrec_backpatch を codegen_common.vibe に統合（codegen.vibe -131行, codegen_gc.vibe -127行）
- **codegen: EMatch の共通ヘルパー抽出**: emit_pat_condition, emit_ctor_field_bindings, emit_tuple_field_bindings を codegen_common.vibe に統合

## 2026-03-06

- **Self-host WASM Codegen P4**: lexer.vibe WASM compilation 完了、dual backend (linear memory + wasm-gc)、closure 実装（lambda lifting, call_indirect, mutable capture ref cells）、ELetRec self-reference backpatch
- **Selfhost Cutover Phase 0-5 完了**: MoonBit 依存を bootstrap 専用へ縮退、selfhost compiler CLI 契約統一、出力同値性 gate 化、CI 統合

## 2026-03-01

- Gate 5: full self-host e2e テスト
  - `vibe/compiler` の実ソースファイルを VibeDb → compile_module → eval_module パイプラインで実行
  - 4 テスト: token enum import、lex→tokens、lex→parse→print roundtrip、meta-circular eval pipeline
  - `index.vibe` re-export は型チェッカー制約により個別ファイル直接 import で回避

## 2026-02-18

- Remove `try/catch` and `await` syntax from the compiler.
  `handle` expression replaces try/catch; `await` removed (async fn uses implicit await).
  All 30+ files updated across parser, core, checker, runtime, codegen, frontend, CLI.

## 2026-02-15

- Split backend capability errors from language-level errors.
  Added `BackendLimit(backend~, feature~)` to `WasmGenError`, structured `user_message()`,
  migrated ~30 codegen sites.
- Implement Text/Object conversion builtins:
  `string_join`, `from_lines`/`to_lines`, `from_json`/`to_json`, `from_jsonl`/`to_jsonl`,
  JSON accessors with opaque `Json` builtin type.
- Generalize symbol/type/signature indexing beyond vibe:
  `language_id` in `AdvancedGraphDef`, language-aware index keys, multi-language test.
- Harden PosixMode compatibility guardrails: 7 regression tests.
- Graph-index benchmarks: snapshot query **2492x** faster than CLI-like baseline.
- `loop` expression with explicit tail-call optimization (WASM block/loop/br).
- Pattern-match ergonomics: `let Pat = expr else { body }`.
- Int model: 62-bit tagged range, hex literal support (0xFF).
- Import/re-export simplification: source-qualified re-export (`export <module-ref> { ... }`).
- Removed `.vibe` fallback-to-cwd on root mkdir failure.
- Bundle size: fixed importer namespace import resolution, 7 codegen bugs for
  Double/closure/62-bit tagged values. Importer totals: 14226 bytes (4/4 compiling).

## 2026-02-14

- Cross-module trait import/export resolution stabilized.
- Reserved-keyword escape/raw identifier support.
- Function-to-type-member forwarding boilerplate reduction.
- Linear-time array construction primitives (`ArrayBuilder`/`push`).
- First-class `Char` and char literals.
- `String` / `Bytes` builder APIs.
- Formatter/lint quickfixes for grammar sharp edges.

## 2026-02-13

- Desugar ambiguity diagnostics for postfix/property access.
- `vibe explain-import <entry>` for lock lookup visualization.
- Trait openness diagnostics (`[TROP001]`/`[TROP002]`/`[TROP003]`).
- `eval` persistence mkdir for nested DB/export paths.
- `vibe new` seeds `vibe/prelude` + `vibe/json` + `vibe/base64` + `vibe/sha1` from nearest ancestor.
- Unknown namespace diagnostics in import resolution.

## 2026-03-01

- **Self-host Compiler Gate 4: 依存計算と incremental checker 本線化**
  - `TypeDb`（`RippleDb` + `TypeEnv` キャッシュ）による fingerprint ベース incremental 型検査
  - cross-module 型伝播: import 先の型を `CtInt` 等で正しく解決（`CtUnknown` fallback なし）
  - cold/warm 結果一致テスト、差分更新テスト（変更モジュール＋依存元のみ再計算）
  - ベンチマーク: warm 0.04µs / cold 8450µs（~210,000倍高速化）
  - 依存抽出を AST ベースに移行（`collect_import_deps` が `SImport`/`SReExport` 直接抽出）
  - `vibe/x/ripple/` 削除→ `vibe/compiler/ripple/` 一本化
  - `vibe/compiler/path.vibe` 削除→ `vibe/module/path.vibe` 一本化

## 2026-02-28

- **Workflow UX Audit**: eval/finalize の相対パス解決を cwd 基準へ統一、shell-stdin --help 対応。
- **Pipe-first Namespace & Symbol Migration (ADR-0020)**: `recv.method(...)` 廃止、`|>` ファースト体系へ移行。`.` を member access 専用化、namespace 正規形を `/pkg@version/module/Type::symbol` に統一、library 一括移行。
- **Prelude Namespace Migration**: `vibe/prelude` を常時解決 namespace に固定。builtin 依存縮小、finalize 出力の normalize 保証、eval UX 改善（`--test-for` 候補提示、相対パス基準明確化、scratch DB 警告分離）。
- **Import/Export Model Refactor**: `use`/`declare` 廃止。`import <ref> {}`/`export <ref> {}`/`internal export`/`extern let %` 導入。library 一括変換。
- **Compiler Refactoring**: type_call/compile_call をカテゴリ dispatch 化、MonoifyContext 拡張、compile_expr ノード別分割、AST walker 共通化、checker global state session 化。
- **CLI / Normalize**: normalize_engine を pass 単位分解、専用テスト追加、オプション解析厳格化、`--check` 非破壊化。
- **vibe/ Library UX**: prelude API 設計方針明文化、命名ゆらぎ整理、`Iterable` trait 導入 + `for-in` 統合、collection 型汎用化（Map/Set trait-bound）、HTTP/Socket 高レベル API、Result ベース API 移行方針（ADR-0018）。
- **vibe/ API Ambiguity Audit**: index.vibe 公開 API 集約、socket high/low 分離、compiler AST 単一ソース化、compiler テスト高速化（-27%: block_has_bindings fast path、has_alias_prefix_rt ガード、cheap pure builtin キャッシュスキップ）、公開面ノイズ削減。
- **Runtime**: VibeDb を import/query/graph/diagnostic 単位に分割、runtime 責務整理、resume one-shot 二重実行解消、perform サイト識別強化。
- **Testing**: serialize/deserialize round-trip property test 追加。
- **Compiler / Language Incident Follow-up**: eval_report_json バリアント取りこぼし修正、旧 import 記法 migration hint、bundle-size baseline 分離。
- **Prelude API Consistency**: prelude HOF 引数順を collection-first 統一、array_find を Option 化、map_get_or/assert_eq/array_contains/array_sort/map_map/map_filter/array_join 追加、generics 移行。
- **Playground** (completed items): ブラウザ eval プレイグラウンド作成、GitHub Pages 自動デプロイ CI、リアルタイム diagnostics 表示。
- **Self-host Compiler Phase 1–6**: lexer/AST/parser/printer/stmt/fixture/type checker/interpreter 完了（~350 tests）。HM 型推論 + let-polymorphism、trait 制約解決、tree-walking eval、import 仮想 FS。
- **Self-host Compiler pain points**: cascading diagnostics 根治、StateLocal/do ノイズ削減、printer while→for-in 移行。forward reference/string interpolation/multi-line string/iteration helper 確認済み。
- **Documentation**: syntax-reference, effects guide, modules guide 完了。
- **Language Features** (completed items): object pipeline operators on typed rows、syntax profile controls、sh_lines host-backed execution strategy。
