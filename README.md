# vibe

vibe language prototype and runtime (MoonBit).

## Features

### Language
- Type inference with effects (`with {Async}`, `with {Error}`)
- Pattern matching and destructuring
- Module system with import/export
- Async/await syntax (runtime gate: `--unstable-async`)
- Lambda expressions with placeholder shorthand (`_+1`)

### Runtime Targets

| Target | Description |
|--------|-------------|
| Native CLI | Compiled execution via the host runtime (`run` / `test` / `shell`) |
| WASM (linear) | Core WASM backend kept for fallback / compatibility |
| WASM + js-string | WASM with JS string builtins for embedding |
| WASM GC | Main `--wasm` backend |
| Component Model | WASI/component packaging for composition |

### Builtin Functions

| Function | Native CLI | WASM | Description |
|----------|------------|------|-------------|
| `sleep(ms)` | host runtime | host runtime | Sleep for milliseconds |
| `sh(cmd)` | host runtime | host import | Execute shell command |
| `path(str)` | host runtime | host import | Normalize path |
| `Stdout::write_char(code)` | host stdout | `wasi:cli/stdout` + `wasi:io/streams` import | Write one char code to stdout |
| `Stdout::write_stream(text)` | host stdout | `wasi:cli/stdout` + `wasi:io/streams` import | Write a string chunk to stdout |
| `Stdin::read_char()` | host stdin (`-1` on eof) | `wasi:cli/stdin` + `wasi:io/streams` import | Read one char code from stdin |
| `Stdin::read_stream(max)` | host stdin (`\"\"` on eof/error) | `wasi:cli/stdin` + `wasi:io/streams` import | Read up to `max` bytes as a string chunk |
| `await expr` | `--unstable-async` runtime gate | stack-switching (x86_64) | Async operation |

## Development

```bash
pkf run            # check + test
pkf run fmt        # format code
pkf run check      # type check
pkf run test       # run tests
pkf run test-integration-deno  # deno integration tests (artifact-only wasm-gc)
pkf run coverage   # moonbit + wasm(deno) coverage
pkf run coverage-moon  # moonbit source coverage (summary/cobertura/html)
pkf run coverage-deno  # wasm integration coverage (summary/lcov/html)
pkf run coverage-wasm-source examples/pattern_coverage.vibe  # vibe source span + wasm counter coverage
pkf run coverage-wasm-std  # vibe/prelude *_test.vibe coverage aggregation (wasm source)
pkf run release-check  # full check before release
pkf run playground-dev  # current wasm build で playground を起動
pkf run playground-build  # GitHub Pages 向け playground を build
```

Coverage で使う主な環境変数:
- `VIBE_MOON_COVERAGE_TARGET=native|wasm|wasm-gc|js`
- `VIBE_MOON_COVERAGE_PACKAGE=<pkg>`
- `VIBE_MOON_COVERAGE_MIN_LINE=<percent>`
- `VIBE_DENO_COVERAGE_FILTER=<regex>`
- `VIBE_DENO_COVERAGE_MIN_LINE=<percent>`
- `VIBE_WASM_SOURCE_COVERAGE_MODE=wasm|wasm-js-string`
- `VIBE_WASM_SOURCE_COVERAGE_NO_DCE=0|1`
- `VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS=0|1`
- `VIBE_WASM_SOURCE_COVERAGE_DIR=<dir>`
- `VIBE_WASM_STD_COVERAGE_MODE=wasm|wasm-js-string`
- `VIBE_WASM_STD_COVERAGE_FILTER=<regex>`
- `VIBE_WASM_STD_COVERAGE_EXCLUDE=<regex>`
- `VIBE_WASM_STD_COVERAGE_STRICT=0|1`
- `VIBE_WASM_STD_COVERAGE_DIR=<dir>`

WASM 向けは 3 層で測る:
- MoonBit 本体ロジック: `pkf run coverage-moon`（必要なら `VIBE_MOON_COVERAGE_TARGET=wasm-gc`）
- `WebAssembly.instantiate` 経由の統合導線: `pkf run coverage-deno`
- vibe ソース span ベースの line/branch: `pkf run coverage-wasm-source <entry.vibe>`
- vibe/prelude の集計: `pkf run coverage-wasm-std`（`summary` の `cases(total/success)` と `failures.txt` を確認）
- 詳細: `docs/coverage.md`

`js/vibe/` には wasm 成果物 (`src/lib`) を呼ぶ JS バインディングを置く:
- `js/vibe/index.js` / `js/vibe/index.d.ts` (`createVibeService`, `init`, `check`, `format`, `checkProject`, `ideOutline`, `idePeekDef`, `ideSearch`)
  - `createVibeService({ bootstrap: { prelude, kv } })` または `service.init({ prelude, kv })` で初期状態を注入可能
  - `checkProject({ entry, files })` と IDE request (`{ entry, path, files, ... }`) は import 解決対応（init で注入した `kv` も解決対象）
- `js/vibe/cli.js` shell から使う JS CLI (`vibe ide` 相当)
- `js/vibe/lsp.js` / `js/vibe/lsp.d.ts` (stdio/ws 非依存の transport 抽象)

`wasm/vibe/` には `src/lib` の配布用 wasm (`wasm-gc`) を置く:
- `wasm/vibe/vibe.wasm`
- `pkf run build-wasm-vibe` で更新
- `pkf run test-wasm-vibe-wasmtime` で `wasmtime --invoke vibe_check` 疎通確認
- `pkf run build-release-assets v0.0.1` で GitHub Release 添付用の versioned asset を `dist/release/v0.0.1/` に生成
- `v*` tag push で `.github/workflows/release.yml` が `vibe-v*.wasm` と checksum を GitHub Release に公開

## CLI

```bash
# Run vibe script
pkf run run -- examples/basics.vibe
# (comprehensive syntax tour)
pkf run run -- examples/syntax.vibe

# Run unstable async examples (required for await/sleep/yield runtime execution)
pkf run run -- --unstable-async examples/async.vibe
# flags can also be placed before command
pkf run run -- --unstable-async run examples/async.vibe
# unstable threads probe builtin (via line shell)
printf 'Threads::probe_wat()\nexit\n' | pkf run run -- shell-stdin --no-prompt --unstable-threads
# unstable threads runtime hints (recommended -W/-S flags)
printf 'Threads::runtime_hints()\nexit\n' | pkf run run -- shell-stdin --no-prompt --unstable-threads

# Run tests in script
pkf run run -- test examples/*.vibe
# For async tests
pkf run run -- test --unstable-async examples/async.vibe

# Compile to WASM
pkf run run -- compile --wasm examples/wasm/sleep_demo.vibe -o /tmp/out.wasm
# Compile + optimize with wite (-Oz default)
pkf run run -- compile --wasm --wite examples/wasm/sleep_demo.vibe -o /tmp/out.opt.wasm
# Compile + optimize with explicit level
pkf run run -- compile --component -O3 script.vibe -o out.component.opt.wasm

# Compile to Component Model WASM
pkf run run -- compile --component script.vibe -o out.component.wasm

# Generate component embedding WIT for wasm-tools/wkg pipeline
pkf run run -- compile --wit-component script.vibe -o out.component.wit

# Build validated component via wkg + wasm-tools
pkf run component-wkg -- script.vibe
# (stdio builtins are wired through wasi:cli/stdin|stdout + wasi:io/streams)

# Interactive shell
pkf run run -- shell

# Line shell for stdio/pipeline environments
pkf run run -- shell-stdin --no-prompt
# Enable unstable async in line shell
pkf run run -- shell-stdin --unstable-async

# IDE-like symbol queries
pkf run run -- ide outline examples/syntax.vibe
pkf run run -- ide peek-def some_fn examples/syntax.vibe
pkf run run -- ide search Option examples/syntax.vibe
# JS-backed ide command
pkf run ide-js -- outline examples/syntax.vibe
pkf run ide-js -- peek-def some_fn examples/syntax.vibe
pkf run ide-js -- search Option examples/syntax.vibe
# `ide-js` は entry から相対 import を再帰収集して project request を生成する

# Advanced graph index PoC (build/query/verify)
pkf run run -- index build examples/syntax.vibe -o /tmp/advanced-graph-index.json
pkf run run -- index query symbol add /tmp/advanced-graph-index.json
pkf run run -- index verify /tmp/advanced-graph-index.json

# Emit LSIF from the same symbol index backend
pkf run run -- lsif -o /tmp/vibe.lsif examples/syntax.vibe

# Build wasm line shell (preview2 stdio imports)
pkf run build-shell-wasi-wasm
# Build wasm compiler CLI (wasi)
pkf run build-compiler-wasi-wasm
# Build wasm checker CLI (json diagnostics)
pkf run build-checker-wasi-wasm
# Run wasm compiler CLI (`--wasm` は wasm-gc を優先)
printf '1 + 2\n' > /tmp/gc_demo.vibe
pkf run run-compiler-wasi-wasm -- --wasm /tmp/gc_demo.vibe -o /tmp/out.wasm
# Run wasm checker CLI (file path or --source)
pkf run run-checker-wasi-wasm -- /tmp/gc_demo.vibe
pkf run run-checker-wasi-wasm -- --source '1 + true'
# Run wasm formatter mode (vibe fmt 相当)
pkf run run-checker-wasi-wasm -- --format --source 'let  x=1'
# Same as above (shortcut)
pkf run run-compiler-wasi-wasm ---gc /tmp/gc_demo.vibe -o /tmp/out.wasm
# Use core wasm MVP backend explicitly
pkf run run-compiler-wasi-wasm ---mvp examples/basics.vibe -o /tmp/out.mvp.wasm

# Build component + run with wasmtime (explicit invoke for non-command component)
pkf run component-run -- vibe/prelude/test_import.vibe
# stdin 経由の実行も可能:
printf 'A' | pkf run component-run -- your_stdio_script.vibe
# stream TUI デモ:
printf 'hello\nworld\n' | pkf run component-run -- examples/wasm/tui_stream_demo.vibe
# 簡易デモ実行タスク:
pkf run demo-tui-stream

# moonix で実行（moonix の CLI 差分はランチャで吸収）
pkf run component-run-moonix -- vibe/prelude/test_import.vibe
# moonix バイナリが無い場合の手動 bootstrap
pkf run bootstrap-moonix

# Install CLI to ~/.local/bin/vibe
pkf run install
```

`build-shell-wasi-wasm` output:
- `_build/wasm/release/build/vibe_wasi/vibe_wasi.wasm`
- this binary imports `wasi:cli/stdin|stdout@0.2.0` and `wasi:io/streams@0.2.0` directly
- run it with a component/p3-compatible host (for example moon-component/mwac integration), not `moon run --target wasm`
- for script-level stdio execution, use `pkf run component-run -- <file.vibe>`
- moonix 実行は `pkf run component-run-moonix -- <file.vibe>`（必要なら `MOONIX_BIN=/path/to/moonix`）
- `component-run-moonix` は `moonix` 未導入時に `scripts/bootstrap_moonix_bin.sh` を自動試行

`build-compiler-wasi-wasm` output:
- `_build/wasm/release/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm`
- run with `moon run --target wasm src/cmd/vibe_compile_wasi -- ...` (or `pkf run run-compiler-wasi-wasm -- ...`)
- compiler filesystem access is routed through `src/io.FileSystemAdapter` abstraction
- `vibe_compile_wasi` では `--wasm` が `wasm-gc` を選ぶ（MVP を使う場合は `--wasm-mvp`）
- 現状 `wasm-gc` backend は実験段階のため、複雑な文法は `--wasm-mvp` を使う

## WASM Execution

### With async host runtime (supports sleep)

```bash
# Build Rust host runtime
pkf run build-async-host

# Run sleep demo
pkf run sleep-demo

# Run any WASM with sleep support
pkf run run -- compile --wasm your_script.vibe -o /tmp/out.wasm
pkf run run-wasm-async -- /tmp/out.wasm
```

### With wasmtime (basic)

```bash
pkf run run -- compile --wasm script.vibe -o /tmp/out.wasm
wasmtime /tmp/out.wasm
```

### With `deps/wasmtime` submodule (experimental flags)

```bash
# one-time init + build
pkf run wasmtime-submodule-init
pkf run build-wasmtime-submodule

# run wasmtime from submodule directly
pkf run wasmtime-submodule -- run -W gc --invoke _start /tmp/out.wasm

# or switch existing vibe scripts/tasks to submodule wasmtime
VIBE_USE_WASMTIME_SUBMODULE=1 pkf run component-run -- script.vibe
VIBE_USE_WASMTIME_SUBMODULE=1 pkf run bench-wasmtime

# inject extra wasmtime runtime flags into vibe scripts/*
# (space-separated list; each token is passed as -W / -S)
VIBE_WASMTIME_WASM_FLAGS='component-model-async=y concurrency-support=y' \
VIBE_WASMTIME_WASI_FLAGS='p3=y' \
VIBE_USE_WASMTIME_SUBMODULE=1 \
pkf run component-run -- script.vibe

# flags are also propagated through justfile-backed tasks
VIBE_WASMTIME_WASM_FLAGS='gc=y' pkf run bench-wasmtime

# inspect current flag env values used by scripts/wasmtime_run.sh
pkf run show-wasmtime-flags

# run minimal WASI Threads probe (imports wasi::thread-spawn + env::memory)
# defaults to:
#   VIBE_WASMTIME_WASM_FLAGS='threads=y shared-memory=y'
#   VIBE_WASMTIME_WASI_FLAGS='threads=y'
VIBE_USE_WASMTIME_SUBMODULE=1 pkf run experimental_wasi_threads_probe

# direct runner under x/threads
VIBE_USE_WASMTIME_SUBMODULE=1 src/x/threads/run_probe.sh

# run minimal shared-everything-threads i31 probe
# defaults to:
#   VIBE_WASMTIME_WASM_FLAGS='gc=y function-references=y shared-everything-threads=y'
# If ../wasmtime/target/debug/wasmtime exists, this runner uses it automatically.
pkf run experimental_shared_everything_threads_probe

# run minimal Component Model threading probe
# defaults to:
#   VIBE_WASMTIME_WASM_FLAGS='component-model=y component-model-async=y component-model-threading=y'
# If ../wasmtime/target/debug/wasmtime exists, this runner uses it automatically.
pkf run experimental_component_model_threading_probe
```

### With wasmtime stack-switching (x86_64 Linux only)

```bash
# Via container (for stack-switching support)
pkf run experimental_wasmtime_stack_switching -- /tmp/out.wasm
```

## Project Structure

```
src/
├── backend/        # Runtime host adapters (target-specific sleep, etc.)
├── codebase/       # Nix-like content-addressed store and path mappings
├── io/             # Unified IO boundary (fs/env/shell/sleep facade)
├── loader/         # Source/lock resolution and module loading pipeline
├── core/           # AST types and serialization
├── parser/         # Lexer and parser
├── checker/        # Type checker with effects
├── codegen/        # WASM code generation
├── runtime/        # Runtime state, caches, compiler hooks, and shell support
├── x/fp/           # Floating-point to decimal formatter utilities
├── x/module_graph/ # Experimental module graph index and codecs
├── cmd/vibe/       # CLI command implementation (native/js)
├── cmd/vibe_wasi/  # WASI line-shell command (wasm)
└── tests/          # Integration-like blackbox tests

examples/
├── *.vibe           # Example scripts
└── wasm/           # WASM-only examples (require host)

vibe/
└── prelude/        # vibe core library (self-hosted prelude modules)

examples/async_host/  # Rust/wasmtime host runtime
```

## Docs

- `docs/vibe.md` - Language specification (normative for implemented behavior)
- `docs/module-system.md` - Current module system spec
- `docs/coverage.md` - Coverage strategy for MoonBit + WASM integration

## Fixtures

Fixtures live in `fixtures/*.vibe` and include a `__DATA__` JSON section.
`moon test` runs them via `src/tests/fixture_test.mbt`.
Runtime-style fixtures (effect, HTTP, struct) live in `fixtures/runtime/`.

WASM fixtures live in `fixtures/wasm/*.vibe` and compare expected WAT.
WASM GC fixtures live in `fixtures/wasm_gc/*.vibe` and check for `struct.new/get/set`.

## Bench

```bash
pkf run bench-wasmtime
pkf run bench-compare
pkf run bench-kpi
pkf run bench-kpi bench/kpi_bench.vibe
pkf run bench-std-baseline-update
pkf run run -- bench examples/simple_bench.vibe
pkf run bench-cmd-latency
pkf run bench-scratch-workflow
pkf run bench-symbol-index
pkf run bench-advanced-graph
pkf run bench-typechecker
```

`vibe bench` は `bench {}` ブロックを言語機能として実行する。  
`<file|dir...>` 指定時の canonical backend は `--backend compiled` で、`--backend wasm` は互換 alias として受け付ける。  
legacy の式ベンチ (`--expr/--case/--cases`) は廃止。`bench {}` を含む `.vibe` file を渡す。
compiled bench path ではサイズ優先で `--no-dce -Oz` 相当のコンパイルを使い、各ケースに `wasm_bytes=<size>` を出力する。
`pkf run bench-kpi` は `vibe bench` の結果を `dist/bench_kpi/latest.tsv` に保存し、`per_us` と `wasm_bytes` を同時に確認できる。
KPI しきい値は `VIBE_BENCH_KPI_MAX_PER_US` / `VIBE_BENCH_KPI_MAX_WASM_BYTES` / `VIBE_BENCH_KPI_MAX_SCORE` で設定可能。
引数なしの `pkf run bench-kpi` は `bench/kpi_bench.vibe`（数値パイプライン/状態更新の4ケース）を対象にする。
`VIBE_BENCH_KPI_N` / `VIBE_BENCH_KPI_WARMUP` 未指定時は `compiled=20000/1000` を使う。
`pkf run bench-std-baseline-update` は `vibe/prelude` を含む bundle-size budget
(`bench/golden/bundle_size_budget.tsv`) と KPI snapshot
(`bench/golden/kpi_wasm.tsv`) を更新する。

`bench-scratch-workflow` は scratch 開発フローを段階別に計測する。

- `VIBE_BENCH_SCENARIOS=all|eval|finalize|export_apply|full` (`all` は `,` 区切り指定可)
- `VIBE_BENCH_CHAIN=<N>` 定義チェーン長（デフォルト `40`）
- `VIBE_BENCH_WARMUP=<N>` / `VIBE_BENCH_RUNS=<N>`
- `VIBE_BENCH_EXPORT_JSON=<path>` で `hyperfine` の JSON を保存

## License

MIT
