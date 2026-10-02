# Bootstrap Policy

This document fixes how the seed compiler behind vibe's self-compilation is
operated. The goal is that HEAD's compiler source can always be rebuilt from
the previous stable compiler, while new language features are adopted in
stages.

## Background

A compiler that can build itself still needs a compiler binary to start each
update from. Established languages make that boundary explicit:

- Rust starts from a prebuilt stage0 compiler, builds stage1 with it, and
  builds stage2 with stage1. Stage3, an optional sanity check, confirms the
  result is the same.
  <https://rustc-dev-guide.rust-lang.org/building/bootstrapping/what-bootstrapping-does.html>
- Go's toolchain is written in Go, so a source build needs a bootstrap Go
  compiler; Go 1.N is, as a rule, bootstrapped with an earlier stable Go.
  <https://go.dev/doc/install/source>
- GHC uses an installed GHC as the stage0/bootstrap compiler and builds stage1,
  stage2 and an optional stage3.
  <https://ghc.gitlab.haskell.org/ghc/doc/users_guide/using.html>

What they share: never trust the HEAD under development outright; pin a known
compiler as the seed and verify in separate stages. vibe follows Rust's naming.
The pinned seed is **stage0**, the compiler stage0 builds from the current
source is **stage1**, and the compiler stage1 rebuilds from the same source is
**stage2**. Stage2 is the release and bump candidate; stage3 is the sanity
check that it reproduces.

## vibe's policy

### Seed compiler

- A seed is a stage2 that passed the gates below, adopted in a **bootstrap
  bump** and published as a `seed/<name>` GitHub prerelease.
- `bootstrap/seed.json` (tracked) pins it: the seed `name`, its release `tag`,
  the `source_commit` it was built from, the build `entry` / `entry_name`, the
  artifact `path` and `sha256`, and the runtime used to run it (runner, compile
  flag, wasmtime flags).
- The artifact itself, `bootstrap/seed/compiler.wasm`, is **not committed**
  (gitignored). `scripts/ensure_seed.sh` fetches it from the pinned release
  and verifies the sha256 (see "Seed artifact distribution" below).
- A seed is not updated on every commit. An update is a bootstrap bump: its
  own commit and PR, allowed only when every gate below passes.

The seed's entry is `lib/@vibe/compiler/cli_support.vibe` / `cli_main`. For
that entry, `scripts/generations.sh` compiles each stage from the flat module
source that `scripts/generate_bundle.sh` produces for
`lib/@vibe/compiler/cli_adapter.vibe`. CLI argv parsing and command dispatch
live in `lib/@vibe/cli/`; the compiler and its link/check/build helpers live in
`lib/@vibe/compiler/`. Stage outputs go under
`_build/selfhost/generations/<seed-name>_<short-sha>/` unless `--out-dir`
says otherwise.

```bash
pkf run generation-seed-info
pkf run generation-status   # read-only: seed pin + latest generation
pkf run generation -- --stage3
bash scripts/generations.sh adopt --artifact _build/selfhost/generations/<gen>/stage2.wasm \
  --name <name> --tag seed/<name> --source-commit <commit>
```

`status` (`scripts/generations.sh status`) rebuilds nothing. It lists the pinned
seed (with sha verification), the current source commit, and the latest
generation manifest (the stage0..stage3 shas and `stage3_equal_stage2`). Use it
to follow a stage0 -> stage1 -> stage2 -> bootstrap bump.

`adopt` copies a stage2 artifact to the seed path and rewrites
`bootstrap/seed.json`: the artifact sha256 always, and the name, tag and source
commit when given. A bootstrap bump commits that manifest change on its own.

### Rust-style staged build

- **stage0**: the pinned seed. Used only to build the new compiler source.
- **stage1**: the compiler stage0 builds from the current source.
- **stage2**: the compiler stage1 builds from the same source. Release and bump
  candidates are stage2.
- **stage3**: optional. Stage2 rebuilds the same source; stage2 and stage3 must
  be byte-identical.

Ordinary development uses the generation as its feedback loop. A seed update
or a release candidate requires the stage3 check. When stage3 differs from
stage2, that difference is the thing to isolate.

### Gate

A bootstrap bump requires at least:

- `pkf run full-gate` is green (staged generation + `scripts/compiler_gate.sh`).
- A generation with the new seed as stage0 gives `stage3 == stage2`. A seed
  that reproduces itself gives `stage0 == stage1 == stage2 == stage3`, the
  fixpoint and the strongest state a bump candidate can be in.
- `bash scripts/ensure_generated.sh --force` succeeds, and `--check` is ok
  afterwards.
- `scripts/check_vibe_fmt.sh` is clean.
- The unit battery (`scripts/unit_test_runner.sh`) is green.

### Adopting a new language feature in the compiler's own source

When the compiler source itself is to use new syntax or a new type-system
feature, keep this order:

1. Implement the feature's parser/checker/codegen in the subset the current
   seed already understands.
2. Pass the generation gates, so the compiler containing the feature can be
   tagged.
3. Update the seed with a bootstrap bump.
4. Only then migrate the compiler source to the new syntax.

"The commit that implements a feature" and "the commit where the compiler
source starts using it" are therefore separate. That is what keeps HEAD
rebuildable from the pinned seed at every commit.

Changing what the printer (`lib/@vibe/parser/printer.vibe`) *emits* is not a
reason for a bump, even though it changes the generated files (the flatten
writes declarations through `print_program`). A bump is needed only when the
compiler source starts using syntax the seed cannot *read*. Probe rather than
infer: whether the seed parses a spelling is one command against
`bootstrap/seed/compiler.wasm`.

## Seed artifact distribution (GitHub Release)

The seed is distributed as a GitHub Release asset rather than committed:
committing a fresh ~1.4 MB binary on every bump only stacked undiffable blobs
in `.git` (20 binary commits had grown it to 824 MB). `bootstrap/seed.json`
records the artifact's sha256 and the release tag that carries it (`seed.tag`);
the bytes are fetched on first use and cached locally.

- `scripts/ensure_seed.sh` compares the pin in `bootstrap/seed.json` with the
  on-disk `bootstrap/seed/compiler.wasm`. When the file is missing or its
  sha256 differs, it fetches the release asset through
  `scripts/fetch_compiler.sh` and installs it at the manifest's artifact path.
  When they agree it exits immediately without touching the network.
  `scripts/generations.sh` calls it from `verify_seed_artifact`, so it rarely
  needs to be run by hand; `VIBE_GENERATION_AUTO_FETCH_SEED=0` disables that
  call (for deliberately offline diagnosis only).
- CI puts an `actions/cache` step keyed on the hash of `bootstrap/seed.json`
  ahead of `scripts/ensure_seed.sh`, so a warm runner needs no network. A
  failed fetch **fails immediately** — silently using an old or wrong seed is
  worse — and the error explains the tag/URL and `--from-dir` (for an
  air-gapped mirror).
- **One exception.** When the pinned tag does not exist yet in the release
  repository (`mizchi/vibe-lang`, checked with `git ls-remote`; override with
  `VIBE_ENSURE_SEED_GIT_REMOTE`) — the window in a bootstrap-bump PR before
  `seed-release` has run — the seed is **rebuilt** instead of fetched:
  `seed.source_commit` is checked out into a worktree (whose own manifest pins
  the previous published seed), `generations.sh build` runs there, and the
  resulting stage2 is installed only if it matches the pinned sha256. A tag
  that exists but cannot be fetched or verified (missing asset, bad manifest,
  sha mismatch), or being offline, still fails immediately.
  `VIBE_ENSURE_SEED_NO_REBUILD=1` disables the exception too. See step 3 of
  "Bootstrap bump procedure" below.

### Release tags and artifacts

- Product releases use `v*` tags, such as `v0.1.0`. The tag triggers
  `.github/workflows/release.yml`, which packages assets with
  `scripts/build_release_assets.sh`.
- Bootstrap seed releases use `seed/<name>`, following `seed.name`, such as
  `seed/array-capacity-2026-09-20`. The manually dispatched
  `.github/workflows/seed-release.yml` uses `scripts/build_seed_release_assets.sh`.
  These have no SemVer version and are published as prereleases.

Both release kinds include the bootstrap artifact trio, produced by
`scripts/build_compiler_seed_assets.sh`:

- `vibe-compiler-<tag>.wasm`: the pinned stage0 seed, copied directly from
  `bootstrap/seed/compiler.wasm` and verified against `bootstrap/seed.json`.
- `vibe-compiler-module-source-<tag>.vibe`: flat module source generated from
  the release's compiler source by the seed-based `scripts/generate_bundle.sh`.
  Consumers can rebuild stage1 and stage2 without repeating flattening.
- `vibe-compiler-seed-<tag>.json`: the seed provenance descriptor. The
  `compiler` block in `release-manifest.json` records the bootstrap artifacts,
  their checksums, and the seed's source commit. `SHA256SUMS.txt` covers the
  shipped files.

Product releases also ship `vibe-cli-<tag>.wasm`, built from current source by
`scripts/build_cli_wasm.sh` (seed → stage1 → stage2). The manifest's top-level
`compiler_wasm` selects this CLI for installation. The installer consumes it
directly and AOT-compiles it for the host; it does not rebuild the CLI from the
bootstrap trio. Package hashes are computed with this same current compiler.

Fetch bootstrap artifacts with `scripts/fetch_compiler.sh`
(`pkf run fetch-compiler`), which reads the nested `compiler` block.

```bash
# Fetch and verify bootstrap artifacts, then print the module-source environment.
eval "$(bash scripts/fetch_compiler.sh <tag> --print-env)"
# Rebuild stage0 -> stage1 -> stage2 using the downloaded flat source.
bash scripts/generations.sh build
```

`prepare_flat_cli_source` in `scripts/generations.sh` uses
`VIBE_PREBUILT_MODULE_SOURCE` and its optional `..._SHA256` without regenerating
the flat source. Without that override, it runs `scripts/generate_bundle.sh`.

Prebuilt flat source belongs to the release's exact source tree. After editing
compiler source, regenerate it rather than reusing a stale release artifact.
`--adopt-seed` additionally verifies the downloaded seed against the locally
pinned checksum.

### Generated compiler files

Five files under `lib/@vibe/compiler/` are outputs of
`scripts/generate_bundle.sh`:

```
compiler_sources_bundle.vibe
cli_adapter_bundle.vibe
selfbuild_runtime_entry_bundle.vibe
_cli_adapter_module_source.vibe
cache/codegen_fingerprint.vibe
```

All five are deterministic functions of (pinned seed, compiler source) and are
**not tracked in git**. `scripts/ensure_generated.sh` produces them when needed:

```bash
bash scripts/ensure_generated.sh                      # regenerate if stale, else a ~1s no-op
bash scripts/ensure_generated.sh --check              # judge freshness only (exit 1 if stale)
bash scripts/ensure_generated.sh --force              # regenerate unconditionally
bash scripts/ensure_generated.sh --print-fingerprint  # for CI cache keys
```

Freshness is decided by a fingerprint over the seed wasm, the source manifest
(`compiler_sources_manifest.tsv`) and every file it names, the generator
scripts themselves, and every non-test library `.vibe` under `lib/@vibe` and
`lib/@vibex`. The fingerprint is recorded in
`lib/@vibe/compiler/.generated.stamp`, with the input list beside it in
`.generated.inputs`. The stamp is removed before generation starts, so an
interrupted run can never leave partial outputs that claim to be current.
`pkf run test`, `release-check`, the CI shards and the SessionStart hook all
call it, so it is rarely run by hand.

There is no bootstrap cycle. The pinned seed resolves the live tree's imports
itself and prints the merged program (`VIBE_EMIT_MERGED_SOURCE`). The flatten
tool is bootstrapped from the seed in three passes (flatten →
emit-module-source → compile), and that tool — **the current source's merge
machinery** — performs the final flatten. The seed's own flatten is not used
for the final output because it is one generation old: an edit to
`merge_sources.vibe` and friends would not take effect until the next seed
bump, and the output would still look valid.

`coverage_drivers.sh`'s exact-path exposure (#1633) keeps the same generation
boundary. Its internal mode is run by `compiler_cov.wasm`, built from current
source, which emits ordinary vibe source DCE'd from a driver entry. The pinned
seed only compiles that output with coverage, so it never has to understand the
new mode — no syntax addition, no seed bump, and no change to the ordinary
`VIBE_EMIT_MERGED_SOURCE` output.

Why these files are not tracked:

- Any two PRs touching compiler source **always** conflicted on all five, and
  the correct content was neither side but a regeneration from the merged
  source.
- About 30% of the packfile (476 MB of 1.6 GB) was their history (159 of the
  last 200 commits).
- Tracking them created a staleness trap: the build silently preferred the
  committed copy, so a source edit nobody regenerated for produced a compiler
  **without that edit** and still reported success.
- CI regenerated them anyway, only to assert the committed copies matched.
  Generating instead of comparing is the same work minus the failure mode.

`bootstrap/seed.json` is what is tracked; the chain starts from the wasm it
pins, and nothing else in the chain is irreducible.

`.gitattributes` still marks the five paths `-diff linguist-generated`, which
keeps a 13 MB single-line bundle out of any diff that includes a local copy.

### Bootstrap bump procedure

Run `seed-release.yml` manually through **`workflow_dispatch`, not a tag push**.
After adoption, `bootstrap/seed.json` already points at the new seed. A tag-push
job would therefore try to fetch the new seed's not-yet-published release as
its own stage0. The required `prior_seed_ref` input breaks that cycle by naming
an existing, published seed to use as stage0.

1. Build a stage2 candidate with `scripts/generations.sh build --stage3` and
   pass the gates above.
2. Run `scripts/generations.sh adopt --artifact <stage2.wasm> --name <name> \
   --tag seed/<name> --source-commit <commit>`. This updates
   `bootstrap/seed.json`, copies the artifact to `bootstrap/seed/compiler.wasm`,
   and records its sha256 and tag. The tag must be `seed/` followed by the
   name; `scripts/build_compiler_seed_assets.sh` refuses a manifest where it
   is not.
3. Commit the `bootstrap/seed.json` update separately, but do not merge the PR
   yet. Fresh CI runners fetch the seed from the new tag; while that tag does
   not exist in the release repository, `scripts/ensure_seed.sh` rebuilds the pinned seed instead:
   it checks out `seed.source_commit` (whose own manifest pins the previous
   published seed) and runs `generations.sh build` there, then installs the
   stage2 only if it matches the pinned sha256. So the bump PR's gates are
   green before the release exists, at the cost of one stage0 -> stage2 build
   per cold job (`actions/cache` keyed on the manifest shares it afterwards).
   The release is still required before merging: after the merge every fresh
   clone of main would otherwise pay that rebuild. `VIBE_ENSURE_SEED_NO_REBUILD=1`
   restores the fail-fast; `scripts/ensure_seed_test.sh` pins the fallback's
   contract (matching rebuild installs, mismatching rebuild is refused).
4. Dispatch the GitHub Actions `seed-release` workflow with that commit as
   `source_ref`:
   - `tag`: the `seed/<name>` chosen in step 2.
   - `source_ref`: the committed bootstrap-bump branch revision.
   - `prior_seed_ref`: required. It cannot default to `source_ref`, whose own
     manifest already points at the unpublished new seed. Use a commit from
     before the source change whose `bootstrap/seed.json` points at the latest
     valid published `seed/*` release; CI reads that manifest and fetches its
     artifact. (The workflow also accepts a commit that still tracks
     `bootstrap/seed/compiler.wasm`, extracting the artifact with `git show`;
     that case only arises for commits from before the seed was untracked.)
   - CI acquires the prior artifact, rebuilds deterministically through stage3,
     adopts the candidate in its workspace, and publishes the assets.
5. Verify that the released compiler sha256 matches `bootstrap/seed.json`
   (the rebuild in step 3 proves the same equality from the other side), then
   merge only after CI is green.
6. The published release appears as a **prerelease**. All CI and local callers
   that read the pin can then fetch it through `scripts/ensure_seed.sh`.
   Because immutable releases are enabled, the workflow first creates a draft,
   attaches every asset, and only then publishes it with
   `gh release edit --draft=false`. Re-dispatching an already-published tag
   fails at preflight; delete that release and tag or choose a new tag.

The seed binaries committed before the seed moved to releases (about 20
commits) stay in history. Rewriting history would break existing clones, forks
and open PRs; compacting it would be a separate, explicitly agreed maintenance
operation.

## Layer split

The runner and the compiler artifact are separate layers.

- **Runner layer**: `runtime/viberun`, wasmtime flags, the cwasm cache, host
  imports, the component adapter.
- **Compiler wasm layer**: the dist/component/check entries built from the CLI
  entry in `lib/@vibe/cli/` and the compiler in `lib/@vibe/compiler/`.

The runner layer may be swapped for performance or execution-platform reasons,
but the gate keeps the canonical compiler rebuildable as a portable compiler
wasm.

## Compiler wasm artifact contract

The canonical builders of a compiler wasm:

| artifact | builder | output | role |
|---|---|---|---|
| stage2 | `scripts/generations.sh build` | `_build/selfhost/generations/<gen>/stage2.wasm` | The candidate self-reproduced from the pinned seed; the source of a bootstrap bump and of a release's CLI. |
| compile-only | `scripts/build_compile_only.sh` | `_build/compile_only/vibe_compile_only.wasm` | The same env-mode CLI as stage2, DCE-rooted at `main_compile_only` (cli_adapter.vibe): only the two production allocator lanes; the gc backend, the coverage / trace / break instrumentation, rc-shadow and the cache / telemetry twins are absent from the wasm, and their switches are refused by name (#2497, gate `scripts/check_compile_only_lanes.sh`). The lane switches that reach codegen as `Bool` parameters (`coverage`, `debug_trace`, `debug_break`, `rc_shadow` of `compile_wasi_module_linked_impl`) fold to their literal in this build, because every remaining caller passes the same one (`fold_const_bool_params`, core), so the instrumented arms inside the shared codegen are gone too. Invoke it as `cli_main_compile_only`. |

Of the release assets, `vibe-compiler-<tag>.wasm` is the adopted seed itself
(a past stage2), published by `scripts/build_release_assets.sh` /
`scripts/build_seed_release_assets.sh`; `vibe-cli-<tag>.wasm` is the stage2 of
the release's own source (see "Release tags and artifacts").

### `vibe.abi` custom section contract

The compiler's codegen
(`lib/@vibe/compiler/codegen/wasm_emit/metadata.vibe::emit_vibe_abi_custom_section`)
embeds a custom section `vibe.abi` in **every program wasm it generates** —
including the compiler binary itself, since that is the compiler compiling
itself.

```
section id 0 (custom), name "vibe.abi", payload:
  version=1
  host_import_abi=<abi>
```

- `version` is the section layout version.
- `host_import_abi` corresponds to the runner layer's host-import selection
  (`VIBE_IMPORT_ABI`; `raw` today). The runner chooses how to resolve imports
  from this value; `scripts/generations.sh` reads it from each compiler wasm it
  runs when `VIBE_IMPORT_ABI` is unset.
- Whichever generation compiles a program (seed, stage1 or stage2), **the
  program's `vibe.abi` must be identical** — that is the ABI contract.
  Behavioural agreement between generations is what the stage3 == stage2 check
  guarantees.
