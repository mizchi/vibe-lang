# Installing vibe

vibe is distributed as a small **wasmtime runner** (`viberun`) plus a
**portable compiler wasm** (`vibe-cli.wasm`). At install time the compiler wasm
is AOT-compiled to a host-specific `vibe-cli.cwasm` so the compiler is not
re-JITed on every command. See `docs/release-roadmap.md` (テーマ1) for the
rationale behind this split.

## Quick install (curl)

```bash
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/install/install.sh | bash
```

The installer shallow-clones the repo when it is run outside a checkout
(override with `VIBE_INSTALL_REPO` / `VIBE_INSTALL_REF`) and then safely
reinvokes the matching `install/install.sh` from that checkout. Requirements:
`git`, `bash`, `cargo` (the wasmtime runner builds from source); `node` is
optional (used to self-build the newest compiler — without it the committed
seed compiler is installed, which is always functional).

## Quick install (from a checkout)

```bash
bash install/install.sh
```

This will:

1. build (or reuse) the `viberun` runner from `runtime/viberun`,
2. build a fresh compiler wasm from the current source (`scripts/build_cli_wasm.sh`,
   seed → stage1 → stage2), falling back to the committed seed if the build
   toolchain is unavailable,
3. AOT-compile it to `vibe-cli.cwasm` for this machine,
4. install the launcher into the toolchain + the dispatcher onto your `PATH`,
5. materialize the stdlib packages (`@vibe/core` / `@vibe/ast` /
   `@vibe/parser`) into `$VIBE_HOME/lib`, hash-verified (`vibe hash`).

Then:

```bash
vibe version
echo 'fn main with Stdout { Stdout::write_stream("42\\n") }' > hello.vibex
vibe run hello.vibex        # -> 42
```

### Install layout (rustup-style toolchains, #755)

```
$VIBE_HOME/                 (default: ~/.vibe)
├── bin/
│   └── vibe                # dispatcher shim: picks a toolchain and execs it
│                           # ($VIBE_TOOLCHAIN > $VIBE_HOME/toolchain file >
│                           #  the single installed toolchain)
├── toolchain               # default toolchain name
├── toolchains/<name>/
│   ├── bin/
│   │   ├── vibe            # launcher (subcommand dispatch + orchestration)
│   │   └── viberun          # wasmtime runner
│   └── lib/
│       ├── vibe-cli.wasm   # portable compiler artifact
│       ├── vibe-cli.cwasm  # host-specific AOT build (`vibe self update`)
│       └── lsp_server.js…  # editor tooling
├── lib/
│   └── @vibe/{core,ast,parser}/   # stdlib packages — the default VIBE_LIB
│                                  # resolution root (ADR-0065 #751), SHARED
│                                  # across toolchains (content-addressed)
└── cache/                  # package fetch cache (#754) — shared
```

Toolchains hold the versioned artifacts; packages and caches are shared and
content-addressed. A future `vibe toolchain` selector (rustup-style) only has
to rewrite `$VIBE_HOME/toolchain` — `install/install.sh` names toolchains
after the installed ref so several can coexist.

PATH policy: **`~/.vibe/bin` is the PATH entry** (the dispatcher lives
there). The installer writes a sourceable `~/.vibe/env` (rustup's
`~/.cargo/env` pattern) and, for a default-prefix install, appends
`. "$HOME/.vibe/env"` to `~/.profile` / `~/.bashrc` / `~/.zshrc` (skip with
`--no-modify-path`; custom `--prefix` installs never touch rc files).
Restart the shell or `. "$HOME/.vibe/env"` to pick it up. An extra symlink
dir is opt-in via `--bin-dir` / `VIBE_BIN_DIR` (used by the test harness).

## Installer options

```
bash install/install.sh [--prefix DIR]      # VIBE_HOME (default ~/.vibe)
                        [--runner PATH]      # use a prebuilt viberun
                        [--cli-wasm PATH]    # use a specific compiler wasm
                        [--toolchain NAME]   # toolchain name (default: main)
                        [--set-default]      # make this the default toolchain
                        [--no-stdlib]        # skip stdlib materialization
                        [--no-modify-path]   # do not touch shell rc files
                        [--bin-dir DIR]      # opt-in extra symlink dir
                        [--no-link]          # skip the --bin-dir symlink
```

To install a released compiler instead of the seed, pass the release artifact:

```bash
bash install/install.sh --cli-wasm vibe-compiler-<tag>.wasm
```

## Commands

```
vibe run     <file.vibex> [-- args]   compile the fixed `main` entry then run
vibe compile <file.vibe> -o <out>     compile to a .wasm
vibe build   <file.vibe> -o <out>     alias of compile
vibe check   <file.vibe|file.vibex>   parse + typecheck (no output kept)
vibe test    <file_test.vibe>...      compile + run test {} blocks
vibe fetch   [project_dir]            vendor git/URL deps from vibe.deps + lock
vibe lsp                              start the stdio LSP server (diagnostics)
vibe context-pack [--out FILE]        emit cheatsheet + verified golden examples
                                       as one file (AI-harness context, #820)
vibe version                          print toolchain versions
vibe self update --cli-wasm <path>    refresh compiler wasm + rebuild .cwasm
vibe help                             usage
```

An executable root is a `.vibex` file with exactly one `fn main`; its
user-visible entry cannot be overridden. Arbitrary entry names remain an
internal compiler/test-harness ABI only.

## Dependencies (git/URL, MVP)

Remote dependencies are vendored into the project (git/URL 分散 model). This is
a **separate layer** from the in-repo package model — `vibe.lock` records
vendored remote deps only; `lib/@scope/pkg` packages are bounded by
`index.vpkg` and pinned through its `deps`/`generated_hash` header instead.
The boundary/visibility/pinning rules live in one place:
[docs/module-system-oracle.md の「現行モデル」節](module-system-oracle.md#現行モデル-canonical--ここが唯一の現行記述)
(#1269).

Declare remote deps in `vibe.deps` (one `<name> <url>` per line; `#` comments
allowed):

```
# vibe.deps
mathlib  https://example.com/mathlib.vibe          # single-file URL
mymod    git+https://example.com/u/mymod.git#v1.2   # git repo, pinned to a ref
```

Then vendor + lock them, and import via the vendored path:

```bash
vibe fetch                     # downloads into ./deps/, writes vibe.lock
```

```vibe
import ./deps/mathlib.vibe { add }        # single-file dep
import ./deps/mymod/index.vibe { thing }  # git dep (vendored as a directory)
fn main with Stdout { Stdout::write_stream("\{add(40, 2)}\n") }
```

`vibe fetch` records each dep's resolved identity in `vibe.lock` for
reproducible builds:

- **single-file** (`https://`, `file://`, local path): content-addressed by
  sha256, cached under `$VIBE_HOME/cache/<sha256>`, vendored to
  `./deps/<name>.vibe`.
- **git** (`git+<remote>[#<ref>]`): cloned, checked out at `<ref>`, vendored as
  a directory `./deps/<name>/`, and pinned to the resolved commit (`git:<sha>`).

This is an MVP of [docs/release-roadmap.md](release-roadmap.md) テーマ2 — seamless
`import "<url>"` syntax and transitive resolution are tracked there.

## Editor support (LSP)

`vibe lsp` starts a stdio LSP server that drives the compiler. It
provides: live diagnostics (all top-level parse errors via error recovery +
located type error), document outline, go-to-definition, **typed hover**
(inferred type of the identifier, including locals/params), completion,
signature help, and **scope-accurate find-references / rename**.
Point your editor's LSP client at `vibe lsp` for the `vibe` language.

> Full feature list, the underlying query primitives (`vibe type-at` /
> `binding-at` / `diagnostics`), and the interactive debugger are documented in
> [editor-and-debugging.md](editor-and-debugging.md).

**VS Code**: install `integrations/vscode-vibe` (it launches `vibe lsp`).

**Neovim**:

```lua
vim.lsp.start({ name = "vibe", cmd = { "vibe", "lsp" }, root_dir = vim.fn.getcwd() })
```

**Helix** (`~/.config/helix/languages.toml`):

```toml
[language-server.vibe-lsp]
command = "vibe"
args = ["lsp"]

[[language]]
name = "vibe"
scope = "source.vibe"
file-types = ["vibe"]
language-servers = ["vibe-lsp"]
```

Diagnostics carry an exact line:col for parse errors and common type errors
(unknown name / arity / field / ctor), and identifier-use positions resolve to
their inferred type via the per-node type table (typed hover). Rename /
references are AST-accurate (scope-aware binding occurrences). Remaining
precision work (call-site / expression-node spans) is tracked as span-arc in
[docs/release-roadmap.md](release-roadmap.md) テーマ4.

## Updating the compiler independently of the runner

The runner and the compiler wasm version independently. To move the compiler
forward (e.g. to a newer compiler build) without rebuilding the runner:

```bash
vibe self update --cli-wasm path/to/new/vibe-cli.wasm
```

This copies the new compiler wasm into place and rebuilds the host-specific
`vibe-cli.cwasm` against the installed runner.

## Notes

- A `vibe-cli.cwasm` is only valid for the exact `viberun`/wasmtime build
  that produced it. The launcher falls back to the portable `vibe-cli.wasm` if
  the `.cwasm` looks older than the runner, and `vibe self update` regenerates
  it. Do not copy a `.cwasm` between machines or toolchain versions.
- Set `VIBE_RUNNER_BACKTRACE=1` (or `RUST_BACKTRACE=1`) to see the full runner
  backtrace when diagnosing a runner-level failure; by default guest traps are
  reported as a single-line message.
