# pkfire / pkspec

[`pkfire`](https://github.com/mizchi/pkfire) (typed task runner with
content-addressed caching) is the **canonical task runner** for vibe-lang —
it replaces the former `justfile`.

[`pkspec`](https://github.com/mizchi/pkspec) is not currently wired into the
task graph. `pkspec/VibeSpec.pkl` / `VibeTest.pkl` — a spec↔test coverage
companion tool — were removed: they were never consumed by `pkf run test` /
`test-local` / any CI job beyond a standalone `pkspec check`/`coverage` step,
and had sat unused since they were added. `pkspec/Packages.pkl` (the former
canonical MoonBit package list, imported by `Taskfile.pkl` to generate one
`test:<pkg>` task per `src/` package) was also removed (#881): those tasks
targeted the retired MoonBit host's `src/` tree (#594) and could never run
after the selfhost-only cutover. If a spec-coverage gate or per-package
differential testing is wanted again, re-run `pkspec init --dir pkspec` and
re-author against the current `lib/@vibe/*` layout rather than resurrecting
the old files.

The task definitions live in `Taskfile.pkl` (238 tasks). Multi-line
shell that doesn't fit a single Pkl `cmd =` lives in `scripts/pkfire/*.sh`
and is invoked directly. CI runs every job through `pkf run …` with
`~/.cache/pkfire` persisted via `actions/cache` so unchanged subgraphs are
cache hits.

## Install

The repo's `nix develop` shell ships `pkgs.pkl`. The pkfire binary is not
in nixpkgs — install it via:

```bash
# Nix (uses the upstream flake)
nix run github:mizchi/pkfire -- list

# go install (needs the Pkl CLI on PATH for pkfire)
go install github.com/mizchi/pkfire/cmd/pkf@latest
```

CI uses the `mizchi/pkfire@v0.10.0` composite action via
`.github/actions/setup-vibe` (set `pkfire: 'true'` on the caller). Pass
`pkfire-cache: 'true'` to also hydrate `~/.cache/pkfire`.

## pkfire — `Taskfile.pkl`

`Taskfile.pkl` is the sole source of task definitions (the former `justfile`
was retired). Simple recipes are inlined via `cmd = …`; complex multi-line
shell lives in `scripts/pkfire/*.sh` (or other `scripts/*.sh`) and is invoked
directly.

Highlights (post-#594 selfhost-only):

| Task           | Behaviour                          | Notes                                |
|----------------|------------------------------------|--------------------------------------|
| `fmt`          | `true` (no-op placeholder)         | selfhost fmt 未移植 (#594)           |
| `test`         | `bash scripts/compiler_gate.sh`| selfhost operation gate — commit 前の主チェック |
| `test-local`   | affected tests via `flaker`        | fast inner loop                      |
| `run`          | `bash scripts/vibe_run.sh $@`      | `acceptsArgs` — pass via `--`        |
| `release-check`| `deps { compiler-gate }`           | moon-free sign-off: bundle/module-source sync + seed→stage1→stage2→stage3 fixpoint + compile/run validation |
| `info` / `check` / `test-update` | legacy `moon …`  | MoonBit host 依存で #594 以降は無効。検証は `test` / `release-check` / `vibe diagnostics` を使う |

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

For one-off shell tasks, `just <recipe>` is still the right choice — the
pkfire Taskfile only mirrors the common entry points.

Diff-aware, affected-only test selection for the selfhost `.vibe` tree is
`pkf run test-local` (the `flaker`-driven `--profile local` affected
strategy — see CLAUDE.md), not `pkf affected`: the per-`src/`-package
`test:<pkg>` targets that `pkf affected … 'test:*'` used to select were
removed (#881) along with the retired MoonBit host (#594).

## git hooks (`pkf hooks`)

`pkf hooks install` writes `.git/hooks/*` shims that delegate to
`pkf run <hook-name>` — pkfire binds a git hook to the task whose name
matches the hook (e.g. the `pre-commit` task).

This repo ships a **`pre-commit`** task that runs
`scripts/pkfire/precommit_fmt.sh`: it `moon fmt`s the staged `.mbt` files and
re-stages them, so every commit lands formatted. Hooks live under `.git/`
(not version-controlled), so each clone must opt in once:

```bash
pkf hooks install      # wire .git/hooks → pkf run
pkf hooks list         # show which hooks are installed / declared
pkf hooks uninstall    # remove the shims
```

## Status

`pkspec/` no longer has anything wired into the task graph — `Packages.pkl`
was removed along with the `test:<pkg>` tasks it generated (#881). The
`.github/workflows/pkfire-pkspec.yml` workflow now only runs
`pkf format --check` + `pkf lint` — both required (no
`continue-on-error`), sub-10s per PR.
