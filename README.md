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
just run run examples/syntax.xsh

# Run tests in script
just run test examples/*.xsh

# Compile to WASM
just run compile --wasm examples/wasm/sleep_demo.xsh -o /tmp/out.wasm

# Compile to Component Model WASM
just run compile --component script.xsh -o out.component.wasm

# Interactive REPL
just run repl

# Install CLI to ~/.local/bin/xsh
just install
```

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

examples/async_host/  # Rust/wasmtime host runtime
```

## Docs

- `docs/xsh.md` - Language/spec notes
- `docs/module.md` - Module system design

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
