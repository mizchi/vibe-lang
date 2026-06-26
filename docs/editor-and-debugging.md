# Editor Integration & Debugging

vibe ships first-class editor support (LSP) and a function-granularity
interactive debugger, both driven by the same `vibe` launcher you installed
(see [install.md](install.md)). This guide covers:

- [Language Server (`vibe lsp`)](#language-server-vibe-lsp)
- [Editor query primitives](#editor-query-primitives)
- [Interactive debugging (`vibe run --break` / `--trace`)](#interactive-debugging)
- [VS Code integration (DAP)](#vs-code-integration)
- [Keeping the compiler up to date (`vibe self update`)](#keeping-the-compiler-up-to-date)

---

## Language Server (`vibe lsp`)

```bash
vibe lsp        # speaks LSP over stdin/stdout
```

`vibe lsp` is a Language Server Protocol server that runs on the same wasmtime
runner + selfhost compiler wasm as the rest of the toolchain (no separate
runtime to install — see ADR-0057 / the 1.0 freeze). Point any LSP client at
the `vibe lsp` command. It provides:

| Feature | Notes |
| --- | --- |
| **Diagnostics** | Parser error-recovery surfaces *all* top-level syntax errors at once (not just the first), plus the located type error for a clean parse. |
| **Hover** | Typed hover — shows the inferred type of the identifier under the cursor, including locals and parameters (per-node type table). |
| **Document symbols** | AST-accurate outline (`vibe symbols`) — functions, values, structs, enums, traits, type aliases, effects, and module-nested declarations, with correct `SymbolKind`s. Handles multi-line declarations; ignores names in strings/comments. |
| **Go to definition** | AST-accurate declaration span (`vibe symbols`), with a line-regex fallback for older compilers. |
| **References / Rename** | AST-accurate via scope-aware binding occurrences (no string/comment false matches; distinguishes shadowed bindings). |
| **Completion** | Identifier and member completion. |
| **Signature help** | Parameter info at call sites. |

Diagnostics rely on a *fresh* compiler wasm built at install time (the seed
fallback has no diagnostics path). `scripts/install.sh` builds that fresh
compiler by default; if you only have the committed seed, hover/diagnostics
degrade gracefully to empty rather than erroring.

### Editor query primitives

The LSP server is built on three launcher subcommands you can also call
directly (useful for scripting or wiring a different editor):

```bash
vibe type-at <file.vibe> <line> <col>     # inferred type of the identifier at 1-based (line,col)
vibe binding-at <file.vibe> <line> <col>  # source spans (START END char offsets) of every occurrence of that binding
vibe symbols <file.vibe>                  # declaration outline (NAME KIND START END per line)
vibe diagnostics <file.vibe>              # all diagnostics, one per line; empty output = clean
```

- `type-at` powers hover. Empty output means there is no env-visible
  identifier at that position.
- `binding-at` powers rename/references. Each line is a `START END` pair of
  char offsets for one occurrence of the binding under the cursor.
- `symbols` powers the document outline and go-to-definition. Each line is
  `NAME KIND START END`, where `KIND` is an LSP `SymbolKind` integer and
  `START END` are char offsets of the declaration name. Because it walks the
  parsed AST (not a line regex) it handles multi-line declarations and
  module-nested symbols and never reports a name that only appears in a string
  or comment.
- `diagnostics` always exits 0 (it is a *report*, not a pass/fail), so a clean
  file simply yields no output.

---

## Interactive debugging

The debugger is **function-granularity** and entirely opt-in — a normal
`vibe run` carries no debug instrumentation.

### Source-mapped traps (always on)

When a program traps at runtime, backtrace frames name the user function *and*
its source line, e.g.:

```
  at boom (prog.vibe:1)
  at main (prog.vibe:2)
```

This needs no flags — it comes from the wasm name section plus the `.funcmap`
sidecar the compiler writes for the entry file.

### Call trace (`--trace`)

```bash
vibe run --trace prog.vibe
```

Compiles with function-call trace instrumentation and prints the entry
sequence, each line annotated with its source location:

```
trace: main (prog.vibe:2)
trace: helper (prog.vibe:1)
```

### Breakpoints (`--break`)

```bash
vibe run --break helper prog.vibe              # break at one function (by name)
vibe run --break helper,worker prog.vibe       # break at several
vibe run --break prog.vibe:3 prog.vibe         # break at the function declared on line 3
vibe run --break 3 prog.vibe                    # bare line (any file)
```

A `<file>:<line>` (or bare `<line>`) breaks at that source line, and a name
breaks at that function's entry. Both forms can be mixed in one comma-separated
spec. Line breakpoints work at **interior** statement lines, not just function
declarations: a single-file program compiled in break mode emits a
`vibe::dbg_line` hook at each `let` / statement boundary, so `--break prog.vibe:7`
pauses when execution reaches line 7 even mid-function. Stepping (`s`/`n`) then
advances at line granularity.

Two scope notes: (1) a statement whose value is a bare literal (e.g. `let a = 1`)
carries no source offset, so it is not individually breakable — put the
breakpoint on a neighbouring line that references a name. (2) Interior-line
breakpoints are emitted only for **single-file** entry programs; a program with
imports falls back to function-declaration-line breakpoints (the merge of
multiple files would otherwise collide source offsets).

Execution pauses at the entry of each named function and prints, to stderr:

```
breakpoint hit: helper
  args: [x=20]
  at helper (prog.vibe:1)
  at main (prog.vibe:2)
```

`args:` shows the function's parameters by **name** (`x=20`) when the compiler
recorded them (the `vibe.dbgnames` section); it falls back to positional
values if names are unavailable.

At each pause the debugger reads **one** command from stdin:

| Command | Action |
| --- | --- |
| `s` / `step` | step into |
| `n` / `next` | step over |
| `o` / `finish` | run to the end of the current function |
| `c` / `continue` (or empty line) | continue to the next breakpoint |
| `q` / `quit` | abort (exit 130) |

A step pause prints `stopped at: <fn>` instead of `breakpoint hit:`. stdout and
the program's exit status pass through unchanged, so a broken run still
produces its normal result when continued.

---

## VS Code integration

`integrations/vscode-vibe/` is a VS Code extension contributing both syntax
highlighting and a debug adapter. The debug side bridges VS Code's Debug
Adapter Protocol to the function-granularity debugger above via
[`js/vibe/dap_server.js`](../js/vibe/dap_server.js) (a small, dependency-free
stdio DAP server).

The adapter:

- maps requested breakpoint **lines** to the enclosing top-level function
  **names** (vibe breakpoints are by function name),
- spawns `vibe run --break ...` with stdin piped and stderr parsed,
- translates each pause into a DAP `stopped` event, exposing the call stack
  (`stackTrace`) and decoded, **named** arguments (`variables`),
- drives the runner's stdin from VS Code's continue / step over / step into /
  step out buttons.

See [`integrations/vscode-vibe/README.md`](../integrations/vscode-vibe/README.md)
for installation. The launcher streams `--break` / `--trace` stderr live (via a
FIFO) so interactive stepping in the editor is not buffered until the program
exits.

---

## Keeping the compiler up to date

The runner (`moonrun_wt`) and the compiler wasm are distributed and updated
independently (ADR-0056 / テーマ1). To swap in a newer compiler artifact
without rebuilding the runner:

```bash
vibe self update --cli-wasm <path-to-vibe-cli.wasm>
```

This installs the given compiler wasm and AOT-compiles it to a host-specific
`.cwasm` for fast startup. `vibe version` reports the active toolchain version,
which is the basis for the SemVer guarantee described in
[spec/1.0-freeze.md](spec/1.0-freeze.md).
