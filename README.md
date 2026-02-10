# xsh

xsh language prototype and runtime (MoonBit).

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
| `stdout_write_char(code)` | effect trace | `wasi:cli/stdout` + `wasi:io/streams` import | Write one char code to stdout |
| `stdout_write_stream(text)` | effect trace | `wasi:cli/stdout` + `wasi:io/streams` import | Write a string chunk to stdout |
| `stdin_read_char()` | returns `-1` on eof | `wasi:cli/stdin` + `wasi:io/streams` import | Read one char code from stdin |
| `stdin_read_stream(max)` | returns `\"\"` on eof/error | `wasi:cli/stdin` + `wasi:io/streams` import | Read up to `max` bytes as a string chunk |
| `await expr` | interpreter | stack-switching (x86_64) | Async operation |

## Development

```bash
just              # check + test
just fmt          # format code
just check        # type check
just test         # run tests
just test-integration-deno  # deno integration tests (artifact-only wasm-gc)
just release-check  # full check before release
```

`js/xsh/` には wasm 成果物 (`src/lib`) を呼ぶ JS バインディングを置く:
- `js/xsh/index.js` / `js/xsh/index.d.ts` (`createXshService`, `init`, `check`, `format`, `checkProject`, `ideOutline`, `idePeekDef`, `ideSearch`)
  - `createXshService({ bootstrap: { prelude, kv } })` または `service.init({ prelude, kv })` で初期状態を注入可能
  - `checkProject({ entry, files })` と IDE request (`{ entry, path, files, ... }`) は import 解決対応（init で注入した `kv` も解決対象）
- `js/xsh/cli.js` shell から使う JS CLI (`xsh ide` 相当)
- `js/xsh/lsp.js` / `js/xsh/lsp.d.ts` (stdio/ws 非依存の transport 抽象)

## CLI

```bash
# Run xsh script
just run run examples/basics.xsh
# (comprehensive syntax tour)
just run run examples/syntax.xsh

# Run unstable async examples (required for await/sleep/yield runtime execution)
just run run --unstable-async examples/async.xsh
# flags can also be placed before command
just run --unstable-async run examples/async.xsh
# unstable threads probe builtin (via line repl)
printf 'threads_probe_wat()\nexit\n' | just run repl-stdin --no-prompt --unstable-threads
# unstable threads runtime hints (recommended -W/-S flags)
printf 'threads_runtime_hints()\nexit\n' | just run repl-stdin --no-prompt --unstable-threads

# Run tests in script
just run test examples/*.xsh
# For async tests
just run test --unstable-async examples/async.xsh

# Compile to WASM
just run compile --wasm examples/wasm/sleep_demo.xsh -o /tmp/out.wasm
# Compile + optimize with wite (-Oz default)
just run compile --wasm --wite examples/wasm/sleep_demo.xsh -o /tmp/out.opt.wasm
# Compile + optimize with explicit level
just run compile --component -O3 script.xsh -o out.component.opt.wasm

# Compile to Component Model WASM
just run compile --component script.xsh -o out.component.wasm

# Generate component embedding WIT for wasm-tools/wkg pipeline
just run compile --wit-component script.xsh -o out.component.wit

# Build validated component via wkg + wasm-tools
just component-wkg script.xsh
# (stdio builtins are wired through wasi:cli/stdin|stdout + wasi:io/streams)

# Interactive REPL
just run repl

# Line REPL for stdio/wasi-like environments
just run repl-wasi --no-prompt
# Enable unstable async in REPL
just run repl-wasi --unstable-async

# IDE-like symbol queries
just run ide outline examples/syntax.xsh
just run ide peek-def some_fn examples/syntax.xsh
just run ide search Option examples/syntax.xsh
# JS-backed ide command
just ide-js outline examples/syntax.xsh
just ide-js peek-def some_fn examples/syntax.xsh
just ide-js search Option examples/syntax.xsh
# `ide-js` は entry から相対 import を再帰収集して project request を生成する

# Advanced graph index PoC (build/query/verify)
just run index build examples/syntax.xsh -o /tmp/advanced-graph-index.json
just run index query symbol add /tmp/advanced-graph-index.json
just run index verify /tmp/advanced-graph-index.json

# Emit LSIF from the same symbol index backend
just run lsif -o /tmp/xsh.lsif examples/syntax.xsh

# Build wasm line REPL (preview2 stdio imports)
just build-repl-wasi-wasm
# Build wasm compiler CLI (wasi)
just build-compiler-wasi-wasm
# Build wasm checker CLI (json diagnostics)
just build-checker-wasi-wasm
# Run wasm compiler CLI (`--wasm` は wasm-gc を優先)
printf '1 + 2\n' > /tmp/gc_demo.xsh
just run-compiler-wasi-wasm --wasm /tmp/gc_demo.xsh -o /tmp/out.wasm
# Run wasm checker CLI (file path or --source)
just run-checker-wasi-wasm /tmp/gc_demo.xsh
just run-checker-wasi-wasm --source '1 + true'
# Run wasm formatter mode (xsh fmt 相当)
just run-checker-wasi-wasm --format --source 'let  x=1'
# Same as above (shortcut)
just run-compiler-wasi-wasm-gc /tmp/gc_demo.xsh -o /tmp/out.wasm
# Use core wasm MVP backend explicitly
just run-compiler-wasi-wasm-mvp examples/basics.xsh -o /tmp/out.mvp.wasm

# Build component + run with wasmtime (explicit invoke for non-command component)
just component-run xsh/std/test_import.xsh
# stdin 経由の実行も可能:
printf 'A' | just component-run your_stdio_script.xsh
# stream TUI デモ:
printf 'hello\nworld\n' | just component-run examples/wasm/tui_stream_demo.xsh
# 簡易デモ実行タスク:
just demo-tui-stream

# moonix で実行（moonix の CLI 差分はランチャで吸収）
just component-run-moonix xsh/std/test_import.xsh
# moonix バイナリが無い場合の手動 bootstrap
just bootstrap-moonix

# Install CLI to ~/.local/bin/xsh
just install
```

`build-repl-wasi-wasm` output:
- `_build/wasm/release/build/xsh_wasi/xsh_wasi.wasm`
- this binary imports `wasi:cli/stdin|stdout@0.2.0` and `wasi:io/streams@0.2.0` directly
- run it with a component/p3-compatible host (for example moon-component/mwac integration), not `moon run --target wasm`
- for script-level stdio execution, use `just component-run <file.xsh>`
- moonix 実行は `just component-run-moonix <file.xsh>`（必要なら `MOONIX_BIN=/path/to/moonix`）
- `component-run-moonix` は `moonix` 未導入時に `scripts/bootstrap_moonix_bin.sh` を自動試行

`build-compiler-wasi-wasm` output:
- `_build/wasm/release/build/cmd/xsh_compile_wasi/xsh_compile_wasi.wasm`
- run with `moon run --target wasm src/cmd/xsh_compile_wasi -- ...` (or `just run-compiler-wasi-wasm ...`)
- compiler filesystem access is routed through `src/io.FileSystemAdapter` abstraction
- `xsh_compile_wasi` では `--wasm` が `wasm-gc` を選ぶ（MVP を使う場合は `--wasm-mvp`）
- 現状 `wasm-gc` backend は実験段階のため、複雑な文法は `--wasm-mvp` を使う

## WASM Execution

### With async host runtime (supports sleep)

```bash
# Build Rust host runtime
just build-async-host

# Run sleep demo
just sleep-demo

# Run any WASM with sleep support
just run compile --wasm your_script.xsh -o /tmp/out.wasm
just run-wasm-async /tmp/out.wasm
```

### With wasmtime (basic)

```bash
just run compile --wasm script.xsh -o /tmp/out.wasm
wasmtime /tmp/out.wasm
```

### With `deps/wasmtime` submodule (experimental flags)

```bash
# one-time init + build
just wasmtime-submodule-init
just build-wasmtime-submodule

# run wasmtime from submodule directly
just wasmtime-submodule run -W gc --invoke run /tmp/out.wasm

# or switch existing xsh scripts/tasks to submodule wasmtime
XSH_USE_WASMTIME_SUBMODULE=1 just component-run script.xsh
XSH_USE_WASMTIME_SUBMODULE=1 just bench-wasmtime

# inject extra wasmtime runtime flags into xsh scripts/*
# (space-separated list; each token is passed as -W / -S)
XSH_WASMTIME_WASM_FLAGS='component-model-async=y concurrency-support=y' \
XSH_WASMTIME_WASI_FLAGS='p3=y' \
XSH_USE_WASMTIME_SUBMODULE=1 \
just component-run script.xsh

# flags are also propagated through justfile-backed tasks
XSH_WASMTIME_WASM_FLAGS='gc=y' just bench-wasmtime

# inspect current flag env values used by scripts/wasmtime_run.sh
just show-wasmtime-flags

# run minimal WASI Threads probe (imports wasi::thread-spawn + env::memory)
# defaults to:
#   XSH_WASMTIME_WASM_FLAGS='threads=y shared-memory=y'
#   XSH_WASMTIME_WASI_FLAGS='threads=y'
XSH_USE_WASMTIME_SUBMODULE=1 just wasi-threads-probe

# direct runner under x/threads
XSH_USE_WASMTIME_SUBMODULE=1 src/x/threads/run_probe.sh
```

### With wasmtime stack-switching (x86_64 Linux only)

```bash
# Via container (for stack-switching support)
just wasmtime-stack-switching /tmp/out.wasm
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
├── xsh/            # Interpreter and compilation
├── x/fp/           # Floating-point to decimal formatter utilities
├── x/module_graph/ # Experimental module graph index and codecs
├── cmd/xsh/        # CLI command implementation (native/js)
├── cmd/xsh_wasi/   # WASI line-REPL command (wasm)
└── tests/          # Integration-like blackbox tests

examples/
├── *.xsh           # Example scripts (interpreter)
└── wasm/           # WASM-only examples (require host)

xsh/
└── std/            # xsh core library (self-hosted std modules)

examples/async_host/  # Rust/wasmtime host runtime
```

## Docs

- `docs/xsh.md` - Language specification (normative for implemented behavior)
- `docs/module_design.md` - Module design proposals (non-normative)
- `docs/module_system.md` - Legacy module draft notes (non-normative)
- `docs/async_design.md` - Async design proposals (non-normative)
- `docs/unstable_features.md` - Unstable runtime feature flags (`--unstable-async`, `--unstable-threads`)

## Fixtures

Fixtures live in `fixtures/*.xsh` and include a `__DATA__` JSON section.
`moon test` runs them via `src/tests/fixture_test.mbt`.

WASM fixtures live in `fixtures/wasm/*.xsh` and compare expected WAT.
WASM GC fixtures live in `fixtures/wasm_gc/*.xsh` and check for `struct.new/get/set`.

## Bench

```bash
just bench-wasmtime
just bench-compare
just bench-cmd-latency
just bench-scratch-workflow
just bench-symbol-index
just bench-advanced-graph
just bench-typechecker
```

`bench-scratch-workflow` は scratch 開発フローを段階別に計測する。

- `XSH_BENCH_SCENARIOS=all|eval|finalize|export_apply|full` (`all` は `,` 区切り指定可)
- `XSH_BENCH_CHAIN=<N>` 定義チェーン長（デフォルト `40`）
- `XSH_BENCH_WARMUP=<N>` / `XSH_BENCH_RUNS=<N>`
- `XSH_BENCH_EXPORT_JSON=<path>` で `hyperfine` の JSON を保存

## License

MIT
