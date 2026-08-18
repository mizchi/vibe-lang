# CLI Commands Reference

This document clarifies the role of each `vibe` CLI command, with special attention to the compile/build variants and other commonly confused command pairs.

Implementation policy: the canonical CLI source lives in `lib/@vibe/compiler/` and
`lib/@vibe/cli/`. The MoonBit host (including the `src/cmd/*` entrypoints) was retired
in #594; new command behavior is added only in `lib/@vibe/compiler/` /
`lib/@vibe/cli/`.

## Quick Reference: Compile & Build Commands

| Command | Audience | Purpose |
|---------|----------|---------|
| `build` | User | Produce a standalone `.wasm` binary from a `.vibe` file (debug or release) |
| `compile` | User | Full-featured compilation with format selection (WASM, Component, WIT, IR, WAC) |
| `serve` | User | Compile an HTTP handler + compose with the wasi-http P3 adapter + `wasmtime serve` (#537) |
| `compile-lite` | Internal | Minimal compile path for strict performance benchmarking |
| `precompile` | User (advanced) | Batch-compile a directory of `.vibe` modules to `.wasm` |
| `compile-closure-payload` | Internal | Compile a materialized closure payload to WASM |

## User-Facing Commands

### run

Execute a vibe script. The final top-level expression must be pure.

```
vibe run <file>
```

Compiles and runs the script via WASM. By default this uses the one-shot execution path; set `VIBE_USE_SESSION_HTTP=1` to opt into the persistent session worker. Set `VIBE_LINKED_CACHE_BACKGROUND=1` to populate the linked debug cache in the background after a successful run.

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
vibe compile --wit <file.vibe>                        # Generate the WIT world for the file's
                                                      #   effect surface (docs/effect-wit-mapping.md)
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

### serve (#537)

Serve a wasi-http P3 handler over HTTP: compile the handler to a component,
compose it with the P3 HTTP adapter (`wac plug`), and launch `wasmtime serve`.

```
vibe serve <handler.vibe>                       # http://127.0.0.1:8080/
vibe serve <handler.vibe> --port 9000
vibe serve <handler.vibe> --addr 0.0.0.0:8080
vibe serve <handler.vibe> --no-run              # emit component + WIT only
vibe serve <handler.vibe> --adapter my.component.wasm
```

The handler contract (see [effect-wit-mapping.md](effect-wit-mapping.md)):

```vibe
export let handler = (method: String, url: String, headers: String, body: String) -> String
```

returning `"STATUS\n<Header: value lines>\n\n<body>"`. Internally the handler
may use algebraic effects (`perform` / `handle`, e.g. `lib/@vibe/wasi/p3/`), as
long as they are discharged inside the file.

The last parameter may instead be a `HostStream` — the request body as it
arrives, rather than collected into a `String` first (#1540):

```vibe skip
export let handler = (method: String, url: String, headers: String, body: HostStream) -> String with Async {
  let mut out = ""
  let mut go = true
  while go {
    let b = host_stream_next(body)
    if b < 0 { go = false } else { out = String::concat(out, String::from_char_code(b)) }
  }
  "200\n\n\{out}"
}
```

`host_stream_next` suspends, so this form carries `with Async` — and the two
go together in both directions: `with Async` without a `HostStream` body has
nothing to await, and a `HostStream` body without `Async` could never be read.
`vibe serve` rejects either half on its own with that reason.

The stream form needs the **stream-body adapter**, whose `handler` import takes
`body: stream<u8>`; the launcher picks it by reading the WIT sidecar, so the
only manual step is building it:

```
VIBE_HTTP_ADAPTER_BODY_STREAM=1 scripts/build_wasi_http_p3_full_adapter.sh \
  _build/http_adapter/vibe_http_p3_body_stream_adapter.component.wasm
```

- Artifact generation lives in the compiler (`VIBE_SERVE_COMPONENT=1`); adapter
  resolution, composition, and serving live in the launcher — the compiled
  `<handler>.component.wasm` + `<handler>.wit` are reusable on their own.
- Prerequisites for the serve step: `wac` (`cargo install wac-cli`) and
  `wasmtime` (v45+). The P3 adapter component is built once by
  `scripts/build_wasi_http_p3_full_adapter.sh` (cargo + wasm-tools) or passed
  via `--adapter` / `VIBE_HTTP_ADAPTER`.
- E2E gates: `scripts/test_wasi_http_p3_full_gate.sh` (String body),
  `scripts/test_serve_async_lift_gate.sh` (async lift, same String contract),
  `scripts/test_serve_body_stream_gate.sh` (`HostStream` body, byte-exact echo).

### precompile

Batch-compile all `.vibe` modules in one or more directories to `.wasm`. Useful for precompiling library/prelude modules ahead of time.

```
vibe precompile <dir...>
vibe precompile --out-dir dist <dir...>
vibe precompile --wasm-js-string <dir...>
vibe precompile -Os <dir...>
```

- Skips `_test.vibe` and `_bench.vibe` files.
- Output directory structure mirrors input, with the first path component stripped (e.g., `lib/@vibe/prelude/foo.vibe` -> `dist/prelude/foo.wasm`).

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

### shell (Compiled REPL) (#805)

Minimal REPL implemented in the launcher. Per ADR-0034 there is **no
interpreter**: the session is a buffer of top-level declarations kept in a
temp dir, and every input line triggers a full recompile of that buffer
through the same compile path as `vibe run` (accumulate + recompile).

```
vibe shell                    # interactive (prompt on a tty)
vibe shell prelude.vibe       # preload a file's declarations into the session
printf '...\n' | vibe shell   # stdin not a tty: no prompts, scriptable
```

Line classification:

- A line starting with a declaration keyword (`fn`/`let`/`struct`/`enum`/
  `type`/`import`/`effect`/`impl`/`trait`/`export`/`suberror`/`test`) is
  appended to the session buffer. The append is validated by recompiling the
  whole buffer; on any diagnostic it is **rolled back**, so the buffer can
  never become poisoned.
- Any other line is treated as an expression: it is wrapped in an internal
  synthetic Int-returning harness (not a `.vibex` entry), compiled against the buffer, and
  the produced wasm is executed. If the Int wrapper does not compile (a
  non-Int value, or an effect row the wrapper lacks), it is retried
  effects-only with a notice — use `:type` to inspect non-Int values.
  (Richer printing is blocked on known gaps: the `println`/`print` builtins
  have no codegen lowering in bare FS-mode compiles, prelude/io's
  `stdout_write` drags `vibe::*` host imports the standalone runner does not
  define, and `Stdout::write_char` writes the raw tagged value.)
- REPL commands: `:help`, `:quit`/`:q`, `:list` (print the buffer),
  `:clear`, `:load <file>` (append a file to the buffer, validated with
  rollback), `:type <expr>` (inferred type, backed by the `vibe type-at`
  editor primitive).

Caveats (by design of the compiled model):

- **Earlier side effects re-run on every expression line.** Each evaluation
  compiles and runs a fresh program, so the whole session replays. This is
  the honest compiled-REPL reading of ADR-0069's memoized-thunk semantics:
  until binding-level memoization lands in the compiler, "memoization" is
  re-computation from source, not a persistent process image.
- Declarations must fit on one line (no multi-line continuation yet).
- Diagnostics point into the composed session program: for a rejected
  declaration/`:load` the reported line matches the `:list` buffer;
  expression errors reference the synthetic wrapper.
- Only Int values print today (see above); everything else evaluates
  effects-only with a stderr notice.
- The session lives in a temp dir with a `lib` symlink, so stdlib imports
  (`import ./lib/@vibe/...`) resolve; other relative imports do not move
  with the session.

The pre-#594 MoonBit-host `shell` variants (`--tui`, `--ai`, `--no-posix`)
and the separate `shell-stdin` command were retired; `vibe shell` reads
stdin line-oriented whenever stdin is not a tty.

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

**Collection wrapping** (ADR-0107, #2103/#2104). A bracket literal is written
on the line it starts on when the joined form ends at or before column 80 --
`[1, 2, 3]`, `[1]`, `[]` -- and goes one element per line when it does not.
The formatter decides that one alone: interior newlines inside brackets have
never survived it, so there is no author choice to read there. A brace field
list -- `struct N { .. }`, `N::{ .. }` -- keeps the line structure it was
written with, like every other brace container: one line stays one line (if it
fits), and a broken one is normalized to one field per line rather than left
packed after the braces are split. A line comment anywhere inside pins the
broken form, because joining would comment out the rest of the line. A broken
struct declaration keeps its `;` separators -- a newline is not a field
separator in the grammar.

`.vpkg` package contracts are formatted too, through a separate path
(`format_vpkg`, #1435). A `.vpkg` file is two languages stacked: the header
(`name = @scope/pkg`, `version = x.y.z`, `description =` + `#|` block,
`deps = { @scope/dep : x.y.z }`, `generated_hash =`) is **not** vibe syntax --
`@scope/pkg` is not an expression -- so it goes through a dedicated writer
that canonicalizes key order, value spacing, the two-space continuation
indent and the deps sort order. Everything below the header is ordinary
bodyless vibe and goes through the same CST formatter as any `.vibe` file.

The boundary is not a heuristic: it mirrors the line classification in
`scan_package_header` (`lib/@vibe/compiler/contract/contract.vibe`), the
loader's own scanner, so a line the loader would not treat as a directive
always falls into the declaration region. If the header is malformed in a way
that makes the split unsafe -- an unterminated `deps = {`, a deps entry with
no `:`, or a key spelling the loader does not recognize such as `name  =` --
the formatter leaves the file **completely untouched** rather than guess. The
loader rejects such a file anyway, with a better message than a formatter
could give.

### normalize

Canonicalize a source file via the in-compiler normalize engine (#882):
parse -> module-flatten -> DCE from exported roots -> section layout
(`//# Imports / Types / Functions / Tests`) re-rendered through the AST
printer. The default rewrites the file in place.

```
vibe normalize <file.vibe>            # rewrite in place
vibe normalize --check <file.vibe>    # exit 1 if not normalized (no write)
vibe normalize --stdout <file.vibe>   # print the result (no write)
```

### init / new

- `vibe init [dir]` -- Create `index.vibe`, `index.lock`, and `.vibe/` in the target directory.
- `vibe new <dir>` -- Scaffold a new project (init + `main.vibex`).

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
| `rc-classify <file>` | RC classifier sets (`NAME SET[,SET...]`; empty = none) |
| `rc-plan [--fn NAME] <file>` | Perceus plan (`FN BINDING ACTION COUNT`; empty = no actions) |
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

### session-http / session-json

Opt-in persistent session workers that accelerate `run`/`check`/`test` by keeping compilation state in memory.

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
| `shell` (tty) | prompt loop, compiled REPL | Interactive exploration |
| `shell` (piped stdin) | line-oriented, no prompts | Scripting, CI, editor integration |

(The retired MoonBit-host `shell-stdin` / `wasm-shell-stdin` modes were
removed in #594; both are covered by piping into `vibe shell`.)

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
| `VIBE_USE_SESSION_HTTP=1` | Enable persistent session worker for run/check/test |
| `VIBE_LINKED_CACHE_BACKGROUND=1` | Enable background linked debug cache build after `run` |
| `VIBE_TEST_JOBS` | Default parallelism for `test` (max 16) |
| `VIBE_TEST_COVERAGE=1` | Required to enable `--coverage` in compile |
