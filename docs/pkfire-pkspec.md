# pkfire / pkspec

[`pkfire`](https://github.com/mizchi/pkfire) (typed task runner with
content-addressed caching) is the **canonical task runner** for vibe-lang —
it replaces the former `justfile`. [`pkspec`](https://github.com/mizchi/pkspec)
(language-agnostic test runner) is wired in as an opt-in companion alongside
`moon test` / `flaker run`.

The task definitions live in `Taskfile.pkl` (238 tasks). Multi-line
shell that doesn't fit a single Pkl `cmd =` lives in `scripts/pkfire/*.sh`
and is invoked directly. CI runs every job through `pkf run …` with
`~/.cache/pkfire` persisted via `actions/cache` so unchanged subgraphs are
cache hits.

## Install

The repo's `nix develop` shell ships `pkgs.pkl`. pkfire / pkspec binaries
are not in nixpkgs — install them via:

```bash
# Nix (uses the upstream flake)
nix run github:mizchi/pkfire -- list
nix run github:mizchi/pkspec -- --help

# go install (needs the Pkl CLI on PATH for pkfire)
go install github.com/mizchi/pkfire/cmd/pkf@latest
go install github.com/mizchi/pkspec/cmd/...@latest
```

CI uses the `mizchi/pkfire@v0.10.0` and `mizchi/pkspec@v0.2.0` composite
actions via `.github/actions/setup-vibe` (set `pkfire: 'true'` on the
caller). Pass `pkfire-cache: 'true'` to also hydrate `~/.cache/pkfire`.

## pkfire — `Taskfile.pkl`

`Taskfile.pkl` mirrors **every** recipe from the `justfile`
(238 tasks: 206 from justfile + 32 generated per-package test tasks).
Simple recipes are inlined; complex multi-line shell stays in the
justfile and is invoked via `just <name>` so the canonical body
doesn't fork.

Highlights:

| Task           | Behaviour                      | Notes                                |
|----------------|--------------------------------|--------------------------------------|
| `fmt`          | `moon fmt`                     | not cached (mutates source files)    |
| `info`         | `moon info`                    | outputs `**/*.mbti`                  |
| `check`        | `moon check --deny-warn …`     | cached on source-tree hash           |
| `test`         | `just test` (12-line recipe)   | wrapped — too tangled to inline      |
| `test-update`  | `moon test --update`           | not cached (refreshes snapshots)     |
| `run`          | `moon run … src/cmd/vibe -- $@`| `acceptsArgs` — pass via `--`        |
| `release-check`| aggregate (typed deps)         | fmt + info + check + test + vibe-normalize + bundle-size + 15 selfhost gates |

Two helper factories keep the file readable:

- `justTask(name)` — wraps a recipe whose body stays in the justfile
- `scriptTask(name, "scripts/X.sh")` — wraps a single-shell-script recipe

Run from the repo root:

```bash
pkf list
pkf run check
pkf run test
pkf run run -- examples/hello.vibe
pkf graph --format tree
pkf run --explain-cache check
```

The cache lives in `~/.cache/pkfire` (global, per-user); `.pkfire/` in the
repo is git-ignored as a fallback.

### Why bother when `just` works?

- **Typed deps**: `deps { check }` is a Pkl value, not a string — typos fail
  at evaluation time.
- **Content-addressed cache**: re-running `pkf run check` after a no-op edit
  is a cache hit; `just check` always re-invokes `moon`.
- **`pkf affected --since=origin/main`**: cheap PR-diff aware runs.

For one-off shell tasks, `just <recipe>` is still the right choice — the
pkfire Taskfile only mirrors the common entry points.

### Differential test execution

`Taskfile.pkl` generates one task per moon package under `src/`
(`test:parser`, `test:checker`, `test:cmd-vibe`, …) whose `inputs` are
scoped to that package's directory. Combine with pkfire's `affected` query
and a `test:*` glob target to run only the packages whose files changed:

```bash
# vs a git ref (e.g. PR base)
pkf affected --since=origin/main 'test:*'

# explicit file list (CI helpers, scripts, hooks)
pkf affected --files="$(git diff --name-only origin/main | paste -sd,)" 'test:*'

# preview only — no commands run
pkf affected --since=origin/main --dry-run --explain 'test:*'

# full sweep, cache reuse for unchanged packages
pkf run 'test:*'
```

The `'test:*'` glob is important: without it, `pkf affected` also pulls in
wide-scope tasks (`check`, `test`, `release-check`, …) whose inputs cover
all of `src/`. Names flatten `/` to `-` (e.g. `test:cmd-vibe` for
`mizchi/vibe/cmd/vibe`) so a single glob covers all 32 packages.

`pkf` treats each `moon test -p` as a black box; cross-package dep
tracking (parser change → checker tests need rerun) is handled inside
moon, not by pkfire. For the final pre-commit sweep, fall back to
`just test` or `pkf run test`.

## pkspec — `pkspec/VibeTest.pkl`

`pkspec/VibeTest.pkl` declares two tests that shell out to `moon test`
(native and JS targets) so the run can be driven with pkspec's sharding,
retry, and rerun-failed flags. It amends `./Test.pkl` from the generated
schemas. (`adapters/MoonTest.pkl` is for native `moon test` discovery /
batching — not needed for this thin wrapper, but available if you want
to switch to discovery-driven runs later.)

### One-time bootstrap

The schemas under `pkspec/` (`Test.pkl`, `Spec.pkl`, `Adapter.pkl`,
`adapters/MoonTest.pkl`, …) are **not** checked in — they are generated by
`pkspec init` and live alongside `VibeTest.pkl`:

```bash
pkspec init --dir pkspec
```

Run that once after cloning. The hand-maintained file is
`pkspec/VibeTest.pkl`; everything else under `pkspec/` is git-ignored
(see `pkspec/.gitignore`).

### Running

```bash
pkspec exec -f pkspec/VibeTest.pkl
pkspec exec -f pkspec/VibeTest.pkl --shard=2/4
pkspec exec -f pkspec/VibeTest.pkl --rerun-failed
pkspec exec -f pkspec/VibeTest.pkl --only moon-test-native
```

### When to reach for it vs `flaker run`

- **`flaker run`** — preferred for local dev: affected-test selection,
  history-aware sampling, 120 s budget.
- **`pkspec exec`** — useful when you want sharding across multiple
  machines, deterministic retry policy, or pkspec's spec-coverage reporting
  (`pkspec check`, `pkspec coverage`).
- **`just test`** — full sweep before commit / on CI.

## Spec gate (`pkspec/VibeSpec.pkl`)

`pkspec/VibeSpec.pkl` declares high-level goals (e.g. `GOAL.test-coverage`)
and the scenarios (`VIBE-TEST-NATIVE`, `VIBE-TEST-JS`) that `VibeTest.pkl`
implements. The `.github/workflows/pkfire-pkspec.yml` workflow runs
`pkspec check` on every PR that touches `pkfire/` or `pkspec/`, which fails
if a declared spec loses its implementation. Useful queries:

```bash
pkspec check pkspec/VibeSpec.pkl pkspec/VibeTest.pkl     # CI gate
pkspec coverage pkspec/VibeSpec.pkl pkspec/VibeTest.pkl  # %
pkspec next pkspec/VibeSpec.pkl pkspec/VibeTest.pkl      # unimpl by priority
pkspec goals pkspec/VibeSpec.pkl pkspec/VibeTest.pkl
```

## Status

Experimental. The main CI lane (`just` / `moon test` / `flaker`) is
untouched. `.github/workflows/pkfire-pkspec.yml` is a separate, scoped
informational job that only runs when `pkfire/` or `pkspec/` change, and is
marked `continue-on-error: true` so it never blocks merges. Promoting to a
gating job is a follow-up — track in `TODO.md` if you take it on.
