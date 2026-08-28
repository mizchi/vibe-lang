# Editor Integration & Debugging

vibe ships first-class editor support (LSP) and a function-granularity
interactive debugger, both driven by the same `vibe` launcher you installed
(see [install.md](install.md)). This guide covers:

- [Language Server (`vibe lsp`)](#language-server-vibe-lsp)
- [Editor query primitives](#editor-query-primitives)
- [Structural search (`vibe grep`)](#structural-search-vibe-grep)
- [Interactive debugging (`vibe run --break` / `--trace`)](#interactive-debugging)
- [VS Code integration (DAP)](#vs-code-integration)
- [Keeping the compiler up to date (`vibe self update`)](#keeping-the-compiler-up-to-date)

---

## Language Server (`vibe lsp`)

```bash
vibe lsp        # speaks LSP over stdin/stdout
```

`vibe lsp` is a Language Server Protocol server that runs on the same wasmtime
runner + compiler wasm as the rest of the toolchain (no separate
runtime to install — see ADR-0057 / the 1.0 freeze). Point any LSP client at
the `vibe lsp` command. It provides:

| Feature | Notes |
| --- | --- |
| **Diagnostics** | Parser error-recovery surfaces *all* top-level syntax errors at once (not just the first), plus the located type error for a clean parse. |
| **Hover** | Typed hover — shows the inferred type of the identifier under the cursor, including locals and parameters (per-node type table). |
| **Document symbols** | AST-accurate outline (`vibe symbols`) — functions, values, structs, enums, traits, type aliases, effects, tests, benches, impls, and module-nested declarations, with correct `SymbolKind`s. Handles multi-line declarations; ignores names in strings/comments. Tests/benches are Function (12); `impl Trait for T` is one Method (6) named after `T`. |
| **Go to definition** | AST-accurate declaration span (`vibe symbols`), with a line-regex fallback for older compilers. |
| **References / Rename** | AST-accurate via scope-aware binding occurrences (no string/comment false matches; distinguishes shadowed bindings). |
| **Completion** | Identifier and member completion. |
| **Signature help** | Parameter info at call sites. |

Diagnostics rely on a *fresh* compiler wasm built at install time (the seed
fallback has no diagnostics path). `install/install.sh` builds that fresh
compiler by default; if you only have the committed seed, hover/diagnostics
degrade gracefully to empty rather than erroring.

### Editor query primitives

The LSP server is built on three launcher subcommands you can also call
directly (useful for scripting or wiring a different editor). **Positions are
bytes** — see [source-range-contract.md](source-range-contract.md) for the one
contract these commands share, and for the single place (the LSP boundary)
where it converts.

```bash
vibe type-at <file.vibe> <line> <col>     # inferred type of the identifier at 1-based (line, BYTE col)
vibe binding-at <file.vibe> <line> <col>  # source spans (START END byte offsets) of every occurrence of that binding
vibe symbols <file.vibe>                  # declaration outline (NAME KIND START END [DOC] per line)
vibe symbols --legend                     # KIND NAME table (LSP SymbolKind v1, 2026-08-17)
vibe check <file.vibe>                    # all diagnostics, one per line on stdout; empty output = clean, exit 1 if not
vibe check --single-file <file.vibe>      # same, analysing the buffer ALONE (no FS import resolution)
vibe check --single-file --json <file.vibe>  # same diagnostics as a JSON array of LSP Diagnostic objects (#820)
```

- `type-at` powers hover. Empty output means there is no env-visible
  identifier at that position. Field accesses resolve at BOTH positions of
  `obj.field` (#645): the base identifier and the field name each yield the
  projection type (EDot carries the field token's own offset).
- `binding-at` powers rename/references. Each line is a `START END` pair of
  byte offsets for one occurrence of the binding under the cursor.
- `symbols` powers the document outline and go-to-definition. Each line is
  `NAME KIND START END`, where `KIND` is an LSP `SymbolKind` integer and
  `START END` are byte offsets of the declaration name. Because it walks the
  parsed AST (not a line regex) it handles multi-line declarations and
  module-nested symbols and never reports a name that only appears in a string
  or comment. Tests and benches are Function (12). An empty test/bench name
  is outlined as the keyword `test`/`bench`. An `impl Trait for T` is one
  Method (6) named after `T` — the impl statement does not carry method
  children.
- **Doc comments (`DOC`).** A declaration's `///` doc comment is appended as a
  fifth field, present only when it has one — a declaration without a doc emits
  the same four fields it always did, with no trailing space. The doc is last
  because it is the only field that can contain spaces, so `cut -d" " -f1-4`
  still reads the fixed part; inside it a newline is the two characters `\n`
  and a backslash is doubled, so one declaration is always one line. The
  structured form (real newlines, for LSP detail) is `symbol_spans_with_docs`.
- **SymbolKind legend v1 (2026-08-17).** `KIND` integers are LSP
  [`SymbolKind`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind)
  values. The machine-readable table is `vibe symbols --legend`: one
  `KIND NAME` line per kind this command actually emits, no decoration,
  never empty. `--help` / `-h` print usage and point at that table. A file
  outline is unchanged when `--legend` is absent. Bump the version when a
  KIND number is added or remapped; never reuse a number.

  | KIND | LSP name | vibe declaration |
  | --- | --- | --- |
  | 2 | Module | `module` |
  | 6 | Method | `impl Trait for T` (named after `T`) |
  | 10 | Enum | `enum`, `suberror` |
  | 11 | Interface | `trait` |
  | 12 | Function | `fn`, `test`, `bench`, let-bound functions |
  | 13 | Variable | other `let` / `let mut` |
  | 23 | Struct | `struct` |
  | 24 | Event | `effect` |
  | 26 | TypeParameter | `type` alias |
- **`--single-file` analyzes ONE file and does not follow its imports**, so on a
  file with imports it reports names it cannot see as undefined. A file that is
  perfectly valid under a plain `vibe check` can come back with
  `unknown name: T::Crimson` in this mode, purely because
  `import ./dep.vibe { Hue as T }` was never resolved. Empty output therefore
  means "clean *as a standalone file*", not "compiles". **To judge a file that
  imports anything, drop the flag** — buffer scope exists for the editor's
  per-buffer feedback, where the unsaved text is the thing being asked about.
  The converse gap — a name imported from a module that does not export it — is
  missed by the single-file mode and only surfaces at codegen (#1521); a plain
  `vibe check` reports it (#1521/#1533).
- Both modes share one contract (#1567): diagnostics on **stdout**, one per
  line, `error: ` marking each diagnostic start (continuations like `hint: `
  are indented under it, so `grep -c '^error: '` is an exact count); **clean =
  empty output + exit 0**; anything reported = **exit 1**.
- `--json` is available in `--single-file` mode, where the compiler's own
  structured emitter produces real ranges: it reuses the same `[@off=N]`-derived
  offsets `vibe lsp`'s `publishDiagnostics` uses, wrapped as
  `{range, severity, source, message}` objects — no separate
  structured-diagnostic format to keep in sync. A clean file yields `[]` and
  exit 0. Without `--single-file` the launcher refuses `--json` rather than
  inventing ranges: the import-resolving lane reports diagnostics as message
  text with no per-diagnostic span attached (#1567).
- `vibe diagnostics` is the **deprecated** spelling of `vibe check
  --single-file`. It is kept behaviourally frozen (raw lines with no `error: `
  prefix, always exit 0) for editors already wired to it — see
  [spec/stable-surface.md](spec/stable-surface.md).
- Once a file type-checks and codegen-validates cleanly, the single-file mode
  also runs two soft, warning-only passes (#1129) that never affect the exit
  code or fail a compile: **unused imports** (a named `import ./f.vibe { a }`
  item, or an `import @pkg @alias` alias, never referenced in the file —
  a whole-program-merge-only alias may still legitimately trip this, since
  a single-file check cannot see cross-file usage) and **unbound non-Unit
  return values** (a bare call statement mid-block, e.g. `foo();`, whose
  return type isn't `Unit` and isn't bound — write `let _ = foo()` to mark
  the discard as intentional). Both are prefixed `"warning: "` in plain
  mode and reported as LSP `DiagnosticSeverity.Warning` (2) in `--json`
  mode, distinguishing them from every other (`Error`, 1) diagnostic here.
- Each `--json` entry also carries a `data` field (#820 sub-item 2): `null`
  for most diagnostics, or a structured fix-it for an effect-row mismatch —
  `{kind: "add_with_clause", target: <function name>, add: [<missing
  operations>], with: [<full resulting row>], note}`. `target` is a NAME, not
  a position: resolve it to a location with `vibe symbols <file>` (which
  already returns `NAME KIND START END` byte offsets) rather than expecting a
  span in the diagnostic itself — the checker only tracks function names and
  effect rows today, not per-declaration source spans, so `data` doesn't
  pretend otherwise.

---

## Structural search (`vibe grep`)

Every primitive above answers **"position → meaning"**. `vibe grep` runs the
other way — **"structure → positions"** — and its filters run on the checker's
answers, not on the grammar alone the way [moongrep](https://github.com/moonbit-community/moongrep)
and ast-grep do (their guards can only regex an identifier capture). #1572.

```bash
vibe grep --pattern 'match $(v:exp) { Some($(x:pat)) => $(b:exp), None => $(n:exp) }' lib
vibe grep --pattern 'Iterator::map($(a:args))' --json lib
```

### Pattern language

A pattern is a single **expression**, written in ordinary vibe syntax, with
`$(name:kind)` metavariables:

| kind | matches | capture text |
| --- | --- | --- |
| `exp` | any single expression | the printed expression |
| `id` | an identifier only — also a field / binder / constructor / type NAME where one is grammatical | the name |
| `const` | a literal only (Int / Double / String / Bool / unit) | the literal |
| `arg` | one argument position (like `exp`, but also matches a labeled argument `l=e`) | the printed argument |
| `args` | **zero or more** consecutive argument positions; at most one per list | the arguments, comma-joined |
| `pat` | any single pattern (match arm / destructuring) | the printed pattern |
| `type` | any single type expression | the printed type |

`$(_:kind)` is anonymous and never has to agree with another occurrence; any
other name must match the **same text** everywhere it appears in the pattern.

`args` is an addition to the six kinds #1572 lists. Without it a pattern could
only ever match one fixed arity, so "every call to this, whatever it is passed"
— the thing a migration sweep actually needs — would not be expressible.

Matching is on the **AST**, so newlines, indentation and comments cannot affect
it. Both the pattern and the file go through the *same* parser, which means
they get the same desugaring. Measured on the current parser:

- `xs |> transform(f)` and `transform(xs, f)` are the same AST and match each
  other;
- `xs.transform(f)` keeps its `EDot` callee and matches only the method
  spelling.

Structural matching keeps the method form separate on purpose. The
resolved-name filter below closes the **alias** half of that gap (`It::map` and
`Iterator::map` are one query), but it does **not** yet relate `xs.map(f)` to
`Iterator::map`: a method callee is an `EDot`, and the checker's member
resolution is not exposed as a name anywhere this can read. A sweep that must
cover both spellings needs two queries today:

```bash
vibe grep --pattern 'Iterator::map($(a:args))'   lib
vibe grep --pattern '$(r:exp).map($(a:args))'    lib
```

**Limitation (v1):** declaration-shaped patterns (`fn …`, top-level `let … =
…`, `enum …`) are rejected with a message saying so, rather than silently
matching nothing. Use `vibe symbols` for declarations.

### Type-aware filters

Passing any of these switches the sweep into the **typed tier**, which resolves
imports through the same walk a plain `vibe check` uses — the `--single-file`
import-blind false positives described above are deliberately *not* reproduced
here. Only files that already have a structural match are typed.

```bash
# the capture's INFERRED type (`_` is a wildcard inside the type)
vibe grep --pattern 'f($(x:exp))' --where '$x : Array[_]' lib

# the capture's RESOLVED name — sees through `import ./m.vibe { Iterator as It }`,
# so `It::map(...)` and `Iterator::map(...)` are one query
vibe grep --pattern '$(f:id)($(a:args))' --where '$f = Iterator::map' lib

# the capture's effect ROW (a bare effect name also matches its operations)
vibe grep --pattern '$(f:id)($(a:args))' --where-row '$f with Async' lib
vibe grep --pattern '$(f:id)($(a:args))' --where-row '$f without Fs' lib

# matches inside declarations that do (or do not) type-check
vibe grep --pattern 'f($(x:exp))' --only-ill-typed lib
vibe grep --pattern 'f($(x:exp))' --only-well-typed lib
```

`--where` and `--where-row` are repeatable and AND together.

Where a capture's type comes from, and what that costs:

- A capture in **callee** position resolves through the final type
  environment (plus the builtin table, so `Fs::read_file` carries its row).
  The checker records a call's *result* at the callee's own offset, so
  reading the offset table there would confidently report the wrong type.
- Every other capture resolves through the per-offset type table — the same
  one `vibe type-at` uses.
- **A callee that is a local or a parameter has no type here** (it is not in
  the final environment): the filter drops the match rather than guessing.
  Same boundary `vibe type-at` documents for locals.
- **A capture containing no identifier-shaped token has no type here either.**
  Only identifiers, call callees and field names carry source offsets in this
  AST, so a bare literal capture (`$(k:const)` bound to `1`) has nothing to
  look its type up *by*. Dropped, not guessed.
- When the import graph itself fails to check, the file has **no** type table:
  every `--where` drops — **including `=`** — and every match counts as
  ill-typed. "We could not resolve this" must not read as "it is not an
  `Array[Int]`", a program that does not compile must not answer
  `--only-well-typed`, and a name filter must not silently fall back to the
  syntactic alias table and call an unvalidated import *resolved*. Pure syntax
  is what the parse-only tier is for.
- `--only-ill-typed` is per *declaration*: the checker reports one type error
  per file, and a match counts as ill-typed when it sits in the same top-level
  declaration as that error. An error with no position covers the whole file.
- `CtUnknown` is treated as *no answer*, not as a type. An unresolvable name
  therefore matches neither `--where-row '$f with E'` nor `'$f without E'`.

### Output

One match per line, fixed field order, greppable — `path:line:col: <matched
text>` then tab-separated `$var=<capture>`:

```
lib/@vibe/x/y.vibe:41:11: readit(q)	$f=readit	$x=q
```

`--json` emits the same matches as a JSON array; each match carries `start` /
`end` byte offsets and per-capture `{text, start}`, plus `type` when the typed
tier ran. **The range is a lower bound, not an extent** (#1941): only
identifier-shaped AST nodes carry an offset, so the span misses trailing
punctuation and cannot see a literal at all -- `add(one, two)` reports an `end`
one byte short of the `)`, and `add(1, 2)` collapses to `add`. `start` is exact,
`end` is a floor, and `text` is the printer's rendering rather than a slice. A
capture carries `start` with no `end` (`-1` when the node has no offset), so it
cannot be sliced at all (#1943). See
[source-range-contract.md](source-range-contract.md). Empty output (`[]` in JSON) means no match, and `vibe grep` exits 0 —
it is a *report*. Only a bad pattern or a bad filter is an error, and those say
what to write instead:

```
$ vibe grep --pattern 'f($(x:expr))' lib
error: grep pattern: unknown metavariable kind `expr` — use one of exp, id, const, arg, args, pat, type
```

`text` is the **printer's canonical rendering** of the matched node and is the
exact, complete description of what matched. `end` is a *lower bound* on the
source extent: only identifier-shaped tokens carry offsets in this AST, so
trailing punctuation and literals are not counted. Use `text`, not `[start,
end)`, when you need to know what the match was.

A file that does not parse is skipped, not fatal: a repo sweep must not stop at
the first work-in-progress file. The skip is reported on stderr
(`warning: grep: skipped \`path\` because it could not be parsed`) so empty
stdout still means no matches, not silently skipped input. Recursion skips
`_build`, `node_modules`, `dist`, `target`, dot-directories, and `deps` (where
`vibe fetch` vendors packages — and, since relative imports nest, each
vendored package's own `deps` below that). Naming one of those directly still
searches it: `vibe grep --pattern '…' deps` asks for exactly that.

---

## Interactive debugging

The debugger is **function-granularity** and entirely opt-in — a normal
`vibe run` carries no debug instrumentation.

### Source-mapped traps (always on)

When a program traps at runtime, backtrace frames name the user function *and*
its source line, e.g.:

```
  at boom (prog.vibex:1)
  at main (prog.vibex:2)
```

This needs no flags — it comes from the wasm name section plus the `.funcmap`
sidecar the compiler writes for the entry file.

### Call trace (`--trace`)

```bash
vibe run --trace prog.vibex
```

Compiles with function-call trace instrumentation and prints the entry
sequence, each line annotated with its source location:

```
trace: main (prog.vibex:2)
trace: helper (prog.vibex:1)
```

### Breakpoints (`--break`)

```bash
vibe run --break helper prog.vibex              # break at one function (by name)
vibe run --break helper,worker prog.vibex       # break at several
vibe run --break prog.vibex:3 prog.vibex        # break at the function declared on line 3
vibe run --break 3 prog.vibex                   # bare line (any file)
```

A `<file>:<line>` (or bare `<line>`) breaks at that source line, and a name
breaks at that function's entry. Both forms can be mixed in one comma-separated
spec. Line breakpoints work at **interior** statement lines, not just function
declarations: a single-file program compiled in break mode emits a
`vibe::dbg_line` hook at each `let` / statement boundary, so `--break prog.vibex:7`
pauses when execution reaches line 7 even mid-function. Stepping (`s`/`n`) then
advances at line granularity.

Interior-line breakpoints work across **multiple files**: `--break helper.vibe:3`
pauses inside an imported module while `--break main.vibex:3` pauses in the entry
file, even though both are "line 3" — the compiler records each statement's source
file (a `vibe.dbgfiles` table) so the runner matches the breakpoint's `<file>`
against the right one. A statement whose value is a bare literal (e.g. `let a = 1`)
is breakable too (#644): the `let`/`let mut` keyword's own offset anchors the probe
when the value itself carries none.

Execution pauses at the entry of each named function and prints, to stderr:

```
breakpoint hit: helper
  args: [x=20]
  at helper (prog.vibex:1)
  at main (prog.vibex:2)
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

#### Static line map (`vibe.linemap`) and more precise trap frames

A `--break`-instrumented module also carries a `vibe.linemap` custom section:
a static table mapping each user function's wasm code offset to a source
`(file, line)`, built from the same interior-line probe sites as the live
`--break` hook above (#644). Unlike `dbg_line`, this table needs no
cooperation from the running program — it can be read straight out of the
compiled `.wasm`, e.g. with `viberun --dump-linemap <file.wasm>` (one
`func_index<TAB>offset<TAB>file<TAB>line` row per probe), and the runner
consults it whenever `wasmtime::WasmBacktrace` hands it a real
`(func_index, func_offset)` pair.

The concrete payoff: when a `--break` run hits an **uncaught trap** (not an
explicit breakpoint), every frame of the backtrace gets annotated with a
`frame: <fn> (<file>:<line>)` line using the *trapping* statement's actual
line — not just that function's declaration line, which is all the default
wasm-name-section-based backtrace can show for a non-topmost frame:

```
viberun: error while executing at wasm backtrace:
    0:   0x1c33 - <unknown>!main (t.vibex:1)
    1:   0x1d39 - <unknown>!_start

Caused by:
    wasm trap: integer divide by zero
  frame: main (t.vibex:4)
  frame: _start
```

Here `main` is declared on line 1, but the division that actually trapped is
on line 4 — the `frame:` line (not `  at `, to avoid colliding with the
launcher's separate declaration-line annotator) gives the precise location.
This only fires for debug-break builds with a non-empty linemap; a plain
`vibe run` trap is unaffected.

**Known scope limit**: linemap entries are recorded only for TOP-LEVEL
function bodies — a probe compiled inside a lambda/closure body is absent
from the static table (its LIVE `--break`/`dbg_line` pause still works
normally; only the *static*, no-execution-needed lookup has this gap).
Genuine **instruction-offset breakpoints** (pausing mid-statement, at an
arbitrary sub-expression) remain future work: it needs every `Expr` node to
carry its own source span, not just statements, which the linemap alone
doesn't provide (docs/release-roadmap.md テーマ3, 3-P0's "残").

---

## VS Code integration

`integrations/vscode-vibe/` is a VS Code extension contributing both syntax
highlighting and a debug adapter. The debug side bridges VS Code's Debug
Adapter Protocol to the function-granularity debugger above via
[`clients/js/dap_server.js`](../clients/js/dap_server.js) (a small, dependency-free
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

The runner (`viberun`) and the compiler wasm are distributed and updated
independently (ADR-0056 / テーマ1). To swap in a newer compiler artifact
without rebuilding the runner:

```bash
vibe self update --cli-wasm <path-to-vibe-cli.wasm>
```

This installs the given compiler wasm and AOT-compiles it to a host-specific
`.cwasm` for fast startup. `vibe version` reports the active toolchain version,
which is the basis for the SemVer guarantee described in
[spec/stable-surface.md](spec/stable-surface.md).
