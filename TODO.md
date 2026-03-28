# TODO

Spec-locked decisions are tracked in `docs/spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## 0.2.0 roadmap: wasm-gc main backend gate (2026-03-27)

- [x] `just test-wasm-gc-mainlane-e2e` を green にする
  - この acceptance suite を通せたら `wasm-gc` を main backend 候補として扱う
  - 現在の gate: closure capture / returned closure call / `for-in` runtime / string runtime
  - 実体: `src/tests/vibe_wasm_gc_mainlane_e2e_test.mbt`
- [x] 上記 gate を通した変更で `--wasm` の既定を `wasm-gc` に切り替える
  - `--wasm` → `WasmGc`, 旧 linear は `--wasm-linear` で利用可能
- [x] gate 緑化後に `just test` / CI shard へ組み込み、experimental 扱いを解除する

## 0.1.0 release sign-off (2026-03-24)

単一 `.wasm` artifact で build/check/compile/run の主要導線が通る状態までは来ている。
直近の Main lane は実装追加より release sign-off の確定が中心。

### 実装単純化 (2026-03-24)

- [x] effect surface を `TyFn/CtFn + with {Name}` に寄せ、named effect を canonical 表現にする
- [x] `module_graph/path` helper を共通化し、loader/runtime/selfhost entry の path 解決重複を削除
- [x] loader の `_build/debug_*` / manifest helper debug 書き込みを撤去
- [x] `special_manifest_header_deps` を撤去し、manifest 依存は実ソース header から組み立てる
- [x] persistent module header / type env codec を shared helper に統一
- [x] `index.vibe` の probe / `cli_cache` 重複 export を削減し、cache helper 経由へ寄せる
- [x] probe export は `selfhost_cli_probe_entry` に分離し、0.1.0 canonical entry は直接実行可能な `selfhost_cli_support.vibe` とする

### 直近の完了

- [x] `test-selfhost-bootstrap`
- [x] `test-selfhost-wasi-selfbuild-kpi`
- [x] `test-selfhost-cli-core`
- [x] `test-selfhost-cli-component-preview2`
- [x] `test-selfhost-cli-preview2-package`
- [x] `test-selfhost-cli-command-component`
- [x] `test-selfhost-cli-command-parity`
- [x] `test-selfhost-cli-direct-component`
- [x] `test-selfhost-cli-direct-parity`
- [x] `test-selfhost-check-preview2-package`
- [x] `test-selfhost-check-command-component`
- [x] `test-selfhost-check-command-parity`
- [x] `test-selfhost-check-direct-component`
- [x] `test-selfhost-check-direct-parity`
- [x] `test-selfhost-cutover`
- [x] `test-golden-wat`
- [x] `just ci-contract-moon`
- [x] `just ci-contract-native`
- [x] `.github/workflows/ci.yml` の `selfhost-gates` を `just release-selfhost-gates` 基準に揃える
- [x] component/direct selfhost gate 用の CI 前提 (`Rust + wasm32 + wasm-tools + wac`) を明示する

### 残タスク

- [x] 実使用ベースの `0.1.0` usability sign-off を 1 周通す
  - `docs/report/0-1-0-usability-signoff.md`
  - [x] `vibe shell`
  - [x] `vibe check`
  - [x] `vibe run`
  - [x] `vibe build`
  - [x] stale `index.lock` recovery / migration の扱いを決める
  - [x] selfhost dist sample compile/run
- [ ] GitHub Actions 上で `just ci-selfhost-gates-shard bootstrap` を通し、selfhost bootstrap の最終ログを固定
- [x] `just release-check` を最新 HEAD で通す
  - local `release-check` は 0.1.0 supported surface に絞る
  - broad compiled package sweep は `just test-vibe-package-suite` へ分離
  - heavy `wasm_opt` / `wasm_runtime` suite は `just test-wasm-heavy` に残し、release gate からは外す
- [ ] `build-selfhost-dist` を latest HEAD で cold build し、sample compile/run を再確認
  - [x] latest HEAD の `build_selfhost_dist.sh` は pass（`wasm-opt` failure 時 raw fallback を含む）
  - [ ] strict な cold-host 条件（既存 host CLI / dist artifact 非依存）でも再確認
- [x] `0.1.0` の supported surface を文書化して freeze
  - `docs/adr/0033-selfhost-0-1-0-release-profile.md`
  - linear/WASM selfhost dist を正式対象
  - GC backend は experimental
  - advanced effect/WIT mapping は experimental
- [ ] selfhost check parity の host `Abort trap: 6` を原因特定して潰す
  - gate 自体は pass しているが、host `vibe check` の失敗時終了が abort に見える
  - `scripts/test_selfhost_check_command_parity.sh`
  - `scripts/test_selfhost_check_direct_parity.sh`

### 0.1.0 gate 外に出した broad package sweep

- [ ] `just test-vibe-package-suite` の compiled-only parity を戻す
  - runtime/effect 系 unsupported:
    `vibe/path`, `vibe/io`, `vibe/fs`, `vibe/time`, `vibe/process`,
    `vibe/shell`, `vibe/x/rlm`, `vibe/socket`
  - current pure regressions:
    `examples/string_add_test.vibe`
    `vibe/json/test_json_import.vibe`
    `vibe/json/jsonrpc_test.vibe`
    `vibe/x/url_test.vibe`

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

## Selfhost CLI parity

- [x] `selfhost_cli_command_component`
  command-shaped component の gate は復旧済み。
  parity は same-instance adapter ではなく preview2 export を fresh invoke する経路で確認する。
  `scripts/test_selfhost_cli_command_parity.sh` は `no-dce` の代表ケースだけを残して runtime を抑える。

- [x] `selfhost_cli_direct_component`
  `Fs.Exists` import leak と closure payload decode/byte handling を修正済み。
  `scripts/test_selfhost_cli_direct_component.sh` と
  `scripts/test_selfhost_cli_direct_parity.sh` の両方が pass。

## Selfhost check parity

- [x] `selfhost_check_preview2_package`
  check surface の preview2 package は復旧済み。

- [x] `selfhost_check_command_component`
  command-shaped check component と parity gate は pass。

- [x] `selfhost_check_direct_component`
  direct filesystem check component と parity gate は pass。

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

- [x] wasm-compile-e2e の高速化（3-shard 並列化で ~5min に短縮）
- [x] selfhost dist validation 修正（`build_selfhost_dist.sh` の sample compile/run が通る）
- [x] P3: minify_zlib 個別対策 (#13) — テスト有効化、CI ジョブ追加

## カバレッジ

目標: branch coverage 70%

- [x] checker/parser/printer/lexer/builtins の全 variant カバー (全 Expr/Stmt/Pat/Type variant が全パスで処理済み)
- [ ] normalize/DCE/loader のテスト拡充
- [ ] CI にカバレッジ gate を組み込み

## Effect System

- [x] 関数呼び出しを跨ぐ perform の handler dispatch — インタプリタ完了
- [x] 関数呼び出しを跨ぐ perform の handler dispatch — インタプリタ + WASM compiled 両方で動作
- [x] throw(x) → Perform("Error", "Throw", [x]) desugar
- [x] suberror の throw を Error effect 経由に統一
- [x] Net → fine-grained capability effects (Http, Socket 個別化、Net は super-effect)
- [ ] WASI P3: effect → WIT マッピング、vibe serve コマンド

## vibe/wasm ツールチェーン

- [x] wasm_opt: directize, call forwarding, signature pruning (remove_unused_types で実装済み)
- [x] wasm_runtime: テスト拡充 (64→81テスト、i64 ops + type conv + control flow)
- [x] wat_encoder: S 式完全対応（f32/f64, table/elem, br_table, call_indirect, float tokenizer）
- [ ] SIMD codegen: v128 命令の emit + lexer intrinsic 化
  - [x] SIMD scan primitives 実験 (skip_ws 7.7x, scan_ident 18x, find_byte 6.3x, memcmp 4.2x)
  - [ ] selfhost codegen に 0xFD prefix SIMD 命令 emit を追加
  - [ ] simd_skip_ws / simd_scan_alnum を builtin 化

## 言語仕様の整合性

- [x] function type / effect 表現の AST 統一 (Raise→Perform 統一で解消)
- [x] method syntax の仕様固定 (expr.field = property access, expr.method() = error, Type::method() = static call)
- [x] 演算子型規則の checker/evaluator 一致
- [x] 文字列補間を typed AST 化 (Expr::StringInterp)

## モジュール分離

- [ ] ルート制約の緩和（兄弟ディレクトリ import 許可）
- [ ] `vibe/types/`, `vibe/parser/` の分離

## Self-Host Compiler

- [ ] MoonBit host CLI を bootstrap 専用へ縮退
- [ ] selfhost perf gap を cutover 水準まで詰める
- [ ] GC backend セルフコンパイルで ~350KB 配布形 (#59)
  - [x] **P0: Enum/Variant codegen** — per-variant struct `[i32 tag, payload...]`, ref.test + ref.cast pattern match
  - [x] **P1: Bytes mutable ops** — struct `(len, cap, data)` wrapper, 12 ops (new/push/set/get/append/blit/fill/slice/concat/from_array/to_array/length)
  - [x] **P2: Record/Struct pattern** — Pat::Struct or-pattern with Pat::Record, Tuple binding
  - [x] **P3: String ops** — 9 ops (index_of/last_index_of/contains/starts_with/ends_with/trim/replace/split/join)
  - [x] **B1: Bitwise ops** — __bit_and/or/xor/not/lshift/rshift (i64 instructions)
  - [x] **B2: Array ops** — Array::length/get/set/push/slice/concat, ArrayBuilder::new/push/freeze
  - [x] **B3: Type conversions** — Int::to_string, Bool::to_string, __to_string, Int::to_double, Double::to_int, String::from_char_code
  - [x] **B4: Func return type** — enum_ctor_names を free-var filter に追加, let rec pre-bind
  - [x] **B5: Type coercion** — if kind mismatch → gc_common_kind, unknown Named type → EqRef fallback
  - [ ] **B6: Effect system** — throw/handle/perform の GC codegen (85+ files が依存、selfhost 必須)
  - [ ] **B7: let rec closure self-ref** — lifted fctx に closure_call_types 伝搬
  - [ ] **B8: MapBuilder** — Map builder の GC 表現
  - [ ] **B9: Pipe operator** — `|>` の GC codegen (24 files)
  - [ ] **P4: selfhost compile E2E** — `vibe/compiler/index.vibe` を `--wasm-gc` でコンパイル
  - [ ] **P5: DCE + wasm-opt** — 未使用コード除去と最適化で ~350KB 目標
- [ ] `vibe/compiler` の論理分割

## Interpreter 廃止

- [x] `vibe run` / `vibe test` の既定 backend を compiled に寄せる
- [x] interpreter backend を `VIBE_ENABLE_INTERPRETER=1` の明示 opt-in にする
- [x] `bench` の interpreter backend / fallback も `VIBE_ENABLE_INTERPRETER=1` 前提に寄せる
- [x] one-shot CLI でも `run/test` の wasm cache を使って compiled 固定費を減らす
- [x] `bench` の generated wasm も content-addressed cache で再利用する
- [x] compiled test 失敗時の詳細取得を per-case compiled fallback に寄せる
- [x] internal `session-json` worker で同一 process の `check/test` cache 再利用口を作る
- [x] `run/check/test` は localhost session worker を既定利用し、`VIBE_USE_SESSION_HTTP=0` で無効化できるようにする
- [x] 長寿命 process で incremental compile cache を常用化
- [x] interpreter の public CLI surface を撤去
  - [x] `run/test` の自動 interpreter fallback を撤去する
  - [x] `bench` の自動 interpreter fallback を撤去する
  - [x] fallback 互換 env の参照を削除する
  - [x] `run/test` の明示 interpreter backend も削除する
  - [x] `bench --backend interpreter` を削除する
  - [x] `bench` の legacy expr mode (`--expr`, `--case`, `--cases`) を削除する
- [ ] compiled parity が揃ったので evaluator / interpreter 実装を削除
  - [x] `wasm-shell-stdin` で scalar let / late import / bool 行が stateful に動く
  - [x] 関数値 `let` 束縛は placeholder 表示に degrade して shell を継続する
  - [x] String 値は compiled REPL の repr transport で表示する
  - [x] Array / Map など composite 値の表示 transport を追加する
  - [x] 通常の `vibe shell` / `shell-stdin` を compiled session backend に切り替える
  - [x] `shell --ai` / `shell --tui` の evaluator 依存を整理する
  - [x] `cli_repl_js` の evaluator 依存を廃止する
  - [x] public CLI の `--syntax posix-*` shell 導線を閉じる
  - [x] `eval` command を public CLI から外す
  - [ ] `src/runtime/lib.mbt` の `Runtime::eval_script_with_mode` caller を 0 にする
  - [ ] host / selfhost evaluator 実装と専用 test を削除する
  - [x] 不要になった selfhost fixture smoke test を削除する
    - [x] `vibe/compiler/fixture_selfhost_test.vibe`
    - [x] `vibe/compiler/fixture_selfhost_roundtrip_test.vibe`
    - [x] `vibe/compiler/fixture_parse_test_support.vibe`
  - [ ] 不要になった interpreter/evaluator 専用 test を棚卸しして段階削除する
    - [ ] `vibe/compiler/eval_*` の fixed-string smoke / wrapper test を分類する
    - [ ] `test-selfhost-cache-probe` を compiled-only の gate へ載せ替えるか、release gate から外したまま整理する
    - [ ] `vibe/compiler/fixture_*_test_support.vibe` の export 面を絞って、重複 fixture test を減らす
    - [ ] host / selfhost で重複している evaluator smoke test を mainline test に統合する
    - [ ] coverage / bootstrap gate に必要な test だけ残す

## Release 運用メモ

- [x] local の `just release-selfhost-gates` は bootstrap を外し、日常の sign-off を軽く保つ
- [x] local の `just release-selfhost-gates` は selfbuild KPI も外し、bootstrap lane は CI と明示 target に閉じる
- [ ] selfhost bootstrap (`test-selfhost-bootstrap`) と selfbuild KPI (`test-selfhost-wasi-selfbuild-kpi`) は CI shard 専用 gate として運用する

## ユーザビリティ改善

- [x] 軽量 struct リテラル sugar `Type { ... }`
- [ ] `String` を `for-in` 対象にする
- [x] トレイトにメソッドシグネチャを許可 (trait Name { method(Type) -> Type })
- [x] `?` 演算子 (expr? → handle { expr } { Error(e) => throw(e) })
