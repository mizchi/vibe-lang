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
| Interpreter (native) | Full-featured runtime with FFI |
| Interpreter (js) | Browser/Node.js compatible |
| WASM | Minimal core WASM output |
| WASM + js-string | WASM with JS string builtins |
| Component Model | WASM Component for composition |

### Builtin Functions

| Function | Interpreter | WASM | Description |
|----------|-------------|------|-------------|
| `sleep(ms)` | native only | host runtime | Sleep for milliseconds |
| `sh(cmd)` | native only | host import | Execute shell command |
| `path(str)` | native only | host import | Normalize path |
| `Stdout::write_char(code)` | effect trace | `wasi:cli/stdout` + `wasi:io/streams` import | Write one char code to stdout |
| `Stdout::write_stream(text)` | effect trace | `wasi:cli/stdout` + `wasi:io/streams` import | Write a string chunk to stdout |
| `Stdin::read_char()` | returns `-1` on eof | `wasi:cli/stdin` + `wasi:io/streams` import | Read one char code from stdin |
| `Stdin::read_stream(max)` | returns `\"\"` on eof/error | `wasi:cli/stdin` + `wasi:io/streams` import | Read up to `max` bytes as a string chunk |
| `await expr` | interpreter | stack-switching (x86_64) | Async operation |

## Development

```bash
just              # check + test
just fmt          # format code
just check        # type check
just test         # run tests
just test-integration-deno  # deno integration tests (artifact-only wasm-gc)
just coverage     # moonbit + wasm(deno) coverage
just coverage-moon  # moonbit source coverage (summary/cobertura/html)
just coverage-deno  # wasm integration coverage (summary/lcov/html)
just coverage-wasm-source examples/pattern_coverage.vibe  # vibe source span + wasm counter coverage
just coverage-wasm-std  # vibe/prelude *_test.vibe coverage aggregation (wasm source)
just release-check  # full check before release
just playground-dev  # current wasm build で playground を起動
just playground-build  # GitHub Pages 向け playground を build
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
- MoonBit 本体ロジック: `just coverage-moon`（必要なら `VIBE_MOON_COVERAGE_TARGET=wasm-gc`）
- `WebAssembly.instantiate` 経由の統合導線: `just coverage-deno`
- vibe ソース span ベースの line/branch: `just coverage-wasm-source <entry.vibe>`
- vibe/prelude の集計: `just coverage-wasm-std`（`summary` の `cases(total/success)` と `failures.txt` を確認）
- 詳細: `docs/coverage.md`

`js/vibe/` には wasm 成果物 (`src/lib`) を呼ぶ JS バインディングを置く:
- `js/vibe/index.js` / `js/vibe/index.d.ts` (`createVibeService`, `init`, `check`, `format`, `checkProject`, `ideOutline`, `idePeekDef`, `ideSearch`)
  - `createVibeService({ bootstrap: { prelude, kv } })` または `service.init({ prelude, kv })` で初期状態を注入可能
  - `checkProject({ entry, files })` と IDE request (`{ entry, path, files, ... }`) は import 解決対応（init で注入した `kv` も解決対象）
- `js/vibe/cli.js` shell から使う JS CLI (`vibe ide` 相当)
- `js/vibe/lsp.js` / `js/vibe/lsp.d.ts` (stdio/ws 非依存の transport 抽象)

`wasm/vibe/` には `src/lib` の配布用 wasm (`wasm-gc`) を置く:
- `wasm/vibe/vibe.wasm`
- `just build-wasm-vibe` で更新
- `just test-wasm-vibe-wasmtime` で `wasmtime --invoke vibe_check` 疎通確認

## CLI

```bash
# Run vibe script
just run run examples/basics.vibe
# (comprehensive syntax tour)
just run run examples/syntax.vibe

# Run unstable async examples (required for await/sleep/yield runtime execution)
just run run --unstable-async examples/async.vibe
# flags can also be placed before command
just run --unstable-async run examples/async.vibe
# unstable threads probe builtin (via line repl)
printf 'Threads::probe_wat()\nexit\n' | just run repl-stdin --no-prompt --unstable-threads
# unstable threads runtime hints (recommended -W/-S flags)
printf 'Threads::runtime_hints()\nexit\n' | just run repl-stdin --no-prompt --unstable-threads

# Run tests in script
just run test examples/*.vibe
# For async tests
just run test --unstable-async examples/async.vibe

# Compile to WASM
just run compile --wasm examples/wasm/sleep_demo.vibe -o /tmp/out.wasm
# Compile + optimize with wite (-Oz default)
just run compile --wasm --wite examples/wasm/sleep_demo.vibe -o /tmp/out.opt.wasm
# Compile + optimize with explicit level
just run compile --component -O3 script.vibe -o out.component.opt.wasm

# Compile to Component Model WASM
just run compile --component script.vibe -o out.component.wasm

# Generate component embedding WIT for wasm-tools/wkg pipeline
just run compile --wit-component script.vibe -o out.component.wit

# Build validated component via wkg + wasm-tools
just component-wkg script.vibe
# (stdio builtins are wired through wasi:cli/stdin|stdout + wasi:io/streams)

# Interactive REPL
just run repl

# Line REPL for stdio/wasi-like environments
just run repl-wasi --no-prompt
# Enable unstable async in REPL
just run repl-wasi --unstable-async

# IDE-like symbol queries
just run ide outline examples/syntax.vibe
just run ide peek-def some_fn examples/syntax.vibe
just run ide search Option examples/syntax.vibe
# JS-backed ide command
just ide-js outline examples/syntax.vibe
just ide-js peek-def some_fn examples/syntax.vibe
just ide-js search Option examples/syntax.vibe
# `ide-js` は entry から相対 import を再帰収集して project request を生成する

# Advanced graph index PoC (build/query/verify)
just run index build examples/syntax.vibe -o /tmp/advanced-graph-index.json
just run index query symbol add /tmp/advanced-graph-index.json
just run index verify /tmp/advanced-graph-index.json

# Emit LSIF from the same symbol index backend
just run lsif -o /tmp/vibe.lsif examples/syntax.vibe

# Build wasm line REPL (preview2 stdio imports)
just build-repl-wasi-wasm
# Build wasm compiler CLI (wasi)
just build-compiler-wasi-wasm
# Build wasm checker CLI (json diagnostics)
just build-checker-wasi-wasm
# Run wasm compiler CLI (`--wasm` は wasm-gc を優先)
printf '1 + 2\n' > /tmp/gc_demo.vibe
just run-compiler-wasi-wasm --wasm /tmp/gc_demo.vibe -o /tmp/out.wasm
# Run wasm checker CLI (file path or --source)
just run-checker-wasi-wasm /tmp/gc_demo.vibe
just run-checker-wasi-wasm --source '1 + true'
# Run wasm formatter mode (vibe fmt 相当)
just run-checker-wasi-wasm --format --source 'let  x=1'
# Same as above (shortcut)
just run-compiler-wasi-wasm-gc /tmp/gc_demo.vibe -o /tmp/out.wasm
# Use core wasm MVP backend explicitly
just run-compiler-wasi-wasm-mvp examples/basics.vibe -o /tmp/out.mvp.wasm

# Build component + run with wasmtime (explicit invoke for non-command component)
just component-run vibe/prelude/test_import.vibe
# stdin 経由の実行も可能:
printf 'A' | just component-run your_stdio_script.vibe
# stream TUI デモ:
printf 'hello\nworld\n' | just component-run examples/wasm/tui_stream_demo.vibe
# 簡易デモ実行タスク:
just demo-tui-stream

# moonix で実行（moonix の CLI 差分はランチャで吸収）
just component-run-moonix vibe/prelude/test_import.vibe
# moonix バイナリが無い場合の手動 bootstrap
just bootstrap-moonix

# Install CLI to ~/.local/bin/vibe
just install
```

`build-repl-wasi-wasm` output:
- `_build/wasm/release/build/vibe_wasi/vibe_wasi.wasm`
- this binary imports `wasi:cli/stdin|stdout@0.2.0` and `wasi:io/streams@0.2.0` directly
- run it with a component/p3-compatible host (for example moon-component/mwac integration), not `moon run --target wasm`
- for script-level stdio execution, use `just component-run <file.vibe>`
- moonix 実行は `just component-run-moonix <file.vibe>`（必要なら `MOONIX_BIN=/path/to/moonix`）
- `component-run-moonix` は `moonix` 未導入時に `scripts/bootstrap_moonix_bin.sh` を自動試行

`build-compiler-wasi-wasm` output:
- `_build/wasm/release/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm`
- run with `moon run --target wasm src/cmd/vibe_compile_wasi -- ...` (or `just run-compiler-wasi-wasm ...`)
- compiler filesystem access is routed through `src/io.FileSystemAdapter` abstraction
- `vibe_compile_wasi` では `--wasm` が `wasm-gc` を選ぶ（MVP を使う場合は `--wasm-mvp`）
- 現状 `wasm-gc` backend は実験段階のため、複雑な文法は `--wasm-mvp` を使う

## WASM Execution

### With async host runtime (supports sleep)

```bash
# Build Rust host runtime
just build-async-host

# Run sleep demo
just sleep-demo

# Run any WASM with sleep support
just run compile --wasm your_script.vibe -o /tmp/out.wasm
just run-wasm-async /tmp/out.wasm
```

### With wasmtime (basic)

```bash
just run compile --wasm script.vibe -o /tmp/out.wasm
wasmtime /tmp/out.wasm
```

### With `deps/wasmtime` submodule (experimental flags)

```bash
# one-time init + build
just wasmtime-submodule-init
just build-wasmtime-submodule

# run wasmtime from submodule directly
just wasmtime-submodule run -W gc --invoke run /tmp/out.wasm

# or switch existing vibe scripts/tasks to submodule wasmtime
VIBE_USE_WASMTIME_SUBMODULE=1 just component-run script.vibe
VIBE_USE_WASMTIME_SUBMODULE=1 just bench-wasmtime

# inject extra wasmtime runtime flags into vibe scripts/*
# (space-separated list; each token is passed as -W / -S)
VIBE_WASMTIME_WASM_FLAGS='component-model-async=y concurrency-support=y' \
VIBE_WASMTIME_WASI_FLAGS='p3=y' \
VIBE_USE_WASMTIME_SUBMODULE=1 \
just component-run script.vibe

# flags are also propagated through justfile-backed tasks
VIBE_WASMTIME_WASM_FLAGS='gc=y' just bench-wasmtime

# inspect current flag env values used by scripts/wasmtime_run.sh
just show-wasmtime-flags

# run minimal WASI Threads probe (imports wasi::thread-spawn + env::memory)
# defaults to:
#   VIBE_WASMTIME_WASM_FLAGS='threads=y shared-memory=y'
#   VIBE_WASMTIME_WASI_FLAGS='threads=y'
VIBE_USE_WASMTIME_SUBMODULE=1 just experimental_wasi_threads_probe

# direct runner under x/threads
VIBE_USE_WASMTIME_SUBMODULE=1 src/x/threads/run_probe.sh
```

### With wasmtime stack-switching (x86_64 Linux only)

```bash
# Via container (for stack-switching support)
just experimental_wasmtime_stack_switching /tmp/out.wasm
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
├── runtime/        # Interpreter and compilation
├── x/fp/           # Floating-point to decimal formatter utilities
├── x/module_graph/ # Experimental module graph index and codecs
├── cmd/vibe/       # CLI command implementation (native/js)
├── cmd/vibe_wasi/  # WASI line-REPL command (wasm)
└── tests/          # Integration-like blackbox tests

examples/
├── *.vibe           # Example scripts (interpreter)
└── wasm/           # WASM-only examples (require host)

vibe/
└── prelude/        # vibe core library (self-hosted prelude modules)

examples/async_host/  # Rust/wasmtime host runtime
```

## Docs

- `docs/vibe.md` - Language specification (normative for implemented behavior)
- `docs/module_design.md` - Module design proposals (non-normative)
- `docs/module-system.md` - Current module system spec
- `docs/vibe-eval.md` - Eval workflow documentation
- `docs/async_design.md` - Async design proposals (non-normative)
- `docs/unstable_features.md` - Unstable runtime feature flags (`--unstable-async`, `--unstable-threads`)
- `docs/coverage.md` - Coverage strategy for MoonBit + WASM integration

## Fixtures

Fixtures live in `fixtures/*.vibe` and include a `__DATA__` JSON section.
`moon test` runs them via `src/tests/fixture_test.mbt`.

WASM fixtures live in `fixtures/wasm/*.vibe` and compare expected WAT.
WASM GC fixtures live in `fixtures/wasm_gc/*.vibe` and check for `struct.new/get/set`.

## Bench

```bash
just bench-wasmtime
just bench-compare
just bench-kpi
just bench-kpi bench/kpi_bench.vibe
just bench-std-baseline-update
just run bench examples/simple_bench.vibe
just bench-cmd-latency
just bench-scratch-workflow
just bench-symbol-index
just bench-advanced-graph
just bench-typechecker
```

`vibe bench` は `bench {}` ブロックを言語機能として実行する。  
`<file|dir...>` 指定時は `--backend wasm` がデフォルト（`--backend interpreter` で従来実装）。  
legacy の式ベンチ (`--expr/--case/--cases`) は `interpreter` backend のみ対応。
`--backend wasm` ではサイズ優先で `--no-dce -Oz` 相当のコンパイルを使い、各ケースに `wasm_bytes=<size>` を出力する。
`just bench-kpi` は `vibe bench` の結果を `dist/bench_kpi/latest.tsv` に保存し、`per_us` と `wasm_bytes` を同時に確認できる。
KPI しきい値は `VIBE_BENCH_KPI_MAX_PER_US` / `VIBE_BENCH_KPI_MAX_WASM_BYTES` / `VIBE_BENCH_KPI_MAX_SCORE` で設定可能。
引数なしの `just bench-kpi` は `bench/kpi_bench.vibe`（数値パイプライン/状態更新の4ケース）を対象にする。
`VIBE_BENCH_KPI_N` / `VIBE_BENCH_KPI_WARMUP` 未指定時は `wasm=20000/1000`, `interpreter=2000/200` を使う。
`just bench-std-baseline-update` は `vibe/prelude` を含む bundle-size budget
(`bench/golden/bundle_size_budget.tsv`) と KPI snapshot
(`bench/golden/kpi_wasm.tsv`, `bench/golden/kpi_interpreter.tsv`) を更新する。

`bench-scratch-workflow` は scratch 開発フローを段階別に計測する。

- `VIBE_BENCH_SCENARIOS=all|eval|finalize|export_apply|full` (`all` は `,` 区切り指定可)
- `VIBE_BENCH_CHAIN=<N>` 定義チェーン長（デフォルト `40`）
- `VIBE_BENCH_WARMUP=<N>` / `VIBE_BENCH_RUNS=<N>`
- `VIBE_BENCH_EXPORT_JSON=<path>` で `hyperfine` の JSON を保存

## License

MIT
