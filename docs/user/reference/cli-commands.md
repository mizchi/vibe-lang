# CLI Commands Reference

This document clarifies the role of each `vibe` CLI command, with special attention to the compile/build variants and other commonly confused command pairs.

Compiler-backed commands are implemented in `lib/@vibe/compiler/` and
`lib/@vibe/cli/`; project and toolchain commands (`new`, `add`, `fetch`,
`toolchain`, `self`) live in the `runtime/vibe` launcher.

## Quick Reference: Compile & Build Commands

| Command | Audience | Purpose |
|---------|----------|---------|
| `compile` | User | Compile a `.vibe` / `.vibex` file to a core `.wasm`, a command component (`--component`), or its WIT world (`--wit`) |
| `build` | User | The same command as `compile` (an alias) |
| `serve` | User | Compile an HTTP handler + compose with the wasi-http P3 adapter + `wasmtime serve` (#537) |

## User-Facing Commands

### run

Compile a `.vibex` executable root and run its fixed `fn main` entry.

```
vibe run <file.vibex> [-- args]
```

`--trace`, `--break <fn>[,<fn>...]`, `--mem` and `--alloc-site[=N]` add a
call trace, an interactive breakpoint, a heap report and per-line allocation
attribution; `vibe help` lists them with their exact output.

### compile / build

`build` is an alias of `compile`: both read the same arguments and produce the
same artifacts.

```
vibe compile <file.vibe|file.vibex>              # core WASM (linear backend)
vibe compile -o out.wasm <file.vibe>             # explicit output path
                                                 #   (also --output / --out)
vibe compile --wit <file.vibe>                   # the WIT world for the file's effect
                                                 #   surface (docs/internal/design/effect-wit-mapping.md)
vibe compile --component <file.vibe>             # a command component from the
                                                 #   module's `vibe_command` export
vibe compile --minify <file.vibe>                # post-optimize with vibe-opt.wasm (#1107)
vibe build --debug <file.vibe>                   # the linked debug lane
vibe compile --entry <name> <file.vibe>          # entry other than `main` (not for .vibex)
```

- A core module needs an entry: `fn main`, or `--entry <name>` naming a
  zero-parameter function (it need not be exported). A library module with neither is refused
  (``entry `main` not found``); `--wit` and `--component` do not need one.
- Output defaults to `.vibe/build/out/<name>.wasm` under the project root
  (`<name>.wit` with `--wit`, `<name>.component.wasm` with `--component`;
  #2675, [install.md](../getting-started/install.md#project-layout)). `-o`
  (or `--output` / `--out`) chooses another path, relative to the directory
  you ran from.
- **`--debug`** builds through the linked debug lane: library modules are
  cached as linked wasm files and only the entry is recompiled. It cannot be
  combined with `--component`, `--wit` or `--minify`.
- **`--minify`** runs the standalone `vibe-opt.wasm` optimizer over the core
  module after it is written. The default artifact is not post-optimized. With
  `--component` it is refused (the minifier takes a core module); with
  `--wit` it is accepted and has no effect, since no module is written.
- `--wasm`, `--wasm-linear` and `--release` are accepted and change nothing.
  They do **not** select a backend: `compile` produces linear core WASM by
  default, and `VIBE_BACKEND=gc` switches it to wasm-gc even when
  `--wasm-linear` is on the command line.
- **`--jobs 1|2|4`** checks independent modules with native Vibe `TaskGroup`
  workers before final code generation. Source discovery and cache publication
  use Node.js; task creation, waiting and cancellation use the native runner.
  It needs compiler-matched checker images and cannot be combined with
  `--debug`, `--component` or `--wit`. Builds without the flag keep the ordinary
  serial path. No speedup is promised; discovery and publication also cost time.
  In a checkout, build images with `scripts/build_taskgroup_checker.sh <compiler.wasm>`
  and set `VIBE_TASKGROUP_ARTIFACT_DIR` when using another output directory.
  To install those images, pass `--taskgroup-artifacts <directory>` together
  with the same `--cli-wasm` to `install/install.sh`. Release bundles ship them.
  For repeated parallel builds, `VIBE_TASKGROUP_JOB_CACHE=1 vibe build --jobs 4 ...`
  enables experimental reuse of successful worker results. Source, dependency
  environments, compiler/worker images and execution environment must match;
  changes trigger fresh checks, and diagnosed modules are checked again.
- **Any other option is refused** with `unknown option: <flag>`. That includes
  the retired MoonBit host's flags (`--no-dce`, `-O<level>`, `--wasm-gc`,
  `--wac`, `--library`, ...). The wasm-gc backend is reached through
  `VIBE_BACKEND=gc` (or `VIBE_TEST_BACKEND=gc` / `VIBE_BENCH_BACKEND=gc` for
  pure tests and benches; [cheatsheet](cheatsheet.md)).
- `--component` and `--wit` produce different artifacts and are refused
  together; a `.vibex` has no export surface, so `--component`, `--wit` and
  `--entry` are refused for it. Use `vibe serve` (below) for an HTTP component.

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

The handler contract (see [effect-wit-mapping.md](../../internal/design/effect-wit-mapping.md)):

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
  `wasmtime` 46 or newer (the first release that serves the ratified
  `wasi:http@0.3.0` world; the repository pins 47.0.2). The P3 adapter component is built once by
  `scripts/build_wasi_http_p3_full_adapter.sh` (cargo + wasm-tools) or passed
  via `--adapter` / `VIBE_HTTP_ADAPTER`.
- E2E gates: `scripts/test_wasi_http_p3_full_gate.sh` (String body),
  `scripts/test_serve_async_lift_gate.sh` (async lift, same String contract),
  `scripts/test_serve_body_stream_gate.sh` (`HostStream` body, byte-exact echo).

### test

Run test blocks in one or more files or directories.

```
vibe test <file|dir...>
vibe test --jobs 4 <dir...>
```

To update a stale `inspect(value, content)` snapshot to the value the run
actually produced, add `--update`; the file is patched, recompiled and rerun:

```
vibe test --update <file_test.vibe|dir...>
```

### check

Parse and type-check without producing output. Errors go to stdout, one per
line, and exit 1; **empty stdout and exit 0 mean the file compiles**. Warnings
never change the exit code: in text mode they go to stderr. With
`--single-file --json` they appear in the array with severity 2; the FS lane's
`--json` array does not include them.
Imports are resolved from the filesystem, so `vibe check` alone answers "does
this compile".

```
vibe check <file...>
vibe check --single-file <file>          # this buffer only, imports not followed
vibe check --json <file>                 # LSP Diagnostic array (`[]` when nothing is reported)
vibe check --profile-tsv timing.tsv <file...>
```

`--single-file` is the editor's mode for unsaved text: a name that comes from
an import reports as unknown there, so it does not answer whether the file
compiles. Positions and their units are specified in
[source-range-contract.md](source-range-contract.md). `vibe diagnostics` is the
deprecated spelling of `vibe check --single-file`, kept unchanged for editors
already on it.

### Editor queries

The semantic queries behind `vibe lsp`, available from the shell. Positions
are 1-based line and 1-based **byte** column; spans are 0-based half-open byte
offsets ([source-range-contract.md](source-range-contract.md)).

```
vibe type-at    <file.vibe> <line> <col>   # inferred type of the identifier there
vibe doc-at     <file.vibe> <line> <col>   # its `///` doc comment
vibe binding-at <file.vibe> <line> <col>   # every occurrence of that binding (START END per line)
vibe symbols [--with-path] <path>...       # declaration outline (NAME KIND START END [DOC])
vibe escapes [--strict] <file.vibe>        # `let mut` bindings a closure captures (NAME START END)
vibe refactor extract-function <file.vibe> <start-byte> <end-byte> <name> [--write]
                                           # preview, or with --write apply, a checked extraction
```

[editor-and-debugging.md](editor-and-debugging.md) documents the output of each
one and how the LSP builds on them.

### shell (Compiled REPL) (#805)

Minimal REPL implemented in the launcher. Per ADR-0034 there is **no
interpreter**: the session is a buffer of top-level declarations kept in a
temp dir, and every input line triggers a full recompile of that buffer
through the same compile path as `vibe run` (accumulate + recompile).

```
vibe shell                    # interactive (prompt on a tty)
vibe shell helpers.vibe       # preload a file's declarations into the session
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
  have no codegen lowering in bare FS-mode compiles, `@vibe/console`'s
  wrappers drag `vibe::*` host imports the standalone runner does not
  define, and `Console::write_char` writes the raw tagged value.)
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

`vibe shell` reads stdin line-oriented, without prompts, whenever stdin is
not a tty.

### add / fetch

A dependency is a package pinned in the root `index.vpkg` and installed under
`.vibe/store/` (#2676, [install.md](../getting-started/install.md#dependencies)). `vibe add`
fetches one from its git source, installs it, and writes the `deps` entry and
the `require @scope/name x.y.z = #pkg:b3:<hex> from <source>@<commit>` pin;
`vibe fetch` restores the store from those pins on a fresh clone, from the
cache under `$VIBE_HOME/cache/pkg/` or from the pinned source, hash-verified
either way.

```
vibe add github:owner/repo[/dir]@<ref> [#pkg:b3:<64hex>]
vibe add git:<url>@<ref>[#<dir>] [#pkg:b3:<64hex>]
vibe fetch
```

A `<ref>` may be a semver constraint (`^1.2`, `~1.2.3`, `>=1.0`, `1.x`); it
resolves to the highest matching tag before the fetch. There is no
`vibe verify`, no `vibe update-lock` and no lock file: the build verifies the
store copy against the pin every time. An optional content hash makes the
initial `add` verify the fetched package before installing it. A full commit
hash can be used as `<ref>` instead of a tag.

### Formatting (`vibe fmt`)

`vibe fmt` runs the CST-token formatter over one file:

```bash
vibe fmt <file.vibe|file.vpkg>           # rewrite in place
vibe fmt --check <file.vibe>             # exit 1 if not formatted
vibe fmt --stdout <file.vibe>            # print, do not write
pkf run fmt                              # all of lib/**/*.vibe + *.vpkg (repository task)
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

### new

- `vibe new [--name @scope/name] <dir>` -- Scaffold a project: `main.vibex`, a root `index.vpkg` (the project marker and manifest; `name = @local/<dir>` unless `--name` gives the package name) and `.gitignore` (which ignores `.vibe/`, where builds and pinned dependencies land).

There is no `vibe init`; scaffolding is `vibe new`.

### Other User Commands

| Command | Description |
|---------|-------------|
| `bench <file\|dir...>` | Run compiled `bench {}` blocks with optional `--iters`, `--warmup` |
| `profile <file.vibex> [--out FILE] [--interval-us N]` | Capture a Wasmtime guest CPU profile of a run |
| `allocs <file>` | Possible heap-allocation sites (`FN KIND OFFSET` per line) |
| `symbols [--legend] <file>` | Declaration outline (`NAME KIND START END [DOC]` per line) |
| `rc-classify <file>` | RC classifier sets (`NAME SET[,SET...]`; empty = none) |
| `rc-plan [--fn NAME] <file>` | Perceus plan (`FN BINDING ACTION COUNT`; empty = no actions) |
| `deps [--direct] <file>` | Resolved import closure, dependency first |
| `grep --pattern '<pat>' [paths]` | AST pattern search, with checker-backed filters |
| `hash [--write] <pkg_dir>` | Package content hash |
| `root` | Print the project root: the outermost `index.vpkg` up from the current directory, not across `.git`; else the current directory (#2675) |
| `clean [--all]` | Remove `.vibe/build/` (`--all`: the pinned `.vibe/store/` too) |
| `add <source-spec>` | Fetch a package into `.vibe/store/` and pin it in the root `index.vpkg` |
| `fetch` | Restore `.vibe/store/` from the pins in the root `index.vpkg` |
| `pkg publish\|install\|add\|yank\|update` | Package registry operations |
| `context-pack [--out FILE]` | Cheatsheet + verified golden examples as one file (#820) |
| `lsp` | Start the stdio LSP server |
| `toolchain list\|default <name>\|remove <name>` | Installed toolchains with the default marked; select the default; delete one, never the default (#2677) |
| `self update [<version>\|latest] [--no-default] [--force]` | Install a release toolchain: download into `$VIBE_HOME/cache/downloads/<tag>/`, verify every asset against `release-manifest.json`, precompile, rename into `toolchains/<version>/` and make it the default (#2678) |
| `self update --cli-wasm <path>` | Refresh the current toolchain's compiler wasm and rebuild its `.cwasm` |
| `self uninstall [--purge]` | Remove `toolchains/`, `bin/`, `env` and `toolchain` under `$VIBE_HOME` (and the installer's rc line); `--purge` also `cache/`, `lib/`, `log/` |
| `version` | Print the toolchain's version from its `manifest.json`, then the runner and compiler paths |

`vibe help` prints the authoritative list; `runtime/vibe` is where it is
defined, and `scripts/check_doc_commands.sh` compares every command shown in
this repository's documents against it. Verbs not listed there (such as
`inspect-update`, which `vibe test --update` calls) are internal plumbing for
the launcher and carry no compatibility promise.

## Environment Variables

| Variable | Description |
|----------|-------------|
| `VIBE_UNSTABLE` | `1` allows importing `@vibe/concurrent/experimental` (the suspendable-task lane); without it `check` and `build` refuse the import |
| `VIBE_BUILD_DIR` | Overrides `<root>/.vibe/build`, where every artifact lands; the launcher derives `VIBE_BUILD_CACHE_DIR=$VIBE_BUILD_DIR/cache` unless that is already set, so the compiler cache moves with it (#2675) |
