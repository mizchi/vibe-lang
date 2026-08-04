# scripts/ — index

Build/test/dev scripts for vibe (selfhost-only). Many scripts derive the repo
root from their own location (`ROOT_DIR="$(dirname "${BASH_SOURCE[0]}")/.."`),
so they assume they live **directly** in `scripts/` — keep new scripts here
(or fix the depth if you nest them). Task wiring lives in `Taskfile.pkl`; CI in
`.github/`.

Categorized so you can find things without `ls | grep`. `*_test.sh` /
`*.test.mjs` next to a script are that script's own tests.

## CLI / dev entrypoints (`vibe_*`)
The selfhost `vibe` subcommands as scripts (used by `pkf run` + tests).
- `vibe_run.sh` — compile+run a `.vibe` (seed → runner). `vibe_run_smoke.sh`
- `vibe_test.sh` — run `test {}` blocks. `vibe_test_smoke.sh`
- `vibe_fmt.sh` / `vibe_normalize.sh` (+ `*_smoke.sh`) — format / normalize
  a single file (`--check`/`--stdout`/write); `ensure_vibe_fmt_entry.sh`
  compiles its wasm entry (`lib/@vibe/cli/fmt_entry.vibe`). `vibe_fmt_apply.sh`
  (`pkf run fmt`) is the tree-wide write-mode counterpart, and
  `check_vibe_fmt.sh` the read-only one -- both run through
  `run_vibe_fmt_batch.sh` + `ensure_vibe_fmt_batch.sh`, which drive the
  batched/sharded CLI entry `lib/@vibe/cli/fmt.vibe` (one wasm process for
  the whole file list, sharded across cores via `Process::sh_capture`
  background+wait) instead of spawning one process per file -- see that
  file's header comment for why.
- `vibe_cli.sh` (+ smoke) — drive the selfhost CLI wasm
- `vibe_pkg.sh` — package publish/install/add/yank/update (hash-verified,
  transparency-log backed #805; `vibe pkg` delegates here). `vibe_core_install.sh`
- `vibe_graph.js` — graph/symbol-index query

## Runtime & runners (wasm execution)
- `wasm_vibe_host_runner.js` — **the** node host runner (fs/http/stdio imports)
- `wasm_http_host_runner.js` — HTTP-host variant
- `run_wasm_vibe_host_runner.sh` — wrapper (most-referenced sibling)
- `run_wasm_js_string_file.mjs` — run a `--wasm-js-string` artifact under node
- `wasmtime_run.sh` / `wasmtime_bin.sh` — wasmtime invocation + flags
- `run_component_stdio.sh` / `run_component_moonix.sh` — component + wasmtime/moonix
- `run_check_*_component.sh` / `run_cli_preview2_component.sh`

## Selfhost build / bootstrap
- `compiler_gate.sh` — **sign-off** (seed→stage1→stage2→stage3
  fixpoint + compile/run validation); `pkf run test` / `release-check`
- `gate.sh` / `trial_gate.sh` — operation gates
- `generations.sh` (+ `_test`) — stage build driver
- `generate_bundle.sh` (+ `_test`) — regenerate `compiler_sources_bundle.vibe`
  / adapter bundles from compiler source
- `build_cli_wasm.sh` — build the distributable compiler wasm (seed→stage1→stage2)
- `fetch_compiler.sh` — fetch a prebuilt compiler
- `refresh_batch_weight_seed.sh` (+ `_test`), `select_test_shard.mjs`

## Tests (`test_*`)
- **Editor primitives:** `test_vibe_symbols.sh`, `test_vibe_type_at.sh`,
  `test_vibe_binding_at.sh`, `test_vibe_diagnostics.sh`, `test_located_diagnostics.sh`
- **Debugger:** `test_vibe_break{,_args,_line,_interior}.sh`, `test_vibe_step.sh`,
  `test_vibe_trace{,_calls}.sh`, `test_vibe_dap.js`
- **LSP / IDE:** `test_vibe_lsp.js`, `test_vibe_lsp_workspace.js`,
  `test_symbol_index.js`, `test_graph_query.js`
- **Compiler component/CLI:** `test_check_*`, `test_cli_*`, `test_rc_bootstrap.sh`
- **Runtime / mem / perf:** `test_vibe_{alloc_site,mem,bench}.sh`,
  `test_gc_selfbuild.sh`, `test_name_section.sh`, `test_simd_emit_wasmtime.sh`
- **Host ABI / library / install:** `test_host_abi.js`, `test_vibe_library.sh`,
  `test_vibe_cli_install.sh`, `test_wasm_vibe_wasmtime.sh`
- **Async / http / process:** `test_real_async_host.sh`, `test_wasi_http_p3_full_gate.sh`

## Coverage
- `coverage_{corpus,driver,drivers,features,fn,manifestcache,merge,multimodule,suite,testexec,unittests}.*`
  — the selfhost-suite coverage lane. `coverage_wasm_{source,std}.mjs`,
  `coverage_{eval,scratch}_sidecar.sh`, `coverage_gen_errcorpus.sh`
- `coverage_acc_tool_run.sh` / `coverage_local_merge_run.sh` — cached-build
  wrappers for `lib/@vibe/cli/coverage_acc_tool.vibe` (global-branch-id
  `acc.json` merge + sum/len stat) and `lib/@vibe/cli/coverage_local_merge.vibe`
  (LOCAL function-name + occurrence-index merge, for runs compiled from a
  different source than acc's own so global branch ids don't line up) — the
  tools themselves live under `lib/@vibe/cli/` (not here) since the merge
  algorithms are generic beyond this repo; shared by `coverage_corpus.sh` /
  `coverage_features.sh` / `coverage_manifestcache.sh` /
  `coverage_multimodule.sh` / `coverage_drivers.sh` / `coverage_unittests.sh`
- `scripts/coverage/` — supporting coverage assets (subdir)

## Bench
- `bench_cmd_latency.sh`, `bench_http.sh`, `bench_regression.mjs`, `bench_rc.*`,
  `bench_vibe_lsp.js`

## Check / lint / gate / repro
- `check_lock_clean.sh`, `check_{bundle_sync,module_source_sync,portable_boundary}.sh`
- `check_vibe_fmt.sh` (+ `vibe_fmt_allowlist.txt`) — CI-enforced `vibe fmt`
  gate (`vibe-fmt-check` job, required): every `lib/**/*.vibe` file must be a
  `vibe_fmt.sh --check` fixpoint unless listed in the allowlist, which now
  holds only the permanent auto-generated bundle exceptions (everything else
  was paid down in the 2026-07-28 bulk reformat). `vibe_fmt_apply.sh` (`pkf
  run fmt`) is the write-mode counterpart that applies the formatter across
  the tree; this script only lints.
- `lint_architecture_debt.sh` (+ `architecture_debt_{rules.tsv,allowlist.txt}`),
  `lint_tracked_experiment_names.sh`
- `verify_rc.sh`, `rc_corpus_parity.sh`, `rc_cutover_readiness.sh`
- `monitor_wasm_bundle_size.sh`, `repro_715_rc_free_list_corruption.sh`

## Install / release
- `installer.sh` (curl entry) → `install.sh` (checkout install; toolchain layout)
- `install_wasmtime_release.sh`
- `build_release_assets.sh`, `build_wasi_http_p3_full_adapter.sh`, `precompile.sh`

## Generators / codegen data
- `generate_runtime_fixture_tests.mjs`, `emit_async_lift_fixture.sh`

## Misc infra
- `cache_clean.sh`, `flaker_run.sh` (+ `_test`), `measure_heap.mjs`

## Subdirs
- `scripts/pkfire/` — pkfire CI shard helpers (`gates_shard.sh`, …)
- `scripts/coverage/` — coverage support assets
