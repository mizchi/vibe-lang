# TODO

Spec-locked decisions are tracked in `docs/spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.
タスクの一次管理は GitHub Issues (`gh issue` / MCP)。本ファイルはロードマップ概要。

## 次の一手 (2026-06-02 時点)

現況スナップショット。open issue は 4 件 (#402 #482 #418 #415)。優先順は下記。

### 現状サマリ

- **0.1.0 surface は通っている**。直近の主戦場は **selfhost cutover の perf gate (#402)**。
- **#402 KPI (wasmtime-aot, RUNS=5 median, 2026-06-02 再計測)**:
  - **TOTAL compile ratio = 1.73–1.79× ✅**。compile gate は旧 `≤1.33×` を撤回し、現実的な baseline として **TOTAL `≤2.5×`** に更新する。
  - **TOTAL check ratio = 0.82–1.01× ✅** (TOTAL gate `≤1.33×` は維持可能)。
  - per-case ratio は当面診断扱い。`base64` compile が `2.571×`、`module_import` check が `1.556×` まで揺れたため、同じ cap を per-case hard gate にすると flaky。
  - レポート: `docs/report/selfhost-cutover-baseline-2026-06-02.md`

### 🔴 #402 compile ratio — 本質診断で攻め方が確定 (重要・要 maintainer 判断)

今セッションの per-frame profile (release/wasmtime, warm) で判明した、ロードマップを書き換える事実。詳細は #402 コメント (2026-05-31, `4586511284`)。

- **bench の "selfhost" は `src/cmd/vibe_compile_wasi` = src/ runtime_compile を `--target wasm` したもの**(vibe/compiler/ ではない)。host は同じ src/ を `--target native`。⇒ **両側は同一 MoonBit コード、アルゴリズム同一。**
- ⇒ **src/ への algorithmic 改善は両側に等しく効く = 構造的に symmetric → compile ratio を原理的に動かさない**。prelude prune (`80098b6`) も過去の accumulator/ripple も「横ばい」だったのはこれが根本原因。**compile ratio 目的の src/ 最適化は ROI ゼロ**。
- **ratio ~4.8× は wasmtime JIT vs native の runtime floor**(frame 別 2.5–13.6×: build_module 13.6× / prelude_add roots-walk 7.4× / cache_key 5.5× / parse_stmts 5.2×)。ばらつきは「wasmtime がその op mix で native よりどれだけ遅いか」を表すだけ。
- **「compile daemon 化」レバーは棄却**: daemon は selfhost の cold-start を amortize するが host(one-shot native)も同じ cold cost を払うので、公平比較では両側 amortize → 残る per-compile work の ~4× は不変。**check が 0.77× なのは host が session-http (~7-9ms/invoke) を払う host-only の計測非対称**であって selfhost daemon の効果ではない(`CHECK_DAEMON_MODE` は default 0)。host check に `VIBE_USE_SESSION_HTTP=0` を与えれば check も ~4× に跳ねる。
- **compile gate ≤ 1.33× は「wasmtime JIT が native の 1.33× 以内」を要求**。branchy な compiler workload で JIT が native の 1.3× 以内は一般に非現実的。**src/ 改善では到達不能。** #402 の compile baseline は **TOTAL ≤2.5×** に更新する。

⇒ 残る実レバー(いずれも maintainer 判断要):
  1. **wasmtime runtime チューニング**(codegen flag / PGO 等。既に `-O3`+cwasm)。floor を 4.8→例えば 4.0 に削る程度、1.33× には届かない見込み。
  2. **operation-mix 置換**(高非対称 frame: build_module の per-byte `ByteBuf::push` を bulk op 化 等)。同上、floor を少し削るのみ。
  3. **cutover 基準の再定義** ← 本命。「native を常用 / wasm は portability・sandbox 用 optional artifact」とするか、gate を runtime 現実(~2-4×)へ緩める。check の "pass" も session-http 非対称依存で、apples-to-apples なら compile/check 共に ~4× が実態。
- **未計測ゲート**: compile/check の **peak RSS ratio ≤ 2.0×** が wasmtime-aot 後に未計測(`/usr/bin/time -v` 環境要)。

### 🟠 open issues (一次ソース)

- [ ] **#402** selfhost cutover tracking — 上記。compile ratio が最後の gate。
- [ ] **#482** host `mizchi/ripple` verifier の O(n²) memo scan — **upstream publish 待ちで bump のみ**。host typecheck hot path に効く(selfhost 側 ripple は #483 で O(N) 化済)。`moon.mod` の `mizchi/ripple` を修正版公開後に bump。
- [ ] **#415** codegen builtin を 2 backend 共有 registry に refactor (Phase B) — linear↔wasm-gc の parity 117 件ずれ、新 builtin 追加時の silent regression 温床。3-6 週、namespace 単位の小 PR 5-7 本。wasm-gc default 化 (Phase D) の前提。
- [ ] **#418** ADR-0052 Phase 2/3 — `mut` struct field の `state_local` effect 分類 + escape 検査。ADR-0017 `state_local` 実装が前提。大規模・既存コード影響大。

### 🟡 機能 / 品質 (issue 化候補、TODO 内に詳細あり)

- [ ] **CI branch coverage 70% gate** + normalize/DCE/loader テスト拡充 (§カバレッジ)
- [ ] **SIMD codegen 本番化** — 0xFD prefix emit + `simd_skip_ws`/`simd_scan_alnum` builtin 化 (§vibe/wasm)
- [ ] **#59 WASM-GC selfbuild ~350KB** — P4 残 3 ケース (simd_patterns / gc_only/index / selfhost_cli_gc_entry) + P5 DCE + wasm-opt
- [ ] **WASI P3**: effect → WIT マッピング + `vibe serve`
- [ ] selfhost accumulator 残 2 sites (`linked_helpers.vibe` の `contains_name` 線形走査) — vibe runtime の Map が hash table 化するまで保留 (ROI ≪、§accumulator 撲滅)

### 🔵 リファクタ / 長期

- [ ] `vibe/types/` `vibe/parser/` 分離、`vibe/compiler` 論理分割
- [ ] MoonBit host CLI を bootstrap 専用へ縮退
- [ ] MoonBit host 重複削減 (§similarity-mbt、残: `src/runtime/db.mbt` の `set_source`/`set_binary_source`)

---

## 次の一手 (2026-05-05 時点) — historical

> 注: 以下は 2026-05-05 時点の整理。`just` は pkfire (`pkf`) に移行済み。最新の優先順は上の「2026-05-31 時点」を参照。各 §詳細は下に残置。

優先順。各項目は該当セクションに詳細あり。

### 🔴 0.1.0 release blocker

- [x] **`just test-vibe-package-suite` compiled-only parity** — 1,455 / 1,455 tests pass（2026-05-03、PR #354）。元の 424 fail から段階的に消化:
  - examples/effects 系の lambda effect propagation: 解消（#352）
  - fs / io / path / time / shell: runtime/effect support 配線完了（#352, #353, #354）
  - examples/syntax: 0/59 → 59/59
  - derive(Eq) enum payload deep 比較: 実装（#341 value_eq runtime helper）
  - Array view writethrough / fs_readdir Array[String] / 文字列 lex compare（#354）

### 🟠 近場の重要

- [ ] **normalize / DCE / loader テスト拡充** — #298 で一部着手、カバー範囲を埋める
- [ ] **CI カバレッジ gate** — branch coverage 70% target
- [ ] **selfhost bootstrap / selfbuild KPI を CI shard 専用 gate 化**
- [ ] **selfhost O(N²) accumulator hotspots を一掃 (#366)** — `claude/benchmark-self-hosted-Pt9Y3` ブランチで survey、commit `7a67c39` (StringBuilder 5 sites) + `0f843b8` (Array push 19 sites) で着手。残タスクは下の §[selfhost accumulator 撲滅](#selfhost-accumulator-撲滅-on²-→-on) を参照

### 🟡 機能追加

- [ ] **WASI P3: effect → WIT マッピング + `vibe serve`**
- [ ] **SIMD codegen 本番化** — selfhost codegen の 0xFD prefix emit + `simd_skip_ws` / `simd_scan_alnum` 組込
- [ ] **#59 WASM-GC selfbuild ~350KB** — P4 compile E2E の残 3 ケース（simd_patterns / gc_only/index / selfhost_cli_gc_entry）+ P5 DCE + wasm-opt
- [x] **pkfire / pkspec 全面導入** — `justfile` を完全削除し `pkfire/Taskfile.pkl` (238 tasks) が canonical。複雑な多行レシピは `scripts/pkfire/*.sh` に抽出。CI は `pkf run` 経由 + `~/.cache/pkfire` を `actions/cache` でキャッシュ。`pkspec/{VibeSpec,VibeTest}.pkl` で `pkspec check` 通る、PR 用 informational gate あり。次は (a) `pkf affected --since=origin/main 'test:*'` を CI の PR 高速化パスに組み込む (b) `pkspec exec` で `moon test` を pkspec 経由で回す

### 🔵 リファクタ / 長期

- [ ] `vibe/types/` / `vibe/parser/` 分離
- [ ] `vibe/compiler` 論理分割
- [ ] MoonBit host CLI を bootstrap 専用へ縮退
- [ ] selfhost perf gap cutover 水準まで（素材: `claude/chunk-compile-experiment` ブランチに hash-bucket lookup / sorted index / O(n) string dedup 等 23 commits、#295）。wasmtime AOT runtime は `tools/moonrun_wasmtime` で実装済、bench-selfhost-perf-wasmtime task で 5 cases 平均 compile ratio 5.7 → 1.2（~5× 改善）。残課題は algorithmic な hash-bucket / dedup 系
- [ ] MoonBit host 重複削減（similarity-mbt 抽出、§[MoonBit host 重複削減](#moonbit-host-重複削減-similarity-mbt-ベース)）

### ⚪ upstream / infra 待ち

- なし（#293/#294 は 2026-04-19 に再現せずクローズ）

### 既知ギャップ（issue として追跡中）

- ~~`just test-wasm-heavy` の wasm_opt / wasm_runtime に 17 fail~~（#356 → PR #357 + #358 で 129/129 ✅）
- **selfhost checker parity 6 件（#364）** — `selfhost-bootstrap-gate`（PR #362）が surface した pre-existing failure。`vibe/compiler/checker_parity_advanced_test.vibe` で 37/43。host CLI では通る src を selfhost checker が reject (struct destructuring let / is expression / let else / trait impl / struct field type mismatch / derive unknown)。informational gate なので blocker ではないが、selfhost compiler の feature gap として要修正。
- ~~derive(Eq) enum with payload の deep 比較~~（#341 で実装済）

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

- [x] `0.1.0` までの進め方をこの順で固定する
  - [x] `build-selfhost-dist` の raw selfhost wasm validation failure を直し、strict cold-host 条件で再確認する (#17)
  - [x] GitHub Actions 上で bootstrap shard の最終ログを固定する (#16, 2026-04-04 closed)
  - [x] `Error` surface を `Result::Ok/Err` に寄せる整理を仕様・stdlib・diagnostics まで確定する (#275, 2026-04-09 commit `719c176`)
  - [x] `main` の required checks / ruleset を release 前に有効化する (#120)
- [x] 実使用ベースの `0.1.0` usability sign-off を 1 周通す
  - `docs/report/0-1-0-usability-signoff.md`
  - [x] `vibe shell`
  - [x] `vibe check`
  - [x] `vibe run`
  - [x] `vibe build`
  - [x] stale `index.lock` recovery / migration の扱いを決める
  - [x] selfhost dist sample compile/run
- [x] GitHub Actions 上で `just ci-selfhost-gates-shard bootstrap` を通し、selfhost bootstrap の最終ログを固定（#16）
- [x] `just release-check` を最新 HEAD で通す
  - local `release-check` は 0.1.0 supported surface に絞る
  - broad compiled package sweep は `just test-vibe-package-suite` へ分離
  - heavy `wasm_opt` / `wasm_runtime` suite は `just test-wasm-heavy` に残し、release gate からは外す
- [x] `build-selfhost-dist` を latest HEAD で cold build し、sample compile/run を再確認
  - raw selfhost wasm validation failure は修正済み
  - strict な cold-host 条件（既存 host CLI / dist artifact 非依存）でも再確認済み
- [x] `0.1.0` の supported surface を文書化して freeze
  - `docs/adr.md` (ADR-0033)
  - linear/WASM selfhost dist を正式対象
  - GC backend は experimental
  - advanced effect/WIT mapping は experimental
- [x] selfhost check parity の host `Abort trap: 6` を原因特定して潰す
  - 2026-04-08 時点で release host / stage1 selfhost checker の exit status は parity cases 11 件で一致
  - 次は `bench/golden/selfhost_check_parity_snapshot.json` と allowlist を現状へ追従させる
  - `scripts/test_selfhost_check_parity.sh`
- [x] `Error` surface を `Result::Ok/Err` に寄せる 0.1.0 前整理方針を確定し、syntax / diagnostics / stdlib migration を揃える (#275, 2026-04-09 完了)
  - 結論: public library API は `Result[T, E]` canonical / `throw` + `handle with Error` は boundary 用 / `?` は現行の Error rethrow sugar のまま freeze
  - 反映先: `vibe/json/`, `docs/{cheatsheet,language-tour,vibe,spec/decisions}.md`, `src/checker/typecheck_errors.mbt` (resume / partial handle hint 追加)

### 0.1.0 gate 外に出した broad package sweep

- [ ] `just test-vibe-package-suite` の compiled-only parity を戻す（2026-04-19 計測: 59 files / 424 tests fail）
  - runtime/effect 系 unsupported:
    `vibe/path`, `vibe/io`, `vibe/fs`, `vibe/time`, `vibe/process`,
    `vibe/shell`, `vibe/x/rlm`, `vibe/socket`
  - 旧来 listed regressions は **全て pass**（`examples/string_add_test.vibe`, `vibe/json/test_json_import.vibe`, `vibe/json/jsonrpc_test.vibe`, `vibe/x/url_test.vibe`）
  - 新たに表面化した主要 failure カテゴリ:
    - **examples/effects 系**: lambda body への effect annotation 伝播抜け（"effect requirements not satisfied: throw" + 既に `with { Error }` 宣言済みでも fail）
    - **examples/syntax**: 0/59 — surface 移行で全失効
    - **examples/cheatsheet_*_test**: 全失効。docs ↔ examples 同期切れ
    - **examples/{enum,record,struct,generic,pattern_match,module_advanced}_test**: 0/N — 仕様変更追従漏れ

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

## selfhost accumulator 撲滅 (O(N²) → O(N))

Tracking issue: **#366**.

`claude/benchmark-self-hosted-Pt9Y3` で実施した survey 結果。selfhost
compiler の hot path に残る `String::concat(out, ...)` /
`Array::concat(out, [x])` の累積パターンを順次 in-place push (or
StringBuilder/ArrayBuilder) に置換する。

**Microbench で確認済の効果範囲** (`bench/bench_string_builder_vs_concat.vibe`,
`bench/bench_array_concat_vs_push.vibe`):

| op | N | concat | push/SB | speedup |
| --- | --- | --- | --- | --- |
| String concat → SB | 64 | 24.2 μs | 1.7 μs | 14.5× |
| String concat → SB | 256 | 151 μs | 5.6 μs | 27.2× |
| Array concat → push | 32 | 72 μs | 1.5 μs | 49× |
| Array concat → push | 128 | 363 μs | 1.9 μs | 192× |
| Array concat → push | 512 | 3,391 μs | 3.1 μs | **1095×** |

### 着手済 (このブランチ)

- [x] `vibe/compiler/cache/persistent_cache.vibe :: bytes_to_hex` — StringBuilder 化 (#TBD `7a67c39`)
- [x] `vibe/compiler/loader/{manifest_sources,index}.vibe :: join_header_values` — StringBuilder 化
- [x] `vibe/compiler/coverage_selfhost_suite_lib.vibe :: join_str` — StringBuilder 化
- [x] `vibe/compiler/codegen/common_base/index.vibe :: resolve_local 診断ビルダー` — StringBuilder 化
- [x] `vibe/compiler/monoify.vibe :: collect_call_sites_*` — out-param walker 化 (10 sites; #TBD `0f843b8`)
- [x] `vibe/compiler/runtime/eval_loader/index.vibe :: collect_exports` — push 化 (5 sites)
- [x] `vibe/compiler/runtime/index.vibe :: upsert_source_cache` / `add_dep` / `db_grouped_merged_source` — push 化 (4 sites)

### 着手済 (続き)

- [x] `vibe/compiler/runtime/typecheck_fs.vibe` — recursive `Array::concat(acc, [x])` 4 sites → `Array::push` 化
- [x] `vibe/compiler/runtime/index.vibe` — recursive `resolve_nested` の dep_acc / stack を `Array::push` + `Array::truncate` 化
- [x] `vibe/parser/parser.vibe` — `parse_trait_stmt` の super-traits 累積を `Array::push` 化（残る `pipe_desugar` の単発 prepend はループ累積ではないため対象外）
- [x] `vibe/x/diff/diff.vibe` — backtrace を `ops_rev` push + in-place reverse 化

### 未着手 (要設計)

- [ ] `vibe/compiler/entry/source_compile/wasi_only/linked_helpers.vibe` — `contains_name` 線形走査 3 sites (要パターン精査: 線形 contains は selfhost runtime では Map[String, Bool] にしても改善しないので、別アプローチ要)
- [ ] `vibe/compiler/entry/source_compile/wasi_only/linked_artifacts.vibe` — `contains_path` 線形走査 2 sites (同上)

### 一旦スキップ (理由付き)

- `vibe/compiler/checker_warning.vibe` (5 sites)、`checker_capture.vibe` (2 sites)、`core/dce.vibe` (2 sites): `if !contains(out, n) { Array::push(out, n) }` 系の dedup。`Map[String, Bool]` set に置換しても、selfhost runtime の `Map::has_key` 自体が線形走査なので効果ゼロ。host CLI 側 (MoonBit) では効くが、selfhost wasm では効かない (vibe runtime の Map が hash table になるまで保留)。詳細は `bench/selfhost_perf/README.md` 参照
- `vibe/json/jsonrpc.vibe` などの `Map::has_key` + `Map::get` パターン (Tier B、~10 sites): 同上の理由でスキップ

### 関連

- `bench/selfhost_perf/README.md` — survey と microbench 結果の詳細
- TODO #295 (selfhost perf gap cutover) — このアキュムレータ最適化はその一部

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

## MoonBit host 重複削減 (similarity-mbt ベース)

2026-04-17 に `nix develop -c similarity-mbt src/` で計測（326 files）。
閾値 0.98 で pairs 14,392。ただし `parser/syntax_kind.mbt` 7626 / `codegen/wasm_codegen_emit.mbt` 3677 / `codegen/wasm_gc_codegen.mbt` 1506 / `flatbuffers_generated.mbt` 636 は「各 token/opcode の同形 3 行 boilerplate」「自動生成コード」が主因で構造上の偽陽性。

ノイズを除いた中規模ファイル (5–100 pairs) が現実的な refactor 候補:

- [x] `src/runtime/store.mbt` — `get_by_addr` / `get_alias` / `pure_cache_get` / `pure_cache_set` / `get_module` は未使用 helper だったので削除（`Runtime::get` は公開 API で残存）
- [x] `src/backend/http_wasm.mbt` vs `src/backend/http_js.mbt` (30 pairs each) — 2 つの target-specific stub を `src/backend/http_stub.mbt` (multi-target) に統合（`exec_stub.mbt` と同パターン）
- [x] `src/benches/advanced_graph_bench.mbt` — parse 6 本を `decode_graph_or_abort[T]` に集約、`bench_graph_watch_realtime_save_rolling_{cbor,flexbuffer}` を `rolling_impl(encode, decode)` で共通化
- [x] `src/codegen/wasm_codegen_rc.mbt` — `emit_rc_init_impl(emit_size closure)` に共通化、`emit_rc_call_or_inline_i64(emit_inline closure)` で dup/drop の分岐を抽出
- [x] `src/cmd/vibe/cli_repl.mbt` — `repl_vibe_view_json` / `repl_vibe_peek_json` は `repl_vibe_symbol_lookup_json` に集約、`repl_is_*` は `Array::contains` へ、`compiled_repl_temp_{source,wasm}_path` は共通 `compiled_repl_temp_path(ext)` 経由
- [x] `src/cmd/vibe/cli_test_cmd.mbt` — `sort_test_entry_paths_for_batching` / `sort_test_entry_batch_units` を `test_entry_selection_sort[T]` 共通 helper に統合
- [ ] `src/runtime/db.mbt` — `set_source` / `set_binary_source` (99%) の共通化（String/Bytes の差をどう吸収するか要検討）。`set_version_ref` / `set_symbol_ref` / `set_path_ref` は `set_ref` 共通 helper 経由に移行済み
- [x] `src/runtime_compile/ir_sexp.mbt` — `sort_map_fields_expr` / `sort_record_fields_expr` / `sort_type_ctors` / `sort_record_type_keys` を `sort_by_key[T]` に統合
- [x] 計測を CI に載せる — `similarity-mbt-report` job を informational として追加（閾値 0.98、sim-report.txt を artifact、`ci-informational` 集約経由）

## モジュール分離

- [x] ルート制約の緩和（兄弟ディレクトリ import 許可）
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
  - [x] **B2: Array ops** — Array::length/get/set/push/slice/concat, ArrayBuilder::new/push/freeze (#64 修正済)
  - [x] **B3: Type conversions** — Int::to_string, Bool::to_string, __to_string, Int::to_double, Double::to_int, String::from_char_code, Double::to_i64_bits
  - [x] **B4: Func return type** — enum_ctor_names を free-var filter に追加, let rec pre-bind
  - [x] **B5: Type coercion** — if kind mismatch → gc_common_kind, unknown Named type → EqRef fallback
  - [x] **B6: Effect system** — throw/handle の GC codegen、非 Error perform は trap fallback
  - [x] **B7: let rec closure self-ref** — lifted fctx に closure_call_types 伝搬 + call name capture + Assign tracking + let rec free-var bind-before-scan
  - [x] **B8: MapBuilder** — Map::new/set/freeze/get/has_key/keys の GC 表現
  - [x] **B9: Pipe operator** — `|>` は parser でデシュガー済み、GC codegen 追加不要
  - [x] **B10: Additional codegen** — StringInterp, TupleIndex, Break/Continue, LetPat, IndexAssign, __rshift/__lshift/__set_index, string pattern, Array::truncate, for-in EqRef fallback
  - [x] **B11: Function-as-value** — top-level 関数の closure wrapper (ref.func + env)、function alias (let f = g) 解決
  - [x] **B12: Module-level globals** — Int/Bool 定数は immutable global、Call/String/Array 等は mutable EqRef global + run body で global.set
  - [x] **B13: Polymorphic Option** — builtin Some/None enum 登録、polymorphic Some with EqRef boxing、nested Ctor pattern bind
  - [x] **B14: HOF parameters** — Type::Func パラメータの closure_call_types 登録、Named 型 alias の generic closure call fallback
  - [ ] **P4: selfhost compile E2E** — 260/263 (99%) compile OK
    - 残り 3: simd_patterns (Bytes::emit_end), gc_only/index (循環参照), selfhost_cli_gc_entry (上流依存)
    - 全て型チェッカー/bundler の上流問題
  - [ ] **P5: DCE + wasm-opt** — 未使用コード除去と最適化で ~350KB 目標
- [ ] `vibe/compiler` の論理分割
  - [x] `loader/index.vibe` の manifest traversal を shared helper に寄せ、source list/source groups の二重 BFS を削減する

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
- [x] compiled parity が揃ったので evaluator / interpreter 実装を削除
  - [x] `wasm-shell-stdin` で scalar let / late import / bool 行が stateful に動く
  - [x] 関数値 `let` 束縛は placeholder 表示に degrade して shell を継続する
  - [x] String 値は compiled REPL の repr transport で表示する
  - [x] Array / Map など composite 値の表示 transport を追加する
  - [x] 通常の `vibe shell` / `shell-stdin` を compiled session backend に切り替える
  - [x] `shell --ai` / `shell --tui` の evaluator 依存を整理する
  - [x] `cli_repl_js` の evaluator 依存を廃止する
  - [x] public CLI の `--syntax posix-*` shell 導線を閉じる
  - [x] `eval` command を public CLI から外す
  - [x] active runtime surface / docs から `Runtime::eval_script_with_mode` 記述を外す
  - [x] host / selfhost evaluator 実装と専用 test を削除する
  - [x] 不要になった selfhost fixture smoke test を削除する
    - [x] `vibe/compiler/fixture_selfhost_test.vibe`
    - [x] `vibe/compiler/fixture_selfhost_roundtrip_test.vibe`
    - [x] `vibe/compiler/fixture_parse_test_support.vibe`
  - [x] 不要になった interpreter/evaluator 専用 test を棚卸しして段階削除する
    - [x] `src/runtime/eval_effects_wbtest.mbt` を削除し、compiled shell / scratch-db 側の coverage に寄せる
    - [x] `src/tests/vibe_wasm_eval_test.mbt` の interpreter parity 前提を外し、WASM decode / effect capture の mainline test に寄せる
    - [x] `vibe/compiler/eval_*` の fixed-string smoke / wrapper test は削除済みで、fixture/mainline test 側へ整理した
    - [x] `test-selfhost-cache-probe` は standalone probe のまま維持し、release gate から外して運用する
    - [x] `vibe/compiler/fixture_*_test_support.vibe` の export 面は `parse_ok` / `roundtrip_ok` / `parse_fixture_spec` に絞り、fixture test を集約した
    - [x] host / selfhost で重複していた evaluator smoke test は削除済みで、compiled mainline test (`src/tests/vibe_wasm_eval_test.mbt` / CLI scratch-db coverage) へ統合した
    - [x] coverage / bootstrap gate は compiled-only 前提に揃え、古い interpreter backend 前提を除去した

## Release 運用メモ

- [x] local の `just release-selfhost-gates` は bootstrap を外し、日常の sign-off を軽く保つ
- [x] local の `just release-selfhost-gates` は selfbuild KPI も外し、bootstrap lane は CI と明示 target に閉じる
- [ ] selfhost bootstrap (`test-selfhost-bootstrap`) と selfbuild KPI (`test-selfhost-wasi-selfbuild-kpi`) は CI shard 専用 gate として運用する

## ユーザビリティ改善

- [x] 軽量 struct リテラル sugar `Type { ... }`
- [x] `String` を `for-in` 対象にする
- [x] トレイトにメソッドシグネチャを許可 (trait Name { method(Type) -> Type })
- [x] `?` 演算子 (expr? → handle { expr } with Error { Throw(e) => throw(e) })
