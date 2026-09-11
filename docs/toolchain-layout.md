# Toolchain and project layout

**Status: decided 2026-09-11 (ADR-0111), implementation tracked in
[#2674](https://github.com/mizchi/vibe-lang/issues/2674).** This document is
the target contract for where the toolchain puts things: the global home under
`$VIBE_HOME`, the project-local `.vibe/` directory, what each command writes,
how dependencies are pinned, and how a toolchain is updated. Until a phase
lands, [install.md](install.md), [build-cache.md](build-cache.md) and the book
describe the shipped behavior; this document describes where they are going.
When the last phase lands, the layout sections below fold into `install.md`,
the ADR row moves to `accepted`, and this file is deleted.

Phases, in dependency order:

1. [#2675](https://github.com/mizchi/vibe-lang/issues/2675) — project root
   discovery and `.vibe/build/` outputs (blocks the rest)
2. [#2676](https://github.com/mizchi/vibe-lang/issues/2676) — one dependency
   lane on the root `index.vpkg` and `.vibe/store/`
3. [#2677](https://github.com/mizchi/vibe-lang/issues/2677) — per-toolchain
   stdlib, toolchain manifest, `vibe toolchain`, environment variables
4. [#2678](https://github.com/mizchi/vibe-lang/issues/2678) — prebuilt runner
   release assets, `vibe self update <version>`, release install path

## 1. What this replaces (measured 2026-09-11)

Measured with the stage2 compiler from `entry-allows-2026-09-11`, running the
launcher the way an installed toolchain runs it, from a scratch project:

- The compiler roots its persistent cache at the literal prefix `_build/vibe_`
  (`lib/@vibe/compiler/cache/cache_underlying.vibe`) and the vpkg type stubs at
  `_build/vibe_vpkg_types/types_` (`lib/@vibe/compiler/loader/loader.vibe`),
  both **relative to the process cwd**. `vibe run sub/main.vibex` from the
  project root writes `./_build/` (7 cache files for a hello program, 31
  module headers once `@vibe/core` is imported); the same file run from inside
  `sub/` writes `sub/_build/`. Neither the entry's location nor any project
  marker is consulted.
- `.vibe/store/` and the workspace `lib/` are resolved relative to cwd too.
  Today "the project root" is whatever directory the user is in.
- `vibe run` / `test` / `bench` compile into `mktemp -t vibe-*` files under
  the OS temp dir. `vibe compile -o out.wasm` leaves `out.wasm.funcmap` next
  to the output; without `-o` the wasm lands next to the source.
- `$VIBE_HOME/lib/@vibe/*` (the stdlib) is shared by every installed
  toolchain and `rm -rf`-overwritten on each install, so two toolchains cannot
  coexist correctly.
- The only update path is `vibe self update --cli-wasm <local path>`.
  Releases publish the compiler wasm, module source, seed json, manifest and
  checksums, and no runner binary: `viberun` is built with cargo at install
  time. There is no toolchain switch command.
- Six environment variables overlap: `VIBE_HOME`, `VIBE_LIB`, `VIBE_CACHE`,
  `VIBE_TEST_CACHE`, `VIBE_BUILD_CACHE_DIR`, `VIBE_TOOLCHAIN`.
- `docs/spec/stable-surface.md` §4 names the lock file `index.lock`; the
  launcher writes `vibe.lock`. `scripts/vibe_pkg.sh` reads `index.vibei` at 22
  sites and `index.vpkg` at none, so the registry lane does not accept a
  current package.

## 2. Global home: `$VIBE_HOME`

`VIBE_HOME` defaults to `~/.vibe` and stays there (not XDG): one directory a
user can find, back up, and delete.

```text
$VIBE_HOME/
  bin/vibe                            dispatcher (the only PATH entry)
  env                                 shell setup, sourced from the rc files
  toolchain                           default toolchain name
  toolchains/<name>/
    bin/{vibe,viberun}                launcher + wasmtime runner
    lib/vibe-cli.wasm                 portable compiler
    lib/vibe-cli.cwasm                host-specific AOT build of it
    lib/{lsp_server.js,symbol_index.js,graph_query.js}
    lib/{vibe_pkg.sh,parallel_warm_pool.sh,context-pack.md}
    lib/@vibe/{core,ast,parser,builtin,console,wit_runtime}
                                      stdlib, PER TOOLCHAIN (today: shared)
    manifest.json                     version, tag or ref, commit, installed_at,
                                      source (release | checkout), sha256 of
                                      runner and compiler wasm, wasmtime version
  lib/@scope/name/                    shared packages from `vibe pkg install`
                                      (dev-mode resolution root, unchanged)
  cache/pkg/sha1/<hex>/               content-addressed package store (CAS)
  cache/pkg/versions.tsv              name@version -> hash (immutable)
  cache/pkg/provenance.tsv            (source, commit) per fetched package
  cache/test/<sha256>.pass            pure-test result cache (ADR-0026)
  cache/downloads/<tag>/              release assets while `self update` runs
  log/                                transparency log (publisher state, #805)
```

Rules:

- A **toolchain** is one versioned unit: runner, compiler, launcher, editor
  scripts, and the stdlib those were built with. Nothing in
  `toolchains/<name>/` is shared with another toolchain. Installing a second
  toolchain never touches the first.
- **Shared** state is only what is keyed by content or independent of the
  compiler version: the package CAS, the test result cache (its key is the
  sha256 of the compiled wasm, which already folds in the compiler), the
  dev-mode `lib/`, and the publisher log.
- A toolchain **name** is the release version (`0.1.0`) for a release
  install, or the sanitized ref (`main`, `my-branch`) for a checkout install,
  exactly as `install/install.sh` names it today.
- The names `build` and `store` are **reserved** directly under `$VIBE_HOME`.
  A project rooted at `$HOME` puts its `.vibe/build/` and `.vibe/store/` there
  (section 4), and they must not collide with toolchain state.
- The pre-#755 **flat layout** (`$VIBE_HOME/bin/vibe` next to
  `$VIBE_HOME/lib/vibe-cli.wasm`) is no longer recognized. 0.1.0 is not
  tagged, so nothing published depends on it; a flat home is refused with a
  message naming the installer.

## 3. Toolchains, releases and updates

### Release assets

Per `vX.Y.Z` tag, `.github/workflows/release.yml` publishes:

| asset | content |
| --- | --- |
| `vibe-compiler-<tag>.wasm`, `vibe-compiler-module-source-<tag>.vibe`, `vibe-compiler-seed-<tag>.json` | as today (the compiler and its seed provenance) |
| `viberun-<tag>-<target>.tar.gz` | **new**: one prebuilt runner per target: `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `aarch64-apple-darwin` (and `x86_64-apple-darwin` while a CI runner exists) |
| `vibe-toolchain-<tag>.tar.gz` | **new**: the platform-independent part of `toolchains/<name>/`: launcher, `vibe_pkg.sh`, `parallel_warm_pool.sh`, LSP scripts, `context-pack.md`, the stdlib packages with their hashes |
| `release-manifest.json` | every asset with its sha256, plus the wasmtime version the runners embed |
| `SHA256SUMS.txt` | as today |

### `vibe self update`

```text
vibe self update [<version> | latest] [--no-default] [--force]
vibe self update --cli-wasm <path>          offline compiler swap, unchanged
```

1. Resolve the tag. `latest` reads the `release-manifest.json` published
   under the latest release's download URL; a version reads the manifest of
   that tag. `VIBE_RELEASE_URL` overrides the download base so a
   test can point it at a `file://` release directory.
2. Download every asset the toolchain needs into
   `$VIBE_HOME/cache/downloads/<tag>/` and verify each against the manifest.
   A mismatch stops here; nothing has been moved yet.
3. Unpack into a staging directory under `toolchains/`, run
   `viberun --precompile` to produce the `.cwasm`, write `manifest.json`.
4. Rename the staging directory to `toolchains/<version>/`. An existing
   toolchain of that name is refused unless `--force`.
5. Make it the default (`$VIBE_HOME/toolchain`) unless `--no-default`.

A toolchain directory is never edited in place after that, with one
documented exception: `--cli-wasm <path>` replaces the compiler wasm and
rebuilds the `.cwasm` of the current toolchain, as it does today.

### `vibe toolchain`

```text
vibe toolchain list                 installed toolchains, the default marked
vibe toolchain default <name>       rewrite $VIBE_HOME/toolchain
vibe toolchain remove <name>        refuses the default
```

Selection order is unchanged: `$VIBE_TOOLCHAIN`, then the `toolchain` file,
then the single installed toolchain. `vibe version` reads `manifest.json`.

### The development channel

A checkout install (`install/install.sh --ref <ref>`, or `bash
install/install.sh` inside a checkout) builds the runner with cargo and the
compiler from the checkout, exactly as today, and names the toolchain after
the ref. That is the only path that needs git, cargo and Node.js.

### Uninstall

```text
vibe self uninstall [--purge]
```

Removes `toolchains/`, `bin/`, `env`, `toolchain`, and the one rc line the
installer added. `--purge` also removes `cache/`, `lib/` and `log/`.

### The dispatcher

`$VIBE_HOME/bin/vibe` is a few lines of shell rewritten by the newest
installer or updater. Its whole contract: pick a toolchain by the selection
order above, export `VIBE_HOME`, and exec `toolchains/<name>/bin/vibe`. It
must keep doing that for any older toolchain's launcher.

## 4. Project root

The **launcher owns the rule**, every verb applies it, and `vibe root` prints
the answer:

1. Walk up from cwd. The root is the **outermost** directory that contains
   `index.vpkg`.
2. Do not cross a directory that contains `.git`. A package checked out inside
   another project resolves to its own repository, not to the outer one.
3. If no `index.vpkg` is found, the root is cwd.

Why outermost and not nearest: a workspace with `@scope/name` packages under
`lib/`, each with its own `index.vpkg`, is one project with one build
directory, and the nearest marker from inside such a package would be the
package itself. Why a marker at all: a
project is a package (its root `index.vpkg` is also its manifest, section 7),
so no second file is needed. Why cwd as the fallback: `vibe check` on a stray
file and a single-file `.vibex` script have no project and must still work
without creating one; they get a `.vibe/build/` where they run.

The launcher `cd`s to the root before invoking the compiler and rewrites
relative path arguments. The root is always an ancestor of cwd, so the rewrite
is a prefix. The **compiler's contract is unchanged: its cwd is the project
root**, and the loader keeps resolving `.vibe/store/` and the workspace `lib/`
relative to cwd. Scripts that drive the compiler directly (the repository's
gates) run from the root and need no change.

`vibe lsp` computes the root from its cwd like every other verb. Editors start
it at the workspace root, which is the project root in the normal case.

A `.vibex` outside any project keeps today's behavior: it may carry its own
`require` pins in its header, and its root is the directory it is run from.

## 5. Project-local `.vibe/`

```text
<root>/
  index.vpkg                          manifest: name, version, deps, require pins
  main.vibex                          entry (written by `vibe new`)
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

- `.vibe/` is the **only** directory the toolchain writes into a project. It
  is reproducible from the sources and the pins, so `vibe new` puts the whole
  directory in `.gitignore`.
- `vibe clean` removes `.vibe/build/`; `vibe clean --all` also removes
  `.vibe/store/`. It replaces `pkf run cache-clean` for a user project.
- The cache is per project on purpose: `rm -rf .vibe` is the whole story of
  cleaning up, and one project cannot poison another. Sharing across
  worktrees or CI jobs is what `VIBE_BUILD_CACHE_DIR` is for (section 8).

## 6. What each verb writes

| verb | writes |
| --- | --- |
| `vibe run x.vibex` | `.vibe/build/run/x.wasm` and its `.funcmap`, overwritten each run |
| `vibe test a/b_test.vibe` | `.vibe/build/test/a/b_test.wasm` and its `.testmeta`; the PASS record goes to `$VIBE_HOME/cache/test/` |
| `vibe bench x_bench.vibe` | `.vibe/build/bench/x_bench.wasm` |
| `vibe build x.vibex`, `vibe compile x.vibe` without `-o` | `.vibe/build/out/x.wasm` (`--wit`: `.vibe/build/out/x.wit`); the path is printed |
| `-o <path>` | as given. A sidecar (`.funcmap`, `.diag`) lives next to the artifact it describes, never next to a source |
| `vibe check`, `symbols`, `type-at`, `binding-at`, `deps`, `grep`, `escapes`, `rc-classify`, `rc-plan`, `allocs`, `doc-at`, `fmt`, `normalize`, `shell` | scratch under the OS temp dir, removed on exit. The compiler cache they warm goes to `.vibe/build/cache/` like any other verb |
| `vibe add`, `vibe fetch` | `.vibe/store/`, the root `index.vpkg` (section 7) |
| `vibe pkg install` (without `--store`) | `$VIBE_HOME/lib/` |

Nothing is written next to a source file, and nothing is left under the OS
temp dir after a verb exits.

## 7. Dependencies: one lane

The root `index.vpkg` header is the manifest. `.vibe/store/` is where pinned
dependencies live. The pin carries its source, so a fresh clone can restore the
store without a registry.

```text
name = @you/app
version = 0.1.0
description =
  #|What the program is
deps = {
  @acme/json : 1.4.0
}

require @acme/json 1.4.0 = #pkg:sha1:<40hex> from github:acme/json@<commit>

generated_hash =
```

- `deps` **declares** a dependency (what `vibe check --deps-missing` checks an
  import against). `require` **pins** it: version, content hash, and the
  resolved source. The `from` clause is `github:owner/repo[/dir]@<commit>` or
  `git:<url>@<commit>[#<dir>]`, always a commit, never a branch. Unifying the
  two spellings into one is a manifest-format decision and out of scope here.
- Standard-library packages (`@vibe/*`) resolve from the toolchain and carry
  no `from` clause.
- **`vibe add <source-spec>`** fetches with git, hashes the package, installs
  it into `.vibe/store/<name>/`, and writes both the `deps` entry and the pin
  line through the `.vpkg` formatter. The name is the one the fetched
  package's own `index.vpkg` declares and must be `@scope/name`. This replaces
  `vibe add <name> <url>` and `vibe pkg add … --store`.
- **`vibe fetch`** restores `.vibe/store/` from the pins: the CAS under
  `$VIBE_HOME/cache/pkg/` first, else the `from` source. The hash is verified
  either way; a mismatch fails closed before anything is copied.
- Resolution order is unchanged (ADR-0065): `.vibe/store/` (pin verified),
  then the workspace `lib/`, then the `VIBE_LIB` roots with the active
  toolchain's stdlib first.
- A dependency is a package: it has an `index.vpkg`. Single-file URL
  dependencies are not supported.
- **`vibe new <dir>`** scaffolds `main.vibex`, `.gitignore`, and a root
  `index.vpkg` with `name = @local/<dir>`; `--name @scope/name` overrides.
  `vibe pkg publish` refuses the `@local` scope.

Retired with this lane: `vibe.deps`, `vibe.lock`, `deps/`,
`vibe fetch --frozen`, `vibe verify`, `VIBE_CACHE`, and the
`$VIBE_HOME/cache/<sha256>` single-file cache. `docs/spec/stable-surface.md`
§4 loses the `vibe add` / `fetch --frozen` / `verify` rows and the
`index.lock` mention along with them; `vibe add` and `vibe fetch` keep their
names with the semantics above.

## 8. Environment variables

| variable | read by | meaning | status |
| --- | --- | --- | --- |
| `VIBE_HOME` | launcher, compiler | the global home (section 2) | kept |
| `VIBE_TOOLCHAIN` | dispatcher | toolchain selection override | kept |
| `VIBE_LIB` | compiler | extra `@scope/name` roots, `:`-separated. The launcher sets it (when unset) to `$TOOLCHAIN_DIR/lib:$VIBE_HOME/lib`, so the active toolchain's stdlib comes first. The compiler's own default with no environment is unchanged | kept |
| `VIBE_BUILD_DIR` | launcher | overrides `<root>/.vibe/build`; the launcher derives `VIBE_BUILD_CACHE_DIR=$VIBE_BUILD_DIR/cache` unless that is already set | **added** |
| `VIBE_BUILD_CACHE_DIR` | compiler | explicit cache root; the isolation knob the unit-test runner and CI already use | kept |
| `VIBE_RELEASE_URL` | launcher, installer | download base for release assets (tests: a `file://` directory) | **added** |
| `VIBE_CACHE` | launcher | fetch cache of the retired vendoring lane | retired |
| `VIBE_TEST_CACHE` | launcher | the result cache is `$VIBE_HOME/cache/test/`, no override | retired |

## 9. Installer contract: `install/install.sh`

Two modes, one entry point:

| mode | selector | requirements | what it does |
| --- | --- | --- | --- |
| release | `--version X.Y.Z` (or `VIBE_INSTALL_VERSION`); the default of the curl entry point once #2678 lands | bash, curl or wget, tar | download the assets of section 3, verify against the manifest, unpack into `toolchains/<version>/`, precompile, write `manifest.json` |
| checkout | `--ref <ref>` (or `VIBE_INSTALL_REF`), or running inside a checkout | git, cargo, Node.js (Node.js not needed with `--cli-wasm`) | build the runner and the compiler from the checkout, as today |

Both modes: install into a staging directory and rename, so a failed install
leaves nothing half-installed; write the dispatcher, `env`, and the default
toolchain marker; the PATH policy is unchanged (`~/.vibe/bin` is the entry,
`~/.vibe/env` is sourced from the rc files only for a default-prefix install,
`--no-modify-path` skips it, `--prefix` never touches rc files). The existing
options (`--runner`, `--cli-wasm`, `--toolchain`, `--set-default`,
`--no-stdlib`, `--bin-dir`, `--no-link`) keep their meaning; `--no-stdlib`
skips the toolchain's own `lib/@vibe/` rather than a shared one.

## 10. This repository

- `_build/` stays for the repository's own tooling: selfhost generations,
  bench and coverage output, gate scratch, CI shard artifacts. That is
  repository infrastructure, not product behavior, and is tracked under #2001.
- The compiler cache and the launcher artifacts move to `.vibe/build/` here
  too, so there is one rule: `.github/workflows/ci.yml` cache paths,
  `docs/build-cache.md`, `scripts/cache_clean.sh`, and every gate that greps
  `_build/vibe_*` follow.
- The repository root has **no** `index.vpkg` (decided: a root package would
  make every loose source its member under ADR-0070, and the gates already run
  from the root). cwd is the root here.
- Until the next bootstrap bump the **seed** compiler still writes
  `_build/vibe_*`, because it predates the prefix change. CI caches both
  patterns during that window and drops the old one with the bump.

## 11. What proves it

- Root rule: a self-test that mutates each case (nested package, `.git`
  boundary, no marker, relative-argument rewrite) and fails, registered per
  `scripts/check_gate_self_tests.sh`.
- Layout: `tests/integration/install/install_test.sh` asserts no `_build/`
  and no sidecar in a scratch project, `.vibe/build/` at the root, two
  toolchains with different stdlib content each running their own,
  `vibe toolchain default` switching without a reinstall, and a flat home
  refused.
- Dependencies: `vibe add` against a local `file://` git fixture; `vibe fetch`
  on a fresh clone, once from the CAS and once from source; a tampered store
  copy refused; the pin line round-tripping through `vibe fmt --check`.
- Updates: a network-free synthetic release directory (manifest, tarballs, a
  fake runner as in `tests/integration/install/curl_bootstrap_test.sh`);
  a tampered asset refused before anything moves; `--force`; the release
  install mode with `PATH` restricted to bash, curl and tar.
