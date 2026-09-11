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

Outside a checkout, the installer initializes a temporary repository and
shallow-fetches the exact branch, tag, or reachable commit selected by
`VIBE_INSTALL_REF` from `VIBE_INSTALL_REPO`, then safely reinvokes the matching
`install/install.sh` from the detached checkout. Requirements: `git`, `bash`,
`cargo` (unless `--runner` supplies a prebuilt runner), and Node.js for the
default compiler seed acquisition/build path. Node.js is optional only when
`--cli-wasm PATH` supplies an existing compiler wasm.

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
5. materialize the stdlib packages (`@vibe/core`, `@vibe/ast`, `@vibe/parser`,
   `@vibe/builtin`, `@vibe/console`, `@vibe/wit_runtime`) into the toolchain's
   own `lib/`, hash-verified (`vibe hash`), and write its `manifest.json`.

Then:

```bash
vibe version
echo 'fn main allows Console { println("42") }' > hello.vibex
vibe run hello.vibex        # -> 42
```

The book's first program is this same builtin form; see
[The Vibe Book](../book/README.md) (`book/en/`) (#1949).

### Install layout (`$VIBE_HOME`, ADR-0111)

```text
$VIBE_HOME/                           default ~/.vibe
  bin/vibe                            dispatcher (the PATH entry)
  env                                 shell setup, sourced from the rc files
  toolchain                           default toolchain name
  toolchains/<name>/
    bin/{vibe,viberun}                launcher + wasmtime runner
    lib/vibe-cli.wasm                 portable compiler
    lib/vibe-cli.cwasm                host-specific AOT build of it
    lib/{lsp_server.js,symbol_index.js,graph_query.js}
    lib/{vibe_pkg.sh,parallel_warm_pool.sh,context-pack.md}
    lib/@vibe/{core,ast,parser,builtin,console,wit_runtime}
                                      stdlib, per toolchain
    manifest.json                     version, ref, commit, installed_at, source,
                                      sha256 of runner and compiler wasm,
                                      wasmtime version
  lib/@scope/name/                    shared packages from `vibe pkg install`
  cache/pkg/sha1/<hex>/               content-addressed package store (CAS)
  cache/pkg/{versions,provenance}.tsv
  cache/test/<sha256>.pass            pure-test result cache
  log/                                transparency log (publisher state)
```

A toolchain is one versioned unit: runner, compiler, launcher, editor
scripts and the stdlib they were built with. Nothing under
`toolchains/<name>/` is shared with another toolchain, so installing a
second one (`--toolchain <name>`, or another `--ref`) never touches the
first. The launcher resolves `@scope/name` through the active toolchain's
`lib/` first, then the shared `$VIBE_HOME/lib`: it sets `VIBE_LIB` to that
pair when you have not set it. The names `build` and `store` are reserved
directly under `$VIBE_HOME`, because a project rooted at `$HOME` keeps its
`.vibe/build/` and `.vibe/store/` there.

The dispatcher picks the toolchain named by `$VIBE_TOOLCHAIN`, else by the
`toolchain` file, else the only installed one:

```bash
vibe toolchain list                 # installed toolchains, the default marked *
vibe toolchain default <name>       # rewrite $VIBE_HOME/toolchain
vibe toolchain remove <name>        # delete one; the default is refused
vibe version                        # reads the toolchain's manifest.json
```

The pre-#755 flat layout (`$VIBE_HOME/bin/vibe` next to
`$VIBE_HOME/lib/vibe-cli.wasm`) is not recognized: the launcher and the
installer refuse it and ask for a reinstall. The release install and update
path (`vibe self update <version>`, prebuilt runners) is the last phase of
[toolchain-layout.md](toolchain-layout.md) (ADR-0111, #2674) and is not
available yet.

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
vibe compile <file.vibe> [-o <out>]   compile to a .wasm (default: .vibe/build/out/<name>.wasm)
vibe build   <file.vibe> [-o <out>]   alias of compile
vibe check   <file.vibe|file.vibex>   parse + typecheck (no output kept)
vibe test    <file_test.vibe|dir>...  compile + run test {} blocks
                                      (a directory expands to *_test.vibe)
vibe add     <source-spec>            fetch a package into .vibe/store/ and pin it
                                      in the root index.vpkg
vibe fetch                            restore .vibe/store/ from the pins
vibe root                             print the project root (outermost index.vpkg)
vibe clean   [--all]                  remove .vibe/build (--all: .vibe/store too)
vibe lsp                              start the stdio LSP server (diagnostics)
vibe context-pack [--out FILE]        emit cheatsheet + verified golden examples
                                       as one file (AI-harness context, #820)
vibe version                          print toolchain versions (from manifest.json)
vibe toolchain list|default <name>|remove <name>
                                      installed toolchains / pick the default / delete one
vibe self update --cli-wasm <path>    refresh compiler wasm + rebuild .cwasm
vibe self uninstall [--purge]         remove the install (--purge: caches, shared packages, log too)
vibe help                             usage
```

An executable root is a `.vibex` file with exactly one `fn main`; its
user-visible entry cannot be overridden. Arbitrary entry names remain an
internal compiler/test-harness ABI only.

## Dependencies

A dependency is a package: a directory with an `index.vpkg` (its contract and
public API boundary, ADR-0070). The root `index.vpkg` of your project is the
manifest, and pinned dependencies live in the project-local `.vibe/store/`
([docs/toolchain-layout.md](toolchain-layout.md), #2676). The boundary,
visibility and pinning rules live in one place:
[docs/module-system-oracle.md の「現行モデル」節](module-system-oracle.md#現行モデル-canonical--ここが唯一の現行記述)
(#1269).

Add a dependency straight from its git source. The name and version are the
ones the fetched package's own `index.vpkg` declares:

```bash
vibe add github:acme/json@v1.4.0     # a package at a repository root
vibe add git:https://example.com/u/mono.git@^1.0#packages/@acme/json
                                     # a subdirectory; ^1.0 resolves to the highest matching tag
```

`vibe add` fetches with git, hashes the package, installs it into
`.vibe/store/<name>/`, and writes two things into the root `index.vpkg`: a
`deps` entry, and a `require` pin recording the version, the content hash and
the source resolved to a commit:

```text
deps = {
  @acme/json : 1.4.0
}
require @acme/json 1.4.0 = #pkg:sha1:<40hex> from github:acme/json@<commit>
```

Import it by name (`import @acme/json { parse }`) and build as usual. The
compiler re-checks the store copy against the pin on every build, so neither
the network nor the transport has to be trusted between builds; a copy that
does not hash to its pin is a build error.

Commit `index.vpkg`; `.vibe/` is ignored. A fresh clone restores the store
from the pins:

```bash
vibe fetch                     # the cache under $VIBE_HOME/cache/pkg/ first, else the pinned source
```

The hash is verified either way, and a mismatch fails closed before anything
is copied. The pins of the packages installed on the way are followed, so a
dependency's own dependencies arrive with it. Standard-library packages
(`@vibe/*`) resolve from the toolchain and need no pin.

There is no lock file and no vendored `deps/` directory: the `require` line is
the lock. Single-file URL dependencies are not supported.

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

## Uninstalling

```bash
vibe self uninstall            # removes toolchains/, bin/, env, toolchain and the rc line
vibe self uninstall --purge    # also cache/, lib/ and log/
```

## Notes

- A `vibe-cli.cwasm` is only valid for the exact `viberun`/wasmtime build
  that produced it. The launcher falls back to the portable `vibe-cli.wasm` if
  the `.cwasm` looks older than the runner, and `vibe self update` regenerates
  it. Do not copy a `.cwasm` between machines or toolchain versions.
- Set `VIBE_RUNNER_BACKTRACE=1` (or `RUST_BACKTRACE=1`) to see the full runner
  backtrace when diagnosing a runner-level failure; by default guest traps are
  reported as a single-line message.
