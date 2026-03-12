# Done

Completed items archived from `TODO.md`.

## 2026-03-10

- **Selfhost compiler を manifest / cache 前提へ再編**
  - `selfhost_sources_manifest.tsv` を source 順序の単一根拠にし、bundle 生成と `module_loader` の compiler root 列挙を一致させた
  - `TypeDb` cached compile API と cache probe を selfhost public API に追加し、strict-recursive selfbuild KPI に warm reuse 指標を載せた
  - `type_db.vibe` / `ripple` の selfhost 解決と `codegen.vibe` wrapper の validate failure を直し、strict-recursive selfbuild を維持したまま compiler 分割を進めた
  - ADR-0022 で selfhost CLI / I-O boundary を固定し、selfhost compiler 本体は pure compile API に留める方針を明文化した
  - host `src/cmd/vibe` 側も `src/loader` の `*_into` API と root 単位 `VibeDb` cache で `check` / `test` loop の warm reuse を持てるようにした
  - final artifact cache の key を entry path 非依存に寄せ、`program_source` / `merged_source` fingerprint で別 entry 間の warm codegen reuse まで通した
  - `db_merged_source` も fingerprint ベースで entry path 非依存にし、同一 merged source なら merge cache も別 entry 間で共有するようにした
  - `db_module_source` も fingerprint ベースで entry path 非依存にし、同一 module source なら codegen 手前の module-only parse/lower も別 entry 間で共有するようにした
  - `collect_source_groups_fs` と `db_grouped_merged_source` を追加し、manifest group 単位の grouped merge cache を FS compile path でも使うようにした
  - `selfbuild_compile_file_from_env` と `test_selfhost_cli_adapter.sh` を追加し、stage1 compiler artifact が selfhost CLI wasm を生成し、その CLI wasm 単体で実ファイル compile を通す artifact-only gate を追加した
  - `selfhost_cli_adapter.vibe` を `VIBE_INPUT` / `VIBE_OUTPUT` / `VIBE_ENTRY` 契約へ一般化し、`scripts/wasm_vibe_host_runner.js` に host-only string arena を追加して env-driven selfhost CLI adapter gate を通した
  - `scripts/wasm_vibe_host_runner.js` が wasm path 後ろの位置引数を `VIBE_INPUT` / `VIBE_OUTPUT` / `VIBE_ENTRY` へ写すようにし、env-driven adapter を host-backed CLI 契約でも実行できるようにした
  - `core/ast.vibe` を新設して `ast.vibe` は wrapper 化し、`vibe/compiler` の物理分割を互換維持つきで始めた
  - `syntax/token.vibe` / `syntax/float_format.vibe` / `syntax/lexer.vibe` / `syntax/parser.vibe` / `syntax/printer.vibe` を新設し、旧 root file は wrapper を残したまま syntax layer の切り出しを始めた
  - `core/types.vibe` と `checker/builtins.vibe` / `checker/checker_resolve.vibe` / `checker/checker_pattern.vibe` / `checker/checker.vibe` / `checker/checker_stmt.vibe` を新設し、旧 root file は wrapper を残したまま checker layer の切り出しを始めた
  - `core/bytebuf.vibe` と `codegen/wasm_emit/index.vibe`, `codegen/common_base/index.vibe`, `codegen/common_extractors/index.vibe`, `codegen/common_analysis/index.vibe` を新設し、旧 root file は wrapper を残したまま codegen layer の切り出しを始めた
  - `codegen/expr/index.vibe`, `codegen/builtin_bodies/index.vibe`, `codegen/wasi/index.vibe`, `codegen/gc/index.vibe` を新設し、旧 root file は wrapper を残したまま codegen main leaf も分割した
  - `runtime/eval_loader/index.vibe`, `runtime/index.vibe`, `loader/index.vibe`, `entry/compiler/index.vibe`, `entry/cli_cache/index.vibe` を新設し、旧 root file は wrapper を残したまま runtime/loader/entry layer も分割した
- **Release preflight に selfhost gate 群を統合**
  - `release-check` から `release-selfhost-gates` を実行し、`sync-vbundle`、selfhost bootstrap / strict-recursive KPI / cutover / check parity / golden WAT をローカル pre-release 導線へ接続
  - `sync_vibe_index_vbundle` と normalize batching helper の self-test を復帰し、preflight 補助 script の回帰も固定
- **Normalize / test runtime の運用回帰を修正**
  - normalize engine の standalone comment 行回りを修正し、multi-file normalize helper と回帰テストを追加
  - `fork_for_test` の loop fuel を保持するようにし、高い `VIBE_TEST_LOOP_FUEL` 既定値を導入
- **Compiler lexer codegen test の tail を削減**
  - 重複していた `codegen_lexer_import_test.vibe` を削除し、`codegen_lexer_test.vibe` は compact lexer fixture 1 本へ再編
  - compiled backend でも `120s timeout` を超えず、special-case の interpreter fallback なしで完走する状態に戻した
- **MapBuilder canonical naming cleanup を仕上げ**
  - language tour eval task と codegen comment を `MapBuilder::*` に統一
  - desugar 側は canonical 名と legacy alias の両方を non-command name として扱い、互換期間中の shell rewrite 回帰を防止

## 2026-03-12

- **Strict-recursive selfbuild を lean stage2 target で復帰**
  - `selfbuild_runtime_entry.vibe` を lean stage2 runtime target に切り出し、`selfbuild_runtime_entry_bundle.vibe` から source を読む形へ整理した
  - `selfbuild_compile_stage2` は `compile_source_wasi_only(..., "selfbuild_entry")` で stage2 target を直接焼くようにし、stage1 artifact からの stage2 compile を source-group 依存なしで通した
  - `just test-selfhost-wasi-selfbuild-kpi 300` は strict-recursive mode で `recursive=1`, `stage2_run=0`, `total=11s` に復帰した
- **JS host 依存なしの Preview2 selfhost CLI gate を追加**
  - `selfhost_cli_component_entry.vibe` を string-lift component export (`compile_cli_request`) として追加し、`len:<entry>` / `chunk:<entry>:<index>` 契約で compiled wasm bytes を返すようにした
  - `scripts/test_selfhost_cli_component_preview2.sh` は wasmtime Preview2 だけで selfhost component を実行し、復元した sample wasm を validate/run して `42` まで確認する
  - `release-selfhost-gates` も JS host 前提の fixed adapter preview2 gate ではなく、この component-only gate を通すように更新した
  - selfhost `compile_wasi_module` は pure sample で未使用の `vibe::env-get` / `args-len` / `args-get` / `fs_*` import を出さないようにし、component から復元した sample wasm を wasmtime 単体でそのまま実行できるようにした
- **Preview2 selfhost CLI を配布形へ整理**
  - `scripts/build_selfhost_cli_preview2_component.sh` で selfhost component/WIT を build し、`scripts/run_selfhost_cli_preview2_component.sh` が `compile-cli-request` 契約を使って input file -> output wasm を復元する
  - `scripts/test_selfhost_cli_preview2_package.sh` を追加し、build/run/validate/run=42 を package gate として固定した
- **Preview2 selfhost CLI の command world 配布形を追加**
  - `selfhost_cli_command_entry.vibe` は `compile_cli_hex(source, entry-name)` を string-lift export として公開し、command adapter が one-shot で wasm bytes を取り出せるようにした
  - `src/codegen/component_codegen.mbt` と `src/runtime_compile/compile.mbt` を更新し、component string-lift が string result を正しく retptr ABI で返せるようにした
  - `scripts/build_selfhost_cli_command_component.sh` は Preview2 `wasi:cli/command` adapter component を組み立て、`scripts/test_selfhost_cli_command_component.sh` は stdin=source / argv[-1]=entry / stdout=wasm の command world で sample compile -> wasm validate -> run=42 を固定した
  - `release-selfhost-gates` に `test-selfhost-cli-preview2-package` と `test-selfhost-cli-command-component` を追加し、配布 gate を pre-release 導線へ統合した
- **Preview2 selfhost CLI の direct fs/argv component 配布形を追加**
  - `selfhost_cli_direct_component_entry.vibe` は `compile-cli-hex(source, entry-name)` だけを export する専用 plug component として build できるようにした
  - `scripts/build_selfhost_cli_direct_component.sh` はその plug component を Preview2 filesystem adapter component と compose し、`run-cli-request(input-path, output-path, entry-name)` surface の distributable component を生成する
  - `scripts/test_selfhost_cli_direct_component.sh` は input file -> output wasm -> wasm validate -> run=42 を direct fs/argv gate として固定し、`release-selfhost-gates` に `test-selfhost-cli-direct-component` を追加した
- **Stage1 core wasm 直接の artifact-only selfhost compile gate を完成**
  - `selfbuild_cli_env_entry` / `selfbuild_cli_args_entry` の両方で、stage1 core wasm 自体が real input を compile し、生成 wasm が `run=42` まで通ることを確認した
  - `scripts/test_selfhost_cli_adapter.sh` は `selfbuild_write_cli_adapter` 経由ではなく、stage1 core wasm をそのまま selfhost CLI artifact として叩く gate に切り替えた
- **Selfhost CLI adapter の compile 入力を grouped closure へ縮小**
  - `selfhost_cli_adapter_sources` / `selfhost_cli_adapter_source_groups` を bundle に追加し、adapter 専用 closure を compiler 全量 source から切り離した
  - stage1 probe で adapter closure は `68 sources / 9 groups -> 24 sources / 5 groups` まで縮小できることを確認した
- **Selfhost compile path に pre-codegen DCE を導入**
  - `core/dce.vibe` を新設し、closure/grouped compile の両方で `compile_wasi_module` 前に unreachable def を pruning するようにした
  - `compiler_cache_test.vibe` に unreachable broken def を codegen 前に落とす回帰を追加した
- **Selfhost adapter bundle 生成の exact source を補強**
  - bundle 生成時に adapter merged source の先頭空行を除去し、bundle self-test で regression を固定した
  - exact merged source は flat source としては duplicate declaration を含み不正だと切り分け、`module_source` 経由の compile path を次段の本命にした
- **Selfhost perf KPI の stable case set を固定**
  - `bench/selfhost_perf/cases.txt` と `bench/selfhost_perf/kpi_cases.txt` から `vibe/compiler/index.vibe` を外し、default/KPI とも stable 5-case set に揃えた
  - `just test-selfhost-perf-gate` の既定閾値を current 実測に合わせ、compile 約4.6x / check 約2.9x の現状を継続観測できる状態へ戻した

## 2026-03-09

- **Selfhost WASI selfbuild (P5/S1-S5) 完了**
  - compiler API export、`compile_source(_wasi)`、module loader、bundle source compile を selfhost 側へ統合
  - strict-recursive selfbuild が通過し、stage1 artifact が stage2 を直接コンパイル可能になった
  - `test-selfhost-wasi-selfbuild` / KPI variant と GitHub Actions gate まで接続済み
- **Compiled WASM backend 回帰を解消して `just test` 全通復帰**
  - float/string/map equality、map builder overwrite、nested let record destructuring、perform/resume fallback、compiled test wrapper の alias/helper chain 回帰を修正
  - compiled integration 657/657 pass に復帰
- **wasm-gc bundling / goldens 整理**
  - wasm-gc backend は `for-in` を直接 lowering するため、DCE で legacy `iter_*` helper を保持しない経路に分離
  - WAT fixture / golden WAT / bench snapshot を現在の dynamic numeric codegen に更新
  - 一時 repro は `cli_wbtest` の回帰テストへ吸収し、不要生成物は削除

## 2026-03-08

- **Selfhost checker 機能差分 T1–T20 全完了** (318+ tests across 20+ files)
  - T1: normalize_type (26 tests), T2: pattern checking (13), T3: unify (22), T4: effects (19)
  - T5: desugar (14), T6: DCE (13), T7: error reporting (20), T8: checker_stmt (6)
  - T9: struct field (12), T10: trait system (18), T11: unify 強化 (30)
  - T12: monomorphization (10), T13: purity analysis (28), T14: builtin types (27)
  - T15: symbol indexing (16), T16: capture safety (20), T17: desugar 強化 (14)
  - T18: warning system (14), T19: LSIF export (12), T20: builtin handlers (31)
- **MoonBit テスト移植完了**: ポータブルな 41 テストを selfhost に移植
  - checker_normalize +6, checker_purity +10, checker_builtins +11
  - checker_trait +4, checker_capture +4, checker_error +6
  - 移植不可: typecheck_env_lifecycle/namespace/export, subtype, type_index, vibe shell desugar, monoify_module (MoonBit 固有機能依存)
- **Compiler Review Backlog**: `compile_expr` 責務分割 (CompileCtx struct 導入, パラメータ 25→6)
- **Language**: variant 安定 ID (type_index << 16 | variant_index)

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
  `String::join`, `Lines::parse`/`Lines::stringify`, `Json::parse`/`Json::stringify`, `Json::parse_lines`/`Json::stringify_lines`,
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
- **Prelude API Consistency**: prelude HOF 引数順を collection-first 統一、Array::find を Option 化、Map::get_or/assert_eq/Array::contains/Array::sort/Map::map/Map::filter/Array::join 追加、generics 移行。
- **Playground** (completed items): ブラウザ eval プレイグラウンド作成、GitHub Pages 自動デプロイ CI、リアルタイム diagnostics 表示。
- **Self-host Compiler Phase 1–6**: lexer/AST/parser/printer/stmt/fixture/type checker/interpreter 完了（~350 tests）。HM 型推論 + let-polymorphism、trait 制約解決、tree-walking eval、import 仮想 FS。
- **Self-host Compiler pain points**: cascading diagnostics 根治、StateLocal/do ノイズ削減、printer while→for-in 移行。forward reference/string interpolation/multi-line string/iteration helper 確認済み。
- **Documentation**: syntax-reference, effects guide, modules guide 完了。
- **Language Features** (completed items): object pipeline operators on typed rows、syntax profile controls、sh_lines host-backed execution strategy。
