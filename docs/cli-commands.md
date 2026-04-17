# CLI Commands Reference

This document clarifies the role of each `vibe` CLI command, with special attention to the compile/build variants and other commonly confused command pairs.

## Quick Reference: Compile & Build Commands

| Command | Audience | Purpose |
|---------|----------|---------|
| `build` | User | Produce a standalone `.wasm` binary from a `.vibe` file (debug or release) |
| `compile` | User | Full-featured compilation with format selection (WASM, Component, WIT, IR, WAC) |
| `compile-lite` | Internal | Minimal compile path for strict performance benchmarking |
| `precompile` | User (advanced) | Batch-compile a directory of `.vibe` modules to `.wasm` |
| `compile-closure-payload` | Internal | Compile a materialized closure payload to WASM |

## User-Facing Commands

### run

Execute a vibe script. The final top-level expression must be pure.

```
vibe run <file>
```

Compiles and runs the script via WASM. Uses a persistent session worker by default (disable with `VIBE_USE_SESSION_HTTP=0`). After successful execution, the linked debug cache is populated in the background for faster subsequent runs.

### build

Produce a standalone `.wasm` binary from a `.vibe` file. This is the recommended command for producing distributable WASM artifacts.

```
vibe build <file.vibe>
vibe build --release <file.vibe>          # optimized (-Oz), default
vibe build --debug <file.vibe>            # fast incremental (linked debug mode)
vibe build -o output.wasm <file.vibe>     # explicit output path
```

- **`--release`** (default): Full compilation with `-Oz` optimization. Falls back to unoptimized if the optimizer does not support generated opcodes.
- **`--debug`**: Uses a linked debug fast path that caches library WASM modules and only recompiles user code when sources change. Significantly faster for iterative development.
- Output defaults to `<basename>.wasm` in the current directory.

### compile

Full-featured compilation with explicit control over output format, optimization level, and advanced options. Use this when you need a specific output format or features not available through `build`.

```
vibe compile <file.vibe>                              # default: core WASM
vibe compile --wasm <file.vibe>                       # core WASM (explicit)
vibe compile --wasm-js-string <file.vibe>             # WASM with JS string builtins
vibe compile --wasm-gc <file.vibe>                    # WASM GC proposal
vibe compile --component <file.vibe>                  # WASM Component Model
vibe compile --component-string-lift <file.vibe>      # Component with string lifting
vibe compile --wit <file.vibe>                        # Generate WIT interface
vibe compile --wit-component <file.vibe>              # WIT + Component combined
vibe compile --wac <file.vibe>                        # WAC composition
vibe compile --compose-p3 --adapter a.wasm <file>     # P3 component composition
vibe compile -Os -o out.wasm <file.vibe>              # custom optimization level
vibe compile --no-dce <file.vibe>                     # disable dead code elimination
vibe compile --coverage <file.vibe>                   # coverage instrumentation (test-only)
vibe compile --debug-errors <file.vibe>               # keep error strings in WASM
vibe compile --http-host-imports <file.vibe>          # wire HTTP builtins to host imports
vibe compile --library <file.vibe>                    # library mode
```

Output defaults to `dist/<basename>.<ext>`.

### When to use `build` vs `compile`

- **Use `build`** for the common case: you want a `.wasm` file and don't need fine-grained control over the output format.
- **Use `compile`** when you need a specific output format (Component Model, WIT, WAC, WASM-GC), coverage instrumentation, or other advanced options.

### precompile

Batch-compile all `.vibe` modules in one or more directories to `.wasm`. Useful for precompiling library/prelude modules ahead of time.

```
vibe precompile <dir...>
vibe precompile --out-dir dist <dir...>
vibe precompile --wasm-js-string <dir...>
vibe precompile -Os <dir...>
```

- Skips `_test.vibe` and `_bench.vibe` files.
- Output directory structure mirrors input, with the first path component stripped (e.g., `vibe/prelude/foo.vibe` -> `dist/prelude/foo.wasm`).

### test

Run test blocks in one or more files or directories.

```
vibe test <file|dir...>
vibe test --jobs 4 <dir...>
```

### check

Parse and type-check scripts without producing output.

```
vibe check <file...>
vibe check --profile-tsv timing.tsv <file...>
```

### shell (Interactive Shell)

Interactive TUI shell for evaluating vibe expressions.

```
vibe shell
vibe shell --tui           # TUI mode
vibe shell --ai            # AI-assisted mode
vibe shell --no-posix      # disable shell/POSIX commands
```

### shell-stdin

Line-oriented shell reading from stdin. Suitable for piping input or non-interactive use.

```
vibe shell-stdin
vibe shell-stdin --no-prompt
vibe shell-stdin --tty
vibe shell-stdin --no-tty
```

### fetch / update-lock

Resolve imports and synchronize the lock file (`index.lock`). `update-lock` is an alias for `fetch` -- they are identical.

```
vibe fetch <file>
vibe update-lock <file>    # same as fetch
```

### fmt

Normalize and format vibe source files.

```
vibe fmt <file...>
vibe fmt --dry-run <file...>
```

### normalize

Normalize declaration order and apply dead code elimination, then format.

```
vibe normalize <file...>
vibe normalize --write <file...>
vibe normalize --check <file...>
```

### init / new

- `vibe init [dir]` -- Create `index.vibe`, `index.lock`, and `.vibe/` in the target directory.
- `vibe new <dir>` -- Scaffold a new project (init + `main.vibe`).

### Other User Commands

| Command | Description |
|---------|-------------|
| `bench <file\|dir...>` | Run compiled `bench {}` blocks with optional `--runs`, `--warmup`, `--n` |
| `bench-file <file>` | Run benchmarks in a single file |
| `hash <file>` | Compute normalized AST hash |
| `save <file>` | Save module to content-addressed store |
| `finalize` | Refactor scratch/db source (`--db`, `--export`, `--library`, `--print`, `--dry-run`) |
| `apply <file>` | Resolve lock + graph head and apply artifacts |
| `symbols [--json] <file>` | List symbols and index inclusion status |
| `explain-import <file>` | Visualize import ref normalization and lock lookup |
| `clean` | Remove build artifacts |
| `lsp` | Start LSP server (stdin/stdout) |
| `ide <subcommand>` | Symbol/type index queries (`outline`, `peek-def`, `search`) |
| `lsif [-o out.lsif] <file>` | Emit LSIF index |
| `expand <file>` | Macro/import expansion |
| `history reset` | Reset scratch namespace history/db |

## Internal Commands

These commands are used by the vibe toolchain internally (e.g., by `build --debug` or the session worker). They may change without notice and are not intended for direct use.

### compile-lite

Minimal compile path used for strict performance comparisons (benchmarking the compiler itself). Strips all optional features: no coverage, no debug errors, no HTTP host imports, no Component Model.

```
vibe compile-lite [--wasm|--wasm-linear|--wasm-gc] [--no-dce] [--in-memory] [--profile-tsv path] [-O<level>] [-o out] <file>
```

- `--in-memory`: Compile without writing output to disk (pure compile-time measurement).
- `--profile-tsv`: Write detailed phase timing (load/type/compile/write) to a TSV file.
- `--profile-callstack`: Write call-stack profiling data.

### compile-closure-payload

Compile a materialized closure payload (produced by `emit-closure-payload`) to WASM.

```
vibe compile-closure-payload <in> <out> [mvp|no-dce]
```

### emit-module-source

Extract entry-pruned module source from a database file.

```
vibe emit-module-source <in> <out> <entry>
```

### emit-closure-payload

Materialize transitive closure payload from a source file.

```
vibe emit-closure-payload <in> <out>
```

### wasm-shell-stdin

Line-oriented shell that compiles each expression to a separate WASM file. Used for testing the compilation pipeline.

```
vibe wasm-shell-stdin [--no-prompt] [-o dir]
```

### session-http / session-json

Persistent session workers that accelerate `run`/`check`/`test` by keeping compilation state in memory.

- `session-http --port N`: HTTP-based session (localhost).
- `session-json`: stdin/stdout JSON protocol.

### Other Internal Commands

| Command | Description |
|---------|-------------|
| `write-file` | Materialize a selector to an output file |
| `index <build\|query\|verify\|wal\|ref>` | Advanced graph index operations |

## Shell Mode Comparison

| Mode | Interface | Use Case |
|------|-----------|----------|
| `shell` | Interactive TUI | Day-to-day interactive exploration |
| `shell-stdin` | stdin/stdout line shell | Scripting, piping, CI, editor integration |
| `wasm-shell-stdin` | stdin/stdout, writes `.wasm` per expression | Internal: testing the WASM compilation pipeline |

## Global Flags

| Flag | Description |
|------|-------------|
| `--syntax vibe` | Select parser mode |
| `--unstable-async` | Enable async runtime features (experimental) |
| `--unstable-threads` | Enable thread runtime features (experimental) |
| `--llm` | Enable LLM/RLM capabilities (requires `VIBE_LLM_PROVIDER`) |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `VIBE_RUN_BACKEND=release\|monolithic` | Disable linked debug fast path for `run` |
| `VIBE_USE_SESSION_HTTP=0` | Disable persistent session worker for run/check/test |
| `VIBE_TEST_JOBS` | Default parallelism for `test` (max 16) |
| `VIBE_TEST_COVERAGE=1` | Required to enable `--coverage` in compile |
