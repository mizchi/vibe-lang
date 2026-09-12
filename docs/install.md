# Installing vibe

vibe is distributed as a small **wasmtime runner** (`viberun`) plus a
**portable compiler wasm** (`vibe-cli.wasm`). At install time the compiler wasm
is AOT-compiled to a host-specific `vibe-cli.cwasm` so the compiler is not
re-JITed on every command. See `docs/release-roadmap.md` (テーマ1) for the
rationale behind this split.

## Quick install (release)

```bash
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/install/install.sh | bash -s -- --version X.Y.Z
```

Installs the published release `vX.Y.Z` (or `latest`) into
`$VIBE_HOME/toolchains/X.Y.Z/` with nothing but bash, curl (or wget), tar and
sha256sum (or shasum): the release's runner for this machine, its compiler
wasm and its toolchain bundle are downloaded into
`$VIBE_HOME/cache/downloads/vX.Y.Z/`, verified against the release's
`release-manifest.json`, unpacked into a staging directory and precompiled,
and only then renamed into place (#2678). `VIBE_INSTALL_VERSION` selects the
version from the environment; `VIBE_RELEASE_URL` overrides the download base.

## Quick install (from source)

```bash
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/install/install.sh | bash
```

Without `--version`, the installer initializes a temporary repository and
shallow-fetches the exact branch, tag, or reachable commit selected by
`--ref` / `VIBE_INSTALL_REF` from `VIBE_INSTALL_REPO`, then safely reinvokes
the matching `install/install.sh` from the detached checkout. Requirements:
`git`, `bash`, `cargo` (unless `--runner` supplies a prebuilt runner), and
Node.js for the default compiler seed acquisition/build path. Node.js is
optional only when `--cli-wasm PATH` supplies an existing compiler wasm.

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
  cache/downloads/<tag>/              release assets while `self update` runs
  log/                                transparency log (publisher state)
```

A toolchain is one versioned unit: runner, compiler, launcher, editor
scripts and the stdlib they were built with. Nothing under
`toolchains/<name>/` is shared with another toolchain, so installing a
second one (`vibe self update <version>`, `--toolchain <name>`, or another
`--ref`) never touches the first, and a toolchain directory is never edited
in place afterwards (the one exception is `vibe self update --cli-wasm`,
under [Updating](#updating)). Its name is the release version (`0.2.0`) for
a release install and the sanitized ref (`main`, `my-branch`) for a checkout
install. What is shared is only what is keyed by content or independent of
the compiler version: the package store `cache/pkg/`, the test result cache
(its key is the sha256 of the compiled wasm, which already folds in the
compiler), the `vibe pkg install` root `lib/`, and `log/`. The launcher
resolves `@scope/name` through the active toolchain's `lib/` first, then the
shared `$VIBE_HOME/lib`: it sets `VIBE_LIB` to that pair when you have not
set it. The names `build` and `store` are reserved directly under
`$VIBE_HOME`, because a project rooted at `$HOME` keeps its `.vibe/build/`
and `.vibe/store/` there.

The dispatcher `$VIBE_HOME/bin/vibe` picks the toolchain named by
`$VIBE_TOOLCHAIN`, else by the `toolchain` file, else the only installed
one. It is a few lines of shell rewritten by whichever installer or updater
ran last; its whole contract is to pick a toolchain that way, export
`VIBE_HOME` and exec `toolchains/<name>/bin/vibe`, so it keeps working for
any older toolchain's launcher:

```bash
vibe toolchain list                 # installed toolchains, the default marked *
vibe toolchain default <name>       # rewrite $VIBE_HOME/toolchain
vibe toolchain remove <name>        # delete one; the default is refused
vibe version                        # reads the toolchain's manifest.json
```

The pre-#755 flat layout (`$VIBE_HOME/bin/vibe` next to
`$VIBE_HOME/lib/vibe-cli.wasm`) is not recognized: the launcher and the
installer refuse it and ask for a reinstall.

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

Two modes, one entry point:

| mode | selector | needs | does |
| --- | --- | --- | --- |
| release | `--version X.Y.Z` or `--version latest` (or `VIBE_INSTALL_VERSION`) | bash, curl or wget, tar, sha256sum or shasum | fetch the release's manifest and toolchain bundle, verify the bundle, and hand over to that release's own `vibe self update` ([Updating](#updating)) |
| checkout | `--ref <ref>` (or `VIBE_INSTALL_REF`), or running inside a checkout | git, cargo (unless `--runner`), Node.js (unless `--cli-wasm`) | build the runner and the compiler from the checkout |

Both modes write the dispatcher, `env` and the default toolchain marker.
`--runner`, `--cli-wasm`, `--toolchain` and `--no-stdlib` belong to the
checkout mode (a release is named by its version and ships its runner,
compiler and stdlib), so the release mode refuses them. The bare curl entry
point stays in checkout mode until a release is published.

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
vibe new     [--name @scope/name] <dir>
                                      scaffold main.vibex, a root index.vpkg and .gitignore
vibe root                             print the project root (outermost index.vpkg)
vibe clean   [--all]                  remove .vibe/build (--all: .vibe/store too)
vibe lsp                              start the stdio LSP server (diagnostics)
vibe context-pack [--out FILE]        emit cheatsheet + verified golden examples
                                       as one file (AI-harness context, #820)
vibe version                          print toolchain versions (from manifest.json)
vibe toolchain list|default <name>|remove <name>
                                      installed toolchains / pick the default / delete one
vibe self update [<version>|latest] [--no-default] [--force]
                                      install a release toolchain and make it the default
vibe self update --cli-wasm <path>    refresh compiler wasm + rebuild .cwasm
vibe self uninstall [--purge]         remove the install (--purge: caches, shared packages, log too)
vibe help                             usage
```

An executable root is a `.vibex` file with exactly one `fn main`; its
user-visible entry cannot be overridden. Arbitrary entry names remain an
internal compiler/test-harness ABI only.

## Project layout

`vibe new <dir>` scaffolds a project, and the root `index.vpkg` it writes is
both the project marker and the manifest:

```text
<root>/
  index.vpkg                          manifest: name, version, deps, require pins
  main.vibex                          entry
  .gitignore                          contains `.vibe/`
  lib/@scope/name/                    workspace packages (optional)
  .vibe/
    store/@scope/name/                pinned dependencies, materialized from the pins
    build/
      cache/vibe_*                    the compiler's persistent cache
      vpkg_types/                     vpkg type stubs
      run/<stem>.wasm (+ .funcmap)    `vibe run`
      test/<path>/<stem>.wasm (+ .testmeta)
      bench/<stem>.wasm
      out/<stem>.wasm                 `vibe build` without -o
```

**Project root.** Every verb applies one rule, and `vibe root` prints the
answer: walk up from the current directory; the root is the **outermost**
directory containing `index.vpkg`, without crossing a directory that
contains `.git`; with no `index.vpkg` in sight, the root is the current
directory. Outermost rather than nearest, because a workspace with
`@scope/name` packages under `lib/`, each with its own `index.vpkg`, is one
project with one build directory. Not across `.git`, because a package
checked out inside another project is its own project. The fallback is what
lets `vibe check` on a stray file and a single-file `.vibex` script work
without a project: they get a `.vibe/build/` where they run, and such a
`.vibex` may carry its own `require` pins in its header.

The launcher changes to the root before invoking the compiler and rewrites
relative path arguments (the root is always an ancestor, so the rewrite is a
prefix); the compiled program itself still runs from the directory you stood
in. The compiler's own contract is that its cwd is the project root, which is
where the loader resolves `.vibe/store/` and the workspace `lib/`. `vibe lsp`
computes the root from its cwd like every other verb, so start it at the
workspace root.

**`.vibe/` is the only directory the toolchain writes into a project.** It is
reproducible from the sources and the pins, which is why `vibe new` puts the
whole directory in `.gitignore`. `vibe clean` removes `.vibe/build/`; `vibe
clean --all` also removes `.vibe/store/`. The cache is per project on
purpose: `rm -rf .vibe` is the whole story of cleaning up, and one project
cannot poison another. Sharing a build directory or a cache across worktrees
or CI jobs is what `VIBE_BUILD_DIR` and `VIBE_BUILD_CACHE_DIR` are for
(below).

What each verb writes:

| verb | writes |
| --- | --- |
| `vibe run x.vibex` | `.vibe/build/run/x.wasm` and its `.funcmap`, overwritten each run |
| `vibe test a/b_test.vibe` | `.vibe/build/test/a/b_test.wasm` and its `.testmeta`; the PASS record goes to `$VIBE_HOME/cache/test/` |
| `vibe bench x_bench.vibe` | `.vibe/build/bench/x_bench.wasm` |
| `vibe build x.vibex`, `vibe compile x.vibe` without `-o` | `.vibe/build/out/x.wasm` (`--wit`: `.vibe/build/out/x.wit`); the path is printed |
| `-o <path>` | as given, relative to the directory you ran from. A sidecar (`.funcmap`, `.diag`) lives next to the artifact it describes, never next to a source |
| `vibe check`, `symbols`, `type-at`, `binding-at`, `deps`, `grep`, `escapes`, `rc-classify`, `rc-plan`, `allocs`, `doc-at`, `fmt`, `normalize`, `shell` | scratch under the OS temp dir, removed on exit. The compiler cache they warm goes to `.vibe/build/cache/` like any other verb |
| `vibe add`, `vibe fetch` | `.vibe/store/`, the root `index.vpkg` |
| `vibe pkg install` (without `--store`) | `$VIBE_HOME/lib/` |

Nothing is written next to a source file, and nothing is left under the OS
temp dir after a verb exits.

## Environment variables

| variable | read by | meaning |
| --- | --- | --- |
| `VIBE_HOME` | dispatcher, launcher, compiler | the global home, default `~/.vibe` |
| `VIBE_TOOLCHAIN` | dispatcher | toolchain selection override |
| `VIBE_LIB` | compiler | extra `@scope/name` roots, `:`-separated. An installed toolchain's launcher sets it (when unset) to `$TOOLCHAIN_DIR/lib:$VIBE_HOME/lib`, so the active toolchain's stdlib comes first; the compiler's own default with no environment is `$VIBE_HOME/lib` |
| `VIBE_BUILD_DIR` | launcher | overrides `<root>/.vibe/build`; the launcher derives `VIBE_BUILD_CACHE_DIR=$VIBE_BUILD_DIR/cache` unless that is already set, so the compiler cache moves with it |
| `VIBE_BUILD_CACHE_DIR` | compiler | the compiler cache root on its own: the isolation knob the unit-test runner and CI use |
| `VIBE_RELEASE_URL` | launcher, installer | download base for release assets (default: this repository's GitHub releases; tests point it at a `file://` directory) |
| `VIBE_INSTALL_VERSION`, `VIBE_INSTALL_REF`, `VIBE_INSTALL_REPO`, `VIBE_BIN_DIR` | installer | the `--version`, `--ref` and `--bin-dir` selectors, and the repository the checkout mode fetches from |

`VIBE_CACHE` and `VIBE_TEST_CACHE` are not read: the vendoring lane whose
fetch cache the first one named is gone, and the test result cache is always
`$VIBE_HOME/cache/test/`. Compiler and test knobs (`VIBE_TEST_JOBS`, the
`--unstable-*` flags) are in [cli-commands.md](cli-commands.md).

## Dependencies

A dependency is a package: a directory with an `index.vpkg` (its contract and
public API boundary, ADR-0070). The root `index.vpkg` of your project is the
manifest, and pinned dependencies live in the project-local `.vibe/store/`
(#2676). The boundary,
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

Resolution order (ADR-0065): `.vibe/store/` (pin verified), then the
workspace `lib/`, then the `VIBE_LIB` roots with the active toolchain's
stdlib first. `vibe new <dir>` names the project `@local/<dir>` unless
`--name @scope/name` is given; `vibe pkg publish` refuses the `@local` scope.

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

## Updating

```bash
vibe self update latest            # install the newest release and make it the default
vibe self update 0.2.0             # a specific release
vibe self update 0.2.0 --no-default
vibe self update 0.2.0 --force     # reinstall over an existing toolchains/0.2.0/
```

A release is resolved through its `release-manifest.json` (`latest` through
the newest release's), every asset is downloaded into
`$VIBE_HOME/cache/downloads/<tag>/` and verified against that manifest, the
toolchain is assembled and precompiled in a staging directory, and only then
renamed into `toolchains/<version>/`. A mismatch stops before anything is
moved. The previous toolchain stays installed: `vibe toolchain default
<name>` switches back, `vibe toolchain remove <name>` deletes it. An
installed version is refused without `--force`.

Per `vX.Y.Z` tag, `.github/workflows/release.yml` publishes:

| asset | content |
| --- | --- |
| `viberun-<tag>-<target>.tar.gz` | one prebuilt runner per target: `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `aarch64-apple-darwin` (and `x86_64-apple-darwin` while a CI runner exists) |
| `vibe-toolchain-<tag>.tar.gz` | the platform-independent part of `toolchains/<name>/`: launcher, `vibe_pkg.sh`, `parallel_warm_pool.sh`, the LSP scripts, `context-pack.md`, the stdlib packages with their hashes |
| `vibe-compiler-<tag>.wasm`, `vibe-compiler-module-source-<tag>.vibe`, `vibe-compiler-seed-<tag>.json` | the compiler and its seed provenance |
| `release-manifest.json` | every asset with its sha256, the runner per target, and the wasmtime version the runners embed |
| `SHA256SUMS.txt` | checksums of all of the above |

`vibe self update` needs the runner for this host, the toolchain bundle and
the compiler wasm; a release with no runner for the host names the targets
it ships.

The runner and the compiler wasm also version independently. To move only the
compiler of the current toolchain forward without a release:

```bash
vibe self update --cli-wasm path/to/new/vibe-cli.wasm
```

This copies the new compiler wasm into place and rebuilds the host-specific
`vibe-cli.cwasm` against the installed runner; it is the one edit ever made
inside an installed toolchain directory.

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
