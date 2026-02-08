# xsh

xsh language prototype and runtime (MoonBit).

## Features

### Language
- Type inference with effects (`with {Async}`, `with {Error}`)
- Pattern matching and destructuring
- Module system with import/export
- Async/await syntax
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
just release-check  # full check before release
```

## CLI

```bash
# Run xsh script
just run run examples/basics.xsh
# (comprehensive syntax tour)
just run run examples/syntax.xsh

# Run tests in script
just run test examples/*.xsh

# Compile to WASM
just run compile --wasm examples/wasm/sleep_demo.xsh -o /tmp/out.wasm

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

# Build wasm line REPL (preview2 stdio imports)
just build-repl-wasi-wasm

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
- `_build/wasm/release/build/xsh_wasi_cli/xsh_wasi_cli.wasm`
- this binary imports `wasi:cli/stdin|stdout@0.2.0` and `wasi:io/streams@0.2.0` directly
- run it with a component/p3-compatible host (for example moon-component/mwac integration), not `moon run --target wasm`
- for script-level stdio execution, use `just component-run <file.xsh>`
- moonix 実行は `just component-run-moonix <file.xsh>`（必要なら `MOONIX_BIN=/path/to/moonix`）
- `component-run-moonix` は `moonix` 未導入時に `scripts/bootstrap_moonix_bin.sh` を自動試行

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

### With wasmtime stack-switching (x86_64 Linux only)

```bash
# Via container (for stack-switching support)
just wasmtime-stack-switching /tmp/out.wasm
```

## Project Structure

```
src/
├── core/           # AST types and serialization
├── parser/         # Lexer and parser
├── checker/        # Type checker with effects
├── codegen/        # WASM code generation
├── xsh/            # Interpreter and compilation
└── xsh_cli/        # CLI application

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

## Fixtures

Fixtures live in `fixtures/*.xsh` and include a `__DATA__` JSON section.
`moon test` runs them via `src/xsh/fixture_test.mbt`.

WASM fixtures live in `fixtures/wasm/*.xsh` and compare expected WAT.
WASM GC fixtures live in `fixtures/wasm_gc/*.xsh` and check for `struct.new/get/set`.

## Bench

```bash
just bench-wasmtime
just bench-compare
just bench-cmd-latency
```

## License

MIT
